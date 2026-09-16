#!/usr/bin/env bash
# 把 hooks/pre-commit.sh.tmpl 复制到当前 git 仓库的 .git/hooks/pre-commit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMPL="$WORKFLOW_ROOT/hooks/pre-commit.sh.tmpl"

[[ -f "$TMPL" ]] || { echo "✗ template not found: $TMPL" >&2; exit 2; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "✗ not in a git repository" >&2; exit 2; }

HOOK="$REPO_ROOT/.git/hooks/pre-commit"
if [[ -e "$HOOK" ]]; then
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  cp "$HOOK" "$HOOK.bak.$ts"
  echo "↳ existing hook backed up to $HOOK.bak.$ts"
fi

cp "$TMPL" "$HOOK"
chmod +x "$HOOK"
echo "✓ installed pre-commit hook → $HOOK"
echo "  export THOTH_HOME=$(cd "$WORKFLOW_ROOT/../.." && pwd) in your shell rc"
