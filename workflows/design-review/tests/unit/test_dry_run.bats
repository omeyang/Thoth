#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1

    cp "$FIXTURES_DIR/minimal.yaml" .design-review.yaml

    mkdir -p redesign
    cat > redesign/sample.md <<'EOF'
# sample
content
EOF
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "--version 退 0 + 打印版本" {
    run "$SCRIPTS_DIR/review-design.sh" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"design-review"* ]]
}

@test "--help 退 0 + USAGE 字样" {
    run "$SCRIPTS_DIR/review-design.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"USAGE"* ]]
}

@test "--dry-run 退 0 + 打印计划" {
    run "$SCRIPTS_DIR/review-design.sh" --dry-run redesign/sample.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY RUN"* ]]
    [[ "$output" == *"redesign/sample.md"* ]]
    [[ "$output" == *"min_rounds=2"* ]]
    [[ "$output" == *"max_rounds=5"* ]]
    [[ "$output" == *"T1"* ]]
    [[ "$output" == *"T2"* ]]
    [[ "$output" == *"T3"* ]]
    [[ "$output" == *"T4"* ]]
}

@test "无 TARGET 且 yaml target.default 为空 退 3" {
    run "$SCRIPTS_DIR/review-design.sh" --dry-run
    [ "$status" -eq 3 ]
    [[ "$output" == *"未指定 TARGET"* ]]
}

@test "TARGET 文件不存在 退 3" {
    run "$SCRIPTS_DIR/review-design.sh" --dry-run no-such.md
    [ "$status" -eq 3 ]
    [[ "$output" == *"不存在"* ]]
}

@test "TARGET 非 .md 退 3" {
    echo "x" > redesign/not-markdown.txt
    run "$SCRIPTS_DIR/review-design.sh" --dry-run redesign/not-markdown.txt
    [ "$status" -eq 3 ]
    [[ "$output" == *".md"* ]]
}

@test "--config 指自定义 yaml" {
    cat > custom.yaml <<'EOF'
rounds:
  min: 3
  max: 4
refs:
  manifest:
    - {path: /tmp/x, tier: "X"}
EOF
    run "$SCRIPTS_DIR/review-design.sh" --dry-run --config custom.yaml redesign/sample.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"min_rounds=3"* ]]
    [[ "$output" == *"max_rounds=4"* ]]
}

@test "CLI --rounds 覆盖 yaml" {
    run "$SCRIPTS_DIR/review-design.sh" --dry-run --rounds 1 redesign/sample.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"min_rounds=1"* ]]
    [[ "$output" == *"max_rounds=1"* ]]
}

@test "--dry-run 不调 mock LLM（即使 mock 注入了）" {
    export DESIGN_REVIEW_CLAUDE_BIN="/bin/false"
    export DESIGN_REVIEW_CODEX_BIN="/bin/false"
    run "$SCRIPTS_DIR/review-design.sh" --dry-run redesign/sample.md
    [ "$status" -eq 0 ]
}

@test "非 --dry-run 模式：mock 注入下能跑完 1 轮（min=max=1）" {
    inject_mocks
    export DR_CALL_TIMEOUT_SEC=10
    export DR_CALL_RETRY=0
    export DR_STANCE_RANDOM_SEED=42
    export DR_PHASE_CASE_OVERRIDE="phases"

    cp "$FIXTURES_DIR/minimal.yaml" .design-review.yaml
    mkdir -p redesign
    echo "# sample" > redesign/sample.md

    run "$SCRIPTS_DIR/review-design.sh" --rounds 1 redesign/sample.md
    [ "$status" -eq 0 ]
    [ -f "redesign/201-sample-supplement.md" ] || \
        [ -f "redesign/201-sample-supplement-r2.md" ]
    [ -f "redesign/.design-runs/suggested-patch.diff" ]
    [ -f "redesign/.design-runs/review-report.md" ]
}
