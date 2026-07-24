#!/usr/bin/env python3
"""collect iphone App.InFocus usage from biome and post a daily rollup to convex."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

MAX_EVENT_SECONDS = 6 * 60 * 60
CAP_EVENT_SECONDS = 3 * 60 * 60
TOP_APPS = 8


def load_dotenv(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        os.environ.setdefault(key, value)


def require_env_str(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"missing required env: {name}")
    return value


def local_offset_minutes(when: datetime) -> int:
    if when.tzinfo is None:
        when = when.astimezone()
    offset = when.utcoffset()
    if offset is None:
        return 0
    return int(offset.total_seconds() // 60)


def day_key_for(when: datetime) -> str:
    return when.astimezone().strftime("%Y-%m-%d")


def parse_day(day: str) -> datetime:
    return datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=timezone.utc).astimezone()


def format_hours(seconds: float) -> str:
    hours = seconds / 3600.0
    if hours >= 10:
        return f"{hours:.0f}h"
    if hours >= 1:
        return f"{hours:.1f}h"
    return f"{int(round(seconds / 60.0))}m"


def build_notification_body(day: str, total_seconds: float, top_apps: list[dict]) -> str:
    parts = [f"{row['title']} {format_hours(row['seconds'])}" for row in top_apps[:3]]
    suffix = f" · {' · '.join(parts)}" if parts else ""
    return f"{day} on iPhone: {format_hours(total_seconds)}{suffix}"


def resolve_aw_bin() -> Path:
    configured = os.environ.get("AW_IMPORT_BIN", "").strip()
    if configured:
        path = Path(configured).expanduser()
        if path.exists():
            return path
        raise SystemExit(f"AW_IMPORT_BIN not found: {path}")

    candidates = [
        Path(__file__).resolve().parent / ".venv" / "bin" / "aw-import-screentime",
        Path("/tmp/aw-screentime/aw-import-screentime/.venv/bin/aw-import-screentime"),
    ]
    for path in candidates:
        if path.exists():
            return path
    raise SystemExit(
        "aw-import-screentime not found. install into scripts/screen-time/.venv "
        "or set AW_IMPORT_BIN."
    )


def biome_home_env(biome_dir: Path | None) -> dict[str, str]:
    env = os.environ.copy()
    if biome_dir is None:
        return env
    biome_dir = biome_dir.expanduser().resolve()
    if not biome_dir.exists():
        raise SystemExit(f"BIOME_HOME not found: {biome_dir}")
    fake_home = Path("/tmp/intent-biome-home")
    library = fake_home / "Library"
    library.mkdir(parents=True, exist_ok=True)
    target = library / "Biome"
    if target.is_symlink() or target.exists():
        if target.is_symlink() or target.is_file():
            target.unlink()
        else:
            # leave real dir alone; replace symlink only
            pass
    if not target.exists():
        target.symlink_to(biome_dir, target_is_directory=True)
    elif not target.is_symlink():
        raise SystemExit(f"refusing to replace non-symlink path: {target}")
    else:
        target.unlink()
        target.symlink_to(biome_dir, target_is_directory=True)
    env["HOME"] = str(fake_home)
    return env


def fetch_events(aw_bin: Path, since_days: int, biome_dir: Path | None) -> list[dict]:
    env = biome_home_env(biome_dir)
    env["NO_COLOR"] = "1"
    env["TERM"] = "dumb"
    env["CLICOLOR"] = "0"
    env["FORCE_COLOR"] = "0"
    result = subprocess.run(
        [str(aw_bin), "events", "preview", "--since", f"{since_days}d"],
        capture_output=True,
        text=True,
        env=env,
        timeout=300,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(
            f"aw-import-screentime failed ({result.returncode}): {result.stderr[:800]}"
        )
    stdout = result.stdout.strip()
    # strip ansi color codes if the cli still emits them
    stdout = re.sub(r"\x1b\[[0-9;]*m", "", stdout)
    if not stdout:
        raise SystemExit(
            f"aw-import-screentime returned empty stdout. stderr={result.stderr[:800]}"
        )
    # if logs leaked onto stdout, keep from first json array
    start = stdout.find("[")
    if start > 0:
        stdout = stdout[start:]
    payload = json.loads(stdout)
    events: list[dict] = []
    for device in payload:
        device_id = device.get("device_id") or "unknown"
        for event in device.get("events") or []:
            event = dict(event)
            event["_device_id"] = device_id
            events.append(event)
    return events


def clean_events(events: list[dict]) -> tuple[list[dict], int]:
    cleaned: list[dict] = []
    dropped = 0
    for event in events:
        duration = float(event.get("duration_seconds") or 0)
        data = event.get("data") or {}
        app = (data.get("app") or "").strip()
        if not app or duration <= 0:
            dropped += 1
            continue
        if duration > MAX_EVENT_SECONDS:
            dropped += 1
            continue
        duration = min(duration, CAP_EVENT_SECONDS)
        title = (data.get("title") or app).strip() or app
        start = datetime.fromisoformat(event["timestamp"].replace("Z", "+00:00"))
        cleaned.append(
            {
                "device_id": event["_device_id"],
                "app": app,
                "title": title,
                "start": start,
                "duration": duration,
            }
        )
    return cleaned, dropped


def allocate_day(
    events: list[dict],
    day: str,
    tz_offset_minutes: int,
) -> dict | None:
    app_seconds: dict[str, float] = defaultdict(float)
    app_titles: dict[str, str] = {}
    hour_seconds = [0.0] * 24
    hour_apps: list[dict[str, float]] = [defaultdict(float) for _ in range(24)]
    hour_titles: list[dict[str, str]] = [{} for _ in range(24)]
    kept_events = 0
    kept_slices = 0

    offset = timedelta(minutes=tz_offset_minutes)
    day_start_local = datetime.strptime(day, "%Y-%m-%d")
    # interpret day boundaries in the requested offset
    day_start = datetime(
        day_start_local.year,
        day_start_local.month,
        day_start_local.day,
        tzinfo=timezone(offset),
    )
    day_end = day_start + timedelta(days=1)

    for event in events:
        start = event["start"]
        end = start + timedelta(seconds=event["duration"])
        # clip to day
        clip_start = max(start, day_start)
        clip_end = min(end, day_end)
        if clip_end <= clip_start:
            continue

        kept_events += 1
        remaining_start = clip_start
        while remaining_start < clip_end:
            local = remaining_start.astimezone(timezone(offset))
            hour_of_day = local.hour
            next_hour = local.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1)
            next_hour_utc = next_hour.astimezone(timezone.utc)
            slice_end = min(clip_end, next_hour_utc)
            seconds = (slice_end - remaining_start).total_seconds()
            if seconds <= 0:
                break

            kept_slices += 1
            app = event["app"]
            title = event["title"]
            app_seconds[app] += seconds
            app_titles[app] = title
            hour_seconds[hour_of_day] += seconds
            hour_apps[hour_of_day][app] += seconds
            hour_titles[hour_of_day][app] = title
            remaining_start = slice_end

    total_seconds = sum(app_seconds.values())
    if total_seconds <= 0:
        return None

    apps = sorted(
        (
            {
                "bundleId": app,
                "title": app_titles[app],
                "seconds": round(seconds, 3),
            }
            for app, seconds in app_seconds.items()
        ),
        key=lambda row: row["seconds"],
        reverse=True,
    )
    top_apps = apps[:TOP_APPS]

    hours = []
    for hour_of_day, total in enumerate(hour_seconds):
        if total <= 0:
            continue
        hour_start = day_start + timedelta(hours=hour_of_day)
        top = sorted(
            (
                {
                    "bundleId": app,
                    "title": hour_titles[hour_of_day][app],
                    "seconds": round(seconds, 3),
                }
                for app, seconds in hour_apps[hour_of_day].items()
            ),
            key=lambda row: row["seconds"],
            reverse=True,
        )[:TOP_APPS]
        hours.append(
            {
                "hourOfDay": hour_of_day,
                "hourStartMs": int(hour_start.timestamp() * 1000),
                "totalSeconds": round(total, 3),
                "topApps": top,
            }
        )

    device_id = "unknown"
    for event in events:
        start = event["start"]
        end = start + timedelta(seconds=event["duration"])
        if end > day_start and start < day_end:
            device_id = event["device_id"]
            break

    return {
        "dayKey": day,
        "sourceDeviceId": device_id,
        "platform": "iphone",
        "totalSeconds": round(total_seconds, 3),
        "eventCount": kept_events,
        "cleanedEventCount": kept_slices,
        "topApps": top_apps,
        "apps": apps,
        "hourlyTotals": [round(value, 3) for value in hour_seconds],
        "hours": hours,
        "timeZoneOffsetMinutes": tz_offset_minutes,
        "notificationBody": build_notification_body(day, total_seconds, top_apps),
    }


def post_json(url: str, body: dict) -> dict:
    # use curl so we inherit the system trust store (python.org installs often miss certs)
    result = subprocess.run(
        [
            "/usr/bin/curl",
            "-sS",
            "-X",
            "POST",
            url,
            "-H",
            "content-type: application/json",
            "--data-binary",
            "@-",
            "--max-time",
            "60",
            "-w",
            "\n%{http_code}",
        ],
        input=json.dumps(body),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"ingest curl failed: {result.stderr[:800]}")
    text = result.stdout.rsplit("\n", 1)
    payload = text[0] if len(text) == 2 else result.stdout
    status = text[1] if len(text) == 2 else "?"
    if not status.startswith("2"):
        raise SystemExit(f"ingest failed ({status}): {payload[:800]}")
    return json.loads(payload)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--day", help="local day YYYY-MM-DD (default: yesterday)")
    parser.add_argument(
        "--backfill-days",
        type=int,
        help="ingest each of the last N local days (includes today when N>0)",
    )
    parser.add_argument("--since-days", type=int, default=21)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--biome-home", help="path to Biome directory dump")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    load_dotenv(script_dir / ".env")

    now_local = datetime.now().astimezone()
    if args.backfill_days is not None:
        if args.backfill_days < 1:
            raise SystemExit("--backfill-days must be >= 1")
        day_keys = [
            (now_local - timedelta(days=offset)).date().isoformat()
            for offset in range(args.backfill_days)
        ]
    elif args.day:
        day_keys = [args.day]
    else:
        day_keys = [(now_local - timedelta(days=1)).date().isoformat()]

    biome_home = args.biome_home or os.environ.get("BIOME_HOME") or None
    biome_dir = Path(biome_home) if biome_home else None

    aw_bin = resolve_aw_bin()
    print(f"[collect] days={day_keys} aw={aw_bin}")
    raw_events = fetch_events(aw_bin, args.since_days, biome_dir)
    cleaned, dropped = clean_events(raw_events)
    print(f"[collect] events raw={len(raw_events)} cleaned={len(cleaned)} dropped={dropped}")

    base_url = require_env_str("CONVEX_SITE_URL").rstrip("/")
    device_id = require_env_str("INTENT_DEVICE_ID")
    device_secret = require_env_str("INTENT_DEVICE_SECRET")
    ingested = 0

    for day in day_keys:
        tz_offset = local_offset_minutes(parse_day(day))
        payload = allocate_day(cleaned, day, tz_offset)
        if payload is None:
            print(f"[collect] skip {day}: no cleaned iphone usage")
            continue

        print(
            f"[collect] {day} total={format_hours(payload['totalSeconds'])} "
            f"apps={len(payload['apps'])} hours={len(payload['hours'])}"
        )
        print(f"[collect] notification: {payload['notificationBody']}")

        if args.dry_run:
            print(json.dumps(payload, indent=2)[:2000])
            ingested += 1
            continue

        body = {
            "deviceId": device_id,
            "deviceSecret": device_secret,
            **payload,
        }
        result = post_json(f"{base_url}/intent/device/screen/ingest", body)
        print(json.dumps(result, indent=2)[:1500])
        ingested += 1

    if ingested == 0:
        raise SystemExit("no cleaned iphone usage for requested days")
    print(f"[collect] done ingested={ingested}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
