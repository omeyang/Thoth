#!/bin/bash
# block-dangerous.sh — PreToolUse hook
# 拦截高风险命令，防止 Claude 执行破坏性操作
#
# 退出码约定:
#   0 = 放行
#   2 = 阻止（stderr 回传给 Claude 说明原因）

set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# 仅拦截 Bash 工具
[[ "$TOOL_NAME" == "Bash" ]] || exit 0
[[ -n "$COMMAND" ]] || exit 0

# ── 规则 1: 禁止 rm -rf（允许 rm 单个文件） ──
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|--recursive\s+--force|-[a-zA-Z]*f[a-zA-Z]*r)'; then
  echo "BLOCKED: rm -rf 操作被禁止。请使用更安全的删除方式，或逐个指定文件。" >&2
  exit 2
fi

# ── 规则 2: 禁止生产环境 kubectl 破坏性操作 ──
if echo "$COMMAND" | grep -qE 'kubectl\s+(delete|drain|cordon|replace\s+--force)' &&
   echo "$COMMAND" | grep -qiE '(--context[= ]*\S*(prod|production|prd)|--namespace[= ]*\S*prod)'; then
  echo "BLOCKED: 生产环境 kubectl 破坏性操作被禁止。请手动在终端中执行。" >&2
  exit 2
fi

# ── 规则 3: 禁止数据库 DROP/FLUSH 操作 ──
if echo "$COMMAND" | grep -qiE '(DROP\s+(DATABASE|TABLE|INDEX|COLLECTION)|FLUSHALL|FLUSHDB|db\.dropDatabase|db\.\w+\.drop\(\))'; then
  echo "BLOCKED: 数据库 DROP/FLUSH 操作被禁止。请手动在终端中执行。" >&2
  exit 2
fi

# ── 规则 4: 禁止 git force push 到 main/master ──
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--force' &&
   echo "$COMMAND" | grep -qE '(main|master)'; then
  echo "BLOCKED: 禁止 force push 到 main/master 分支。" >&2
  exit 2
fi

# ── 规则 5: 禁止 git reset --hard ──
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
  echo "BLOCKED: git reset --hard 被禁止。请使用 git stash 或创建备份分支后再操作。" >&2
  exit 2
fi

# ── 规则 6: 禁止修改 /etc 和系统目录 ──
if echo "$COMMAND" | grep -qE '(sudo\s+rm|sudo\s+mv|sudo\s+chmod|sudo\s+chown)\s+.*/etc/'; then
  echo "BLOCKED: 禁止修改系统目录 /etc。" >&2
  exit 2
fi

# ── 规则 7: 禁止 docker system prune -a ──
if echo "$COMMAND" | grep -qE 'docker\s+system\s+prune\s+-a'; then
  echo "BLOCKED: docker system prune -a 会清理所有未使用的镜像。请手动执行。" >&2
  exit 2
fi

exit 0
