#!/bin/bash
# smoke: collect biome iphone usage and ingest into the configured convex deployment.
set -euo pipefail

REPO="/Users/rami/Documents/code/react-native/calendar-metrics"
BACKEND_ENV="$REPO/packages/backend/.env.local"
COLLECTOR_DIR="$REPO/scripts/screen-time"
COLLECTOR_ENV="$COLLECTOR_DIR/.env"

load_dotenv() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    local key="${line%%=*}"
    local val="${line#*=}"
    key="$(echo "$key" | xargs)"
    export "$key=$val"
  done < "$file"
}

load_dotenv "$BACKEND_ENV"
load_dotenv "$COLLECTOR_ENV"

SITE="${CONVEX_SITE_URL:-https://industrious-puffin-924.convex.site}"
SITE="${SITE%/}"

echo "=== health ($SITE) ==="
/usr/bin/curl -sS "$SITE/intent/health"
echo

if [[ -z "${INTENT_DEVICE_ID:-}" || -z "${INTENT_DEVICE_SECRET:-}" ]]; then
  if [[ -z "${INTENT_SETUP_KEY:-}" ]]; then
    echo "missing INTENT_DEVICE_* and INTENT_SETUP_KEY" >&2
    exit 1
  fi
  echo "=== bootstrap device ==="
  BOOT=$(/usr/bin/curl -sS -X POST "$SITE/intent/bootstrap" \
    -H 'content-type: application/json' \
    --data-binary "{\"setupKey\":\"$INTENT_SETUP_KEY\",\"deviceName\":\"screen-collector\",\"platform\":\"macos\",\"settings\":{\"autoStartFocus\":false,\"autoCompleteFocus\":false,\"autoShowReview\":false}}")
  echo "$BOOT" | /usr/bin/python3 -m json.tool
  INTENT_DEVICE_ID=$(echo "$BOOT" | /usr/bin/python3 -c 'import sys,json; print(json.load(sys.stdin)["device"]["deviceId"])')
  INTENT_DEVICE_SECRET=$(echo "$BOOT" | /usr/bin/python3 -c 'import sys,json; print(json.load(sys.stdin)["device"]["deviceSecret"])')
  cat > "$COLLECTOR_ENV" <<EOF
CONVEX_SITE_URL=$SITE
INTENT_DEVICE_ID=$INTENT_DEVICE_ID
INTENT_DEVICE_SECRET=$INTENT_DEVICE_SECRET
EOF
fi

echo "=== collect + ingest ==="
cd "$COLLECTOR_DIR"
export CONVEX_SITE_URL="$SITE"
export INTENT_DEVICE_ID INTENT_DEVICE_SECRET
AW_IMPORT_BIN="$PWD/.venv/bin/aw-import-screentime" /usr/local/bin/python3.13 collect_iphone_screentime.py

echo "=== summary ==="
/usr/bin/curl -sS -X POST "$SITE/intent/device/screen/summary" \
  -H 'content-type: application/json' \
  --data-binary "{\"deviceId\":\"$INTENT_DEVICE_ID\",\"deviceSecret\":\"$INTENT_DEVICE_SECRET\",\"includeHours\":true}" \
  | /usr/bin/python3 -c 'import sys,json; d=json.load(sys.stdin); day=d.get("day") or {}; print(json.dumps({"ok":d.get("ok"),"notificationBody":day.get("notificationBody"),"totalSeconds":day.get("totalSeconds"),"hourCount":len(day.get("hours") or []),"topApps":[a["title"] for a in (day.get("topApps") or [])[:5],"hourlyTotalsNonZero":sum(1 for x in (day.get("hourlyTotals") or []) if x>0)}, indent=2))'

echo SMOKE_DONE
