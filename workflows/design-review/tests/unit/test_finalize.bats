#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/errors.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/log.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/state.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/finalize.sh"

    RUN_DIR="$TEST_TMPDIR/run"
    mkdir -p "$RUN_DIR"
    state_init "$RUN_DIR" "test" "redesign/01-scheduler.md" ".design-review.yaml"
    state_set "$RUN_DIR" current_round 3
    state_set "$RUN_DIR" tokens_used_total 2300000

    mkdir -p "$TEST_TMPDIR/redesign"
    echo "# scheduler" > "$TEST_TMPDIR/redesign/01-scheduler.md"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "write_review_report 露出 NEEDS-INFO 为『待核实』并计数 + 列出发现" {
    cat > "$RUN_DIR/consensus.yaml" <<'EOF'
round: 1
findings:
  - cross_id: cf-001
    classification: NEEDS-INFO
    canonical_text: "promoted 回退兜底依赖老 legacy-service 在跑，与原则 3.4 冲突"
    severity: P0
    votes: {T1: agree, T2: agree, T3: agree, T4: agree}
  - cross_id: cf-002
    classification: 必修
    canonical_text: "另一条必修"
    severity: P1
    votes: {T1: agree, T2: agree, T3: agree, T4: agree}
EOF
    write_review_report "$RUN_DIR/consensus.yaml" "MAX_REACHED" "$RUN_DIR/report.md" "$RUN_DIR"
    grep -q "待核实" "$RUN_DIR/report.md"
    grep -q "| 待核实 | 1 |" "$RUN_DIR/report.md"
    grep -q "promoted 回退兜底依赖老 legacy-service" "$RUN_DIR/report.md"
}

@test "write_supplement_md 露出 NEEDS-INFO 待核实项" {
    cat > "$RUN_DIR/consensus.yaml" <<'EOF'
round: 1
findings:
  - cross_id: cf-001
    classification: NEEDS-INFO
    canonical_text: "灰度 pass-through 语义与基线单值比较不一致"
    severity: P2
    votes: {T1: agree, T2: agree, T3: agree, T4: agree}
EOF
    write_supplement_md "$RUN_DIR/consensus.yaml" "redesign/01-b-gray.md" "MAX_REACHED" "$RUN_DIR/supp.md" "$RUN_DIR"
    grep -q "待核实" "$RUN_DIR/supp.md"
    grep -q "灰度 pass-through 语义与基线单值比较不一致" "$RUN_DIR/supp.md"
}

@test "derive_topic redesign/01-scheduler.md → scheduler" {
    [ "$(derive_topic "redesign/01-scheduler.md")" = "scheduler" ]
}

@test "derive_topic redesign/01-a-scaling.md → scaling" {
    [ "$(derive_topic "redesign/01-a-scaling.md")" = "scaling" ]
}

@test "derive_topic 无前缀也工作" {
    [ "$(derive_topic "foo.md")" = "foo" ]
}

@test "write_supplement_md 包含必修项 + decision + 中文" {
    write_supplement_md "$FIXTURES_DIR/final-consensus.yaml" \
        "redesign/01-scheduler.md" "CONVERGED" \
        "$TEST_TMPDIR/sup.md" "$RUN_DIR"
    [ -f "$TEST_TMPDIR/sup.md" ]
    grep -q "lifecyclefsm 漏处理" "$TEST_TMPDIR/sup.md"
    grep -q "subscription_name" "$TEST_TMPDIR/sup.md"
    ! grep -q "CheckVersion 应该是" "$TEST_TMPDIR/sup.md"
    ! grep -q "quantum encryption" "$TEST_TMPDIR/sup.md"
    grep -q "CONVERGED" "$TEST_TMPDIR/sup.md"
}

