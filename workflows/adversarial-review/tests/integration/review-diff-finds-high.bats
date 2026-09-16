#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "FG-H finding → exit 1 + 表格写入日志" {
  mkdir -p pkg/foo
  echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  AIREVIEW_FIXTURE=one-high AIREVIEW_CODEX_FIXTURE=one-high \
    run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 1 ]
  grep -q "highest severity: high" docs/adversarial-review-log.md
}
