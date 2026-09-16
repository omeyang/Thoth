#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/errors.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/finding.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "validate_finding 完整 finding → OK + 保持 High" {
    run validate_finding "$FIXTURES_DIR/finding-complete.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    [[ "$output" == *"High"* ]]
}

@test "validate_finding 缺 q3 → REJECT" {
    run validate_finding "$FIXTURES_DIR/finding-missing-q3.yaml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REJECT"* ]]
    [[ "$output" == *"q3_old_arch_handling"* ]]
}

@test "validate_finding 含糊词 → 降级一档" {
    run validate_finding "$FIXTURES_DIR/finding-vague-words.yaml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REJECT"* ]]
}

@test "validate_finding 1 个含糊词 → High 降到 Medium" {
    cat > "$TEST_TMPDIR/f.yaml" <<'EOF'
finding:
  id: f-x
  severity: P1
  source_agent: T1
  source_role: R1
  confidence: High
  q1_real_scenario: "可能存在"
  q2_avoidable_by_process: "no"
  q3_old_arch_handling: "ref"
  q4_not_hallucinated: "yes"
  control_in_our_hands: "yes"
  concrete_scenario: "x"
  numbers_tagged: []
  evidence: ["ref-1"]
  proposed_action: "do"
EOF
    run validate_finding "$TEST_TMPDIR/f.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK Medium"* ]]
}

@test "validate_finding evidence 空数组 → REJECT" {
    run validate_finding "$FIXTURES_DIR/finding-no-evidence.yaml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REJECT"* ]]
    [[ "$output" == *"evidence"* ]]
}

@test "validate_finding 文件不存在 → exit 2" {
    run validate_finding "$TEST_TMPDIR/no-such.yaml"
    [ "$status" -eq 2 ]
}

@test "count_vague_words 'TBD' → 1" {
    local n
    n="$(count_vague_words 'this is TBD')"
    [ "$n" -eq 1 ]
}

@test "count_vague_words '大概 可能 unknown' → 3" {
    local n
    n="$(count_vague_words '大概 可能 unknown')"
    [ "$n" -eq 3 ]
}

@test "downgrade_confidence High 降到 Medium" {
    [ "$(downgrade_confidence High)" = "Medium" ]
}

@test "downgrade_confidence Medium 降到 Speculative" {
    [ "$(downgrade_confidence Medium)" = "Speculative" ]
}

@test "downgrade_confidence Speculative 降到 REJECT" {
    [ "$(downgrade_confidence Speculative)" = "REJECT" ]
}
