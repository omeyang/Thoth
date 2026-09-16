#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/errors.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/vote.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "classify_votes 4-0 → 必修" {
    run classify_votes 4 0
    [ "$status" -eq 0 ]
    [ "$output" = "必修" ]
}

@test "classify_votes 3-1 → 必修" {
    run classify_votes 3 1
    [ "$output" = "必修" ]
}

@test "classify_votes 2-2 → 存疑" {
    run classify_votes 2 2
    [ "$output" = "存疑" ]
}

@test "classify_votes 1-3 → 舍弃" {
    run classify_votes 1 3
    [ "$output" = "舍弃" ]
}

@test "classify_votes 0-4 → 舍弃" {
    run classify_votes 0 4
    [ "$output" = "舍弃" ]
}

@test "classify_votes 非法输入退非零" {
    run classify_votes 5 0
    [ "$status" -ne 0 ]
}

@test "merge_findings canonical_text 含双引号 → cross-attack.yaml 仍合法且文本完整" {
    cat > t1.yaml <<'EOF'
team: T1
findings:
  - {id: T1-f1, canonical_text: 'grayVersion="" 隐式表达，缺显式开关', severity: P2}
EOF
    for t in t2 t3 t4; do printf 'team: X\nfindings: []\n' > "$t.yaml"; done
    run merge_findings t1.yaml t2.yaml t3.yaml t4.yaml cross.yaml
    [ "$status" -eq 0 ]
    yq e '.' cross.yaml >/dev/null
    [ "$(yq e '.cross_findings[0].canonical_text' cross.yaml)" = 'grayVersion="" 隐式表达，缺显式开关' ]
}

@test "tally_votes agree+covered vs refute+discard" {
    local result
    result="$(tally_votes "$FIXTURES_DIR/votes-all-agree.yaml" cf-001)"
    [ "$result" = "4 0" ]
}

@test "tally_votes 2-2 计票" {
    local result
    result="$(tally_votes "$FIXTURES_DIR/votes-disputed.yaml" cf-001)"
    [ "$result" = "2 2" ]
}

@test "tally_votes refute+discard 都算反对" {
    local result
    result="$(tally_votes "$FIXTURES_DIR/votes-refuted.yaml" cf-001)"
    [ "$result" = "0 4" ]
}

@test "classify_cross_finding 端到端：all-agree 文件→必修" {
    run classify_cross_finding "$FIXTURES_DIR/votes-all-agree.yaml" cf-001
    [ "$status" -eq 0 ]
    [ "$output" = "必修" ]
}

@test "classify_cross_finding 端到端：disputed 文件→存疑" {
    run classify_cross_finding "$FIXTURES_DIR/votes-disputed.yaml" cf-001
    [ "$output" = "存疑" ]
}

@test "merge_findings 4 份 teamreport → cross_findings 文件" {
    for t in T1 T2 T3 T4; do
        cat > "$TEST_TMPDIR/teamreport-${t}.yaml" <<EOF
team: $t
findings:
  - id: ${t}-f1
    canonical_text: "shared finding text"
    severity: P0
EOF
    done
    run merge_findings \
        "$TEST_TMPDIR/teamreport-T1.yaml" \
        "$TEST_TMPDIR/teamreport-T2.yaml" \
        "$TEST_TMPDIR/teamreport-T3.yaml" \
        "$TEST_TMPDIR/teamreport-T4.yaml" \
        "$TEST_TMPDIR/cross.yaml"
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMPDIR/cross.yaml" ]
    local count
    count="$(yq eval '.cross_findings | length' "$TEST_TMPDIR/cross.yaml")"
    [ "$count" -eq 1 ]
}

@test "merge_findings 不同 text → 分别 cross-finding" {
    cat > "$TEST_TMPDIR/teamreport-T1.yaml" <<'EOF'
team: T1
findings:
  - {id: T1-f1, canonical_text: "finding A", severity: P0}
EOF
    cat > "$TEST_TMPDIR/teamreport-T2.yaml" <<'EOF'
team: T2
findings:
  - {id: T2-f1, canonical_text: "finding B", severity: P1}
EOF
    cat > "$TEST_TMPDIR/teamreport-T3.yaml" <<'EOF'
team: T3
findings: []
EOF
    cat > "$TEST_TMPDIR/teamreport-T4.yaml" <<'EOF'
team: T4
findings: []
EOF
    merge_findings \
        "$TEST_TMPDIR/teamreport-T1.yaml" \
        "$TEST_TMPDIR/teamreport-T2.yaml" \
        "$TEST_TMPDIR/teamreport-T3.yaml" \
        "$TEST_TMPDIR/teamreport-T4.yaml" \
        "$TEST_TMPDIR/cross.yaml"
    local count
    count="$(yq eval '.cross_findings | length' "$TEST_TMPDIR/cross.yaml")"
    [ "$count" -eq 2 ]
}

