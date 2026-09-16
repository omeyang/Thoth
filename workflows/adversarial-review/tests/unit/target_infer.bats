#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  source "$LIB_DIR/target_infer.sh"
}

@test "deepest_common: single dir → dir name" {
  run deepest_common <(printf '%s\n' "pkg/util/xsemaphore/redis.go" "pkg/util/xsemaphore/lua.go")
  [ "$status" -eq 0 ]
  [ "$output" = "xsemaphore" ]
}

@test "deepest_common: multi-pkg under same parent → parent name" {
  run deepest_common <(printf '%s\n' "pkg/foo/a.go" "pkg/bar/b.go")
  [ "$status" -eq 0 ]
  [ "$output" = "pkg" ]
}

@test "deepest_common: root file (no slash) → empty + status 1" {
  run deepest_common <(printf '%s\n' "main.go" "go.mod")
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "files_basename: first 3 basenames hyphen-joined" {
  run files_basename <(printf '%s\n' "a.go" "pkg/b.go" "x/y/c.go" "skip-me.go")
  [ "$status" -eq 0 ]
  [ "$output" = "a.go-b.go-c.go" ]
}

@test "sanitize_target: keeps alnum/dot/hyphen/underscore" {
  [ "$(sanitize_target 'foo bar/baz')" = "foo-bar-baz" ]
  [ "$(sanitize_target 'x@y\$z')" = "x-y-z" ]
  [ "$(sanitize_target 'ok_name.go')" = "ok_name.go" ]
}

@test "target_from_diff: auto strategy single-pkg" {
  run target_from_diff <(printf '%s\n' "pkg/util/xsemaphore/redis.go") auto
  [ "$status" -eq 0 ]
  [ "$output" = "xsemaphore" ]
}

@test "target_from_diff: auto fallback to files when common is shallow" {
  run target_from_diff <(printf '%s\n' "pkg/foo/a.go" "pkg/bar/b.go") auto
  [ "$status" -eq 0 ]
  [ "$output" = "a.go-b.go" ]
}

@test "target_from_diff: no usable input → commit-fallback" {
  run target_from_diff /dev/null auto
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^commit- ]]
}
