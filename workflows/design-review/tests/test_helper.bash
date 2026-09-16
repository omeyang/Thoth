#!/usr/bin/env bash
# design-review 测试通用 helper
# 所有 bats 文件用 `load '../test_helper'` 加载

# shellcheck disable=SC2034
WORKFLOW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$WORKFLOW_ROOT/scripts"
TEMPLATES_DIR="$WORKFLOW_ROOT/templates"
FIXTURES_DIR="$WORKFLOW_ROOT/tests/fixtures"
MOCKS_DIR="$WORKFLOW_ROOT/tests/mocks"

# 每个测试用独立临时目录，自动清理
setup() {
    TEST_TMPDIR="$(mktemp -d -t design-review-test-XXXXXX)"
    export TEST_TMPDIR
    cd "$TEST_TMPDIR" || exit 1
}

teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

# 注入 mock LLM
inject_mocks() {
    export DESIGN_REVIEW_CLAUDE_BIN="$MOCKS_DIR/mock-claude.sh"
    export DESIGN_REVIEW_CODEX_BIN="$MOCKS_DIR/mock-codex.sh"
}

assert_success() {
    if [ "$status" -ne 0 ]; then
        echo "expected success, got status=$status"
        echo "output: $output"
        return 1
    fi
}

assert_failure() {
    local expected_code="${1:-}"
    if [ "$status" -eq 0 ]; then
        echo "expected failure, got status=0"
        echo "output: $output"
        return 1
    fi
    if [ -n "$expected_code" ] && [ "$status" -ne "$expected_code" ]; then
        echo "expected status=$expected_code, got $status"
        return 1
    fi
}

assert_output_contains() {
    local needle="$1"
    if [[ "$output" != *"$needle"* ]]; then
        echo "expected output to contain: $needle"
        echo "actual: $output"
        return 1
    fi
}
