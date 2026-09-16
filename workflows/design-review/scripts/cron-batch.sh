#!/usr/bin/env bash
# design-review 每晚批量对抗审查 dispatcher（系统 cron 调用）
#
# 每整点跑一次：自顶向下、一次一篇地审 <REDESIGN_SUBDIR>/ 下 00*/01* 设计文档。
# 用 flock 全局锁 + 按「窗口日期」重置的游标：超时不重叠、不丢篇、不并发。
#
# 项目旋钮不写在本脚本里，而在 profile 目录的 profile.env（见 lib/profile.sh 的查找顺序）：
#   REPO=/path/to/repo            # 必填：被审仓库根
#   REDESIGN_SUBDIR=design        # 必填：设计文档子目录
#   MAX_ROUNDS=5                  # 可选：每篇最多轮次（env 可覆盖）
#   WINDOW_END_HOUR=7             # 可选：<= 该小时算作前一晚窗口（窗口跨午夜）
#   PARENT_DOC=01-core.md         # 可选：父级详设文件名，排在 00-* 之后、其余 01-* 之前
#
# 用法（cron 行）：
#   0 20-23,0-7 * * * /usr/bin/zsh -lc '<this>/cron-batch.sh <profile>'
#   注意：claude/codex 的 PATH 在 ~/.zshrc 里，而 `zsh -lc` 是非交互登录 shell
#   不 source .zshrc → 裸 cron 下二者都不在 PATH（探活秒退 exit 2）。故本脚本
#   不依赖 shell 模式，自己补齐 PATH + fnm（见下方 export 段）。
#
# 手动：
#   cron-batch.sh <profile>            # 跑当晚游标指向的下一篇并进位
#   cron-batch.sh <profile> --plan     # 只打印计划（窗口日期/游标/篇目/将执行的命令），不跑、不进位
#   MAX_ROUNDS=3 cron-batch.sh <profile>   # 临时覆盖最大轮次
#   THOTH_PROFILES=/path/to/profiles cron-batch.sh <profile>   # 指定 profile 根目录
#
# 退出码：0 正常（含跳过/当晚跑完）；1 配置错误（profile 不存在 / 旋钮缺失 / 仓库缺失）
set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts → design-review → workflows → Thoth
THOTH_HOME="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export THOTH_HOME

# 自给自足地补齐 LLM CLI 的 PATH —— 不依赖 ~/.zshrc（非交互 cron 不会 source 它）。
# claude 在 ~/.local/bin；codex/node 经 fnm 提供，需先把 fnm 自身放进 PATH 再 eval。
export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$SCRIPT_DIR:$PATH"
[ -d "$HOME/.local/share/fnm" ] && eval "$(fnm env 2>/dev/null || true)"

# root 下 claude 的 bypassPermissions / codex 的 bypass-sandbox 仅在 IS_SANDBOX=1 时放行。
# 该变量只在交互 shell 有（cron 的 zsh -lc 拿不到），否则 claude 报
# "--dangerously-skip-permissions cannot be used with root" 直接失败。本机即沙箱，显式补上。
export IS_SANDBOX="${IS_SANDBOX:-1}"

PROFILE="${1:-}"
MODE="${2:-run}"   # run | --plan

# ─── 项目配置：从 profile 目录的 profile.env 读 ─────────────────────
case "$PROFILE" in
  ""|-h|--help)
    echo "用法: cron-batch.sh <profile> [--plan]   (profile 目录含 profile.env，见 lib/profile.sh)" >&2
    exit 1 ;;
esac

# shellcheck source=lib/profile.sh
source "$SCRIPT_DIR/lib/profile.sh"
PROFILE_DIR="$(resolve_profile_dir "$PROFILE")" || {
    echo "未知 profile: $PROFILE（查找顺序: \$THOTH_PROFILES/design-review、~/.config/thoth/profiles/design-review、内置 profiles/）" >&2
    exit 1
}
[ -f "$PROFILE_DIR/profile.env" ] || { echo "profile 缺 profile.env: $PROFILE_DIR" >&2; exit 1; }
_ENV_MAX_ROUNDS="${MAX_ROUNDS:-}"   # 命令行 env 优先于 profile.env
# shellcheck source=/dev/null
source "$PROFILE_DIR/profile.env"
[ -n "${REPO:-}" ] || { echo "profile.env 缺 REPO: $PROFILE_DIR/profile.env" >&2; exit 1; }
[ -n "${REDESIGN_SUBDIR:-}" ] || { echo "profile.env 缺 REDESIGN_SUBDIR: $PROFILE_DIR/profile.env" >&2; exit 1; }
MAX_ROUNDS="${_ENV_MAX_ROUNDS:-${MAX_ROUNDS:-5}}"
WINDOW_END_HOUR="${WINDOW_END_HOUR:-7}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/design-review-cron"
LOG_DIR="$STATE_DIR/logs"
LOCK_FILE="$STATE_DIR/$PROFILE.lock"
CURSOR_FILE="$STATE_DIR/$PROFILE.cursor"
mkdir -p "$LOG_DIR"

