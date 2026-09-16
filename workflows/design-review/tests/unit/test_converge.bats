#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/errors.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/converge.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "compute_deltas 无变化 → 全 0" {
    run compute_deltas \
        "$FIXTURES_DIR/consensus-r1-baseline.yaml" \
        "$FIXTURES_DIR/consensus-r2-no-change.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"findings_new=0"* ]]
    [[ "$output" == *"findings_refuted=0"* ]]
    [[ "$output" == *"classification_changed=0"* ]]
    [[ "$output" == *"vote_changed=0"* ]]
}

@test "compute_deltas 新增 cf-004 → findings_new=1" {
    run compute_deltas \
        "$FIXTURES_DIR/consensus-r1-baseline.yaml" \
        "$FIXTURES_DIR/consensus-r2-new-finding.yaml"
    [[ "$output" == *"findings_new=1"* ]]
    [[ "$output" == *"findings_refuted=0"* ]]
}

@test "compute_deltas cf-002 存疑→舍弃 → findings_refuted=1 + class_changed=1" {
    run compute_deltas \
        "$FIXTURES_DIR/consensus-r1-baseline.yaml" \
        "$FIXTURES_DIR/consensus-r2-refuted.yaml"
    [[ "$output" == *"findings_refuted=1"* ]]
    [[ "$output" == *"classification_changed=1"* ]]
}

@test "compute_deltas cf-001 必修→存疑 → class_changed=1 + vote_changed>0" {
    run compute_deltas \
        "$FIXTURES_DIR/consensus-r1-baseline.yaml" \
        "$FIXTURES_DIR/consensus-r2-class-changed.yaml"
    [[ "$output" == *"classification_changed=1"* ]]
    [[ "$output" == *"vote_changed=2"* ]]
}

@test "decide_convergence round=1 min=2 → CONTINUE（强制最低轮）" {
    run decide_convergence 1 2 5 0 0 \
        "findings_new=0" "findings_refuted=0" \
        "classification_changed=0" "vote_changed=0"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CONTINUE"* ]]
}

@test "decide_convergence Δ全0 且 round>=min → CONVERGED" {
    run decide_convergence 3 2 5 0 0 \
        "findings_new=0" "findings_refuted=0" \
        "classification_changed=0" "vote_changed=0"
    [[ "$output" == *"CONVERGED"* ]]
}

@test "decide_convergence round=max → MAX_REACHED" {
    run decide_convergence 5 2 5 0 0 \
        "findings_new=1" "findings_refuted=0" \
        "classification_changed=0" "vote_changed=0"
    [[ "$output" == *"MAX_REACHED"* ]]
}

@test "decide_convergence stuck>=3 + vote_changed>0 + class_changed==0 → STABLE_BUT_VOTING" {
    run decide_convergence 4 2 5 3 0 \
        "findings_new=0" "findings_refuted=0" \
        "classification_changed=0" "vote_changed=2"
    [[ "$output" == *"STABLE_BUT_VOTING"* ]]
}

@test "decide_convergence dispute>=3 + class_changed>0 → UNRESOLVED_DISPUTE" {
    run decide_convergence 4 2 5 0 3 \
        "findings_new=0" "findings_refuted=0" \
        "classification_changed=1" "vote_changed=0"
    [[ "$output" == *"UNRESOLVED_DISPUTE"* ]]
}

@test "decide_convergence 一般情况有 Δ → CONTINUE" {
    run decide_convergence 3 2 5 0 0 \
        "findings_new=1" "findings_refuted=0" \
        "classification_changed=0" "vote_changed=1"
    [[ "$output" == *"CONTINUE"* ]]
}

@test "decide_convergence min > max → 报错" {
    run decide_convergence 1 5 3 0 0 \
        "findings_new=0" "findings_refuted=0" \
        "classification_changed=0" "vote_changed=0"
    [ "$status" -ne 0 ]
}
