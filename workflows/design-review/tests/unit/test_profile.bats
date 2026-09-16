#!/usr/bin/env bats
# 项目 profile（插件）定位 + 覆盖 + 配置解析 + prompt 注入
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/errors.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/log.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/config.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/profile.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/agent.sh"

    export THOTH_HOME="$WORKFLOW_ROOT/../.."
    export DR_TEMPLATES_DIR="$TEMPLATES_DIR"
    # 三层根：THOTH_PROFILES > XDG_CONFIG_HOME/thoth/profiles > 内置 profiles/
    export THOTH_PROFILES="$TEST_TMPDIR/root-a"
    export XDG_CONFIG_HOME="$TEST_TMPDIR/xdg"
    mkdir -p "$THOTH_PROFILES/design-review" "$XDG_CONFIG_HOME/thoth/profiles/design-review"
    unset DR_PROFILE_DIR DR_REFS_MANIFEST
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset THOTH_PROFILES XDG_CONFIG_HOME DR_PROFILE_DIR DR_REFS_MANIFEST DR_TEMPLATES_DIR
}

# ---------- resolve_profile_dir ----------

@test "resolve_profile_dir 内置 example 可被找到（第三层）" {
    run resolve_profile_dir example
    [ "$status" -eq 0 ]
    [ "$output" = "$(cd "$WORKFLOW_ROOT/profiles/example" && pwd)" ]
}

@test "resolve_profile_dir ~/.config 层优先于内置" {
    mkdir -p "$XDG_CONFIG_HOME/thoth/profiles/design-review/example"
    run resolve_profile_dir example
    [ "$status" -eq 0 ]
    [ "$output" = "$XDG_CONFIG_HOME/thoth/profiles/design-review/example" ]
}

@test "resolve_profile_dir THOTH_PROFILES 层优先于 ~/.config" {
    mkdir -p "$XDG_CONFIG_HOME/thoth/profiles/design-review/p1" "$THOTH_PROFILES/design-review/p1"
    run resolve_profile_dir p1
    [ "$status" -eq 0 ]
    [ "$output" = "$THOTH_PROFILES/design-review/p1" ]
}

@test "resolve_profile_dir 路径形式直接透传（含 / 即路径）" {
    mkdir -p "$TEST_TMPDIR/anywhere/p2"
    run resolve_profile_dir "$TEST_TMPDIR/anywhere/p2"
    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_TMPDIR/anywhere/p2" ]
}

@test "resolve_profile_dir 路径形式支持 \$THOTH_PROFILES 前缀展开" {
    mkdir -p "$THOTH_PROFILES/design-review/p3"
    run resolve_profile_dir '$THOTH_PROFILES/design-review/p3'
    [ "$status" -eq 0 ]
    [ "$output" = "$THOTH_PROFILES/design-review/p3" ]
}

@test "resolve_profile_dir 找不到 → 返回 1 且无输出" {
    run resolve_profile_dir no-such-profile
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run resolve_profile_dir "$TEST_TMPDIR/no/such/dir"
    [ "$status" -eq 1 ]
}

# ---------- resolve_template ----------

@test "resolve_template 无 profile → templates/ 默认" {
    unset DR_PROFILE_DIR
    run resolve_template agent-legacy-archeologist.md
    [ "$status" -eq 0 ]
    [ "$output" = "$TEMPLATES_DIR/agent-legacy-archeologist.md" ]
}

@test "resolve_template profile 同名文件存在 → 覆盖" {
    mkdir -p "$TEST_TMPDIR/prof"
    echo "# override" > "$TEST_TMPDIR/prof/agent-legacy-archeologist.md"
    export DR_PROFILE_DIR="$TEST_TMPDIR/prof"
    run resolve_template agent-legacy-archeologist.md
    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_TMPDIR/prof/agent-legacy-archeologist.md" ]
    # profile 没有的文件仍走默认
    run resolve_template agent-closure-judge.md
    [ "$output" = "$TEMPLATES_DIR/agent-closure-judge.md" ]
}

