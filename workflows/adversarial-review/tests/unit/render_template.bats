#!/usr/bin/env bats
# render_template 的路径拼接与变量注入。
#
# 回归背景：实现里曾写成 "$TEMPLATES_DIR/$1"，漏了 .md 后缀，而 templates/ 下
# 的文件都是 <name>.md。三个调用点（codex-attack / codex-defend /
# claude-orchestrator）因此全部拿不到模板，render_template 返回 2；
# 调用链上层不阻断提交，于是对抗审查长期静默空跑无人察觉。
load "../test_helper.bash"

setup() {
  export LIB_DIR TEMPLATES_DIR
  OUT_DIR="$(mktemp -d)"
}

teardown() {
  [[ -n "${OUT_DIR:-}" && -d "$OUT_DIR" ]] && rm -rf "$OUT_DIR"
}

# 调用方传的是不带扩展名的模板名，实现必须自己补 .md
@test "render_template 按 <name>.md 解析模板名" {
  run bash -c "
    export LIB_DIR='$LIB_DIR' TEMPLATES_DIR='$TEMPLATES_DIR'
    source '$LIB_DIR/quorum.sh'
    render_template codex-attack '$OUT_DIR/out.md'
  "
  [ "$status" -eq 0 ]
  [ -s "$OUT_DIR/out.md" ]
}

# 三个生产调用点用到的模板都必须可解析，缺一个就是整条链断掉
@test "render_template 覆盖全部生产调用点的模板" {
  for name in codex-attack codex-defend claude-orchestrator; do
    run bash -c "
      export LIB_DIR='$LIB_DIR' TEMPLATES_DIR='$TEMPLATES_DIR'
      source '$LIB_DIR/quorum.sh'
      render_template $name '$OUT_DIR/$name.out'
    "
    [ "$status" -eq 0 ] || {
      echo "render_template $name 失败: $output"
      return 1
    }
    [ -s "$OUT_DIR/$name.out" ]
  done
}

@test "render_template 把 {{VAR}} 替换为环境变量值" {
  printf '目标={{TARGET}} 结束\n' > "$TEMPLATES_DIR/.render-test-tmp.md"
  run bash -c "
    export LIB_DIR='$LIB_DIR' TEMPLATES_DIR='$TEMPLATES_DIR' TARGET='pkg/util/xmac'
    source '$LIB_DIR/quorum.sh'
    render_template .render-test-tmp '$OUT_DIR/subst.out'
    cat '$OUT_DIR/subst.out'
  "
  rm -f "$TEMPLATES_DIR/.render-test-tmp.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"目标=pkg/util/xmac 结束"* ]]
}

@test "render_template 模板缺失时返回 2 且报出完整路径" {
  run bash -c "
    export LIB_DIR='$LIB_DIR' TEMPLATES_DIR='$TEMPLATES_DIR'
    source '$LIB_DIR/quorum.sh'
    render_template definitely-not-a-template '$OUT_DIR/nope.out'
  "
  [ "$status" -eq 2 ]
  [[ "$output" == *"template missing"* ]]
  [[ "$output" == *"definitely-not-a-template.md"* ]]
}
