#!/usr/bin/env bash
# design-review 跨轮状态持久化（state.yaml）
# 不要直接执行；由其他脚本 source

[ -n "${_DR_STATE_LOADED:-}" ] && return 0
_DR_STATE_LOADED=1

_state_file() {
    echo "$1/state.yaml"
}

_now_rfc3339() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# state_init <run-dir> <run-id> <target> <config-path>
state_init() {
    local dir="$1"
    local run_id="$2"
    local target="$3"
    local config="$4"

    mkdir -p "$dir"
    local now
    now="$(_now_rfc3339)"

    cat > "$(_state_file "$dir")" <<EOF
run_id: $run_id
target: $target
config_path: $config
created_at: $now
updated_at: $now

current_round: 0
last_completed_round: 0
status: in_progress

stuck_count: 0
dispute_count: 0

tokens_used_total: 0

enabled_roles: R1,R2,R3,R4,R5
EOF
}

# state_get <run-dir> <key>
state_get() {
    local f
    f="$(_state_file "$1")"
    local key="$2"
    [ -f "$f" ] || { echo ""; return 0; }
    local v
    v="$(yq eval ".${key} // \"\"" "$f" 2>/dev/null)"
    [ "$v" = "null" ] && v=""
    echo "$v"
}

# state_set <run-dir> <key> <value>
state_set() {
    local f
    f="$(_state_file "$1")"
    local key="$2"
    local value="$3"
    [ -f "$f" ] || { echo "state_set: state.yaml 不存在 $f" >&2; return 1; }

    local now
    now="$(_now_rfc3339)"
    local _val="$value" _now="$now"
    _val="$_val" yq -i ".${key} = strenv(_val)" "$f"
    _now="$_now" yq -i ".updated_at = strenv(_now)" "$f"
}

# state_increment <run-dir> <numeric-key>
state_increment() {
    local f
    f="$(_state_file "$1")"
    local key="$2"
    [ -f "$f" ] || { echo "state_increment: state.yaml 不存在 $f" >&2; return 1; }

    local cur
    cur="$(yq eval ".${key} // 0" "$f")"
    [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
    local new=$((cur + 1))

    state_set "$1" "$key" "$new"
}
