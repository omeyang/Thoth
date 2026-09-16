#!/bin/bash
# go-test-async.sh — PostToolUse hook (async)
# 在 Edit/Write 操作后异步运行受影响包的测试
# 结果通过 systemMessage 回传给 Claude 上下文
#
# 使用方式: 在 settings.json 中设置 "async": true, "timeout": 300

set -uo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

[[ "$FILE_PATH" == *.go ]] || exit 0
[[ -f "$FILE_PATH" ]] || exit 0

# 需要 go 和 jq
command -v go &>/dev/null || exit 0
command -v jq &>/dev/null || exit 0

DIR=$(dirname "$FILE_PATH")

# 找到模块根目录
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

RESULT=$(cd "$MODULE_ROOT" && go test -race -count=1 -timeout 60s "$PKG" 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
  PASS_COUNT=$(echo "$RESULT" | grep -c "^ok" || true)
  echo "{\"systemMessage\": \"Tests PASSED ($PASS_COUNT packages) for $PKG\"}"
else
  # 截断过长输出，保留最后 50 行，用 jq 构建合法 JSON
  TRIMMED=$(echo "$RESULT" | tail -50)
  jq -n --arg msg "Tests FAILED for $PKG" --arg detail "$TRIMMED" \
    '{"systemMessage": ($msg + "\n" + $detail)}'
fi

exit 0
