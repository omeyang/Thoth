#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  source "$LIB_DIR/skip_paths.sh"
}

@test "skip_paths_match: *.md matches README.md" {
  run skip_paths_match "README.md" "*.md"
  [ "$status" -eq 0 ]
}

@test "skip_paths_match: docs/** matches docs/x/y.md" {
  run skip_paths_match "docs/x/y.md" "docs/**"
  [ "$status" -eq 0 ]
}

@test "skip_paths_match: **/testdata/** matches pkg/foo/testdata/x.txt" {
  run skip_paths_match "pkg/foo/testdata/x.txt" "**/testdata/**"
  [ "$status" -eq 0 ]
}

@test "skip_paths_match: *.md does not match foo.go" {
  run skip_paths_match "foo.go" "*.md"
  [ "$status" -eq 1 ]
}

@test "all_paths_skipped: every line matches one pattern" {
  run bash -c '
    source "'"$LIB_DIR"'/skip_paths.sh"
    printf "%s\n" "README.md" "docs/a.md" | all_paths_skipped /dev/stdin "*.md" "docs/**"
  '
  [ "$status" -eq 0 ]
}

@test "all_paths_skipped: one path unmatched → false" {
  run bash -c '
    source "'"$LIB_DIR"'/skip_paths.sh"
    printf "%s\n" "README.md" "main.go" | all_paths_skipped /dev/stdin "*.md"
  '
  [ "$status" -eq 1 ]
}
