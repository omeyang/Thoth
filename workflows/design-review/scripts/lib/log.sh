#!/usr/bin/env bash
# design-review 日志辅助
# 不要直接执行；由其他脚本 source

[ -n "${_DR_LOG_LOADED:-}" ] && return 0
_DR_LOG_LOADED=1

# log_run_id — 生成 YYYYmmdd-HHMMSS-<rand4> 格式 run id
log_run_id() {
    local ts rand
    ts="$(date -u +%Y%m%d-%H%M%S)"
    rand="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 4)"
    printf '%s-%s\n' "$ts" "$rand"
}

# log_append <file> <content>
# 追加 content 到 file，用 flock 保护并发；自动创建父目录
log_append() {
    local file="$1"
    local content="$2"
    mkdir -p "$(dirname "$file")"
    (
        flock -x 9
        printf '%s\n' "$content" >> "$file"
    ) 9>>"${file}.lock"
}
