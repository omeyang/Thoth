#!/bin/sh
# 把仓库文档同步到 GitHub Wiki（与 Maat 的 scripts/sync-wiki.sh 同一思路）。
#
# 用法：scripts/sync-wiki.sh [wiki-remote]
#   默认 remote 为 git@github.com:omeyang/Thoth.wiki.git
#
# 行为：
#   1. 克隆 Wiki 仓库到临时目录，清空旧页面
#   2. README.md -> Home.md；docs/*.md、各组件 README、skills/CATALOG.md、
#      每个 SKILL.md、每个 agent、两个脚本工作流的 WORKFLOW.md 各生成一页
#   3. 仓库内相对链接改写为 Wiki 页面链接或 GitHub blob 链接，生成 _Sidebar.md
#   4. 有变更时提交并推送

set -eu

REMOTE=${1:-git@github.com:omeyang/Thoth.wiki.git}
REPO_URL=https://github.com/omeyang/Thoth
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/wiki"

cd "$ROOT"
git clone -q "$REMOTE" "$OUT"
find "$OUT" -maxdepth 1 -name '*.md' -type f -exec rm -f {} +

# page <源文件> <页面名>：复制并改写链接
# 链接规则：
#   指向已收录源文件的相对链接 -> 页面名
#   其他仓库内相对链接        -> $REPO_URL/blob/main/<路径>
page() {
    src=$1; name=$2; dir=$(dirname "$src")
    awk -v repo="$REPO_URL" -v dir="$dir" -v map="$WORK/map.txt" '
        BEGIN { while ((getline line < map) > 0) { split(line, kv, "\t"); pages[kv[1]] = kv[2] } }
        {
            out = ""
            rest = $0
            while (match(rest, /\]\([^)#]+(#[^)]*)?\)/)) {
                pre = substr(rest, 1, RSTART)               # 含 "]("
                link = substr(rest, RSTART + 2, RLENGTH - 3) # 去掉 "](" 与 ")"
                rest = substr(rest, RSTART + RLENGTH)
                anchor = ""
                if (index(link, "#") > 0) { anchor = substr(link, index(link, "#")); link = substr(link, 1, index(link, "#") - 1) }
                if (link ~ /^(https?:|mailto:)/ || link == "") { out = out pre link anchor ")"; continue }
                # 归一化相对路径
                p = link; sub(/^\.\//, "", p)
                if (dir != ".") {
                    full = dir "/" p
                    while (sub(/[^\/]+\/\.\.\//, "", full)) {}
                    p = full
                }
                sub(/\/$/, "", p)
                if (p in pages) out = out pre pages[p] anchor ")"
                else if (p "/README.md" in pages) out = out pre pages[p "/README.md"] anchor ")"
                else if (p "/SKILL.md" in pages) out = out pre pages[p "/SKILL.md"] anchor ")"
                else out = out pre repo "/blob/main/" p anchor ")"
            }
            print out rest
        }' "$src" > "$OUT/$name.md"
}

# 收录清单：源文件 \t 页面名
: > "$WORK/map.txt"
add() { printf '%s\t%s\n' "$1" "$2" >> "$WORK/map.txt"; }

add README.md Home
add docs/architecture.md 架构
add docs/roadmap.md 路线图
add docs/naming-conventions.md 命名规范
add CONTRIBUTING.md 贡献指南
add skills/CATALOG.md 技能目录
add skills/README.md 技能说明
add docs/agents.md 子代理
add hooks/README.md Hooks
add mcp/README.md MCP
add mcp/servers/README.md MCP-服务器清单
add workflows/README.md 工作流
add workflows/adversarial-review/WORKFLOW.md adversarial-review
add workflows/design-review/WORKFLOW.md design-review
for d in skills/*/; do
    n=$(basename "$d"); add "skills/$n/SKILL.md" "skill-$n"
done
for f in agents/*.md; do
    n=$(basename "$f" .md); [ "$n" = README ] && continue; add "agents/$n.md" "agent-$n"
done

while IFS="$(printf '\t')" read -r src name; do
    page "$src" "$name"
done < "$WORK/map.txt"

# 侧边栏
{
    printf '**[Home](Home)**\n\n'
    printf '**总览**\n- [架构](架构)\n- [路线图](路线图)\n- [命名规范](命名规范)\n- [贡献指南](贡献指南)\n\n'
    printf '**组件**\n- [技能目录](技能目录)\n- [子代理](子代理)\n- [Hooks](Hooks)\n- [MCP](MCP)\n- [工作流](工作流)\n  - [adversarial-review](adversarial-review)\n  - [design-review](design-review)\n\n'
    printf '**技能**\n'
    for d in skills/*/; do n=$(basename "$d"); printf -- '- [%s](skill-%s)\n' "$n" "$n"; done
    printf '\n**子代理**\n'
    for f in agents/*.md; do n=$(basename "$f" .md); [ "$n" = README ] && continue; printf -- '- [%s](agent-%s)\n' "$n" "$n"; done
} > "$OUT/_Sidebar.md"

printf '本 Wiki 由 [scripts/sync-wiki.sh](%s/blob/main/scripts/sync-wiki.sh) 自仓库文档生成，修改请提交到仓库。\n' "$REPO_URL" > "$OUT/_Footer.md"

cd "$OUT"
git add -A
if git diff --cached --quiet; then
    echo "wiki: 无变更"
    exit 0
fi
git -c user.name="$(git -C "$ROOT" config user.name)" -c user.email="$(git -C "$ROOT" config user.email)" \
    commit -q -m "docs: sync wiki from $(git -C "$ROOT" rev-parse --short HEAD)"
git push -q origin HEAD
echo "wiki: 已推送 $(find . -maxdepth 1 -name "*.md" | wc -l) 页"
