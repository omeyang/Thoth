#!/bin/bash
# go-format.sh — PostToolUse hook
# 在 Edit/Write 操作后自动对 .go 文件执行 goimports + gofmt
#
# 退出码约定:
#   0 = 成功（静默）
#   1 = 非阻塞错误（仅日志）
#   2 = 阻塞错误（stderr 回传给 Claude）

set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# 仅处理 .go 文件
[[ "$FILE_PATH" == *.go ]] || exit 0

# 文件必须存在
[[ -f "$FILE_PATH" ]] || exit 0

# goimports（整理 import 并格式化）
if command -v goimports &>/dev/null; then
  goimports -w "$FILE_PATH" 2>/dev/null
else
  gofmt -w "$FILE_PATH" 2>/dev/null
fi

exit 0
