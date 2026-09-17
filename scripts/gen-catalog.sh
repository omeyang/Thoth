#!/usr/bin/env bash
# shellcheck disable=SC2016
# 从各 skills/*/SKILL.md 的 frontmatter 生成 skills/CATALOG.md
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fm_desc() {
    awk 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} index($0,"description:")==1{sub("^description:[ ]*",""); print; exit}' "$1" \
        | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/' | sed 's/|/\\|/g'
}

count=$(find skills -mindepth 1 -maxdepth 1 -type d | wc -l)
{
    printf '# 技能包目录\n\n'
    printf '技能包总数：%s（由 `scripts/gen-catalog.sh` 生成，不要手改）\n\n' "$count"
    printf '安装插件后按 `/thoth:<name>` 调用（Codex 为 `$<name>`）。\n\n'
    printf '| 技能包 | 描述 |\n|---|---|\n'
    for dir in $(find skills -mindepth 1 -maxdepth 1 -type d | sort); do
        name=${dir#skills/}
        printf '| [`%s`](%s/SKILL.md) | %s |\n' "$name" "$name" "$(fm_desc "$dir/SKILL.md")"
    done
} > skills/CATALOG.md
echo "skills/CATALOG.md: $count skills"
