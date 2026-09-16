#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "并发 review-diff → 日志条目都到位" {
  mkdir -p pkg/a pkg/b
  echo 'package a' > pkg/a/a.go
  echo 'package b' > pkg/b/b.go
  git add pkg/a/a.go pkg/b/b.go
  AIREVIEW_FIXTURE=clean AIREVIEW_CODEX_FIXTURE=empty \
    "$SCRIPTS_DIR/review-diff.sh" &
  PID1=$!
  AIREVIEW_FIXTURE=clean AIREVIEW_CODEX_FIXTURE=empty \
    "$SCRIPTS_DIR/review-diff.sh" &
  PID2=$!
  wait "$PID1" "$PID2"
  N=$(grep -c '^## ' docs/adversarial-review-log.md)
  [ "$N" -ge 1 ]
}
