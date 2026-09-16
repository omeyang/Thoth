#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "empty diff → exit 3, no log entry" {
  AIREVIEW_FIXTURE=clean run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 3 ]
  [ ! -f docs/adversarial-review-log.md ]
}
