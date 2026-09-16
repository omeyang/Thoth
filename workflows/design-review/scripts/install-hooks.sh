#!/usr/bin/env bash
# design-review hook 安装器
# 把 templates/pre-commit.sh.tmpl 装到当前 git 仓库的 .git/hooks/pre-commit
#
# 用法（在目标项目根执行）：
#   $THOTH_HOME/workflows/design-review/scripts/install-hooks.sh
#
# 选项：
#   --force        已存在 pre-commit 时强制覆盖（备份原文件）
#   --uninstall    卸载（仅当 pre-commit 是本工具装的）
#   --dry-run      仅打印将要做的事
#
# 退出码：
#   0  成功 / 幂等（hook 已是最新）
#   1  失败（非 git 仓库 / 模板缺失 / 权限不足）
#   2  pre-commit 已存在且非本工具装的（用 --force 覆盖）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$WORKFLOW_DIR/templates/pre-commit.sh.tmpl"
LINT_DOC_ABS="$SCRIPT_DIR/lint-doc.sh"

# 本工具签名 — uninstall 用它确认归属
MARKER="# design-review pre-commit hook"

FORCE=0
UNINSTALL=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,16p' "$0"
            exit 0
            ;;
        *)
            echo "未知参数：$1" >&2
            exit 1
            ;;
    esac
done

# 1. 校验当前目录是 git 仓库
GIT_DIR=""
if ! GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)"; then
    echo "install-hooks: 当前目录不是 git 仓库（git rev-parse 失败）" >&2
    exit 1
fi

HOOK_PATH="$GIT_DIR/hooks/pre-commit"

# 2. uninstall 路径
if [ "$UNINSTALL" -eq 1 ]; then
    if [ ! -f "$HOOK_PATH" ]; then
        echo "install-hooks: 无 pre-commit hook 可卸载"
        exit 0
    fi
    if ! grep -qF "$MARKER" "$HOOK_PATH"; then
        echo "install-hooks: $HOOK_PATH 非本工具安装（缺 marker），拒绝卸载" >&2
        exit 2
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] 将删除 $HOOK_PATH"
        exit 0
    fi
    rm -f "$HOOK_PATH"
    echo "install-hooks: 已卸载 $HOOK_PATH"
    exit 0
fi

# 3. install 路径
[ -f "$TEMPLATE" ] || { echo "install-hooks: 模板缺失 $TEMPLATE" >&2; exit 1; }

# 渲染：把 @DR_LINT_DOC_FALLBACK@ 替换为绝对路径
RENDERED=""
RENDERED="$(sed -e "s|@DR_LINT_DOC_FALLBACK@|$LINT_DOC_ABS|g" "$TEMPLATE")"

# 4. 幂等检测：已存在且内容一致 → noop
if [ -f "$HOOK_PATH" ]; then
    if grep -qF "$MARKER" "$HOOK_PATH" && [ "$(cat "$HOOK_PATH")" = "$RENDERED" ]; then
        echo "install-hooks: $HOOK_PATH 已是最新（noop）"
        exit 0
    fi

    if ! grep -qF "$MARKER" "$HOOK_PATH" && [ "$FORCE" -ne 1 ]; then
        echo "install-hooks: $HOOK_PATH 已存在且非本工具装的；用 --force 覆盖（自动备份）" >&2
        exit 2
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] 将备份 $HOOK_PATH → ${HOOK_PATH}.bak.<timestamp>，再写入新 hook"
    else
        local_ts="$(date +%Y%m%d-%H%M%S)"
        cp -p "$HOOK_PATH" "${HOOK_PATH}.bak.${local_ts}"
        echo "install-hooks: 已备份原 hook → ${HOOK_PATH}.bak.${local_ts}"
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] 将写入 $HOOK_PATH（chmod +x）"
    echo "[dry-run] LINT_DOC fallback = $LINT_DOC_ABS"
    exit 0
fi

# 5. 写入并赋可执行
mkdir -p "$(dirname "$HOOK_PATH")"
printf '%s\n' "$RENDERED" > "$HOOK_PATH"
chmod +x "$HOOK_PATH"

echo "install-hooks: 已安装 $HOOK_PATH"
echo "  - 暂存 redesign/*.md 时自动跑 lint-doc.sh"
echo "  - 用 git commit --no-verify 单次跳过；--uninstall 永久卸载"
