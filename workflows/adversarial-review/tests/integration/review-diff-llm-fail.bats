#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "LLM fail + strict=false → exit 0 + FAILED 条目" {
  mkdir -p pkg/foo; echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  AIREVIEW_FIXTURE=fail-1 AIREVIEW_CODEX_FIXTURE=fail-1 \
    run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 0 ]
  grep -q "FAILED" docs/adversarial-review-log.md
}
