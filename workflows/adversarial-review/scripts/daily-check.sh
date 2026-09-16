#!/usr/bin/env bash
# 对账：检查今日日志条目数 ≥ EXPECTED；若 daily_check.enabled=false 直接 exit 0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIB_DIR="$SCRIPT_DIR/lib"
source "$LIB_DIR/config.sh"

CFG_FILE="${1:-$PWD/.adversarial-review.yaml}"
config_load "$CFG_FILE" || { echo "✗ config: $CFG_FILE" >&2; exit 2; }

ENABLED=$(config_get_default .daily_check.enabled false)
if [[ "$ENABLED" != "true" ]]; then
  echo "daily_check disabled in $CFG_FILE; exit 0"
  exit 0
fi

EXPECTED=$(config_get_default .daily_check.expected_entries 15)
LOG_FILE=$(config_get_default .log.file docs/adversarial-review-log.md)
TODAY=$(TZ=Asia/Shanghai date +%Y-%m-%d)

if [[ ! -f "$LOG_FILE" ]]; then
  echo "[$TODAY] ALERT: log file missing: $LOG_FILE"
  exit 1
fi

COUNT=$(grep -c "^## $TODAY " "$LOG_FILE" 2>/dev/null || echo 0)
if [[ "$COUNT" -lt "$EXPECTED" ]]; then
  echo "[$TODAY] ALERT entries=$COUNT/$EXPECTED"
  grep -A 4 "^## $TODAY " "$LOG_FILE" 2>/dev/null || true
  exit 1
fi

echo "[$TODAY] OK entries=$COUNT/$EXPECTED"
