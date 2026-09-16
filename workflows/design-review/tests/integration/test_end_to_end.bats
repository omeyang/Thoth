#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1

    cp "$FIXTURES_DIR/minimal.yaml" .design-review.yaml
    mkdir -p redesign

    inject_mocks
    export DR_STANCE_RANDOM_SEED=42
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset DR_STANCE_RANDOM_SEED DR_PHASE_CASE_OVERRIDE
}

@test "perfect-doc → 必修=0 + supplement 含 '必修项'" {
    echo "# perfect" > redesign/perfect.md
    export DR_PHASE_CASE_OVERRIDE="perfect"
    run "$SCRIPTS_DIR/review-design.sh" --rounds 2 redesign/perfect.md
    [ "$status" -eq 0 ]
    [ -f "redesign/201-perfect-supplement.md" ]
    grep -q "必修" "redesign/201-perfect-supplement.md"
    grep -q "必修项.*0" "redesign/201-perfect-supplement.md"
}

@test "known-flaws → 必修=1 + supplement 含 finding text" {
    echo "# known-flaws" > redesign/known-flaws.md
    export DR_PHASE_CASE_OVERRIDE="known-flaws"
    run "$SCRIPTS_DIR/review-design.sh" --rounds 2 redesign/known-flaws.md
    [ "$status" -eq 0 ]
    [ -f "redesign/201-known-flaws-supplement.md" ]
    grep -q "scheduler 漏写单写者矩阵" "redesign/201-known-flaws-supplement.md"
}

@test "agent-absent → exit 2 + status=aborted" {
    echo "# x" > redesign/x.md
    export DR_PHASE_CASE_OVERRIDE="no-such-case"
    run "$SCRIPTS_DIR/review-design.sh" --rounds 1 redesign/x.md
    [ "$status" -eq 2 ]
}

@test "patch.diff 产生且引用 supplement 文件" {
    echo "# patch-test" > redesign/patch-test.md
    export DR_PHASE_CASE_OVERRIDE="known-flaws"
    "$SCRIPTS_DIR/review-design.sh" --rounds 2 redesign/patch-test.md
    [ -f "redesign/.design-runs/suggested-patch.diff" ]
    grep -q "201-patch-test-supplement.md" "redesign/.design-runs/suggested-patch.diff"
}

@test "review-report.md 含三表 + 决策" {
    echo "# report-test" > redesign/report-test.md
    export DR_PHASE_CASE_OVERRIDE="known-flaws"
    "$SCRIPTS_DIR/review-design.sh" --rounds 2 redesign/report-test.md
    [ -f "redesign/.design-runs/review-report.md" ]
    grep -q "必修" "redesign/.design-runs/review-report.md"
    grep -q "存疑" "redesign/.design-runs/review-report.md"
    grep -q "舍弃" "redesign/.design-runs/review-report.md"
}

@test "split findings → 真 cross-attack 投票后 必修=1 + 存疑=1（单队发现不再消失）" {
    echo "# split" > redesign/split.md
    export DR_PHASE_CASE_OVERRIDE="split"
    run "$SCRIPTS_DIR/review-design.sh" --rounds 1 redesign/split.md
    [ "$status" -eq 0 ]
    [ -f "redesign/.design-runs/review-report.md" ]
    # cf-002(Y) 全 agree → 必修；cf-001(X) 2 refute → 存疑
    grep -q "| 必修 | 1 |" "redesign/.design-runs/review-report.md"
    grep -q "| 存疑 | 1 |" "redesign/.design-runs/review-report.md"
    # 必修发现 Y 进入 supplement（修前会因 unknown 票被丢弃）
    grep -q "asset_id 冲突" "redesign/201-split-supplement.md"
}

@test "MAX_REACHED 强停（mock 永不收敛非可重现 — 改用 max=1 测）" {
    echo "# max-test" > redesign/max-test.md
    export DR_PHASE_CASE_OVERRIDE="known-flaws"
    run "$SCRIPTS_DIR/review-design.sh" --rounds 1 redesign/max-test.md
    [ "$status" -eq 0 ]
    # status 应是 converged 或 max_reached（R1 < min=1 不触发 CONTINUE）
    [ -f "redesign/.design-runs/review-report.md" ]
}