# ─── 窗口日期：当前小时 <= WINDOW_END_HOUR 归入前一天的夜间窗口 ───────
HOUR=$((10#$(date +%H)))
if [ "$HOUR" -le "$WINDOW_END_HOUR" ]; then
    WINDOW_DATE="$(date -d 'yesterday' +%Y-%m-%d)"
else
    WINDOW_DATE="$(date +%Y-%m-%d)"
fi
LOG_FILE="$LOG_DIR/$WINDOW_DATE.log"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$PROFILE" "$*" | tee -a "$LOG_FILE"; }

# ─── 被审文档列表（自顶向下，动态生成、自适应新增子模块）─────────────
#   00-*.md（顶层）→ $PARENT_DOC（父级详设，可选，profile.env 配）→ 其余 01-*.md（子模块，排序）
[ -d "$REPO/$REDESIGN_SUBDIR" ] || { echo "设计文档目录不存在: $REPO/$REDESIGN_SUBDIR" >&2; exit 1; }
cd "$REPO"
RD="$REDESIGN_SUBDIR"
DOCS=()
for f in "$RD"/00-*.md;     do DOCS+=("$(basename "$f")"); done
PARENT_DOC="${PARENT_DOC:-}"
[ -n "$PARENT_DOC" ] && [ -f "$RD/$PARENT_DOC" ] && DOCS+=("$PARENT_DOC")
for f in "$RD"/01-*.md; do
    b="$(basename "$f")"
    [ "$b" = "$PARENT_DOC" ] && continue
    DOCS+=("$b")
done
COUNT=${#DOCS[@]}
[ "$COUNT" -gt 0 ] || { echo "未找到 00*/01* 文档" >&2; exit 1; }

# scope 规则：00-* 清空聚焦（全系统审）；其余沿用 yaml 的 scope.focus
scope_args_for() { case "$1" in 00-*) printf '%s\0%s\0' --scope "";; esac; }

# ─── 游标读取 ───────────────────────────────────────────────────────
CUR_CYCLE=""; CUR_INDEX=0
if [ -f "$CURSOR_FILE" ]; then
    CUR_CYCLE="$(sed -n 's/^cycle_id=//p' "$CURSOR_FILE")"
    CUR_INDEX="$(sed -n 's/^index=//p' "$CURSOR_FILE")"
    [[ "$CUR_INDEX" =~ ^[0-9]+$ ]] || CUR_INDEX=0
fi

# ─── --plan：只打印计划，不跑、不进位、不加锁 ───────────────────────
if [ "$MODE" = "--plan" ]; then
    eff_index="$CUR_INDEX"
    [ "$CUR_CYCLE" != "$WINDOW_DATE" ] && eff_index=0
    echo "profile=$PROFILE  hour=$HOUR  window_date=$WINDOW_DATE  max_rounds=$MAX_ROUNDS"
    echo "cursor: cycle=$CUR_CYCLE index=$CUR_INDEX  ->  本窗口生效 index=$eff_index / 共 $COUNT 篇"
    echo "文档顺序："
    i=0
    for d in "${DOCS[@]}"; do
        mark=" "; [ "$i" -eq "$eff_index" ] && mark="*"
        sc=""; [[ "$d" == 00-* ]] && sc="  (--scope \"\")"
        printf "  [%s] %2d  %s%s\n" "$mark" "$i" "$d" "$sc"
        i=$((i+1))
    done
    if [ "$eff_index" -lt "$COUNT" ]; then
        nd="${DOCS[$eff_index]}"; sc=""; [[ "$nd" == 00-* ]] && sc=' --scope ""'
        echo "将执行: review-design.sh $RD/$nd --max-rounds $MAX_ROUNDS --quiet$sc"
    else
        echo "本窗口已跑完，无待审篇目。"
    fi
    exit 0
fi

# ─── 全局锁：占用中（上一篇还在跑）则跳过本整点，不动游标 ───────────
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "上一篇仍在运行，跳过本整点（不动游标）"
    exit 0
fi

# ─── 按窗口日期重置游标 ─────────────────────────────────────────────
if [ "$CUR_CYCLE" != "$WINDOW_DATE" ]; then
    CUR_INDEX=0
    log "=== 新一晚窗口 $WINDOW_DATE 开始，游标重置；共 $COUNT 篇，max_rounds=$MAX_ROUNDS ==="
fi

# ─── 当晚跑完 ───────────────────────────────────────────────────────
if [ "$CUR_INDEX" -ge "$COUNT" ]; then
    log "当晚 $COUNT 篇已全部覆盖，本整点 no-op"
    exit 0
fi

DOC="${DOCS[$CUR_INDEX]}"
mapfile -d '' SCOPE_ARGS < <(scope_args_for "$DOC")

log "开始审查 [$CUR_INDEX/$COUNT] $RD/$DOC （max_rounds=$MAX_ROUNDS${SCOPE_ARGS:+ scope=清空}）"
rc=0
review-design.sh "$RD/$DOC" --max-rounds "$MAX_ROUNDS" --quiet "${SCOPE_ARGS[@]}" >>"$LOG_FILE" 2>&1 || rc=$?
log "完成 [$CUR_INDEX/$COUNT] $DOC，review-design.sh 退出码=$rc"

# ─── 按篇快照报告/补丁 ─────────────────────────────────────────────
# 工具把 review-report.md / suggested-patch.diff 写成固定名，下一篇会覆盖；
# 按篇另存留存（supplement 已按 topic 命名，无需快照）。
DR_OUT="$RD/.design-runs"
BASE="${DOC%.md}"
if [ -f "$DR_OUT/review-report.md" ]; then
    cp -f "$DR_OUT/review-report.md" "$DR_OUT/review-report-$BASE.md"
    log "快照报告 -> review-report-$BASE.md"
fi
if [ -f "$DR_OUT/suggested-patch.diff" ]; then
    cp -f "$DR_OUT/suggested-patch.diff" "$DR_OUT/suggested-patch-$BASE.diff"
    log "快照补丁 -> suggested-patch-$BASE.diff"
fi

# ─── 进位（成功/失败都进，一篇失败不卡死整晚）─────────────────────
NEXT=$((CUR_INDEX + 1))
printf 'cycle_id=%s\nindex=%s\n' "$WINDOW_DATE" "$NEXT" > "$CURSOR_FILE"
log "游标进位 -> index=$NEXT"
exit 0
