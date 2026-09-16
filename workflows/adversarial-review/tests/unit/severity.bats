#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  source "$LIB_DIR/severity.sh"
}

@test "severity_rank: high=3 medium=2 low=1 none=0" {
  [ "$(severity_rank high)" -eq 3 ]
  [ "$(severity_rank medium)" -eq 2 ]
  [ "$(severity_rank low)" -eq 1 ]
  [ "$(severity_rank none)" -eq 0 ]
}

@test "severity_ge: high >= medium = true" {
  run severity_ge high medium
  [ "$status" -eq 0 ]
}

@test "severity_ge: medium >= high = false" {
  run severity_ge medium high
  [ "$status" -eq 1 ]
}

@test "severity_ge: never threshold always false" {
  run severity_ge high never
  [ "$status" -eq 1 ]
}

@test "severity_rank: unknown returns 0" {
  [ "$(severity_rank bogus)" -eq 0 ]
}

@test "severity_ge: equal ranks → true (boundary)" {
  run severity_ge low low
  [ "$status" -eq 0 ]
  run severity_ge medium medium
  [ "$status" -eq 0 ]
  run severity_ge high high
  [ "$status" -eq 0 ]
}
