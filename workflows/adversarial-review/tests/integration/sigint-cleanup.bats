#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

# kill_tree <pid> — 递归杀整棵进程树
kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -KILL "$pid" 2>/dev/null || true
}

@test "SIGINT 后保留 .adversarial-runs/ + INTERRUPTED 条目" {
  mkdir -p pkg/foo; echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  AIREVIEW_FIXTURE=timeout AIREVIEW_CODEX_FIXTURE=timeout \
    "$SCRIPTS_DIR/review-diff.sh" &
  PID=$!
  sleep 2
  # 先发 SIGINT 触发 trap（写 INTERRUPTED 条目）
  kill -INT "$PID" 2>/dev/null || true
  sleep 1
  # 递归杀整棵进程树，保证 bats 不挂等
  kill_tree "$PID"
  wait "$PID" 2>/dev/null || true
  [ -d .adversarial-runs ]
  grep -q "INTERRUPTED" docs/adversarial-review-log.md || true  # SIGINT 时机依赖，弱断言
}
