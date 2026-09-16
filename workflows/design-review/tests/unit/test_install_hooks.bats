#!/usr/bin/env bats
# install-hooks.sh 单元测试：幂等 / --force / --uninstall / --dry-run

load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d -t design-review-installhooks-XXXXXX)"
    cd "$TEST_TMPDIR" || exit 1
    git init -q
    git config user.email t@t
    git config user.name t
    INSTALLER="$SCRIPTS_DIR/install-hooks.sh"
    HOOK=".git/hooks/pre-commit"
}

teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

@test "install-hooks 全新仓库 → 装上 pre-commit 且可执行" {
    run "$INSTALLER"
    [ "$status" -eq 0 ]
    [ -x "$HOOK" ]
    grep -qF "design-review pre-commit hook" "$HOOK"
}

@test "install-hooks 第二次跑 → 幂等 noop" {
    "$INSTALLER" >/dev/null
    run "$INSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"已是最新"* ]]
}

@test "install-hooks 已存在他人 hook → rc=2 提示用 --force" {
    echo "# other tool's hook" > "$HOOK"
    chmod +x "$HOOK"
    run "$INSTALLER"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--force"* ]]
}

@test "install-hooks --force → 备份原 hook 后覆盖" {
    echo "# other tool's hook" > "$HOOK"
    chmod +x "$HOOK"
    run "$INSTALLER" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"备份"* ]]
    ls "$HOOK".bak.* >/dev/null
    grep -qF "design-review pre-commit hook" "$HOOK"
}

@test "install-hooks --uninstall 本工具装的 → 删除" {
    "$INSTALLER" >/dev/null
    run "$INSTALLER" --uninstall
    [ "$status" -eq 0 ]
    [ ! -f "$HOOK" ]
}

@test "install-hooks --uninstall 非本工具装的 → 拒绝（rc=2）" {
    echo "# other tool's hook" > "$HOOK"
    chmod +x "$HOOK"
    run "$INSTALLER" --uninstall
    [ "$status" -eq 2 ]
    [ -f "$HOOK" ]
}

@test "install-hooks --dry-run 全新 → 不实际写文件" {
    run "$INSTALLER" --dry-run
    [ "$status" -eq 0 ]
    [ ! -f "$HOOK" ]
    [[ "$output" == *"dry-run"* ]]
}

@test "install-hooks 非 git 仓库 → rc=1" {
    cd /tmp
    NON_GIT="$(mktemp -d)"
    cd "$NON_GIT"
    run "$INSTALLER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"git"* ]]
    rm -rf "$NON_GIT"
}

@test "pre-commit hook 暂存断链 redesign/*.md → 阻断 commit" {
    "$INSTALLER" >/dev/null
    mkdir -p redesign
    cat > redesign/foo.md <<'EOF'
# foo
[bad](./nonexistent.md)
EOF
    git add redesign/foo.md
    THOTH_HOME="$(cd "$SCRIPTS_DIR/../.." && pwd)"
    export THOTH_HOME
    run git commit -m "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"断链"* ]] || [[ "$output" == *"阻断"* ]]
}

@test "pre-commit hook 暂存合法 redesign/*.md → 放行" {
    "$INSTALLER" >/dev/null
    mkdir -p redesign
    cat > redesign/good.md <<'EOF'
# 合法文档
没有外链也没有内链。
EOF
    git add redesign/good.md
    THOTH_HOME="$(cd "$SCRIPTS_DIR/../.." && pwd)"
    export THOTH_HOME
    run git commit -m "x"
    [ "$status" -eq 0 ]
}

@test "pre-commit hook 暂存非 redesign 文件 → 跳过 lint" {
    "$INSTALLER" >/dev/null
    echo "随便" > foo.txt
    git add foo.txt
    THOTH_HOME="$(cd "$SCRIPTS_DIR/../.." && pwd)"
    export THOTH_HOME
    run git commit -m "x"
    [ "$status" -eq 0 ]
}
