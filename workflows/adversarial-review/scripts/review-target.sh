#!/usr/bin/env bash
# 全包扫描对抗审查入口
# Usage: review-target.sh <target-name> [--workdir=<path>] [--config=<path>] [--no-fix] [--no-commit]
set -euo pipefail

if [[ "${AIREVIEW_RUNNING:-}" == "1" ]]; then
  exit 0
fi
export AIREVIEW_RUNNING=1
export AIREVIEW_TRIGGER="review-target"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIB_DIR="$SCRIPT_DIR/lib"
export TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"

source "$LIB_DIR/severity.sh"
source "$LIB_DIR/config.sh"

TARGET=""
WORKDIR=""
CFG_FILE="$PWD/.adversarial-review.yaml"
NO_FIX=0
NO_COMMIT=0

for arg in "$@"; do
  case "$arg" in
    --workdir=*) WORKDIR="${arg#*=}" ;;
    --config=*)  CFG_FILE="${arg#*=}" ;;
    --no-fix)    NO_FIX=1 ;;
    --no-commit) NO_COMMIT=1 ;;
    -h|--help)   sed -n '3,4p' "$0"; exit 0 ;;
    -*)          echo "unknown arg: $arg" >&2; exit 2 ;;
    *)           TARGET="$arg" ;;
  esac
done

[[ -n "$TARGET" ]] || { echo "✗ usage: review-target.sh <target-name>" >&2; exit 2; }

config_load "$CFG_FILE" || { echo "✗ config: $CFG_FILE" >&2; exit 2; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ not in a git repo" >&2; exit 2; }
cd "$REPO_ROOT"

# WORKDIR 自动定位
if [[ -z "$WORKDIR" ]]; then
  MAXDEPTH=$(config_get_default .repo.search_maxdepth 3)
  SEARCH_DIRS=()
  while IFS= read -r d; do [[ -n "$d" ]] && SEARCH_DIRS+=("$d"); done < <(config_get_array .repo.search_dirs)
  for d in "${SEARCH_DIRS[@]}"; do
    [[ -d "$REPO_ROOT/$d" ]] || continue
    found=$(find "$REPO_ROOT/$d" -maxdepth "$MAXDEPTH" -type d -name "$TARGET" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then WORKDIR="$found"; break; fi
  done
fi

[[ -n "$WORKDIR" && -d "$WORKDIR" ]] || { echo "✗ TARGET '$TARGET' not found under search_dirs" >&2; exit 2; }

[[ "$NO_FIX" -eq 1 ]] && export AIREVIEW_NO_FIX=1
[[ "$NO_COMMIT" -eq 1 ]] && export AIREVIEW_NO_COMMIT=1

LOG_FILE=$(config_get_default .log.file docs/adversarial-review-log.md)
RUN_DIR=$(config_get_default .log.run_dir .adversarial-runs)
FAIL_ON=$(config_get_default .policy.fail_on_severity high)
STRICT_ERR=$(config_get_default .policy.strict_on_error false)

mkdir -p "$RUN_DIR"
source "$LIB_DIR/quorum.sh"

set +e
JSON=$(quorum_run "$TARGET" "$WORKDIR" "$RUN_DIR")
QRC=$?
set -e

if [[ "$QRC" -ne 0 ]] || ! echo "$JSON" | yq eval -P '.' - >/dev/null 2>&1; then
  log_append "$LOG_FILE" "$RUN_DIR" "$(printf '## %s TARGET=%s\n- 状态: FAILED (rc=%s)\n' "$(date +%F)" "$TARGET" "$QRC")"
  [[ "$STRICT_ERR" == "true" ]] && exit 2
  exit 0
fi

HIGHEST=$(echo "$JSON" | yq eval '.highest_severity // "none"' -)
LOG_ENTRY_PATH=$(echo "$JSON" | yq eval '.log_entry_path // ""' -)
if [[ -n "$LOG_ENTRY_PATH" && -f "$LOG_ENTRY_PATH" ]]; then
  log_append "$LOG_FILE" "$RUN_DIR" "$(cat "$LOG_ENTRY_PATH")"
else
  log_append "$LOG_FILE" "$RUN_DIR" "$(printf '## %s TARGET=%s — OK 留痕（无发现）\n' "$(date +%F)" "$TARGET")"
fi

severity_ge "$HIGHEST" "$FAIL_ON" && exit 1
exit 0
