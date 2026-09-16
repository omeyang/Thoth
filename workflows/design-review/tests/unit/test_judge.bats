#!/usr/bin/env bats
# 闭环裁判去偏：异质双裁判 + 位置交换 + 一致性合并
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
    source "$SCRIPTS_DIR/lib/finding.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/failure.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/state.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/agent.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/judge.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/phases.sh"

    inject_mocks
    export DR_CALL_TIMEOUT_SEC=10
    export DR_CALL_RETRY=0
    declare -gA CFG_TEAMS=( [T1]=claude [T2]=codex [T3]=claude [T4]=codex )

    RUN_DIR="$TEST_TMPDIR/run"
    mkdir -p "$RUN_DIR/R1"
    echo "# doc" > "$TEST_TMPDIR/sample.md"

    # 两裁判都走 mock-claude/codex（指向同一 mock 脚本）
    export DR_JUDGE_TOOL_A="claude"
    export DR_JUDGE_TOOL_B="codex"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset DR_CALL_TIMEOUT_SEC DR_CALL_RETRY DR_DUAL_JUDGE DR_JUDGE_CASE_OVERRIDE \
          DR_JUDGE_TOOL_A DR_JUDGE_TOOL_B
}

_one_cross_finding() {
    cat > "$RUN_DIR/R1/cross-attack.yaml" <<'EOF'
cross_findings:
  - cross_id: cf-001
    canonical_text: "X"
    severity: P1
    votes: {T1: agree, T2: agree, T3: agree, T4: unknown}
EOF
}

# ---- reconcile_judges：一致才采信 ----

@test "reconcile_judges 两裁判一致 uphold → uphold" {
    run reconcile_judges uphold uphold
    [ "$output" = "uphold" ]
}

@test "reconcile_judges 两裁判一致 reject → reject" {
    run reconcile_judges reject reject
    [ "$output" = "reject" ]
}

@test "reconcile_judges 方向不一致 → needs-info（不多数碾压）" {
    run reconcile_judges uphold reject
    [ "$output" = "needs-info" ]
}

@test "reconcile_judges uphold vs needs-info → needs-info" {
    run reconcile_judges uphold needs-info
    [ "$output" = "needs-info" ]
}

# ---- _judge_enabled：配置开关 ----

@test "_judge_enabled 默认开" {
    unset DR_DUAL_JUDGE
    run _judge_enabled
    [ "$status" -eq 0 ]
}

@test "_judge_enabled DR_DUAL_JUDGE=0 关" {
    export DR_DUAL_JUDGE=0
    run _judge_enabled
    [ "$status" -ne 0 ]
}

# ---- 位置交换：A 正序 / B 逆序 ----

@test "_build_judge_pending 正序 vs 逆序 cross_id 顺序相反" {
    cat > "$RUN_DIR/R1/cross-attack.yaml" <<'EOF'
cross_findings:
  - {cross_id: cf-001, canonical_text: "A", severity: P1, votes: {T1: agree}}
  - {cross_id: cf-002, canonical_text: "B", severity: P1, votes: {T1: agree}}
  - {cross_id: cf-003, canonical_text: "C", severity: P1, votes: {T1: agree}}
EOF
    _build_judge_pending "$RUN_DIR/R1/cross-attack.yaml" "$RUN_DIR/R1/pA.yaml" 0
    _build_judge_pending "$RUN_DIR/R1/cross-attack.yaml" "$RUN_DIR/R1/pB.yaml" 1
    local fwd rev
    fwd="$(yq eval '.cross_findings[].cross_id' "$RUN_DIR/R1/pA.yaml" | tr '\n' ' ')"
    rev="$(yq eval '.cross_findings[].cross_id' "$RUN_DIR/R1/pB.yaml" | tr '\n' ' ')"
    [ "$fwd" = "cf-001 cf-002 cf-003 " ]
    [ "$rev" = "cf-003 cf-002 cf-001 " ]
}

