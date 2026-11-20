#!/usr/bin/env bash
# Validate the two-skill repository and reject removed legacy architecture.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1
fail=0
err() { printf 'ERROR: %s\n' "$*" >&2; fail=1; }

fm_field() {
    awk -v k="$2" 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} index($0,k":")==1{sub("^"k":[ ]*",""); print; exit}' "$1" \
        | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
}

for legacy in .agents .claude-plugin .codex-plugin agents docs evals hooks mcp templates workflows; do
    [ ! -e "$legacy" ] || err "旧架构目录不应存在：$legacy"
done

for required in explain-business-visually ui-craft; do
    [ -d "skills/$required" ] || err "缺少当前核心技能：$required"
done

for dir in skills/*/; do
    name=${dir%/}; name=${name#skills/}
    f="$dir/SKILL.md"
    [ -f "$f" ] || { err "$dir 缺少 SKILL.md"; continue; }
    [ "$(head -1 "$f")" = "---" ] || err "$f 缺少 frontmatter"
    [ "$(fm_field "$f" name)" = "$name" ] || err "$f name 与目录不一致"
    description=$(fm_field "$f" description)
    [ -n "$description" ] || err "$f 缺少 description"
    length=$(printf '%s' "$description" | wc -m)
    [ "$length" -le 1024 ] || err "$f description 超过 1024 字符"
    lines=$(wc -l < "$f")
    [ "$lines" -le 500 ] || err "$f 超过 500 行"
    for key in user-invocable allowed-tools version; do
        [ -z "$(fm_field "$f" "$key")" ] || err "$f 含已废弃字段 $key"
    done
done

count=$(find skills -mindepth 1 -maxdepth 1 -type d | wc -l)
[ "$count" -eq 2 ] || err "当前仓库只维护 2 个技能，实际为 $count"
grep -q "技能包总数：$count" skills/CATALOG.md || err "skills/CATALOG.md 计数过期，运行 scripts/gen-catalog.sh"

[ "$fail" -eq 0 ] && echo "validate: OK ($count skills, legacy tree absent)"
exit "$fail"
