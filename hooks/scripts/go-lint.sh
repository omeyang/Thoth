#!/bin/bash
# go-lint.sh — PostToolUse hook
# 在 Edit/Write 操作后对变更文件所在包执行 golangci-lint
# 发现问题时以 exit 2 返回，将 stderr 回传给 Claude 自行修复
#
# 退出码约定:
#   0 = 通过
#   2 = lint 错误（回传给 Claude）

set -uo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

[[ "$FILE_PATH" == *.go ]] || exit 0
[[ -f "$FILE_PATH" ]] || exit 0

# 定位包目录
DIR=$(dirname "$FILE_PATH")

# 需要 golangci-lint
if ! command -v golangci-lint &>/dev/null; then
  exit 0
fi

# 找到最近的 go.mod 所在目录作为工作目录
MODULE_ROOT="$DIR"
while [[ "$MODULE_ROOT" != "/" ]]; do
  [[ -f "$MODULE_ROOT/go.mod" ]] && break
  MODULE_ROOT=$(dirname "$MODULE_ROOT")
done

if [[ ! -f "$MODULE_ROOT/go.mod" ]]; then
  exit 0
fi

# 计算相对包路径
REL_PATH="${DIR#"$MODULE_ROOT"}"
REL_PATH="${REL_PATH#/}"
if [[ -z "$REL_PATH" ]]; then
  PKG="./..."
else
  PKG="./${REL_PATH}/..."
fi

OUTPUT=$(cd "$MODULE_ROOT" && golangci-lint run --timeout 30s "$PKG" 2>&1) || {
  echo "$OUTPUT" >&2
  exit 2
}

exit 0
