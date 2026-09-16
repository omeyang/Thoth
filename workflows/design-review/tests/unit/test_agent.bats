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
    source "$SCRIPTS_DIR/lib/agent.sh"

    inject_mocks
    export DR_CALL_TIMEOUT_SEC=5
    export DR_CALL_RETRY=0
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset DR_CALL_TIMEOUT_SEC DR_CALL_RETRY
}

@test "call_team_agent claude/T1/pro/round1/smoke 拿到预设 yaml" {
    call_team_agent claude T1 pro 1 smoke /dev/null "$TEST_TMPDIR/out.yaml"
    [ -f "$TEST_TMPDIR/out.yaml" ]
    grep -q "team_id: smoke" "$TEST_TMPDIR/out.yaml"
}

@test "call_team_agent codex/T2/con/round1/smoke 同样拿到 smoke 内容" {
    call_team_agent codex T2 con 1 smoke /dev/null "$TEST_TMPDIR/out.yaml"
    grep -q "team_id: smoke" "$TEST_TMPDIR/out.yaml"
}

@test "call_team_agent round1-T1-pro case 命中专属 fixture" {
    call_team_agent claude T1 pro 1 round1 /dev/null "$TEST_TMPDIR/out.yaml"
    grep -q "M3 阶段 A test finding" "$TEST_TMPDIR/out.yaml"
}

@test "call_team_agent round1-T1-con case 命中专属 fixture" {
    call_team_agent claude T1 con 1 round1 /dev/null "$TEST_TMPDIR/out.yaml"
    grep -q "T1 con stance finding" "$TEST_TMPDIR/out.yaml"
}

@test "call_team_agent mock 缺 fixture → exit 99 透传出去" {
    run call_team_agent claude T1 pro 1 no-such /dev/null "$TEST_TMPDIR/out.yaml"
    [ "$status" -eq 99 ]
}

@test "call_team_agent tool 不是 claude/codex → exit 2" {
    run call_team_agent invalid-tool T1 pro 1 smoke /dev/null "$TEST_TMPDIR/out.yaml"
    [ "$status" -eq 2 ]
}

@test "build_prompt_file 4 段齐 + R1 模式" {
    # 拼 prompt 用 templates/agent-legacy-archeologist.md + stance-pro.md
    build_prompt_file "$TEST_TMPDIR/prompt.txt" \
        "$TEMPLATES_DIR/agent-legacy-archeologist.md" \
        "$TEMPLATES_DIR/stance-pro.md" \
        "/path/to/target.md" \
        "$TEST_TMPDIR/run" \
        1 \
        T3
    [ -f "$TEST_TMPDIR/prompt.txt" ]
    grep -q "基线考古员" "$TEST_TMPDIR/prompt.txt"
    grep -q "立场：pro" "$TEST_TMPDIR/prompt.txt"
    grep -q "/path/to/target.md" "$TEST_TMPDIR/prompt.txt"
    grep -q "principles.md" "$TEST_TMPDIR/prompt.txt"
}

@test "build_prompt_file 注入真实 team/stance/round 身份块" {
    build_prompt_file "$TEST_TMPDIR/prompt.txt" \
        "$TEMPLATES_DIR/agent-legacy-archeologist.md" \
        "$TEMPLATES_DIR/stance-neutral.md" \
        "/path/to/target.md" \
        "$TEST_TMPDIR/run" \
        1 \
        T3
    grep -q "你的身份" "$TEST_TMPDIR/prompt.txt"
    grep -q "team: T3" "$TEST_TMPDIR/prompt.txt"
    grep -q "stance: neutral" "$TEST_TMPDIR/prompt.txt"
    grep -q "不要照抄 schema 示例里的 T1" "$TEST_TMPDIR/prompt.txt"
    grep -q "T3-f1" "$TEST_TMPDIR/prompt.txt"
}

@test "build_prompt_file 设了 DR_SCOPE_FOCUS → 注入审查范围段" {
    DR_SCOPE_FOCUS="调度 Pod" \
    DR_SCOPE_OUT=$'路由 Pod 详细设计（待补）\n计算 Pod 详细设计（待补）' \
    build_prompt_file "$TEST_TMPDIR/prompt.txt" \
        "$TEMPLATES_DIR/agent-legacy-archeologist.md" \
        "$TEMPLATES_DIR/stance-pro.md" \
        "/path/to/target.md" \
        "$TEST_TMPDIR/run" \
        1 \
        T1
    grep -q "本次审查范围" "$TEST_TMPDIR/prompt.txt"
    grep -q "焦点：调度 Pod" "$TEST_TMPDIR/prompt.txt"
    grep -q "路由 Pod 详细设计（待补）" "$TEST_TMPDIR/prompt.txt"
    grep -q "不要把这些区域的承接缺口当本设计的必修发现" "$TEST_TMPDIR/prompt.txt"
}

