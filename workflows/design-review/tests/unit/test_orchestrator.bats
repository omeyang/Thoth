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
    source "$SCRIPTS_DIR/lib/vote.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/converge.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/stance.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/finding.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/failure.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/state.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/agent.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/phases.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/budget.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/finalize.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/orchestrator.sh"

    inject_mocks
    export DR_CALL_TIMEOUT_SEC=10
    export DR_CALL_RETRY=0

    declare -gA CFG_TEAMS=( [T1]=claude [T2]=codex [T3]=claude [T4]=codex )
    export CFG_STANCE_VALUES="pro,con,neutral"

    export DR_STANCE_RANDOM_SEED=42

    # phases mock 有 'team' 字段
    export DR_PHASE_CASE_OVERRIDE="phases"

    RUN_DIR="$TEST_TMPDIR/run"
    mkdir -p "$RUN_DIR"
    state_init "$RUN_DIR" "test-run" "redesign/sample.md" ".design-review.yaml"

    mkdir -p "$TEST_TMPDIR/redesign"
    echo "# sample" > "$TEST_TMPDIR/redesign/sample.md"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset DR_CALL_TIMEOUT_SEC DR_CALL_RETRY DR_STANCE_RANDOM_SEED DR_PHASE_CASE_OVERRIDE
}

@test "run_one_round R1 → 产 R1/{stances,teamreport*,cross-attack,consensus}.yaml" {
    run run_one_round "$RUN_DIR" 1 "$TEST_TMPDIR/redesign/sample.md" 2 5
    [ "$status" -eq 0 ]
    [ -f "$RUN_DIR/R1/stances.yaml" ]
    for t in T1 T2 T3 T4; do
        [ -f "$RUN_DIR/R1/teamreport-${t}.yaml" ]
    done
    [ -f "$RUN_DIR/R1/cross-attack.yaml" ]
    [ -f "$RUN_DIR/R1/consensus.yaml" ]
}

@test "run_one_round R1 决策 = CONTINUE（R1 < min=2 强制继续）" {
    local out
    out="$(run_one_round "$RUN_DIR" 1 "$TEST_TMPDIR/redesign/sample.md" 2 5)"
    [[ "$out" == *"CONTINUE"* ]]
}

@test "run_one_round 立场至少 1 个 con" {
    run_one_round "$RUN_DIR" 1 "$TEST_TMPDIR/redesign/sample.md" 2 5
    grep -q ": con" "$RUN_DIR/R1/stances.yaml"
}

@test "run_design_review 完整跑：2 轮收敛" {
    run run_design_review "$RUN_DIR" "$TEST_TMPDIR/redesign/sample.md" 2 5
    [ "$status" -eq 0 ]
    [ -f "$RUN_DIR/R2/consensus.yaml" ]
    [ "$(state_get "$RUN_DIR" status)" = "converged" ]
}

@test "run_design_review max=1 → MAX_REACHED 强停" {
    run run_design_review "$RUN_DIR" "$TEST_TMPDIR/redesign/sample.md" 1 1
    [ "$status" -eq 0 ]
    [ "$(state_get "$RUN_DIR" status)" = "max_reached" ]
}

@test "run_design_review 2 队缺席 → exit 2 + status=aborted" {
    export DR_PHASE_CASE_OVERRIDE="no-such-case"
    run run_design_review "$RUN_DIR" "$TEST_TMPDIR/redesign/sample.md" 2 5
    [ "$status" -eq 2 ]
    [ "$(state_get "$RUN_DIR" status)" = "aborted" ]
}
