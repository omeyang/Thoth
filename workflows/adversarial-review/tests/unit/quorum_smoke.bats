#!/usr/bin/env bats
load "../test_helper.bash"

@test "quorum.sh sources without error" {
  run bash -c "export LIB_DIR='$LIB_DIR'; source '$LIB_DIR/quorum.sh' && declare -F quorum_run quorum_apply_fixes log_append cleanup_runs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"quorum_run"* ]]
  [[ "$output" == *"quorum_apply_fixes"* ]]
  [[ "$output" == *"log_append"* ]]
}
