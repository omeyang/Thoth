#!/usr/bin/env bash
# shellcheck disable=SC2016
# 仓库结构校验：skills / agents / hooks / 插件清单。CI 与本地共用。
# 用法：scripts/validate.sh    退出码 0 = 通过，1 = 有错误

set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1
fail=0
err() { printf 'ERROR: %s\n' "$*" >&2; fail=1; }

fm_field() { # $1 文件 $2 字段名 -> 值（去引号）
    awk -v k="$2" 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} index($0,k":")==1{sub("^"k":[ ]*",""); print; exit}' "$1" \
        | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
}

# ---- skills ----
for dir in skills/*/; do
    name=${dir%/}; name=${name#skills/}
    f="$dir/SKILL.md"
    [ -f "$f" ] || { err "$dir 缺少 SKILL.md"; continue; }
    [ "$(head -1 "$f")" = "---" ] || err "$f 缺少 frontmatter"
    n=$(fm_field "$f" name)
    [ "$n" = "$name" ] || err "$f name=$n 与目录 $name 不一致"
    d=$(fm_field "$f" description)
    [ -n "$d" ] || err "$f 缺少 description"
    len=$(printf '%s' "$d" | wc -m)
    [ "$len" -le 1024 ] || err "$f description ${len} 字符，超过 1024"
    lines=$(wc -l < "$f")
    [ "$lines" -le 500 ] || err "$f ${lines} 行，超过 500"
    for k in user-invocable allowed-tools version; do
        [ -z "$(fm_field "$f" "$k")" ] || err "$f 含已废弃字段 $k"
    done
    if grep -nE 'XKit|\bx(metrics|retry|trace|ctx|tenant|limit|sampling|log|dlock|breaker|kafka)\.' "$dir" -r --include='*.md' >/dev/null; then
        err "$dir 引用了 XKit 私有包"; grep -nE 'XKit|\bx(metrics|retry|trace|ctx|tenant|limit|sampling|log|dlock|breaker|kafka)\.' "$dir" -r --include='*.md' | head -3 >&2
    fi
    if grep -nE 'Go 1\.2[5-9]|go1\.2[5-9]|Green Tea|WaitGroup\.Go|T\.Output\(|T\.Attr\(|json/v2|errors\.AsType|Task 工具|Task\(' "$dir" -r --include='*.md' >/dev/null; then
        err "$dir 含 1.25+ 或过期内容"; grep -nE 'Go 1\.2[5-9]|go1\.2[5-9]|Green Tea|WaitGroup\.Go|T\.Output\(|T\.Attr\(|json/v2|errors\.AsType|Task 工具|Task\(' "$dir" -r --include='*.md' | head -3 >&2
    fi
done

# ---- agents ----
for f in agents/*.md; do
    [ "$(basename "$f")" = README.md ] && continue
    name=$(basename "$f" .md)
    [ "$(fm_field "$f" name)" = "$name" ] || err "$f name 与文件名不一致"
    [ -n "$(fm_field "$f" description)" ] || err "$f 缺少 description"
    [ -n "$(fm_field "$f" tools)" ] || err "$f 缺少 tools"
    for s in $(fm_field "$f" skills | tr -d '[],'); do
        [ -d "skills/$s" ] || err "$f 预载了不存在的技能 $s"
    done
done

# ---- hooks / manifests ----
for j in hooks/hooks.json .claude-plugin/plugin.json .claude-plugin/marketplace.json mcp/configs/*.json; do
    jq -e . "$j" >/dev/null 2>&1 || err "$j 不是合法 JSON"
done
for s in $(jq -r '.. | .command? // empty' hooks/hooks.json | sed 's|"${CLAUDE_PLUGIN_ROOT}"/||'); do
    [ -x "$s" ] || err "hooks.json 引用的 $s 不存在或不可执行"
done

# ---- catalog 与 README 计数 ----
count=$(find skills -mindepth 1 -maxdepth 1 -type d | wc -l)
grep -q "技能包总数：$count" skills/CATALOG.md || err "skills/CATALOG.md 的总数与实际 $count 不一致（运行 scripts/gen-catalog.sh）"

[ $fail -eq 0 ] && echo "validate: OK ($count skills)"
exit $fail