@test "_text_similarity 近义对高分 / 不同对低分" {
    local s1 s2
    s1="$(_text_similarity \
        "check_version 数据未就绪在基线是等待，Scheduler loading 超时会误判为加载失败" \
        "check_version 数据未就绪会被调度超时误判为 load_failed")"
    s2="$(_text_similarity \
        "check_version 数据未就绪会被调度超时误判为 load_failed" \
        "graceful 搬迁 loaded→切流 未承接双 Pod 重叠期缓存一致性握手")"
    [ "$s1" -ge 30 ]
    [ "$s2" -lt 30 ]
}

@test "merge_findings 近义 finding（同严重度）合并为 1 条 + 两队 agree" {
    cat > "$TEST_TMPDIR/teamreport-T1.yaml" <<'EOF'
team: T1
findings:
  - {id: T1-f1, canonical_text: "check_version 数据未就绪在基线是等待，Scheduler loading 超时会误判为加载失败", severity: P2}
EOF
    cat > "$TEST_TMPDIR/teamreport-T2.yaml" <<'EOF'
team: T2
findings: []
EOF
    cat > "$TEST_TMPDIR/teamreport-T3.yaml" <<'EOF'
team: T3
findings:
  - {id: T3-f1, canonical_text: "check_version 数据未就绪会被调度超时误判为 load_failed", severity: P2}
EOF
    cat > "$TEST_TMPDIR/teamreport-T4.yaml" <<'EOF'
team: T4
findings: []
EOF
    merge_findings \
        "$TEST_TMPDIR/teamreport-T1.yaml" "$TEST_TMPDIR/teamreport-T2.yaml" \
        "$TEST_TMPDIR/teamreport-T3.yaml" "$TEST_TMPDIR/teamreport-T4.yaml" \
        "$TEST_TMPDIR/cross.yaml"
    [ "$(yq eval '.cross_findings | length' "$TEST_TMPDIR/cross.yaml")" -eq 1 ]
    [ "$(yq eval '.cross_findings[0].votes.T1' "$TEST_TMPDIR/cross.yaml")" = "agree" ]
    [ "$(yq eval '.cross_findings[0].votes.T3' "$TEST_TMPDIR/cross.yaml")" = "agree" ]
}

@test "merge_findings 不同 finding（同严重度）不误并" {
    cat > "$TEST_TMPDIR/teamreport-T1.yaml" <<'EOF'
team: T1
findings:
  - {id: T1-f1, canonical_text: "allocation 未承接租户资产数量上限", severity: P1}
EOF
    cat > "$TEST_TMPDIR/teamreport-T2.yaml" <<'EOF'
team: T2
findings:
  - {id: T2-f1, canonical_text: "graceful 搬迁 loaded→切流 未承接双 Pod 重叠期缓存一致性握手", severity: P1}
EOF
    cat > "$TEST_TMPDIR/teamreport-T3.yaml" <<'EOF'
team: T3
findings: []
EOF
    cat > "$TEST_TMPDIR/teamreport-T4.yaml" <<'EOF'
team: T4
findings: []
EOF
    merge_findings \
        "$TEST_TMPDIR/teamreport-T1.yaml" "$TEST_TMPDIR/teamreport-T2.yaml" \
        "$TEST_TMPDIR/teamreport-T3.yaml" "$TEST_TMPDIR/teamreport-T4.yaml" \
        "$TEST_TMPDIR/cross.yaml"
    [ "$(yq eval '.cross_findings | length' "$TEST_TMPDIR/cross.yaml")" -eq 2 ]
}

@test "merge_findings DR_DEDUP_THRESHOLD 可调高到禁用近义合并" {
    cat > "$TEST_TMPDIR/teamreport-T1.yaml" <<'EOF'
team: T1
findings:
  - {id: T1-f1, canonical_text: "check_version 数据未就绪在基线是等待，Scheduler loading 超时会误判为加载失败", severity: P2}
EOF
    cat > "$TEST_TMPDIR/teamreport-T2.yaml" <<'EOF'
team: T2
findings: []
EOF
    cat > "$TEST_TMPDIR/teamreport-T3.yaml" <<'EOF'
team: T3
findings:
  - {id: T3-f1, canonical_text: "check_version 数据未就绪会被调度超时误判为 load_failed", severity: P2}
EOF
    cat > "$TEST_TMPDIR/teamreport-T4.yaml" <<'EOF'
team: T4
findings: []
EOF
    DR_DEDUP_THRESHOLD=95 merge_findings \
        "$TEST_TMPDIR/teamreport-T1.yaml" "$TEST_TMPDIR/teamreport-T2.yaml" \
        "$TEST_TMPDIR/teamreport-T3.yaml" "$TEST_TMPDIR/teamreport-T4.yaml" \
        "$TEST_TMPDIR/cross.yaml"
    [ "$(yq eval '.cross_findings | length' "$TEST_TMPDIR/cross.yaml")" -eq 2 ]
}
