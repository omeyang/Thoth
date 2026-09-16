#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/errors.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/config.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "load_config 读最简 yaml 后默认填充" {
    cp "$FIXTURES_DIR/minimal.yaml" "$TEST_TMPDIR/.design-review.yaml"
    load_config "$TEST_TMPDIR/.design-review.yaml"

    [ "$CFG_LLM_CLAUDE_MODEL" = "" ]
    [ "$CFG_LLM_CODEX_COMMAND" = "codex" ]
    [ "$CFG_LLM_CALL_TIMEOUT" -eq 1200 ]
    [ "$CFG_LLM_CALL_RETRY" -eq 1 ]

    [ "$CFG_ROUNDS_MIN" -eq 2 ]
    [ "$CFG_ROUNDS_MAX" -eq 5 ]

    [ "$CFG_BUDGET_TOKENS_PER_SUBAGENT" -eq 30000 ]
    [ "$CFG_BUDGET_TOKENS_PER_TEAM_ROUND" -eq 200000 ]

    [ "$CFG_POLICY_FAIL_ON_SEVERITY" = "P1" ]
    [ "${CFG_POLICY_STRICT_ON_ERROR}" = "false" ]

    [ "$CFG_OUTPUT_SUPPLEMENT_DIR" = "redesign" ]
    [ "$CFG_OUTPUT_TEMP_DIR" = "/tmp/design-review-runs" ]

    [ "$CFG_VERIFY_ENABLED" = "true" ]
}

@test "load_config 读不存在的文件报错 exit 2" {
    run load_config "$TEST_TMPDIR/no-such.yaml"
    [ "$status" -eq 2 ]
    [[ "$output" == *"配置文件不存在"* ]]
}

@test "load_config refs 至少 1 项校验" {
    cat > "$TEST_TMPDIR/empty-refs.yaml" <<'EOF'
refs:
  manifest: []
EOF
    run load_config "$TEST_TMPDIR/empty-refs.yaml"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refs.manifest 至少需 1 项"* ]]
}

@test "load_config 用户值覆盖默认" {
    cat > "$TEST_TMPDIR/custom.yaml" <<'EOF'
llm:
  claude_model: claude-sonnet-4-6
  call_timeout_seconds: 300
rounds:
  min: 1
  max: 3
refs:
  manifest:
    - {path: /tmp/fake, tier: "X"}
EOF
    load_config "$TEST_TMPDIR/custom.yaml"
    [ "$CFG_LLM_CLAUDE_MODEL" = "claude-sonnet-4-6" ]
    [ "$CFG_LLM_CALL_TIMEOUT" -eq 300 ]
    [ "$CFG_ROUNDS_MIN" -eq 1 ]
    [ "$CFG_ROUNDS_MAX" -eq 3 ]
}

@test "load_config teams 默认 T1-T4" {
    cp "$FIXTURES_DIR/minimal.yaml" "$TEST_TMPDIR/.design-review.yaml"
    load_config "$TEST_TMPDIR/.design-review.yaml"
    [ "${CFG_TEAMS[T1]}" = "claude" ]
    [ "${CFG_TEAMS[T2]}" = "codex" ]
    [ "${CFG_TEAMS[T3]}" = "claude" ]
    [ "${CFG_TEAMS[T4]}" = "codex" ]
}

@test "load_config refs 路径展开成数组" {
    cp "$FIXTURES_DIR/minimal.yaml" "$TEST_TMPDIR/.design-review.yaml"
    load_config "$TEST_TMPDIR/.design-review.yaml"
    [ "${#CFG_REFS_PATHS[@]}" -eq 1 ]
    [ "${CFG_REFS_PATHS[0]}" = "/tmp/fake-legacy" ]
    [ "${CFG_REFS_TIERS[0]}" = "基线-功能权威" ]
}

@test "load_config target.exclude 展开成数组" {
    cat > "$TEST_TMPDIR/exc.yaml" <<'EOF'
target:
  default: "redesign/*.md"
  exclude:
    - "redesign/90-followup.md"
    - "redesign/91-parameters.md"
refs:
  manifest:
    - {path: /tmp/fake, tier: "X"}
EOF
    load_config "$TEST_TMPDIR/exc.yaml"
    [ "${#CFG_TARGET_EXCLUDE[@]}" -eq 2 ]
    [ "${CFG_TARGET_EXCLUDE[0]}" = "redesign/90-followup.md" ]
    [ "${CFG_TARGET_EXCLUDE[1]}" = "redesign/91-parameters.md" ]
}

@test "load_config target.exclude 缺省为空数组" {
    cp "$FIXTURES_DIR/minimal.yaml" "$TEST_TMPDIR/.design-review.yaml"
    load_config "$TEST_TMPDIR/.design-review.yaml"
    [ "${#CFG_TARGET_EXCLUDE[@]}" -eq 0 ]
}

@test "load_config scope.focus / out_of_scope / note" {
    cat > "$TEST_TMPDIR/scope.yaml" <<'EOF'
scope:
  focus: "调度 Pod"
  out_of_scope:
    - "路由 Pod 详细设计（待补）"
    - "计算 Pod 详细设计（待补）"
  note: "先调度"
refs:
  manifest:
    - {path: /tmp/fake, tier: "X"}
EOF
    load_config "$TEST_TMPDIR/scope.yaml"
    [ "$CFG_SCOPE_FOCUS" = "调度 Pod" ]
    [ "${#CFG_SCOPE_OUT_OF_SCOPE[@]}" -eq 2 ]
    [ "${CFG_SCOPE_OUT_OF_SCOPE[0]}" = "路由 Pod 详细设计（待补）" ]
    [ "$CFG_SCOPE_NOTE" = "先调度" ]
}

@test "load_config scope 缺省为空" {
    cp "$FIXTURES_DIR/minimal.yaml" "$TEST_TMPDIR/.design-review.yaml"
    load_config "$TEST_TMPDIR/.design-review.yaml"
    [ -z "$CFG_SCOPE_FOCUS" ]
    [ "${#CFG_SCOPE_OUT_OF_SCOPE[@]}" -eq 0 ]
}

@test "load_config background.docs + relations" {
    cat > "$TEST_TMPDIR/bg.yaml" <<'EOF'
background:
  docs:
    - path: "design/00-overview.md"
      role: "系统顶层"
    - path: "redesign/01-scheduler.md"
      role: "调度详设入口"
  relations: |
    00 是顶层，01 细化。
refs:
  manifest:
    - {path: /tmp/fake, tier: "X"}
EOF
    load_config "$TEST_TMPDIR/bg.yaml"
    [ "${#CFG_BG_PATHS[@]}" -eq 2 ]
    [ "${CFG_BG_PATHS[0]}" = "design/00-overview.md" ]
    [ "${CFG_BG_ROLES[1]}" = "调度详设入口" ]
    [[ "$CFG_BG_RELATIONS" == *"00 是顶层"* ]]
}

@test "load_config background 缺省为空" {
    cp "$FIXTURES_DIR/minimal.yaml" "$TEST_TMPDIR/.design-review.yaml"
    load_config "$TEST_TMPDIR/.design-review.yaml"
    [ "${#CFG_BG_PATHS[@]}" -eq 0 ]
    [ -z "$CFG_BG_RELATIONS" ]
}
