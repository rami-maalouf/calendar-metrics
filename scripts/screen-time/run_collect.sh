#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/collect_$(date +%Y%m%d_%H%M%S).log"

PYTHON_BIN="$SCRIPT_DIR/.venv/bin/python3"
if [[ ! -x "$PYTHON_BIN" ]]; then
  if [[ -x /usr/local/bin/python3.13 ]]; then
    PYTHON_BIN=/usr/local/bin/python3.13
  else
    PYTHON_BIN=/usr/bin/python3
  fi
fi

export AW_IMPORT_BIN="${AW_IMPORT_BIN:-$SCRIPT_DIR/.venv/bin/aw-import-screentime}"

cd "$SCRIPT_DIR"
{
  echo "=== screen time collect $(date -Iseconds) ==="
  echo "python=$PYTHON_BIN aw=$AW_IMPORT_BIN"
  "$PYTHON_BIN" "$SCRIPT_DIR/collect_iphone_screentime.py" "$@"
  echo "=== done $(date -Iseconds) ==="
} 2>&1 | tee -a "$LOG_FILE"

# keep last 20 logs
ls -t "$LOG_DIR"/collect_*.log 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true
