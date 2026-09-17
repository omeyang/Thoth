#!/bin/bash
# protect-secrets.sh — PreToolUse hook
# 拦截对密钥、凭证文件的读写，防止把秘密带进对话或被改写
#
# 退出码约定:
#   0 = 放行
#   2 = 阻止（stderr 回传给 Claude 说明原因）

set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# 目标路径：文件类工具取 file_path，Bash 取整条命令
case "$TOOL_NAME" in
  Read|Edit|Write) TARGET=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty') ;;
  Bash)            TARGET=$(echo "$INPUT" | jq -r '.tool_input.command // empty') ;;
  *)               exit 0 ;;
esac
[[ -n "$TARGET" ]] || exit 0

# 允许示例与模板文件
if echo "$TARGET" | grep -qE '\.env\.(example|sample|template)\b'; then
  exit 0
fi

# 密钥/凭证文件名特征
PATTERN='(^|[/ "'"'"'])(\.env(\.[A-Za-z0-9_-]+)?|\.netrc|\.npmrc|\.pypirc|credentials(\.json)?|service-account[^ ]*\.json|id_(rsa|ed25519|ecdsa|dsa)|[^ ]*\.(pem|key|p12|pfx|jks|keystore))($|[ "'"'"'])'

if echo "$TARGET" | grep -qE "$PATTERN"; then
  echo "BLOCKED: 目标疑似密钥或凭证文件（$TOOL_NAME）。请由人工处理，或改用 .env.example 之类的模板文件。" >&2
  exit 2
fi

# Bash 里常见的凭证读取方式
if [[ "$TOOL_NAME" == "Bash" ]] && echo "$TARGET" | grep -qE '(cat|less|more|head|tail|bat|grep|sed|awk|cp|mv|scp)\s+[^|;&]*~?/?\.(aws|ssh|gnupg|kube|docker)/'; then
  echo "BLOCKED: 命令试图读取或搬运 ~/.aws、~/.ssh、~/.gnupg、~/.kube、~/.docker 下的凭证。" >&2
  exit 2
fi

exit 0
