#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "partial staging + auto_stash=false → 警告不阻断" {
  mkdir -p pkg/foo
  echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  echo '// modified after staging' >> pkg/foo/foo.go
  AIREVIEW_FIXTURE=clean AIREVIEW_CODEX_FIXTURE=empty \
    run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"unstaged"* ]] || [[ "$output" == *"unstaged"* ]]
}

@test "partial staging + auto_stash=true → stash + 恢复" {
  yq -i '.diff.auto_stash_unstaged = true' .adversarial-review.yaml
  mkdir -p pkg/foo
  echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  echo '// modified after staging' >> pkg/foo/foo.go
  AIREVIEW_FIXTURE=clean AIREVIEW_CODEX_FIXTURE=empty \
    run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 0 ]
  # 恢复后工作区应仍含 unstaged 改动
  grep -q "modified after staging" pkg/foo/foo.go
}
