# iPhone screen time sync

Daily Mac collector reads Biome `App.InFocus` (phone usage synced to the Mac), cleans it, upserts into Convex with **daily + hourly** rollups, and Intent iOS shows a local notification with the summary.

## What gets stored

- `intentScreenDays` - one row per day (totals, top apps, 24-slot `hourlyTotals`, notification text)
- `intentScreenAppDays` - per-app seconds for the day
- `intentScreenHours` - per local hour (0-23) with top apps in that hour

Cleaning:

- drop events longer than 6h (stuck sessions)
- cap remaining events at 3h
- split durations across hour boundaries

## One-time setup

### 1. Full Disk Access

Grant **Full Disk Access** to Terminal (and `/bin/bash` if using launchd) so live `~/Library/Biome` is readable.

System Settings → Privacy & Security → Full Disk Access.

### 2. Install aw-import-screentime

```bash
cd scripts/screen-time
/usr/local/bin/python3.13 -m venv .venv
.venv/bin/pip install 'ccl-segb @ git+https://github.com/cclgroupltd/ccl-segb.git'
.venv/bin/pip install 'aw-import-screentime @ git+https://github.com/ActivityWatch/aw-import-screentime.git'
```

### 3. Env

```bash
cp scripts/screen-time/.env.example scripts/screen-time/.env
# fill CONVEX_SITE_URL, INTENT_DEVICE_ID, INTENT_DEVICE_SECRET
```

Use the same device pair as Intent iOS/Mac.

### 4. Dry-run (optional dump)

```bash
cd scripts/screen-time
BIOME_HOME=/path/to/Biome AW_IMPORT_BIN=$PWD/.venv/bin/aw-import-screentime \
  python3 collect_iphone_screentime.py --day 2026-07-22 --dry-run --biome-home /path/to/Biome
```

### 5. Ingest yesterday

```bash
./run_collect.sh
# or
python3 collect_iphone_screentime.py
```

### 6. launchd (morning)

Edit `com.orbitlabs.intent.screentime.plist`, replace `REPLACE_WITH_ABS_PATH`, then:

```bash
cp com.orbitlabs.intent.screentime.plist ~/Library/LaunchAgents/studio.orbitlabs.intent.screentime.plist
launchctl load ~/Library/LaunchAgents/studio.orbitlabs.intent.screentime.plist
```

## HTTP API

All require `deviceId` + `deviceSecret`.

| Route | Purpose |
|---|---|
| `POST /intent/device/screen/ingest` | Upsert one day + apps + hours |
| `POST /intent/device/screen/summary` | Latest (or `dayKey`) summary including hours |
| `POST /intent/device/screen/recent` | Recent day rollups for charts (shared across devices) |
| `POST /intent/device/screen/ack-notification` | Mark notification delivered |

Screen rows are stored under a shared owner (`intent_shared`) so Mac + iOS paired devices all see the same phone data.

## Phone notification

**Intent iOS:** Settings → **Screen Time Notification** (default `12:00 AM`).

- **AM** (before noon): notification is about the **previous** calendar day
- **PM** (noon and later): notification is about the **same** calendar day

At the chosen time the app schedules a local reminder. On launch / foreground after that fire, Intent fetches `/screen/summary` for the matching `dayKey`. If `notificationDeliveredAt` is null, it posts the detailed local notification and acks.

**Shortcuts (optional):** schedule a morning Shortcut that POSTs summary and uses “Show Notification” with `day.notificationBody` - useful if the app is not opened.

## Out of scope (for now)

- Mac knowledgeC
- Dayflow categories
- APNs remote push
