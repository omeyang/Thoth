#!/usr/bin/env bash
# design-review 文档自洽 lint
# M4 阶段实现 L2 内链可达 + L5 含糊词 warn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/errors.sh
source "$SCRIPT_DIR/lib/errors.sh"

_DR_VAGUE_WORDS_LINT=(TBD TODO FIXME 待补 待定 大概 可能 也许)

lint_doc() {
    local f="$1"
    [ -f "$f" ] || { echo "lint-doc: 文件不存在 $f" >&2; return 2; }

    local errors=0
    local warns=0
    local dir
    dir="$(dirname "$f")"

    # L2: 内链可达 — 抽 markdown 内联链接，过滤 http(s) 和纯 anchor
    local links
    links="$(grep -oE '\]\([^)]+\)' "$f" | sed -E 's/^\]\(//; s/\)$//' || true)"

    while IFS= read -r link; do
        [ -z "$link" ] && continue
        [[ "$link" =~ ^https?:// ]] && continue
        [[ "$link" =~ ^# ]] && continue
        local path="${link%%#*}"
        [ -z "$path" ] && continue
        local target
        if [[ "$path" = /* ]]; then
            target="$path"
        else
            target="$dir/$path"
        fi
        if [ ! -e "$target" ]; then
            printf 'ERROR: %s 断链 → %s\n' "$f" "$link" >&2
            errors=$((errors + 1))
        fi
    done <<< "$links"

    # L5: 含糊词 warn
    local w
    for w in "${_DR_VAGUE_WORDS_LINT[@]}"; do
        local count
        count="$(grep -c -F -- "$w" "$f" 2>/dev/null || true)"
        [ -z "$count" ] && count=0
        if [ "$count" -gt 0 ]; then
            printf 'WARN: %s 含糊词 "%s" × %d\n' "$f" "$w" "$count" >&2
            warns=$((warns + 1))
        fi
    done

    if [ "$errors" -gt 0 ]; then
        printf 'lint-doc: %s 失败：%d errors，%d warns\n' "$f" "$errors" "$warns" >&2
        return 1
    fi

    printf 'lint-doc: %s 通过（%d warns）\n' "$f" "$warns"
    return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ $# -eq 0 ]; then
        echo "USAGE: lint-doc.sh <file.md>" >&2
        exit 2
    fi
    lint_doc "$1"
fi
