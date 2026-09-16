#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/errors.sh"
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
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "happy path: stance → merge → classify → converge=CONVERGED" {
    local raw enforced
    raw="$(shuffle_team_stances "pro,con,neutral" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    enforced="$(enforce_con $raw)"
    [ "$(echo "$enforced" | grep -c '=con$')" -ge 1 ]

    for t in T1 T2 T3 T4; do
        cat > "$TEST_TMPDIR/teamreport-${t}.yaml" <<EOF
team: $t
findings:
  - id: ${t}-f1
    canonical_text: "scheduler 缺 inconsistent 二次失败处理"
    severity: P0
EOF
    done
    [ "$(count_absent_teams \
        "$TEST_TMPDIR/teamreport-T1.yaml" "$TEST_TMPDIR/teamreport-T2.yaml" \
        "$TEST_TMPDIR/teamreport-T3.yaml" "$TEST_TMPDIR/teamreport-T4.yaml")" -eq 0 ]

    merge_findings \
        "$TEST_TMPDIR/teamreport-T1.yaml" "$TEST_TMPDIR/teamreport-T2.yaml" \
        "$TEST_TMPDIR/teamreport-T3.yaml" "$TEST_TMPDIR/teamreport-T4.yaml" \
        "$TEST_TMPDIR/cross.yaml"
    [ "$(yq eval '.cross_findings | length' "$TEST_TMPDIR/cross.yaml")" -eq 1 ]

    [ "$(classify_cross_finding "$TEST_TMPDIR/cross.yaml" cf-001)" = "必修" ]

    cat > "$TEST_TMPDIR/c1.yaml" <<'EOF'
round: 1
findings:
  - cross_id: cf-001
    classification: 必修
    votes: {T1: agree, T2: agree, T3: agree, T4: agree}
EOF
    cat > "$TEST_TMPDIR/c2.yaml" <<'EOF'
round: 2
findings:
  - cross_id: cf-001
    classification: 必修
    votes: {T1: agree, T2: agree, T3: agree, T4: agree}
EOF

    local deltas
    deltas="$(compute_deltas "$TEST_TMPDIR/c1.yaml" "$TEST_TMPDIR/c2.yaml")"

    local decision
    # shellcheck disable=SC2086
    decision="$(decide_convergence 2 2 5 0 0 $deltas)"
    [[ "$decision" == *"CONVERGED"* ]]
}

@test "dispute path: cf-001 撕扯 3 轮 → UNRESOLVED_DISPUTE" {
    cat > "$TEST_TMPDIR/c1.yaml" <<'EOF'
round: 1
findings:
  - cross_id: cf-001
    classification: 必修
    votes: {T1: agree, T2: agree, T3: refute, T4: refute}
EOF
    cat > "$TEST_TMPDIR/c2.yaml" <<'EOF'
round: 2
findings:
  - cross_id: cf-001
    classification: 存疑
    votes: {T1: agree, T2: agree, T3: refute, T4: refute}
EOF
    cat > "$TEST_TMPDIR/c3.yaml" <<'EOF'
round: 3
findings:
  - cross_id: cf-001
    classification: 必修
    votes: {T1: agree, T2: agree, T3: refute, T4: refute}
EOF

    local stuck=0 dispute=0 deltas counters

    deltas="$(compute_deltas "$TEST_TMPDIR/c1.yaml" "$TEST_TMPDIR/c2.yaml")"
    # shellcheck disable=SC2086
    counters="$(update_stuck_dispute_counters "$stuck" "$dispute" $deltas)"
    stuck="${counters%% *}"
    dispute="${counters##* }"
    [ "$dispute" -eq 1 ]

    deltas="$(compute_deltas "$TEST_TMPDIR/c2.yaml" "$TEST_TMPDIR/c3.yaml")"
    # shellcheck disable=SC2086
    counters="$(update_stuck_dispute_counters "$stuck" "$dispute" $deltas)"
    stuck="${counters%% *}"
    dispute="${counters##* }"
    [ "$dispute" -eq 2 ]

    cat > "$TEST_TMPDIR/c4.yaml" <<'EOF'
round: 4
findings:
  - cross_id: cf-001
    classification: 存疑
    votes: {T1: agree, T2: agree, T3: refute, T4: refute}
EOF
    deltas="$(compute_deltas "$TEST_TMPDIR/c3.yaml" "$TEST_TMPDIR/c4.yaml")"
    # shellcheck disable=SC2086
    counters="$(update_stuck_dispute_counters "$stuck" "$dispute" $deltas)"
    stuck="${counters%% *}"
    dispute="${counters##* }"
    [ "$dispute" -eq 3 ]

    local decision
    # shellcheck disable=SC2086
    decision="$(decide_convergence 4 2 5 "$stuck" "$dispute" $deltas)"
    [[ "$decision" == *"UNRESOLVED_DISPUTE"* ]]
}

@test "degrade path: 当 R5 启用 → degrade_roles 去掉 R5 后 4 个" {
    local r
    r="$(degrade_roles "R1,R2,R3,R4,R5" "R5,R4,R3")"
    [ "$r" = "R1,R2,R3,R4" ]

    r="$(degrade_roles "$r" "R5,R4,R3")"
    [ "$r" = "R1,R2,R3" ]

    r="$(degrade_roles "$r" "R5,R4,R3")"
    [ "$r" = "R1,R2" ]

    run degrade_roles "$r" "R5,R4,R3"
    [ "$status" -eq 1 ]
}
