#!/usr/bin/env bash
# 增量对抗审查入口（pre-commit 主消费者）
# Usage: review-diff.sh [--ref=<git-ref>] [--scope=<auto|files|deepest-common>] [--config=<path>]
set -euo pipefail

# 重入保护
if [[ "${AIREVIEW_RUNNING:-}" == "1" ]]; then
  exit 0
fi
export AIREVIEW_RUNNING=1
export AIREVIEW_NO_FIX=1   # review-diff 永远不自动改代码
export AIREVIEW_TRIGGER="review-diff"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIB_DIR="$SCRIPT_DIR/lib"
export TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"

source "$LIB_DIR/severity.sh"
source "$LIB_DIR/skip_paths.sh"
source "$LIB_DIR/diff_sizing.sh"
source "$LIB_DIR/target_infer.sh"
source "$LIB_DIR/config.sh"

# ===== 错误信息打印工具 =====
die() {
  local cat="$1" reason="$2" fix="$3" log="${4:-}"
  cat >&2 <<EOF
✗ adversarial-review: $cat
  reason: $reason
  fix:    $fix
  log:    ${log:-(none)}
EOF
  exit "${5:-2}"
}

# shellcheck disable=SC2317
die_arg() { die "usage" "$1" "see review-diff.sh --help" "" 2; }

# ===== 参数解析 =====
REF=""
SCOPE=""
CFG_FILE="$PWD/.adversarial-review.yaml"

for arg in "$@"; do
  case "$arg" in
    --ref=*)    REF="${arg#*=}" ;;
    --scope=*)  SCOPE="${arg#*=}" ;;
    --config=*) CFG_FILE="${arg#*=}" ;;
    -h|--help)  sed -n '3,5p' "$0"; exit 0 ;;
    *)          die_arg "unknown arg: $arg" ;;
  esac
done

# ===== 配置加载 =====
config_load "$CFG_FILE" || die "config" "cannot load $CFG_FILE" "create from examples/adversarial-review.yaml.example"

REF="${REF:-$(config_get_default .diff.default_ref --cached)}"
SCOPE="${SCOPE:-$(config_get_default .diff.scope_strategy auto)}"
MAX_LINES=$(config_get_default .diff.max_diff_lines 500)
LOG_FILE=$(config_get_default .log.file docs/adversarial-review-log.md)
RUN_DIR=$(config_get_default .log.run_dir .adversarial-runs)
FAIL_ON=$(config_get_default .policy.fail_on_severity high)
STRICT_ERR=$(config_get_default .policy.strict_on_error false)

# ===== 依赖体检 =====
for bin in claude codex git yq envsubst flock timeout; do
  command -v "$bin" >/dev/null || die "missing dependency" "'$bin' not found in PATH" "install $bin"
done

# ===== 必须在 git 仓库 =====
git rev-parse --show-toplevel >/dev/null 2>&1 || die "git" "not inside a git repository" "run inside a git checkout"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# ===== Diff 文件列表 =====
TS=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$RUN_DIR"
DIFF_FILE="$RUN_DIR/diff-${TS}.patch"
NAME_FILE="$RUN_DIR/diff-files-${TS}.txt"

# shellcheck disable=SC2086
git diff $REF --name-only > "$NAME_FILE"
# shellcheck disable=SC2086
git diff $REF > "$DIFF_FILE"

# 空 diff
if [[ ! -s "$NAME_FILE" ]]; then
  exit 3
fi

# 全 skip_paths
SKIP_ARGS=()
while IFS= read -r p; do
  [[ -n "$p" ]] && SKIP_ARGS+=("$p")
done < <(config_get_array .diff.skip_paths)
if [[ ${#SKIP_ARGS[@]} -gt 0 ]]; then
  if all_paths_skipped "$NAME_FILE" "${SKIP_ARGS[@]}"; then
    exit 3
  fi
fi

# 超 max_diff_lines
if ! diff_size_ok "$DIFF_FILE" "$MAX_LINES"; then
  echo "diff > $MAX_LINES lines; use scripts/review-target.sh <name> instead" >&2
  exit 3
fi

# ===== Partial staging 检测（spec §7.5）=====
AUTO_STASH=$(config_get_default .diff.auto_stash_unstaged false)
HAS_UNSTAGED=0
while IFS= read -r sf; do
  [[ -z "$sf" ]] && continue
  if [[ -f "$sf" ]] && ! git diff --quiet -- "$sf" 2>/dev/null; then
    HAS_UNSTAGED=1; break
  fi
done < "$NAME_FILE"

if [[ "$HAS_UNSTAGED" -eq 1 ]]; then
  if [[ "$AUTO_STASH" == "true" ]]; then
    git stash push --keep-index --include-untracked --quiet -m "aireview-${TS}" || true
    trap 'git stash pop --quiet 2>/dev/null || true' EXIT
  else
    echo "⚠ adversarial-review: staged files have additional unstaged changes" >&2
    echo "  LLM sees --cached diff, which may not match committed code" >&2
    echo "  set diff.auto_stash_unstaged=true to auto-isolate" >&2
  fi
fi

# ===== 推断 TARGET =====
TARGET=$(target_from_diff "$NAME_FILE" "$SCOPE")

# ===== 启动合议 =====
source "$LIB_DIR/quorum.sh"

# trap SIGINT
# shellcheck disable=SC2317
on_signal() {
  local sig="$1"
  log_append "$LOG_FILE" "$RUN_DIR" "$(printf '## %s TARGET=%s\n- 状态: INTERRUPTED (%s)\n- staged: %s\n' "$(date +%F)" "$TARGET" "$sig" "$(tr '\n' ' ' < "$NAME_FILE")")"
  exit 130
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

set +e
JSON=$(quorum_run "$TARGET" "$REPO_ROOT" "$RUN_DIR")
QRC=$?
set -e

# ===== 失败路径 =====
if [[ "$QRC" -ne 0 ]] || [[ -z "$JSON" ]] || ! echo "$JSON" | yq eval -P '.' - >/dev/null 2>&1; then
  log_append "$LOG_FILE" "$RUN_DIR" "$(printf '## %s TARGET=%s\n- 状态: FAILED (rc=%s)\n- 详情: see %s\n' "$(date +%F)" "$TARGET" "$QRC" "$RUN_DIR")"
  if [[ "$STRICT_ERR" == "true" ]]; then
    die "llm" "quorum failed (rc=$QRC)" "see $RUN_DIR" "$RUN_DIR" 2
  fi
  exit 0
fi

# ===== 解析 verdict =====
HIGHEST=$(echo "$JSON" | yq eval '.highest_severity // "none"' -)
LOG_ENTRY_PATH=$(echo "$JSON" | yq eval '.log_entry_path // ""' -)

# 追加日志（每次都留痕）
if [[ -n "$LOG_ENTRY_PATH" && -f "$LOG_ENTRY_PATH" ]]; then
  log_append "$LOG_FILE" "$RUN_DIR" "$(cat "$LOG_ENTRY_PATH")"
else
  log_append "$LOG_FILE" "$RUN_DIR" "$(printf '## %s TARGET=%s — OK 留痕（无发现）\n' "$(date +%F)" "$TARGET")"
fi

# ===== 阈值判定 =====
if severity_ge "$HIGHEST" "$FAIL_ON"; then
  echo "✗ adversarial-review: blocked by $HIGHEST finding (threshold=$FAIL_ON)" >&2
  echo "  see $LOG_FILE for verdict table" >&2
  exit 1
fi

exit 0