@test "run_dual_judge 真喂给 B 的 prompt 是逆序" {
    export DR_JUDGE_CASE_OVERRIDE="judge-agree"
    cat > "$RUN_DIR/R1/cross-attack.yaml" <<'EOF'
cross_findings:
  - {cross_id: cf-001, canonical_text: "A", severity: P1, votes: {T1: agree}}
  - {cross_id: cf-002, canonical_text: "B", severity: P1, votes: {T1: agree}}
EOF
    for t in T1 T2 T3 T4; do echo "team: $t" > "$RUN_DIR/R1/teamreport-${t}.yaml"; done
    run_dual_judge "$RUN_DIR/R1" 1 "$TEST_TMPDIR/sample.md" "$RUN_DIR"
    # 位置交换契约：A 正序（cf-001 在前）、B 逆序（cf-002 在前）
    local a_order b_order
    a_order="$(yq eval '.cross_findings[].cross_id' "$RUN_DIR/R1/judge-pending-A.yaml" | tr '\n' ' ')"
    b_order="$(yq eval '.cross_findings[].cross_id' "$RUN_DIR/R1/judge-pending-B.yaml" | tr '\n' ' ')"
    [ "$a_order" = "cf-001 cf-002 " ]
    [ "$b_order" = "cf-002 cf-001 " ]
    # 两 prompt 真传给了裁判（文件存在且非空）
    [ -s "$RUN_DIR/R1/judge-prompt-A.txt" ]
    [ -s "$RUN_DIR/R1/judge-prompt-B.txt" ]
}

# ---- run_dual_judge：一致 → 采信；不一致 → NEEDS-INFO ----

@test "run_dual_judge 两裁判一致 uphold → dual-judge.yaml reconciled=uphold" {
    export DR_JUDGE_CASE_OVERRIDE="judge-agree"
    _one_cross_finding
    for t in T1 T2 T3 T4; do echo "team: $t" > "$RUN_DIR/R1/teamreport-${t}.yaml"; done
    run_dual_judge "$RUN_DIR/R1" 1 "$TEST_TMPDIR/sample.md" "$RUN_DIR"
    [ -f "$RUN_DIR/R1/dual-judge.yaml" ]
    [ "$(yq eval '.verdicts[] | select(.cross_id=="cf-001").reconciled' "$RUN_DIR/R1/dual-judge.yaml")" = "uphold" ]
}

@test "run_dual_judge 两裁判分歧 → reconciled=needs-info" {
    export DR_JUDGE_CASE_OVERRIDE="judge-disagree"
    _one_cross_finding
    for t in T1 T2 T3 T4; do echo "team: $t" > "$RUN_DIR/R1/teamreport-${t}.yaml"; done
    run_dual_judge "$RUN_DIR/R1" 1 "$TEST_TMPDIR/sample.md" "$RUN_DIR"
    [ "$(yq eval '.verdicts[] | select(.cross_id=="cf-001").judge_a' "$RUN_DIR/R1/dual-judge.yaml")" = "uphold" ]
    [ "$(yq eval '.verdicts[] | select(.cross_id=="cf-001").judge_b' "$RUN_DIR/R1/dual-judge.yaml")" = "reject" ]
    [ "$(yq eval '.verdicts[] | select(.cross_id=="cf-001").reconciled' "$RUN_DIR/R1/dual-judge.yaml")" = "needs-info" ]
}

@test "run_dual_judge DR_DUAL_JUDGE=0 → 跳过，不产 dual-judge.yaml" {
    export DR_DUAL_JUDGE=0
    export DR_JUDGE_CASE_OVERRIDE="judge-agree"
    _one_cross_finding
    run run_dual_judge "$RUN_DIR/R1" 1 "$TEST_TMPDIR/sample.md" "$RUN_DIR"
    [ "$status" -ne 0 ]
    [ ! -f "$RUN_DIR/R1/dual-judge.yaml" ]
}

# ---- judge_final_classification：与 vote.sh 衔接 ----

@test "judge_final_classification uphold → 交回票数算（3agree-0 → 必修）" {
    cat > "$RUN_DIR/R1/cross-attack.yaml" <<'EOF'
cross_findings:
  - {cross_id: cf-001, canonical_text: X, severity: P0, votes: {T1: agree, T2: agree, T3: agree, T4: agree}}
EOF
    cat > "$RUN_DIR/R1/dual-judge.yaml" <<'EOF'
verdicts:
  - {cross_id: cf-001, judge_a: uphold, judge_b: uphold, reconciled: uphold}
EOF
    run judge_final_classification "$RUN_DIR/R1/cross-attack.yaml" "$RUN_DIR/R1/dual-judge.yaml" cf-001
    [ "$output" = "必修" ]
}

@test "judge_final_classification reject → 舍弃（碾过票数）" {
    cat > "$RUN_DIR/R1/cross-attack.yaml" <<'EOF'
cross_findings:
  - {cross_id: cf-001, canonical_text: X, severity: P0, votes: {T1: agree, T2: agree, T3: agree, T4: agree}}
EOF
    cat > "$RUN_DIR/R1/dual-judge.yaml" <<'EOF'
verdicts:
  - {cross_id: cf-001, judge_a: reject, judge_b: reject, reconciled: reject}
EOF
    run judge_final_classification "$RUN_DIR/R1/cross-attack.yaml" "$RUN_DIR/R1/dual-judge.yaml" cf-001
    [ "$output" = "舍弃" ]
}

