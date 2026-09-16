#!/usr/bin/env bats
# 多角色队内 self-review（R1-R5）+ 队内合议 merge 的单元测试
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/errors.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/log.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/finding.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/agent.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/phases.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset DR_ENABLED_ROLES
}

# ---------- _role_template ----------

@test "_role_template R1 → legacy-archeologist" {
    run _role_template R1
    [ "$status" -eq 0 ]
    [[ "$output" == *"agent-legacy-archeologist.md" ]]
}

@test "_role_template R3 → closure-judge" {
    run _role_template R3
    [ "$status" -eq 0 ]
    [[ "$output" == *"agent-closure-judge.md" ]]
}

@test "_role_template R5 → control-audit" {
    run _role_template R5
    [ "$status" -eq 0 ]
    [[ "$output" == *"agent-control-audit.md" ]]
}

@test "_role_template 未知角色 → 非零退出" {
    run _role_template R9
    [ "$status" -ne 0 ]
}

# ---------- _enabled_roles ----------

@test "_enabled_roles 默认 → R1..R5 全 5 个" {
    unset DR_ENABLED_ROLES
    run _enabled_roles
    [ "$status" -eq 0 ]
    [ "$output" = "R1 R2 R3 R4 R5" ]
}

@test "_enabled_roles 尊重 DR_ENABLED_ROLES" {
    declare -a DR_ENABLED_ROLES=(R1 R3)
    run _enabled_roles
    [ "$status" -eq 0 ]
    [ "$output" = "R1 R3" ]
}

# ---------- merge_role_reports（队内合议） ----------

@test "merge_role_reports 合并多角色不同 findings + 顶层身份正确" {
    cat > role-T1-R1.yaml <<'EOF'
team: T1
findings:
  - {id: T1-f1, source_role: R1, canonical_text: "基线契约 X", severity: P1}
EOF
    cat > role-T1-R3.yaml <<'EOF'
team: T1
findings:
  - {id: T1-f9, source_role: R3, canonical_text: "闭环 Y", severity: P2}
EOF
    run merge_role_reports out.yaml T1 pro 2 role-T1-R1.yaml role-T1-R3.yaml
    [ "$status" -eq 0 ]
    [ "$(yq eval '.team' out.yaml)" = "T1" ]
    [ "$(yq eval '.stance' out.yaml)" = "pro" ]
    [ "$(yq eval '.round' out.yaml)" = "2" ]
    [ "$(yq eval '.findings | length' out.yaml)" -eq 2 ]
}

@test "merge_role_reports 跨角色同 canonical_text 去重为 1 条" {
    cat > role-T1-R1.yaml <<'EOF'
team: T1
findings:
  - {id: T1-f1, source_role: R1, canonical_text: "同一个问题", severity: P1}
EOF
    cat > role-T1-R2.yaml <<'EOF'
team: T1
findings:
  - {id: T1-f2, source_role: R2, canonical_text: "同一个问题", severity: P1}
EOF
    run merge_role_reports out.yaml T1 con 1 role-T1-R1.yaml role-T1-R2.yaml
    [ "$status" -eq 0 ]
    [ "$(yq eval '.findings | length' out.yaml)" -eq 1 ]
}

@test "merge_role_reports 跳过非法角色文件，用合法的产出" {
    cat > role-T1-R1.yaml <<'EOF'
team: T1
findings:
  - {id: T1-f1, source_role: R1, canonical_text: "合法发现", severity: P1}
EOF
    printf 'this is not: [valid yaml\n' > role-T1-R4.yaml
    run merge_role_reports out.yaml T1 neutral 1 role-T1-R1.yaml role-T1-R4.yaml
    [ "$status" -eq 0 ]
    [ -f out.yaml ]
    [ "$(yq eval '.findings | length' out.yaml)" -eq 1 ]
}

@test "merge_role_reports 合法但 0 findings → 合法空报告 + exit 0" {
    cat > role-T1-R1.yaml <<'EOF'
team: T1
findings: []
EOF
    run merge_role_reports out.yaml T1 pro 1 role-T1-R1.yaml
    [ "$status" -eq 0 ]
    [ -f out.yaml ]
    [ "$(yq eval '.findings | length' out.yaml)" -eq 0 ]
}

@test "merge_role_reports 全部非法 → 非零退出且不产出合法报告" {
    printf 'broken: [\n' > role-T1-R1.yaml
    printf 'also: ]broken\n' > role-T1-R2.yaml
    run merge_role_reports out.yaml T1 pro 1 role-T1-R1.yaml role-T1-R2.yaml
    [ "$status" -ne 0 ]
    # 不应产出可被 count_absent 误判为"在场"的合法 teamreport
    if [ -f out.yaml ]; then
        ! yq eval '.findings' out.yaml >/dev/null 2>&1
    fi
}
