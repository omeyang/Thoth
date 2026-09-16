#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    cp "$FIXTURES_DIR/doc-valid.md" .
    cp "$FIXTURES_DIR/doc-broken-link.md" .
    cp "$FIXTURES_DIR/doc-vague-term.md" .
}

teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

@test "lint_doc 合法文档 → exit 0" {
    run "$SCRIPTS_DIR/lint-doc.sh" doc-valid.md
    [ "$status" -eq 0 ]
}

@test "lint_doc 断链文档 → exit 1 + 报哪条链" {
    run "$SCRIPTS_DIR/lint-doc.sh" doc-broken-link.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"no-such-file.md"* ]] || [[ "$output" == *"断链"* ]]
}

@test "lint_doc 含糊词文档 → exit 0 (warn 不阻断)" {
    run "$SCRIPTS_DIR/lint-doc.sh" doc-vague-term.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"TBD"* ]] || [[ "$output" == *"大概"* ]] || [[ "$output" == *"WARN"* ]]
}

@test "lint_doc 文件不存在 → exit 2" {
    run "$SCRIPTS_DIR/lint-doc.sh" no-such.md
    [ "$status" -eq 2 ]
}

@test "lint_doc 外部链接（http）不校验" {
    cat > only-http.md <<'INNER'
# 仅 http 链接
[外站](https://example.com/path)
[更多](http://x.org)
INNER
    run "$SCRIPTS_DIR/lint-doc.sh" only-http.md
    [ "$status" -eq 0 ]
}

@test "lint_doc anchor (#section) 不校验存在性" {
    cat > anchor-only.md <<'INNER'
# 仅 anchor
[本节](#section)
INNER
    run "$SCRIPTS_DIR/lint-doc.sh" anchor-only.md
    [ "$status" -eq 0 ]
}
