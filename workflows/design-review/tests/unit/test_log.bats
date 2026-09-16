#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/errors.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/log.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "log_run_id 返回 YYYYmmdd-HHMMSS-XXXX 形态" {
    local rid
    rid="$(log_run_id)"
    [[ "$rid" =~ ^[0-9]{8}-[0-9]{6}-[a-z0-9]{4}$ ]]
}

@test "log_append 写入并加锁" {
    local logf="$TEST_TMPDIR/log.md"
    log_append "$logf" "## 第一条"
    log_append "$logf" "## 第二条"
    grep -q "第一条" "$logf"
    grep -q "第二条" "$logf"
}

@test "log_append 创建父目录" {
    local logf="$TEST_TMPDIR/nested/dir/log.md"
    log_append "$logf" "## 内容"
    [ -f "$logf" ]
    grep -q "内容" "$logf"
}