@test "judge_final_classification needs-info + 弱票(2-2) → NEEDS-INFO" {
    cat > "$RUN_DIR/R1/cross-attack.yaml" <<'EOF'
cross_findings:
  - {cross_id: cf-001, canonical_text: X, severity: P0, votes: {T1: agree, T2: refute, T3: agree, T4: refute}}
EOF
    cat > "$RUN_DIR/R1/dual-judge.yaml" <<'EOF'
verdicts:
  - {cross_id: cf-001, judge_a: uphold, judge_b: reject, reconciled: needs-info}
EOF
    run judge_final_classification "$RUN_DIR/R1/cross-attack.yaml" "$RUN_DIR/R1/dual-judge.yaml" cf-001
    [ "$output" = "NEEDS-INFO" ]
}

@test "judge_final_classification needs-info + 团队 4-0 强共识 → 必修（共识压过裁判分歧）" {
    cat > "$RUN_DIR/R1/cross-attack.yaml" <<'EOF'
cross_findings:
  - {cross_id: cf-001, canonical_text: X, severity: P0, votes: {T1: agree, T2: agree, T3: agree, T4: agree}}
EOF
    cat > "$RUN_DIR/R1/dual-judge.yaml" <<'EOF'
verdicts:
  - {cross_id: cf-001, judge_a: uphold, judge_b: needs-info, reconciled: needs-info}
EOF
    run judge_final_classification "$RUN_DIR/R1/cross-attack.yaml" "$RUN_DIR/R1/dual-judge.yaml" cf-001
    [ "$output" = "必修" ]
}

@test "judge_final_classification needs-info + 团队 3-1 → 必修" {
    cat > "$RUN_DIR/R1/cross-attack.yaml" <<'EOF'
cross_findings:
  - {cross_id: cf-001, canonical_text: X, severity: P1, votes: {T1: agree, T2: agree, T3: agree, T4: refute}}
EOF
    cat > "$RUN_DIR/R1/dual-judge.yaml" <<'EOF'
verdicts:
  - {cross_id: cf-001, judge_a: needs-info, judge_b: needs-info, reconciled: needs-info}
EOF
    run judge_final_classification "$RUN_DIR/R1/cross-attack.yaml" "$RUN_DIR/R1/dual-judge.yaml" cf-001
    [ "$output" = "必修" ]
}

@test "judge_final_classification 无 dual 记录 → 退回纯票数（向后兼容）" {
    cat > "$RUN_DIR/R1/cross-attack.yaml" <<'EOF'
cross_findings:
  - {cross_id: cf-001, canonical_text: X, severity: P0, votes: {T1: agree, T2: refute, T3: agree, T4: refute}}
EOF
    echo "verdicts: []" > "$RUN_DIR/R1/dual-judge.yaml"
    run judge_final_classification "$RUN_DIR/R1/cross-attack.yaml" "$RUN_DIR/R1/dual-judge.yaml" cf-001
    [ "$output" = "存疑" ]
}

# ---- run_phase_c 集成：双裁判分歧落 NEEDS-INFO 进 consensus ----

@test "run_phase_c 全参 + 双裁判分歧 → consensus 该条 NEEDS-INFO" {
    export DR_JUDGE_CASE_OVERRIDE="judge-disagree"
    _one_cross_finding
    for t in T1 T2 T3 T4; do echo "team: $t" > "$RUN_DIR/R1/teamreport-${t}.yaml"; done
    run run_phase_c "$RUN_DIR/R1" 1 "$TEST_TMPDIR/sample.md" "$RUN_DIR"
    [ "$status" -eq 0 ]
    [ "$(yq eval '.findings[] | select(.cross_id=="cf-001").classification' "$RUN_DIR/R1/consensus.yaml")" = "NEEDS-INFO" ]
}

@test "run_phase_c 少参（旧调用）→ 纯票数路径，不跑双裁判" {
    cat > "$RUN_DIR/R1/cross-attack.yaml" <<'EOF'
cross_findings:
  - {cross_id: cf-001, canonical_text: X, severity: P0, votes: {T1: agree, T2: agree, T3: agree, T4: agree}}
EOF
    run run_phase_c "$RUN_DIR/R1"
    [ "$status" -eq 0 ]
    [ ! -f "$RUN_DIR/R1/dual-judge.yaml" ]
    [ "$(yq eval '.findings[] | select(.cross_id=="cf-001").classification' "$RUN_DIR/R1/consensus.yaml")" = "必修" ]
}
