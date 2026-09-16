#!/usr/bin/env bash
# Diff 行数：仅计 +/- 开头的行（跳过 +++/--- 文件头与 @@hunk）

diff_lines() {
  local file="$1"
  [[ -s "$file" ]] || { echo 0; return; }
  grep -cE '^[+-][^+-]|^[+-]$' "$file" 2>/dev/null || echo 0
}

# diff_size_ok <diff-file> <max-lines> → 0 if within limit
diff_size_ok() {
  local n
  n=$(diff_lines "$1")
  [[ "$n" -le "$2" ]]
}
