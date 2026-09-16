#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  setup_workdir; write_minimal_config
  yq -i '.policy.strict_on_error = true' .adversarial-review.yaml
}
teardown() { teardown_workdir; }

@test "LLM fail + strict=true → exit 2" {
  mkdir -p pkg/foo; echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  AIREVIEW_FIXTURE=fail-1 AIREVIEW_CODEX_FIXTURE=fail-1 \
    run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 2 ]
}
