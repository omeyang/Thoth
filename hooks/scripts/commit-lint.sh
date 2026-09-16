#!/bin/bash
# commit-lint.sh — PreToolUse hook
# 在 Bash 工具执行 git commit 时检查 commit message 格式
# 遵循 Conventional Commits 规范
#
# 退出码约定:
#   0 = 放行
#   2 = 阻止（格式不符合规范）

set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[[ "$TOOL_NAME" == "Bash" ]] || exit 0

# 仅检查 git commit 命令
echo "$COMMAND" | grep -qE 'git\s+commit' || exit 0

# 提取 -m 参数的 commit message
# 支持 -m "msg" 和 HEREDOC 两种格式
MSG=""
if echo "$COMMAND" | grep -qE '\-m\s+"'; then
  MSG=$(echo "$COMMAND" | sed -n 's/.*-m\s*"\([^"]*\)".*/\1/p' | head -1)
elif echo "$COMMAND" | grep -qE '\-m\s+'"'"''; then
  MSG=$(echo "$COMMAND" | sed -n "s/.*-m\s*'\([^']*\)'.*/\1/p" | head -1)
fi

# HEREDOC 格式不好解析，跳过
[[ -n "$MSG" ]] || exit 0

# 取第一行
FIRST_LINE=$(echo "$MSG" | head -1)

# Conventional Commits 格式: type(scope): description
# type: feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert
PATTERN='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\(.+\))?: .{1,}'

if ! echo "$FIRST_LINE" | grep -qE "$PATTERN"; then
  cat >&2 <<'EOF'
BLOCKED: Commit message 不符合 Conventional Commits 规范。

格式: type(scope): description

允许的 type:
  feat     新功能
  fix      Bug 修复
  docs     文档变更
  style    格式（不影响代码运行）
  refactor 重构（既不修复 Bug 也不添加功能）
  perf     性能优化
  test     测试
  build    构建系统或依赖
  ci       CI 配置
  chore    其他杂项
  revert   回滚

示例: feat(auth): add JWT token refresh
EOF
  exit 2
fi

# 检查第一行长度（建议不超过 72 字符）
if [[ ${#FIRST_LINE} -gt 72 ]]; then
  echo "WARNING: Commit message 第一行超过 72 字符 (${#FIRST_LINE})，建议缩短。" >&2
  # 仅警告，不阻止
fi

exit 0