@test "build_prompt_file 未设 DR_SCOPE_FOCUS → 不注入范围段" {
    unset DR_SCOPE_FOCUS DR_SCOPE_OUT
    build_prompt_file "$TEST_TMPDIR/prompt.txt" \
        "$TEMPLATES_DIR/agent-legacy-archeologist.md" \
        "$TEMPLATES_DIR/stance-pro.md" \
        "/path/to/target.md" \
        "$TEST_TMPDIR/run" \
        1 \
        T1
    ! grep -q "本次审查范围" "$TEST_TMPDIR/prompt.txt"
}

@test "build_prompt_file 设了 DR_BG_DOCS → 注入背景文档 + 文档关系，跳过 target 自身" {
    DR_BG_DOCS=$'design/00-overview.md|系统顶层\ndesign/01-core.md|调度详设入口' \
    DR_BG_RELATIONS=$'00 是顶层，01 细化，子模块不重复。' \
    build_prompt_file "$TEST_TMPDIR/prompt.txt" \
        "$TEMPLATES_DIR/agent-legacy-archeologist.md" \
        "$TEMPLATES_DIR/stance-pro.md" \
        "design/01-core.md" \
        "$TEST_TMPDIR/run" \
        1 \
        T1
    grep -q "背景文档" "$TEST_TMPDIR/prompt.txt"
    grep -q "文档关系" "$TEST_TMPDIR/prompt.txt"
    grep -q "00-overview.md" "$TEST_TMPDIR/prompt.txt"
    grep -q "00 是顶层" "$TEST_TMPDIR/prompt.txt"
    # target 自身（01-scheduler）不应出现在背景清单的 bullet 行
    ! grep -q "^- \`design/01-core.md\`" "$TEST_TMPDIR/prompt.txt"
}

@test "build_prompt_file 未设 DR_BG_DOCS → 不注入背景段" {
    unset DR_BG_DOCS DR_BG_RELATIONS
    build_prompt_file "$TEST_TMPDIR/prompt.txt" \
        "$TEMPLATES_DIR/agent-legacy-archeologist.md" \
        "$TEMPLATES_DIR/stance-pro.md" \
        "/path/to/target.md" \
        "$TEST_TMPDIR/run" \
        1 \
        T1
    ! grep -q "背景文档" "$TEST_TMPDIR/prompt.txt"
}

@test "build_prompt_file team 为空 → exit 1" {
    run build_prompt_file "$TEST_TMPDIR/prompt.txt" \
        "$TEMPLATES_DIR/agent-legacy-archeologist.md" \
        "$TEMPLATES_DIR/stance-pro.md" \
        "/path/to/target.md" \
        "$TEST_TMPDIR/run" \
        1 \
        ""
    [ "$status" -eq 1 ]
}

@test "build_prompt_file R≥2 含上一轮历史包路径" {
    build_prompt_file "$TEST_TMPDIR/prompt.txt" \
        "$TEMPLATES_DIR/agent-legacy-archeologist.md" \
        "$TEMPLATES_DIR/stance-con.md" \
        "/path/to/target.md" \
        "$TEST_TMPDIR/run" \
        2 \
        T4
    grep -q "上一轮历史包" "$TEST_TMPDIR/prompt.txt"
    grep -q "teamreport-T1.yaml" "$TEST_TMPDIR/prompt.txt"
    grep -q "cross-attack.yaml" "$TEST_TMPDIR/prompt.txt"
    grep -q "consensus.yaml" "$TEST_TMPDIR/prompt.txt"
}

@test "build_prompt_file agent_template 不存在 → exit 1" {
    run build_prompt_file "$TEST_TMPDIR/prompt.txt" \
        "/no/such/agent.md" \
        "$TEMPLATES_DIR/stance-pro.md" \
        "/path/to/target.md" \
        "$TEST_TMPDIR/run" \
        1 \
        T1
    [ "$status" -eq 1 ]
}

@test "call_team_agent 超时 → exit 124" {
    cat > "$TEST_TMPDIR/slow-mock.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30
echo "should not reach"
EOF
    chmod +x "$TEST_TMPDIR/slow-mock.sh"
    export DESIGN_REVIEW_CLAUDE_BIN="$TEST_TMPDIR/slow-mock.sh"
    export DR_CALL_TIMEOUT_SEC=1
    run call_team_agent claude T1 pro 1 smoke /dev/null "$TEST_TMPDIR/out.yaml"
    [ "$status" -eq 124 ]
}
