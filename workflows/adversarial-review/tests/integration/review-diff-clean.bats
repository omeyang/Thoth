#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "clean review → exit 0 + log留痕" {
  mkdir -p pkg/foo
  echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  AIREVIEW_FIXTURE=clean AIREVIEW_CODEX_FIXTURE=empty \
    run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 0 ]
  [ -f docs/adversarial-review-log.md ]
  grep -q "TARGET=foo" docs/adversarial-review-log.md
}
