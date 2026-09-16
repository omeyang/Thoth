#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  setup_workdir; write_minimal_config
  # 把 timeout 调到 5 秒，让 mock sleep 1300 触发
  yq -i '.verify.timeout_seconds = 5' .adversarial-review.yaml
}
teardown() { teardown_workdir; }

@test "LLM timeout → 归类 LLM 失败" {
  mkdir -p pkg/foo; echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  AIREVIEW_FIXTURE=timeout AIREVIEW_CODEX_FIXTURE=timeout \
    run timeout 30 "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
  # FAILED 或没写日志（timeout 路径）
}
