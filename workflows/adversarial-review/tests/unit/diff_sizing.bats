#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  source "$LIB_DIR/diff_sizing.sh"
  TMPF="$(mktemp)"
}

teardown() { rm -f "$TMPF"; }

@test "diff_lines: counts +/- lines only" {
  cat > "$TMPF" <<'EOF'
diff --git a/foo b/foo
index 1234..5678
--- a/foo
+++ b/foo
@@ -1,3 +1,4 @@
 keep
-removed
+added1
+added2
EOF
  [ "$(diff_lines "$TMPF")" -eq 3 ]
}

@test "diff_lines: empty file → 0" {
  : > "$TMPF"
  [ "$(diff_lines "$TMPF")" -eq 0 ]
}

@test "diff_size_ok: under threshold → 0" {
  printf '+x\n%.0s' {1..100} > "$TMPF"
  run diff_size_ok "$TMPF" 500
  [ "$status" -eq 0 ]
}

@test "diff_size_ok: over threshold → 1" {
  printf '+x\n%.0s' {1..600} > "$TMPF"
  run diff_size_ok "$TMPF" 500
  [ "$status" -eq 1 ]
}

@test "diff_size_ok: exact boundary n=max → 0 (inclusive)" {
  printf '+x\n%.0s' {1..500} > "$TMPF"
  run diff_size_ok "$TMPF" 500
  [ "$status" -eq 0 ]
}