@test "resolve_role_template_path 相对路径先 profile 再 design-review 目录" {
    mkdir -p "$TEST_TMPDIR/prof"
    echo "# custom" > "$TEST_TMPDIR/prof/custom.md"
    export DR_PROFILE_DIR="$TEST_TMPDIR/prof"
    run resolve_role_template_path custom.md
    [ "$output" = "$TEST_TMPDIR/prof/custom.md" ]
    run resolve_role_template_path templates/agent-closure-judge.md
    [ "$output" = "$(cd "$WORKFLOW_ROOT" && pwd)/templates/agent-closure-judge.md" ]
    run resolve_role_template_path /abs/x.md
    [ "$output" = "/abs/x.md" ]
}

# ---------- config 解析 ----------

@test "load_config 解析 profile 与 roles.R1.template" {
    cat > cfg.yaml <<'EOF'
profile: my-project
roles:
  R1: {name: legacy-archeologist, template: agent-legacy-archeologist.md, enabled: true}
  R3: {name: closure-judge, template: templates/agent-closure-judge.md, enabled: true}
refs:
  manifest:
    - {path: /tmp/fake-legacy, tier: "基线-功能权威"}
EOF
    load_config cfg.yaml
    [ "$CFG_PROFILE" = "my-project" ]
    [ "${CFG_ROLE_TEMPLATES[R1]}" = "agent-legacy-archeologist.md" ]
    [ "${CFG_ROLE_TEMPLATES[R3]}" = "templates/agent-closure-judge.md" ]
    [ -z "${CFG_ROLE_TEMPLATES[R2]:-}" ]
}

@test "load_config 无 profile 段 → CFG_PROFILE 为空" {
    cp "$FIXTURES_DIR/minimal.yaml" cfg.yaml
    load_config cfg.yaml
    [ -z "$CFG_PROFILE" ]
    [ "${#CFG_ROLE_TEMPLATES[@]}" -eq 0 ]
}

# ---------- prompt 注入 ----------

@test "build_prompt_file profile 有 principles.md → 注入项目原则段" {
    mkdir -p "$TEST_TMPDIR/prof"
    echo "# 项目原则" > "$TEST_TMPDIR/prof/principles.md"
    export DR_PROFILE_DIR="$TEST_TMPDIR/prof"
    build_prompt_file "$TEST_TMPDIR/prompt.txt" \
        "$TEMPLATES_DIR/agent-legacy-archeologist.md" \
        "$TEMPLATES_DIR/stance-pro.md" \
        "/path/to/target.md" "$TEST_TMPDIR/run" 1 T1
    grep -q "项目原则（追加，优先级高于通用原则）" "$TEST_TMPDIR/prompt.txt"
    grep -q "$TEST_TMPDIR/prof/principles.md" "$TEST_TMPDIR/prompt.txt"
}

@test "build_prompt_file profile 无 principles.md / 无 profile → 不注入项目原则段" {
    mkdir -p "$TEST_TMPDIR/prof-empty"
    export DR_PROFILE_DIR="$TEST_TMPDIR/prof-empty"
    build_prompt_file "$TEST_TMPDIR/prompt.txt" \
        "$TEMPLATES_DIR/agent-legacy-archeologist.md" \
        "$TEMPLATES_DIR/stance-pro.md" \
        "/path/to/target.md" "$TEST_TMPDIR/run" 1 T1
    ! grep -q "项目原则（追加" "$TEST_TMPDIR/prompt.txt"
    unset DR_PROFILE_DIR
    build_prompt_file "$TEST_TMPDIR/prompt2.txt" \
        "$TEMPLATES_DIR/agent-legacy-archeologist.md" \
        "$TEMPLATES_DIR/stance-pro.md" \
        "/path/to/target.md" "$TEST_TMPDIR/run" 1 T1
    ! grep -q "项目原则（追加" "$TEST_TMPDIR/prompt2.txt"
}

@test "build_prompt_file 设了 DR_REFS_MANIFEST → 引用生成的清单而非示例文件" {
    export DR_REFS_MANIFEST="$TEST_TMPDIR/run/refs-manifest.yaml"
    build_prompt_file "$TEST_TMPDIR/prompt.txt" \
        "$TEMPLATES_DIR/agent-legacy-archeologist.md" \
        "$TEMPLATES_DIR/stance-pro.md" \
        "/path/to/target.md" "$TEST_TMPDIR/run" 1 T1
    grep -q "$TEST_TMPDIR/run/refs-manifest.yaml" "$TEST_TMPDIR/prompt.txt"
    ! grep -q "refs-manifest.example.yaml" "$TEST_TMPDIR/prompt.txt"
}

