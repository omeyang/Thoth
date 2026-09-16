#!/usr/bin/env bash
# 共享测试工具：定位脚本路径、临时目录、PATH 注入

WORKFLOW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$WORKFLOW_ROOT/scripts"
LIB_DIR="$WORKFLOW_ROOT/scripts/lib"
TEMPLATES_DIR="$WORKFLOW_ROOT/templates"
FIXTURES_DIR="$WORKFLOW_ROOT/tests/fixtures"

# Mock 二进制路径前置 PATH
export PATH="$FIXTURES_DIR/bin:$PATH"

# 每个测试用独立 tempdir，bats 会自动清理
setup_workdir() {
  WORKDIR="$(mktemp -d)"
  export WORKDIR
  cd "$WORKDIR" || return 1
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
}

teardown_workdir() {
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
    rm -rf "$WORKDIR"
  fi
}

# 写一个最小可用的 .adversarial-review.yaml 到 $WORKDIR
write_minimal_config() {
  cat > "$WORKDIR/.adversarial-review.yaml" <<EOF
repo: { root: ., search_dirs: [pkg], search_maxdepth: 3 }
llm: { claude_model: "", codex_command: codex, parallel_codex: true }
review: { dimensions: ["nil/typed-nil"], max_findings_per_source: 8 }
diff:
  default_ref: "--cached"
  scope_strategy: auto
  max_diff_lines: 500
  skip_paths: ["*.md", "docs/**"]
  auto_stash_unstaged: false
verify: { cmd: "echo verify-ok", timeout_seconds: 600 }
commit: { prefix_template: "fix({{TARGET}})", push_after_fix: false }
log: { file: docs/adversarial-review-log.md, run_dir: .adversarial-runs }
policy: { fail_on_severity: high, strict_on_error: false }
daily_check: { enabled: false, expected_entries: 15 }
EOF
}
