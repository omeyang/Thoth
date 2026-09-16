#!/usr/bin/env bash
# Mock Claude CLI for design-review testing
# 按 --team / --stance / --round / --case 查表返回预设 yaml
#
# 用法：
#   mock-codex.sh --team T1 --stance pro --round 1 --case <case-name> \
#                  --input <path> [> output.yaml]
#
# 查表顺序：
#   1) tests/mocks/scripts/${case}-${team}-${stance}-R${round}.yaml
#   2) tests/mocks/scripts/${case}-${team}-${stance}.yaml
#   3) tests/mocks/scripts/${case}-default.yaml
# 都不存在 → 退出 99

set -euo pipefail

team=""
stance=""
round=""
case_name=""

while [ $# -gt 0 ]; do
    case "$1" in
        --team)   team="$2";       shift 2 ;;
        --stance) stance="$2";     shift 2 ;;
        --round)  round="$2";      shift 2 ;;
        --case)   case_name="$2";  shift 2 ;;
        --input)  shift 2 ;;
        --help)   echo "mock-codex.sh — see file header"; exit 0 ;;
        *)        shift ;;
    esac
done

[ -n "$case_name" ] || { echo "mock-codex: missing --case" >&2; exit 99; }

mocks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/scripts" && pwd 2>/dev/null || true)"
[ -d "$mocks_dir" ] || { echo "mock-codex: scripts dir not found: $mocks_dir" >&2; exit 99; }

candidates=(
    "${mocks_dir}/${case_name}-${team}-${stance}-R${round}.yaml"
    "${mocks_dir}/${case_name}-${team}-${stance}.yaml"
    "${mocks_dir}/${case_name}-${team}.yaml"
    "${mocks_dir}/${case_name}-default.yaml"
)

for c in "${candidates[@]}"; do
    if [ -f "$c" ]; then
        cat "$c"
        exit 0
    fi
done

echo "mock-codex: no fixture for case=$case_name team=$team stance=$stance round=$round" >&2
exit 99