@test "build_prompt_file 未设 DR_REFS_MANIFEST → 回退示例文件" {
    unset DR_REFS_MANIFEST
    build_prompt_file "$TEST_TMPDIR/prompt.txt" \
        "$TEMPLATES_DIR/agent-legacy-archeologist.md" \
        "$TEMPLATES_DIR/stance-pro.md" \
        "/path/to/target.md" "$TEST_TMPDIR/run" 1 T1
    grep -q "refs-manifest.example.yaml" "$TEST_TMPDIR/prompt.txt"
}

# ---------- 主入口 dry-run ----------

@test "review-design.sh --profile 找不到 → exit 2（配置错误）" {
    echo "# doc" > target.md
    run "$SCRIPTS_DIR/review-design.sh" target.md --dry-run --profile no-such-profile
    [ "$status" -eq 2 ]
    [[ "$output" == *"profile 不存在"* ]]
}

@test "review-design.sh yaml profile + --dry-run 打印 profile 目录" {
    echo "# doc" > target.md
    mkdir -p "$THOTH_PROFILES/design-review/p9"
    cat > .design-review.yaml <<'EOF'
profile: p9
refs:
  manifest:
    - {path: /tmp/fake-legacy, tier: "基线-功能权威"}
EOF
    run "$SCRIPTS_DIR/review-design.sh" target.md --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"profile=$THOTH_PROFILES/design-review/p9"* ]]
}

@test "review-design.sh --profile 覆盖 yaml profile" {
    echo "# doc" > target.md
    mkdir -p "$THOTH_PROFILES/design-review/p9" "$THOTH_PROFILES/design-review/p10"
    cat > .design-review.yaml <<'EOF'
profile: p9
refs:
  manifest:
    - {path: /tmp/fake-legacy, tier: "基线-功能权威"}
EOF
    run "$SCRIPTS_DIR/review-design.sh" target.md --dry-run --profile p10
    [ "$status" -eq 0 ]
    [[ "$output" == *"profile=$THOTH_PROFILES/design-review/p10"* ]]
}

@test "review-design.sh 无 profile → dry-run 打印 profile=（none）" {
    echo "# doc" > target.md
    run "$SCRIPTS_DIR/review-design.sh" target.md --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"profile=（none）"* ]]
}

# ---------- cron-batch profile ----------

@test "cron-batch.sh <profile> --plan 通过 THOTH_PROFILES 找到 profile.env" {
    mkdir -p "$TEST_TMPDIR/repo/design" "$THOTH_PROFILES/design-review/cronp"
    echo "# a" > "$TEST_TMPDIR/repo/design/00-overview.md"
    echo "# b" > "$TEST_TMPDIR/repo/design/01-core.md"
    echo "# c" > "$TEST_TMPDIR/repo/design/01-a-sub.md"
    cat > "$THOTH_PROFILES/design-review/cronp/profile.env" <<EOF
REPO=$TEST_TMPDIR/repo
REDESIGN_SUBDIR=design
PARENT_DOC=01-core.md
MAX_ROUNDS=3
EOF
    run "$SCRIPTS_DIR/cron-batch.sh" cronp --plan
    [ "$status" -eq 0 ]
    [[ "$output" == *"profile=cronp"* ]]
    [[ "$output" == *"max_rounds=3"* ]]
    [[ "$output" == *"共 3 篇"* ]]
    # 顺序：00 → PARENT_DOC → 其余 01-*
    [[ "$output" =~ 00-overview.md.*01-core.md.*01-a-sub.md ]]
}

@test "cron-batch.sh 未知 profile → exit 1 + 明确报错" {
    run "$SCRIPTS_DIR/cron-batch.sh" no-such-profile --plan
    [ "$status" -eq 1 ]
    [[ "$output" == *"未知 profile: no-such-profile"* ]]
}

@test "cron-batch.sh profile.env 缺 REPO → exit 1" {
    mkdir -p "$THOTH_PROFILES/design-review/bad"
    echo "REDESIGN_SUBDIR=design" > "$THOTH_PROFILES/design-review/bad/profile.env"
    run "$SCRIPTS_DIR/cron-batch.sh" bad --plan
    [ "$status" -eq 1 ]
    [[ "$output" == *"缺 REPO"* ]]
}
