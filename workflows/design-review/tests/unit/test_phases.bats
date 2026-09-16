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
    source "$SCRIPTS_DIR/lib/finding.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/failure.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/state.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/agent.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/phases.sh"

    inject_mocks
    export DR_CALL_TIMEOUT_SEC=10
    export DR_CALL_RETRY=0

    # CFG_TEAMS 默认值
    declare -gA CFG_TEAMS=( [T1]=claude [T2]=codex [T3]=claude [T4]=codex )

    RUN_DIR="$TEST_TMPDIR/run"
    mkdir -p "$RUN_DIR/R1"
    state_init "$RUN_DIR" "smoke-run" "redesign/sample.md" ".design-review.yaml"
    cat > "$RUN_DIR/R1/stances.yaml" <<'EOF'
T1: pro
T2: con
T3: neutral
T4: pro
EOF

    echo "# sample" > "$TEST_TMPDIR/sample.md"

    # 用 phases case 避免 smoke 字段 team_id 与 _is_team_absent 看 team 的冲突
    export DR_PHASE_CASE_OVERRIDE="phases"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset DR_CALL_TIMEOUT_SEC DR_CALL_RETRY DR_PHASE_CASE_OVERRIDE
}

@test "run_phase_a 4 队全到 → 4 份合并 teamreport + exit 0" {
    run run_phase_a "$RUN_DIR/R1" "$RUN_DIR/R1/stances.yaml" \
        "$TEST_TMPDIR/sample.md" "$RUN_DIR" 1
    [ "$status" -eq 0 ]
    for t in T1 T2 T3 T4; do
        [ -f "$RUN_DIR/R1/teamreport-${t}.yaml" ]
    done
    # 队内合议后顶层身份用真实 team（非各角色文件自报的 mock 值）
    grep -q "team: T1" "$RUN_DIR/R1/teamreport-T1.yaml"
}

@test "run_phase_a 每队扇出全部 5 角色 → 落 role-T-Rn.yaml" {
    run_phase_a "$RUN_DIR/R1" "$RUN_DIR/R1/stances.yaml" \
        "$TEST_TMPDIR/sample.md" "$RUN_DIR" 1
    # T1 应有 R1-R5 共 5 份角色输出
    for r in R1 R2 R3 R4 R5; do
        [ -f "$RUN_DIR/R1/role-T1-${r}.yaml" ]
    done
    # 4 队 × 5 角色 = 20 份角色输出
    [ "$(ls "$RUN_DIR/R1"/role-T*-R*.yaml | wc -l)" -eq 20 ]
}

@test "run_phase_a 落 per-role prompt 文件且角色/立场正确" {
    run_phase_a "$RUN_DIR/R1" "$RUN_DIR/R1/stances.yaml" \
        "$TEST_TMPDIR/sample.md" "$RUN_DIR" 1
    # T1 stance=pro：R1 prompt 含 基线考古员；R3 prompt 含闭环裁判
    [ -f "$RUN_DIR/R1/prompt-T1-R1.txt" ]
    [ -f "$RUN_DIR/R1/prompt-T1-R3.txt" ]
    grep -q "基线考古员" "$RUN_DIR/R1/prompt-T1-R1.txt"
    grep -q "立场：pro" "$RUN_DIR/R1/prompt-T1-R1.txt"
    grep -q "闭环" "$RUN_DIR/R1/prompt-T1-R3.txt"
}

@test "run_phase_a 尊重 DR_ENABLED_ROLES 子集 → 每队只跑指定角色" {
    declare -a DR_ENABLED_ROLES=(R1 R3)
    run_phase_a "$RUN_DIR/R1" "$RUN_DIR/R1/stances.yaml" \
        "$TEST_TMPDIR/sample.md" "$RUN_DIR" 1
    [ -f "$RUN_DIR/R1/role-T1-R1.yaml" ]
    [ -f "$RUN_DIR/R1/role-T1-R3.yaml" ]
    [ ! -f "$RUN_DIR/R1/role-T1-R2.yaml" ]
    [ ! -f "$RUN_DIR/R1/role-T1-R5.yaml" ]
    # 2 角色 × 4 队 = 8 份
    [ "$(ls "$RUN_DIR/R1"/role-T*-R*.yaml | wc -l)" -eq 8 ]
}

@test "run_phase_a 2 队 mock 失败 → exit 2" {
    export DR_PHASE_CASE_OVERRIDE="no-such-case"
    run run_phase_a "$RUN_DIR/R1" "$RUN_DIR/R1/stances.yaml" \
        "$TEST_TMPDIR/sample.md" "$RUN_DIR" 1
    [ "$status" -eq 2 ]
}

@test "run_phase_b 把 4 队 teamreport 合并到 cross-attack.yaml" {
    cat > "$RUN_DIR/R1/teamreport-T1.yaml" <<'EOF'
team: T1
findings:
  - {id: T1-f1, canonical_text: "shared finding", severity: P0}
EOF
    cat > "$RUN_DIR/R1/teamreport-T2.yaml" <<'EOF'
team: T2
findings:
  - {id: T2-f1, canonical_text: "shared finding", severity: P0}
EOF
    cat > "$RUN_DIR/R1/teamreport-T3.yaml" <<'EOF'
team: T3
findings:
  - {id: T3-f1, canonical_text: "T3 unique", severity: P1}
EOF
    cat > "$RUN_DIR/R1/teamreport-T4.yaml" <<'EOF'
team: T4
findings: []
EOF
    run run_phase_b "$RUN_DIR/R1"
    [ "$status" -eq 0 ]
    [ -f "$RUN_DIR/R1/cross-attack.yaml" ]
    [ "$(yq eval '.cross_findings | length' "$RUN_DIR/R1/cross-attack.yaml")" -eq 2 ]
}

