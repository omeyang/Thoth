#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "AIREVIEW_RUNNING=1 → exit 0 immediately" {
  mkdir -p pkg/foo; echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  AIREVIEW_RUNNING=1 run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 0 ]
  [ ! -f docs/adversarial-review-log.md ]
}
