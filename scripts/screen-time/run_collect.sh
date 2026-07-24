#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/collect_$(date +%Y%m%d_%H%M%S).log"

cd "$SCRIPT_DIR"
{
  echo "=== screen time collect $(date -Iseconds) ==="
  /usr/bin/env python3 "$SCRIPT_DIR/collect_iphone_screentime.py" "$@"
  echo "=== done $(date -Iseconds) ==="
} 2>&1 | tee -a "$LOG_FILE"

# keep last 20 logs
ls -t "$LOG_DIR"/collect_*.log 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true
