#!/bin/bash
# session-context.sh — SessionStart hook
# 会话启动时自动注入项目上下文信息

set -uo pipefail

echo "=== Session Context ==="

# Git 状态
if git rev-parse --is-inside-work-tree &>/dev/null; then
  echo ""
  echo "--- Git ---"
  echo "Branch: $(git branch --show-current 2>/dev/null)"
  echo "Status:"
  git status --short 2>/dev/null | head -20
  DIRTY=$(git status --short 2>/dev/null | wc -l)
  if [[ $DIRTY -gt 20 ]]; then
    echo "  ... and $((DIRTY - 20)) more files"
  fi
  echo ""
  echo "Recent commits:"
  git log --oneline -5 2>/dev/null
fi

# Kubernetes 上下文
if command -v kubectl &>/dev/null; then
  echo ""
  echo "--- Kubernetes ---"
  CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")
  echo "Context: $CONTEXT"
  if [[ "$CONTEXT" != "none" ]]; then
    NAMESPACE=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
    echo "Namespace: ${NAMESPACE:-default}"
  fi
fi

# Go 版本
if command -v go &>/dev/null; then
  echo ""
  echo "--- Go ---"
  go version 2>/dev/null
  if [[ -f "go.mod" ]]; then
    MODULE=$(head -1 go.mod | awk '{print $2}')
    echo "Module: $MODULE"
  fi
fi

# Docker
if command -v docker &>/dev/null; then
  RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l)
  if [[ $RUNNING -gt 0 ]]; then
    echo ""
    echo "--- Docker ---"
    echo "Running containers: $RUNNING"
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | head -10
  fi
fi

echo ""
echo "=== End Context ==="