@test "write_review_report 含 三表 + token 用量" {
    write_review_report "$FIXTURES_DIR/final-consensus.yaml" "CONVERGED" \
        "$TEST_TMPDIR/report.md" "$RUN_DIR"
    [ -f "$TEST_TMPDIR/report.md" ]
    grep -q "必修" "$TEST_TMPDIR/report.md"
    grep -q "存疑" "$TEST_TMPDIR/report.md"
    grep -q "舍弃" "$TEST_TMPDIR/report.md"
    grep -qE "(2\.3M|2300000)" "$TEST_TMPDIR/report.md"
}

@test "write_suggested_patch 输出 unified diff" {
    write_suggested_patch "$FIXTURES_DIR/final-consensus.yaml" \
        "$TEST_TMPDIR/redesign/01-scheduler.md" \
        "$TEST_TMPDIR/patch.diff"
    [ -f "$TEST_TMPDIR/patch.diff" ]
    grep -qE "^(---|\+\+\+|@@)" "$TEST_TMPDIR/patch.diff"
    grep -q "01-scheduler.md" "$TEST_TMPDIR/patch.diff"
}

@test "finalize_run 落 3 份产物到正确位置" {
    mkdir -p "$TEST_TMPDIR/redesign"
    mkdir -p "$TEST_TMPDIR/redesign/.design-runs"

    finalize_run "$RUN_DIR" "$FIXTURES_DIR/final-consensus.yaml" \
        "$TEST_TMPDIR/redesign/01-scheduler.md" \
        "CONVERGED" \
        "$TEST_TMPDIR"

    [ -f "$TEST_TMPDIR/redesign/201-scheduler-supplement.md" ]
    [ -f "$TEST_TMPDIR/redesign/.design-runs/suggested-patch.diff" ]
    [ -f "$TEST_TMPDIR/redesign/.design-runs/review-report.md" ]
}

@test "finalize_run supplement 重名 → 加 -r2 后缀" {
    mkdir -p "$TEST_TMPDIR/redesign"
    touch "$TEST_TMPDIR/redesign/201-scheduler-supplement.md"

    finalize_run "$RUN_DIR" "$FIXTURES_DIR/final-consensus.yaml" \
        "$TEST_TMPDIR/redesign/01-scheduler.md" \
        "CONVERGED" \
        "$TEST_TMPDIR"

    [ -f "$TEST_TMPDIR/redesign/201-scheduler-supplement-r2.md" ]
}

@test "finalize_run 追加 log entry 到 logging.file" {
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/log.sh"

    mkdir -p "$TEST_TMPDIR/redesign"
    mkdir -p "$TEST_TMPDIR/redesign/.design-runs"

    # 准备 R3 round dir + stances（finalize 读取 final round 的 stances）
    mkdir -p "$RUN_DIR/R3"
    cat > "$RUN_DIR/R3/stances.yaml" <<'EOF'
T1: pro
T2: con
T3: neutral
T4: con
EOF

    export DR_TEMPLATES_DIR="$TEMPLATES_DIR"
    export CFG_LOGGING_FILE="docs/dr-log-test.md"

    finalize_run "$RUN_DIR" "$FIXTURES_DIR/final-consensus.yaml" \
        "$TEST_TMPDIR/redesign/01-scheduler.md" \
        "CONVERGED" \
        "$TEST_TMPDIR"

    [ -f "$TEST_TMPDIR/docs/dr-log-test.md" ]
    grep -q "test" "$TEST_TMPDIR/docs/dr-log-test.md"
    grep -q "CONVERGED" "$TEST_TMPDIR/docs/dr-log-test.md"
    grep -q "必修=2" "$TEST_TMPDIR/docs/dr-log-test.md"
    grep -q "存疑=1" "$TEST_TMPDIR/docs/dr-log-test.md"
    grep -q "舍弃=1" "$TEST_TMPDIR/docs/dr-log-test.md"
    grep -q "T1=pro" "$TEST_TMPDIR/docs/dr-log-test.md"

    unset DR_TEMPLATES_DIR CFG_LOGGING_FILE
}
