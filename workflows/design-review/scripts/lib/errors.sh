#!/usr/bin/env bash
# design-review 退出码常量 + 错误处理工具
# 不要直接执行；由其他脚本 source
#
# shellcheck disable=SC2034
# 常量定义在本文件，调用在 source 后的脚本里 — SC2034 在此为误报

[ -n "${_DR_ERRORS_LOADED:-}" ] && return 0
_DR_ERRORS_LOADED=1

# 退出码（与 WORKFLOW.md §9 一致）
readonly EXIT_OK=0
readonly EXIT_SEVERITY_FAIL=1
readonly EXIT_CONFIG=2
readonly EXIT_NO_TARGET=3
readonly EXIT_FORCE_STOP=4
readonly EXIT_UNRESOLVED=5
readonly EXIT_INTERRUPTED=130

# die <msg> [code] — 打印 msg 到 stderr，以 code 退出（默认 EXIT_CONFIG）
die() {
    local msg="$1"
    local code="${2:-$EXIT_CONFIG}"
    printf '%s\n' "design-review: ERROR: $msg" >&2
    exit "$code"
}

warn() {
    printf '%s\n' "design-review: WARN: $1" >&2
}

info() {
    [ "${DR_QUIET:-0}" -eq 0 ] && printf '%s\n' "design-review: $1" >&2
    return 0
}

debug() {
    [ "${DR_VERBOSE:-0}" -eq 1 ] && printf '%s\n' "design-review: DEBUG: $1" >&2
    return 0
}

# _yaml_dq <string> — 输出合法的 YAML 双引号标量（含转义）
# 用于手工拼 yaml 时安全发射任意文本（canonical_text 等真实内容常含 " : 等）：
#   echo "    canonical_text: $(_yaml_dq "$text")"
# 转义反斜杠与双引号；内嵌换行/回车压成空格（这些字段约定单行）。
_yaml_dq() {
    local s="${1-}"
    s="${s//\\/\\\\}"     # \ → \\（必须先转义反斜杠）
    s="${s//\"/\\\"}"     # " → \"
    s="${s//$'\n'/ }"      # 换行 → 空格
    s="${s//$'\r'/ }"      # 回车 → 空格
    printf '"%s"' "$s"
}
