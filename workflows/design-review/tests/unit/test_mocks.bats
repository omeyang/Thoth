#!/usr/bin/env bats
load '../test_helper'

@test "mock-claude.sh --case smoke 返回 smoke-default.yaml" {
    run "$MOCKS_DIR/mock-claude.sh" --team T1 --stance pro --round 1 --case smoke --input /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"team_id: smoke"* ]]
}

@test "mock-claude.sh 缺 --case 退出 99" {
    run "$MOCKS_DIR/mock-claude.sh" --team T1 --stance pro --round 1 --input /dev/null
    [ "$status" -eq 99 ]
}

@test "mock-claude.sh 未知 case 退出 99" {
    run "$MOCKS_DIR/mock-claude.sh" --team T1 --stance pro --round 1 --case no-such --input /dev/null
    [ "$status" -eq 99 ]
}

@test "mock-codex.sh 与 mock-claude.sh 同形态" {
    run "$MOCKS_DIR/mock-codex.sh" --team T2 --stance con --round 1 --case smoke --input /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"team_id: smoke"* ]]
}
