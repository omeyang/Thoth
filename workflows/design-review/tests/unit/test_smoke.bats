#!/usr/bin/env bats
load '../test_helper'

@test "helper loads and exposes WORKFLOW_ROOT" {
    [ -n "$WORKFLOW_ROOT" ]
    [ -d "$WORKFLOW_ROOT" ]
}

@test "setup creates TEST_TMPDIR" {
    [ -n "$TEST_TMPDIR" ]
    [ -d "$TEST_TMPDIR" ]
}

@test "templates dir exists" {
    [ -d "$TEMPLATES_DIR" ]
}

@test "bats can run a passing test" {
    true
}