@test "_apply_cross_votes 改 unknown 票、保留 proposer agree" {
    cat > "$RUN_DIR/R1/cross-attack.yaml" <<'EOF'
cross_findings:
  - cross_id: cf-001
    canonical_text: "X"
    severity: P1
    votes: {T1: unknown, T2: unknown, T3: agree, T4: unknown}
EOF
    cat > "$RUN_DIR/R1/vote-T1.yaml" <<'EOF'
team: T1
votes:
  - cross_id: cf-001
    vote: refute
    reason: "no evidence"
EOF
    _apply_cross_votes "$RUN_DIR/R1/cross-attack.yaml" T1 "$RUN_DIR/R1/vote-T1.yaml"
    [ "$(yq eval '.cross_findings[0].votes.T1' "$RUN_DIR/R1/cross-attack.yaml")" = "refute" ]
    [ "$(yq eval '.cross_findings[0].votes.T3' "$RUN_DIR/R1/cross-attack.yaml")" = "agree" ]
}

@test "_apply_cross_votes 不覆盖已有非 unknown 票" {
    cat > "$RUN_DIR/R1/cross-attack.yaml" <<'EOF'
cross_findings:
  - cross_id: cf-001
    canonical_text: "X"
    severity: P1
    votes: {T1: agree, T2: unknown, T3: agree, T4: unknown}
EOF
    cat > "$RUN_DIR/R1/vote-T1.yaml" <<'EOF'
team: T1
votes:
  - cross_id: cf-001
    vote: refute
EOF
    _apply_cross_votes "$RUN_DIR/R1/cross-attack.yaml" T1 "$RUN_DIR/R1/vote-T1.yaml"
    [ "$(yq eval '.cross_findings[0].votes.T1' "$RUN_DIR/R1/cross-attack.yaml")" = "agree" ]
}

@test "run_cross_attack 对 unknown 票真投票后写回 cross-attack" {
    export DR_PHASE_CASE_OVERRIDE="split"
    cat > "$RUN_DIR/R1/cross-attack.yaml" <<'EOF'
cross_findings:
  - cross_id: cf-001
    canonical_text: "split 发现 X"
    severity: P1
    votes: {T1: unknown, T2: unknown, T3: agree, T4: unknown}
  - cross_id: cf-002
    canonical_text: "split 发现 Y"
    severity: P1
    votes: {T1: unknown, T2: unknown, T3: unknown, T4: agree}
EOF
    echo "# doc" > "$TEST_TMPDIR/sample.md"
    run_cross_attack "$RUN_DIR/R1" 1 "$TEST_TMPDIR/sample.md" "$RUN_DIR"
    local cross="$RUN_DIR/R1/cross-attack.yaml"
    [ "$(yq eval '.cross_findings[] | select(.cross_id=="cf-001").votes.T1' "$cross")" = "refute" ]
    [ "$(yq eval '.cross_findings[] | select(.cross_id=="cf-001").votes.T2' "$cross")" = "refute" ]
    [ "$(yq eval '.cross_findings[] | select(.cross_id=="cf-001").votes.T4' "$cross")" = "agree" ]
    # cf-001 应已无 unknown（4 票齐）
    [ "$(yq eval '[.cross_findings[] | select(.cross_id=="cf-001").votes.[] | select(. == "unknown")] | length' "$cross")" -eq 0 ]
}

@test "run_phase_c 把 cross-attack 分类到 consensus" {
    cat > "$RUN_DIR/R1/cross-attack.yaml" <<'EOF'
cross_findings:
  - cross_id: cf-001
    canonical_text: "all agree"
    severity: P0
    votes: {T1: agree, T2: agree, T3: agree, T4: agree}
  - cross_id: cf-002
    canonical_text: "2-2 split"
    severity: P1
    votes: {T1: agree, T2: refute, T3: agree, T4: refute}
EOF
    run run_phase_c "$RUN_DIR/R1"
    [ "$status" -eq 0 ]
    [ -f "$RUN_DIR/R1/consensus.yaml" ]
    [ "$(yq eval '.findings[] | select(.cross_id == "cf-001") | .classification' "$RUN_DIR/R1/consensus.yaml")" = "必修" ]
    [ "$(yq eval '.findings[] | select(.cross_id == "cf-002") | .classification' "$RUN_DIR/R1/consensus.yaml")" = "存疑" ]
}

@test "run_phase_d round=1 min=2 → CONTINUE（强制最低轮）" {
    cat > "$RUN_DIR/R1/consensus.yaml" <<'EOF'
round: 1
findings:
  - cross_id: cf-001
    classification: 必修
    votes: {T1: agree, T2: agree, T3: agree, T4: agree}
EOF
    mkdir -p "$RUN_DIR/R2"
    cp "$RUN_DIR/R1/consensus.yaml" "$RUN_DIR/R2/consensus.yaml"

    run run_phase_d "$RUN_DIR/R2/consensus.yaml" "$RUN_DIR/R1/consensus.yaml" \
        1 2 5 "$RUN_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CONTINUE"* ]]
}

@test "run_phase_d 无变化且 round>=min → CONVERGED" {
    cat > "$RUN_DIR/R1/consensus.yaml" <<'EOF'
round: 1
findings:
  - cross_id: cf-001
    classification: 必修
    votes: {T1: agree, T2: agree, T3: agree, T4: agree}
EOF
    mkdir -p "$RUN_DIR/R2"
    cp "$RUN_DIR/R1/consensus.yaml" "$RUN_DIR/R2/consensus.yaml"

    run run_phase_d "$RUN_DIR/R2/consensus.yaml" "$RUN_DIR/R1/consensus.yaml" \
        2 2 5 "$RUN_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CONVERGED"* ]]
}
