#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "all paths under skip → exit 3" {
  echo "# foo" > README.md
  git add README.md
  AIREVIEW_FIXTURE=clean run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 3 ]
}
