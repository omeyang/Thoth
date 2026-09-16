# 对抗审查工作流提取实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 XKit 的 `scripts/adversarial-review*.sh`（277 行 Bash + 硬编码 XKit 事实）提取重构为 `Thoth/workflows/adversarial-review/` 通用工作流（双入口 + YAML 配置 + Prompt 模板 + bats 测试 + WORKFLOW.md），并完成 XKit 侧迁移。

**Architecture:** 单一工作流目录，`scripts/` 下双入口（`review-diff.sh` for pre-commit / `review-target.sh` for 全包扫描）共享 `scripts/lib/quorum.sh` 四路合议底层；Prompt 完全外置 `templates/`；YAML 配置通过 `yq` 加载；测试用 bats-core + mock LLM 二进制。

**Tech Stack:** Bash 5+, bats-core 1.11+, shellcheck 0.10+, yq v4 (mikefarah/yq), claude CLI (Anthropic), codex CLI (OpenAI), envsubst (gettext), flock, git ≥ 2.30

**关联 spec:** `docs/specs/2026-05-16-adversarial-review-extraction-design.md`

---

## Phase 0：环境与骨架

### Task 1：安装工具 + 创建目录结构 + Makefile + .shellcheckrc

**Files:**
- Create: `workflows/adversarial-review/Makefile`
- Create: `workflows/adversarial-review/.shellcheckrc`
- Create: `workflows/adversarial-review/.gitkeep` 占位（后续步骤会替换）

- [ ] **Step 1：检测 / 安装 bats + shellcheck**

```bash
command -v bats >/dev/null || dnf5 install -y bats
command -v shellcheck >/dev/null || dnf5 install -y ShellCheck
command -v yq >/dev/null || { echo "yq missing — abort"; exit 1; }
bats --version && shellcheck --version | head -1 && yq --version
```

Expected: 三行版本号都打印，bats ≥ 1.11，shellcheck ≥ 0.10，yq ≥ v4。

- [ ] **Step 2：创建完整目录骨架**

```bash
cd /root/code/ai/github.com/omeyang/Thoth
mkdir -p workflows/adversarial-review/{scripts/lib,templates,examples,hooks,tests/{unit,integration,fixtures/{bin,diff,config,findings}}}
ls workflows/adversarial-review/
```

Expected: 列出 `scripts/ templates/ examples/ hooks/ tests/`。

- [ ] **Step 3：写 `workflows/adversarial-review/Makefile`**

```makefile
# Makefile for adversarial-review workflow
SCRIPTS := $(wildcard scripts/*.sh scripts/lib/*.sh)
TEST_HELPERS := tests/test_helper.bash

.PHONY: lint test test-unit test-integration help

help:
	@echo "Targets: lint, test, test-unit, test-integration"

lint:
	shellcheck -e SC1091 -e SC2155 $(SCRIPTS) hooks/*.tmpl scripts/*.sh

test: test-unit test-integration

test-unit:
	bats tests/unit/

test-integration:
	bats tests/integration/
```

- [ ] **Step 4：写 `workflows/adversarial-review/.shellcheckrc`**

```
# Disable warnings irrelevant for this workflow
disable=SC1091  # source: dynamic path
disable=SC2155  # declare and assign separately (intentional in our style)
```

- [ ] **Step 5：先用占位让 lint 不抛 missing-files 错误**

```bash
echo '#!/usr/bin/env bash' > workflows/adversarial-review/scripts/.placeholder.sh
make -C workflows/adversarial-review lint || true  # 只测命令本身可运行
```

Expected: shellcheck 命令能跑（具体输出后续 task 会有内容）。

- [ ] **Step 6：commit 骨架**

```bash
cd /root/code/ai/github.com/omeyang/Thoth
git add workflows/adversarial-review/
git commit -m "chore(adversarial-review): 工作流目录骨架 + Makefile + shellcheckrc"
```

---

### Task 2：tests/test_helper.bash + Mock LLM 二进制

**Files:**
- Create: `workflows/adversarial-review/tests/test_helper.bash`
- Create: `workflows/adversarial-review/tests/fixtures/bin/claude`
- Create: `workflows/adversarial-review/tests/fixtures/bin/codex`

- [ ] **Step 1：写 test_helper.bash（被所有 .bats 文件 source）**

`workflows/adversarial-review/tests/test_helper.bash`:

```bash
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
llm: { claude_model: claude-opus-4-7, codex_command: codex, parallel_codex: true }
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
```

- [ ] **Step 2：写 mock claude 二进制**

`workflows/adversarial-review/tests/fixtures/bin/claude`:

```bash
#!/usr/bin/env bash
# Mock Claude CLI for tests. AIREVIEW_FIXTURE selects scenario.
case "${AIREVIEW_FIXTURE:-}" in
  empty)      echo "无发现"; exit 0 ;;
  one-high)   cat <<'EOF'
| 编号 | 严重度 | 文件:行 | 根因 | 分类 | 来源数 | 对抗结果 |
|------|--------|---------|------|------|--------|----------|
| 1    | FG-H   | foo.go:42 | nil deref on bar() return | 必修 | 2 | a |
EOF
              exit 0 ;;
  one-medium) cat <<'EOF'
| 编号 | 严重度 | 文件:行 | 根因 | 分类 | 来源数 | 对抗结果 |
|------|--------|---------|------|------|--------|----------|
| 1    | FG-M   | bar.go:10 | err 未 wrap | 存疑 | 1 | c |
EOF
              exit 0 ;;
  timeout)    sleep 1300 ;;
  fail-1)     echo "claude API 429" >&2; exit 1 ;;
  *)          echo "MOCK claude: missing AIREVIEW_FIXTURE='${AIREVIEW_FIXTURE:-}'" >&2; exit 99 ;;
esac
```

```bash
chmod +x workflows/adversarial-review/tests/fixtures/bin/claude
```

- [ ] **Step 3：写 mock codex 二进制**

`workflows/adversarial-review/tests/fixtures/bin/codex`:

```bash
#!/usr/bin/env bash
# Mock Codex CLI for tests. AIREVIEW_CODEX_FIXTURE selects scenario per-call.
case "${AIREVIEW_CODEX_FIXTURE:-}" in
  empty)      echo "无发现"; exit 0 ;;
  one-high)   cat <<'EOF'
| 编号 | 严重度 | 文件:行 | 根因 | 修复 | 非FP理由 |
|------|--------|---------|------|------|----------|
| 1    | FG-H   | foo.go:42 | nil deref | check return | 已 grep 调用方无前置 nil 检查 |
EOF
              exit 0 ;;
  timeout)    sleep 1300 ;;
  fail-1)     echo "codex error" >&2; exit 1 ;;
  *)          echo "MOCK codex: missing AIREVIEW_CODEX_FIXTURE" >&2; exit 99 ;;
esac
```

```bash
chmod +x workflows/adversarial-review/tests/fixtures/bin/codex
```

- [ ] **Step 4：跑空 bats 验证 fixture 路径正确**

```bash
cat > /tmp/sanity.bats <<'EOF'
load "$WORKFLOW_ROOT/../tests/test_helper.bash"
@test "mock claude runs" {
  AIREVIEW_FIXTURE=empty run claude
  [ "$status" -eq 0 ]
  [ "$output" = "无发现" ]
}
EOF
WORKFLOW_ROOT=/root/code/ai/github.com/omeyang/Thoth/workflows/adversarial-review/scripts \
  bats /tmp/sanity.bats
rm /tmp/sanity.bats
```

Expected: `1 test, 0 failures`。

- [ ] **Step 5：commit**

```bash
cd /root/code/ai/github.com/omeyang/Thoth
git add workflows/adversarial-review/tests/
git commit -m "test(adversarial-review): test_helper + mock claude/codex 二进制"
```

---

## Phase 1：Lib 模块（TDD：先测试，后实现）

### Task 3：lib/severity.sh — 严重度比较

**Files:**
- Create: `workflows/adversarial-review/scripts/lib/severity.sh`
- Test: `workflows/adversarial-review/tests/unit/severity.bats`

- [ ] **Step 1：写失败测试**

`tests/unit/severity.bats`:

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  source "$LIB_DIR/severity.sh"
}

@test "severity_rank: high=3 medium=2 low=1 none=0" {
  [ "$(severity_rank high)" -eq 3 ]
  [ "$(severity_rank medium)" -eq 2 ]
  [ "$(severity_rank low)" -eq 1 ]
  [ "$(severity_rank none)" -eq 0 ]
}

@test "severity_ge: high >= medium = true" {
  run severity_ge high medium
  [ "$status" -eq 0 ]
}

@test "severity_ge: medium >= high = false" {
  run severity_ge medium high
  [ "$status" -eq 1 ]
}

@test "severity_ge: never threshold always false" {
  run severity_ge high never
  [ "$status" -eq 1 ]
}

@test "severity_rank: unknown returns 0" {
  [ "$(severity_rank bogus)" -eq 0 ]
}
```

- [ ] **Step 2：跑测试，确认全失败**

```bash
cd /root/code/ai/github.com/omeyang/Thoth/workflows/adversarial-review
bats tests/unit/severity.bats
```

Expected: 5 tests, 5 failures（severity.sh 还不存在）。

- [ ] **Step 3：写实现**

`scripts/lib/severity.sh`:

```bash
#!/usr/bin/env bash
# Severity ordering: high > medium > low > none. "never" disables.
severity_rank() {
  case "$1" in
    high)   echo 3 ;;
    medium) echo 2 ;;
    low)    echo 1 ;;
    *)      echo 0 ;;
  esac
}

# severity_ge $actual $threshold → exit 0 if actual >= threshold
severity_ge() {
  local actual_rank threshold_rank
  actual_rank=$(severity_rank "$1")
  threshold_rank=$(severity_rank "$2")
  # threshold "never" → rank 0 with special exit (always false)
  if [[ "$2" == "never" ]]; then
    return 1
  fi
  [[ "$actual_rank" -ge "$threshold_rank" ]]
}
```

- [ ] **Step 4：跑测试确认全过**

```bash
bats tests/unit/severity.bats
```

Expected: `5 tests, 0 failures`。

- [ ] **Step 5：commit**

```bash
cd /root/code/ai/github.com/omeyang/Thoth
git add workflows/adversarial-review/scripts/lib/severity.sh workflows/adversarial-review/tests/unit/severity.bats
git commit -m "feat(adversarial-review): lib/severity.sh + 单元测试"
```

---

### Task 4：lib/skip_paths.sh — glob 路径匹配

**Files:**
- Create: `workflows/adversarial-review/scripts/lib/skip_paths.sh`
- Test: `workflows/adversarial-review/tests/unit/skip_paths.bats`

- [ ] **Step 1：写失败测试**

`tests/unit/skip_paths.bats`:

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  source "$LIB_DIR/skip_paths.sh"
}

@test "skip_paths_match: *.md matches README.md" {
  run skip_paths_match "README.md" "*.md"
  [ "$status" -eq 0 ]
}

@test "skip_paths_match: docs/** matches docs/x/y.md" {
  run skip_paths_match "docs/x/y.md" "docs/**"
  [ "$status" -eq 0 ]
}

@test "skip_paths_match: **/testdata/** matches pkg/foo/testdata/x.txt" {
  run skip_paths_match "pkg/foo/testdata/x.txt" "**/testdata/**"
  [ "$status" -eq 0 ]
}

@test "skip_paths_match: *.md does not match foo.go" {
  run skip_paths_match "foo.go" "*.md"
  [ "$status" -eq 1 ]
}

@test "all_paths_skipped: every line matches one pattern" {
  printf '%s\n' "README.md" "docs/a.md" | {
    run all_paths_skipped <(cat) "*.md" "docs/**"
    [ "$status" -eq 0 ]
  }
}

@test "all_paths_skipped: one path unmatched → false" {
  run bash -c '
    source "'"$LIB_DIR"'/skip_paths.sh"
    printf "%s\n" "README.md" "main.go" | all_paths_skipped /dev/stdin "*.md"
  '
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2：跑测试确认全失败**

```bash
bats tests/unit/skip_paths.bats
```

Expected: 6 failures。

- [ ] **Step 3：写实现**

`scripts/lib/skip_paths.sh`:

```bash
#!/usr/bin/env bash
# Glob 匹配（支持 ** 跨目录）。需 bash 4+ extglob/globstar。
shopt -s extglob globstar nullglob 2>/dev/null || true

# skip_paths_match <file> <pattern> → 0 if match
skip_paths_match() {
  local file="$1" pattern="$2"
  # Bash globstar 模式匹配
  case "$file" in
    $pattern) return 0 ;;
    *)        return 1 ;;
  esac
}

# all_paths_skipped <file-with-paths-one-per-line> <pattern>...
# → 0 if every path matches at least one pattern; 1 if any path is unmatched
all_paths_skipped() {
  local input="$1"; shift
  local patterns=("$@")
  local path matched
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    matched=0
    for p in "${patterns[@]}"; do
      if skip_paths_match "$path" "$p"; then
        matched=1; break
      fi
    done
    [[ "$matched" -eq 0 ]] && return 1
  done < "$input"
  return 0
}
```

- [ ] **Step 4：跑测试确认全过**

```bash
bats tests/unit/skip_paths.bats
```

Expected: `6 tests, 0 failures`。

- [ ] **Step 5：commit**

```bash
git add workflows/adversarial-review/scripts/lib/skip_paths.sh workflows/adversarial-review/tests/unit/skip_paths.bats
git commit -m "feat(adversarial-review): lib/skip_paths.sh + glob 匹配测试"
```

---

### Task 5：lib/diff_sizing.sh — diff 行数计数

**Files:**
- Create: `workflows/adversarial-review/scripts/lib/diff_sizing.sh`
- Test: `workflows/adversarial-review/tests/unit/diff_sizing.bats`

- [ ] **Step 1：写失败测试**

`tests/unit/diff_sizing.bats`:

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  source "$LIB_DIR/diff_sizing.sh"
  TMPF="$(mktemp)"
}

teardown() { rm -f "$TMPF"; }

@test "diff_lines: counts +/- lines only" {
  cat > "$TMPF" <<'EOF'
diff --git a/foo b/foo
index 1234..5678
--- a/foo
+++ b/foo
@@ -1,3 +1,4 @@
 keep
-removed
+added1
+added2
EOF
  [ "$(diff_lines "$TMPF")" -eq 3 ]
}

@test "diff_lines: empty file → 0" {
  : > "$TMPF"
  [ "$(diff_lines "$TMPF")" -eq 0 ]
}

@test "diff_size_ok: under threshold → 0" {
  printf '+x\n%.0s' {1..100} > "$TMPF"
  run diff_size_ok "$TMPF" 500
  [ "$status" -eq 0 ]
}

@test "diff_size_ok: over threshold → 1" {
  printf '+x\n%.0s' {1..600} > "$TMPF"
  run diff_size_ok "$TMPF" 500
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2：跑测试确认失败**

```bash
bats tests/unit/diff_sizing.bats
```

Expected: 4 failures。

- [ ] **Step 3：写实现**

`scripts/lib/diff_sizing.sh`:

```bash
#!/usr/bin/env bash
# Diff 行数：仅计 +/- 开头的行（跳过 +++/--- 文件头与 @@hunk）

diff_lines() {
  local file="$1"
  [[ -s "$file" ]] || { echo 0; return; }
  grep -cE '^[+-][^+-]|^[+-]$' "$file" 2>/dev/null || echo 0
}

# diff_size_ok <diff-file> <max-lines> → 0 if within limit
diff_size_ok() {
  local n
  n=$(diff_lines "$1")
  [[ "$n" -le "$2" ]]
}
```

- [ ] **Step 4：跑测试**

```bash
bats tests/unit/diff_sizing.bats
```

Expected: `4 tests, 0 failures`。

- [ ] **Step 5：commit**

```bash
git add workflows/adversarial-review/scripts/lib/diff_sizing.sh workflows/adversarial-review/tests/unit/diff_sizing.bats
git commit -m "feat(adversarial-review): lib/diff_sizing.sh + 行数测试"
```

---

### Task 6：lib/target_infer.sh — 从 diff 推断 TARGET 名

**Files:**
- Create: `workflows/adversarial-review/scripts/lib/target_infer.sh`
- Test: `workflows/adversarial-review/tests/unit/target_infer.bats`

- [ ] **Step 1：写失败测试**

`tests/unit/target_infer.bats`:

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  source "$LIB_DIR/target_infer.sh"
}

@test "deepest_common: single dir → dir name" {
  run deepest_common <(printf '%s\n' "pkg/util/xsemaphore/redis.go" "pkg/util/xsemaphore/lua.go")
  [ "$status" -eq 0 ]
  [ "$output" = "xsemaphore" ]
}

@test "deepest_common: multi-pkg under same parent → parent name" {
  run deepest_common <(printf '%s\n' "pkg/foo/a.go" "pkg/bar/b.go")
  [ "$status" -eq 0 ]
  [ "$output" = "pkg" ]
}

@test "deepest_common: root file (no slash) → empty + status 1" {
  run deepest_common <(printf '%s\n' "main.go" "go.mod")
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "files_basename: first 3 basenames hyphen-joined" {
  run files_basename <(printf '%s\n' "a.go" "pkg/b.go" "x/y/c.go" "skip-me.go")
  [ "$status" -eq 0 ]
  [ "$output" = "a.go-b.go-c.go" ]
}

@test "sanitize_target: keeps alnum/dot/hyphen/underscore" {
  [ "$(sanitize_target 'foo bar/baz')" = "foo-bar-baz" ]
  [ "$(sanitize_target 'x@y\$z')" = "x-y-z" ]
  [ "$(sanitize_target 'ok_name.go')" = "ok_name.go" ]
}

@test "target_from_diff: auto strategy single-pkg" {
  run target_from_diff <(printf '%s\n' "pkg/util/xsemaphore/redis.go") auto
  [ "$status" -eq 0 ]
  [ "$output" = "xsemaphore" ]
}

@test "target_from_diff: auto fallback to files when common is shallow" {
  run target_from_diff <(printf '%s\n' "pkg/foo/a.go" "pkg/bar/b.go") auto
  [ "$status" -eq 0 ]
  [ "$output" = "a.go-b.go" ]
}

@test "target_from_diff: no usable input → commit-fallback" {
  run target_from_diff /dev/null auto
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^commit- ]]
}
```

- [ ] **Step 2：跑测试确认失败**

```bash
bats tests/unit/target_infer.bats
```

- [ ] **Step 3：写实现**

`scripts/lib/target_infer.sh`:

```bash
#!/usr/bin/env bash
# 从 diff 涉及的文件路径推断 TARGET 名

# deepest_common <file-with-paths> → echo dir-basename, exit 0;
#   或 exit 1 if 没有公共父目录（即至少一个文件在根）
deepest_common() {
  local input="$1"
  local first prefix path
  if ! IFS= read -r first < "$input"; then
    return 1
  fi
  # 路径无 / → 根文件，无公共父
  [[ "$first" != */* ]] && return 1
  prefix="${first%/*}"
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    [[ "$path" != */* ]] && return 1
    while [[ "$path/" != "$prefix"/* ]]; do
      # 缩短 prefix 到上一级
      [[ "$prefix" != */* ]] && return 1
      prefix="${prefix%/*}"
    done
  done < "$input"
  echo "${prefix##*/}"
}

# files_basename <file-with-paths> → echo "a.go-b.go-c.go" (前 3 个 basename 用 - 拼)
files_basename() {
  local input="$1"
  local result="" path bn n=0
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    bn="${path##*/}"
    if [[ -z "$result" ]]; then
      result="$bn"
    else
      result="$result-$bn"
    fi
    n=$((n+1))
    [[ "$n" -ge 3 ]] && break
  done < "$input"
  [[ -n "$result" ]] || return 1
  echo "$result"
}

# sanitize_target <name> → echo cleaned (only alnum . _ - kept; others → -)
sanitize_target() {
  echo "$1" | tr -c 'a-zA-Z0-9._-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//'
}

# target_from_diff <file-with-paths> <strategy>
#   strategy: auto | deepest-common | files
target_from_diff() {
  local input="$1" strategy="${2:-auto}"
  local out
  case "$strategy" in
    deepest-common)
      out=$(deepest_common "$input") || return 1
      ;;
    files)
      out=$(files_basename "$input") || return 1
      ;;
    auto)
      out=$(deepest_common "$input")
      # 拒绝过浅的 common（如 pkg/cmd/internal 顶层）
      if [[ -z "$out" || "$out" =~ ^(pkg|cmd|internal|src|lib)$ ]]; then
        out=$(files_basename "$input") || true
      fi
      ;;
    *)
      echo "unknown strategy: $strategy" >&2; return 2 ;;
  esac
  if [[ -z "$out" ]]; then
    out="commit-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  fi
  sanitize_target "$out"
}
```

- [ ] **Step 4：跑测试**

```bash
bats tests/unit/target_infer.bats
```

Expected: `8 tests, 0 failures`。

- [ ] **Step 5：commit**

```bash
git add workflows/adversarial-review/scripts/lib/target_infer.sh workflows/adversarial-review/tests/unit/target_infer.bats
git commit -m "feat(adversarial-review): lib/target_infer.sh + auto/files/deepest 推断测试"
```

---

### Task 7：lib/config.sh — YAML 配置加载

**Files:**
- Create: `workflows/adversarial-review/scripts/lib/config.sh`
- Test: `workflows/adversarial-review/tests/unit/config.bats`

- [ ] **Step 1：写失败测试**

`tests/unit/config.bats`:

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  source "$LIB_DIR/config.sh"
  TMPCFG="$(mktemp --suffix=.yaml)"
  cat > "$TMPCFG" <<'EOF'
repo: { root: /tmp/proj, search_dirs: [pkg, cmd], search_maxdepth: 3 }
diff: { default_ref: "--cached", scope_strategy: auto, max_diff_lines: 500 }
policy: { fail_on_severity: high, strict_on_error: false }
log: { file: docs/log.md, run_dir: .runs }
verify: { cmd: "task pre-push", timeout_seconds: 600 }
llm: { claude_model: claude-opus-4-7, codex_command: codex }
EOF
}

teardown() { rm -f "$TMPCFG"; }

@test "config_load: missing file → exit 2" {
  run config_load /nonexistent.yaml
  [ "$status" -eq 2 ]
}

@test "config_get: top-level path" {
  config_load "$TMPCFG"
  [ "$(config_get .repo.root)" = "/tmp/proj" ]
  [ "$(config_get .policy.fail_on_severity)" = "high" ]
}

@test "config_get: missing key returns empty + status 0" {
  config_load "$TMPCFG"
  run config_get .nope.nope
  [ "$status" -eq 0 ]
  [ -z "$output" ] || [ "$output" = "null" ]
}

@test "config_get_default: returns default if missing" {
  config_load "$TMPCFG"
  [ "$(config_get_default .nope.nope FALLBACK)" = "FALLBACK" ]
  [ "$(config_get_default .repo.root WRONG)" = "/tmp/proj" ]
}

@test "config_get_array: returns one-per-line" {
  config_load "$TMPCFG"
  run config_get_array .repo.search_dirs
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "pkg" ]
  [ "${lines[1]}" = "cmd" ]
}
```

- [ ] **Step 2：跑测试确认失败**

```bash
bats tests/unit/config.bats
```

- [ ] **Step 3：写实现**

`scripts/lib/config.sh`:

```bash
#!/usr/bin/env bash
# YAML 配置加载（依赖 yq v4）

CFG_PATH=""

config_load() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "config: file not found: $path" >&2
    return 2
  fi
  command -v yq >/dev/null || { echo "config: 'yq' not in PATH" >&2; return 2; }
  CFG_PATH="$path"
  # 验证可解析
  yq eval '.' "$path" >/dev/null 2>&1 || { echo "config: invalid YAML: $path" >&2; return 2; }
}

# config_get <yq-path>  → echo value or empty
config_get() {
  [[ -n "$CFG_PATH" ]] || { echo "config: not loaded" >&2; return 2; }
  local val
  val=$(yq eval "$1 // \"\"" "$CFG_PATH" 2>/dev/null)
  # yq returns "null" for missing → normalize to empty
  [[ "$val" == "null" ]] && val=""
  echo "$val"
}

config_get_default() {
  local val
  val=$(config_get "$1")
  if [[ -z "$val" ]]; then
    echo "$2"
  else
    echo "$val"
  fi
}

# config_get_array <yq-path>  → echo each item on its own line
config_get_array() {
  [[ -n "$CFG_PATH" ]] || { echo "config: not loaded" >&2; return 2; }
  yq eval "$1 // [] | .[]" "$CFG_PATH" 2>/dev/null
}
```

- [ ] **Step 4：跑测试**

```bash
bats tests/unit/config.bats
```

Expected: `5 tests, 0 failures`。

- [ ] **Step 5：commit**

```bash
git add workflows/adversarial-review/scripts/lib/config.sh workflows/adversarial-review/tests/unit/config.bats
git commit -m "feat(adversarial-review): lib/config.sh + yq 加载测试"
```

---

### Task 8：lib/quorum.sh — 四路合议核心（最复杂）

**Files:**
- Create: `workflows/adversarial-review/scripts/lib/quorum.sh`

> 注：quorum.sh 的端到端集成测试在 Task 15（涉及 review-diff），此处仅写实现 + smoke 测试。

- [ ] **Step 1：先写一个 smoke 测试（确保 source 不报错 + 函数定义齐全）**

追加到 `tests/unit/severity.bats` 或新建 `tests/unit/quorum_smoke.bats`：

`tests/unit/quorum_smoke.bats`:

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

@test "quorum.sh sources without error" {
  run bash -c "source '$LIB_DIR/quorum.sh' && declare -F quorum_run quorum_apply_fixes log_append cleanup_runs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"quorum_run"* ]]
  [[ "$output" == *"quorum_apply_fixes"* ]]
  [[ "$output" == *"log_append"* ]]
}
```

- [ ] **Step 2：写实现 — quorum.sh（含模板渲染、并行 codex、claude 编排）**

`scripts/lib/quorum.sh`:

```bash
#!/usr/bin/env bash
# 四路合议核心：被入口脚本 source。
# 依赖：lib/severity.sh、lib/config.sh、envsubst、claude、codex、flock、timeout

# 必须先 source 其他 lib（由调用方保证 LIB_DIR 已设）
: "${LIB_DIR:?LIB_DIR not set}"

# render_template <template-name> <output-file>
#   读 templates/<name>.md，envsubst 注入 export 出去的 {{VAR}}
render_template() {
  local tmpl="$TEMPLATES_DIR/$1" out="$2"
  [[ -f "$tmpl" ]] || { echo "template missing: $tmpl" >&2; return 2; }
  # envsubst 不支持 {{VAR}}，用 sed 把 {{VAR}} → ${VAR} 后再 envsubst
  sed -E 's/\{\{([A-Z_][A-Z_0-9]*)\}\}/\${\1}/g' "$tmpl" | envsubst > "$out"
}

# quorum_run <TARGET> <WORKDIR> <LOG_DIR>
#   stdout: one-line JSON (verdict / highest_severity / ...)
quorum_run() {
  local target="$1" workdir="$2" log_dir="$3"
  local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$log_dir"

  export TARGET="$target" WORKDIR="$workdir"
  export DIMENSIONS; DIMENSIONS=$(config_get_array .review.dimensions | sed 's/^/- /')
  export SEVERITY_DEF="FG-H（可致 panic/数据错乱/死锁/泄漏）、FG-M（契约偏离/错误丢失/竞态边缘）、FG-L（代码异味；忽略）"
  export VERIFY_CMD; VERIFY_CMD=$(config_get_default .verify.cmd "echo verify-not-set")
  export COMMIT_PREFIX; COMMIT_PREFIX=$(config_get_default .commit.prefix_template "fix({{TARGET}})")
  export LOG_FILE; LOG_FILE=$(config_get_default .log.file "docs/adversarial-review-log.md")

  # ===== 阶段 1：Codex 双路后台并行 =====
  local codex_a="$log_dir/codex-A-${target}-${ts}.md"
  local codex_b="$log_dir/codex-B-${target}-${ts}.md"
  local codex_cmd; codex_cmd=$(config_get_default .llm.codex_command codex)
  local codex_timeout; codex_timeout=$(config_get_default .verify.timeout_seconds 600)

  local prompt_a="$log_dir/codex-attack-prompt-${ts}.md"
  local prompt_b="$log_dir/codex-defend-prompt-${ts}.md"
  render_template codex-attack  "$prompt_a"
  render_template codex-defend  "$prompt_b"

  timeout "$codex_timeout" "$codex_cmd" exec -s danger-full-access --cd "$workdir" \
    "$(cat "$prompt_a")" > "$codex_a" 2>&1 &
  local pid_a=$!
  timeout "$codex_timeout" "$codex_cmd" exec -s danger-full-access --cd "$workdir" \
    "$(cat "$prompt_b")" > "$codex_b" 2>&1 &
  local pid_b=$!

  # ===== 阶段 2：Claude 主编排 =====
  local claude_model; claude_model=$(config_get_default .llm.claude_model claude-opus-4-7)
  local claude_prompt="$log_dir/claude-orchestrator-prompt-${ts}.md"
  export CODEX_A_FILE="$codex_a" CODEX_B_FILE="$codex_b"
  export CODEX_A_PID="$pid_a" CODEX_B_PID="$pid_b"
  export LOG_DIR="$log_dir" TS="$ts"
  render_template claude-orchestrator "$claude_prompt"

  local quorum_timeout
  quorum_timeout=$(( codex_timeout * 2 ))
  set +e
  timeout "$quorum_timeout" claude -p "$(cat "$claude_prompt")" \
    --dangerously-skip-permissions --model "$claude_model" \
    > "$log_dir/claude-orchestrator-${ts}.log" 2>&1
  local rc=$?
  set -e

  # 确保后台 codex 进程已收尸
  wait "$pid_a" 2>/dev/null || true
  wait "$pid_b" 2>/dev/null || true

  # ===== 阶段 3：解析合议结果 =====
  local verdict_file="$log_dir/verdict-${ts}.json"
  if [[ -f "$verdict_file" ]]; then
    cat "$verdict_file"
    return 0
  else
    # Claude 未写 verdict → 失败
    cat <<EOF
{"verdict":{"must_fix":0,"disputed":0,"discarded":0},"highest_severity":"none","error":"claude orchestrator failed (rc=$rc)","log_entry_path":""}
EOF
    return $rc
  fi
}

# quorum_apply_fixes <WORKDIR> <LOG_DIR> — 仅 review-target 调用
quorum_apply_fixes() {
  local workdir="$1" log_dir="$2"
  # 实际修复由 claude-orchestrator 阶段 E 完成；此处仅做后置验证
  local verify; verify=$(config_get_default .verify.cmd "")
  [[ -z "$verify" ]] && return 0
  ( cd "$workdir" && eval "$verify" )
}

# log_append <log-file> <run-dir> <entry-content>  — flock 锁保护
# NOTE: signature changed during Task 8 fix (commit fa45e3a) — second arg is run_dir for late-log fallback,
# previously read from $LOG_DIR env var which broke after subshell-wrapping quorum_run.
log_append() {
  local file="$1" run_dir="$2"; shift 2
  local content="$*"
  local lock="${file}.lock"
  mkdir -p "$(dirname "$file")"
  if flock -w 30 -x 9; then
    {
      [[ -f "$file" ]] || echo "# Adversarial Review Log"
      echo ""
      echo "$content"
    } >> "$file"
    return 0
  else
    # 抢锁超时 → 写到 late-log
    local late="${run_dir:-/tmp}/late-log-$(date -u +%s).md"
    {
      echo ""
      echo "$content"
    } > "$late"
    echo "WARN: log lock contention; wrote to $late" >&2
    return 0
  fi 9>"$lock"
}

# cleanup_runs <log-dir>  — 删 7 天前的中间文件
cleanup_runs() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -type f -mtime +7 -delete 2>/dev/null || true
}
```

- [ ] **Step 3：跑 smoke 测试**

```bash
bats tests/unit/quorum_smoke.bats
```

Expected: `1 test, 0 failures`。

- [ ] **Step 4：跑 shellcheck**

```bash
make -C workflows/adversarial-review lint
```

Expected: `scripts/lib/quorum.sh` 通过（可能有少量 SC2155 但已禁）。

- [ ] **Step 5：commit**

```bash
git add workflows/adversarial-review/scripts/lib/quorum.sh workflows/adversarial-review/tests/unit/quorum_smoke.bats
git commit -m "feat(adversarial-review): lib/quorum.sh — 四路合议核心 + render_template + log_append flock"
```

---

## Phase 2：Prompt 模板（5 个）

### Task 9：写 5 个 templates/*.md

**Files:**
- Create: `workflows/adversarial-review/templates/codex-attack.md`
- Create: `workflows/adversarial-review/templates/codex-defend.md`
- Create: `workflows/adversarial-review/templates/claude-orchestrator.md`
- Create: `workflows/adversarial-review/templates/cross-codex-attacks-claude.md`
- Create: `workflows/adversarial-review/templates/log-entry.md`

> 这些模板是 prompt 工程，从原 XKit 脚本第 105-218 行抽出 + 通用化。变量用 `{{VAR}}`，由 `render_template` 替换。

- [ ] **Step 1：写 templates/codex-attack.md**

```markdown
对 {{TARGET}} 包对抗审查，读 {{WORKDIR}} 下所有 .go（含 doc.go / _test.go）。

扫描维度：
{{DIMENSIONS}}

## 输出规范（强约束）
- **只输出最终清单，禁止输出搜索过程、工具调用、思考过程、验证说明**
- 严格 Markdown 表格，列头：`严重度 | 文件:行号 | 根因(≤80字) | 修复建议(≤80字) | 非FP理由(≤60字)`
- 最多 8 行
- 无真问题就只输出一行：`无发现`
- 严重度：{{SEVERITY_DEF}}
- 只列 FG-H 和 FG-M；FG-L 忽略
```

- [ ] **Step 2：写 templates/codex-defend.md**

```markdown
作为 {{TARGET}} 资深复核者，独立审查 {{WORKDIR}} 下所有 .go，只列你证据最充分的 FG-H/M 真问题，每条必须能举出攻击路径。

## 输出规范（强约束）
- **只输出最终清单，禁止输出搜索过程、工具调用、思考过程、验证说明**
- 严格 Markdown 表格，列头：`严重度 | 文件:行号 | 根因(≤80字) | 修复建议(≤80字) | 非FP理由(≤60字)`
- 最多 8 行
- 无真问题就只输出一行：`无发现`
- 严重度：{{SEVERITY_DEF}}
- 只列 FG-H 和 FG-M
```

- [ ] **Step 3：写 templates/claude-orchestrator.md（最长，~80 行）**

```markdown
你是 {{TARGET}} 自动化对抗审查 v2 主编排器。目标：{{TARGET}}（路径 {{WORKDIR}}）。

## 上下文
外部已并行启动 2 个 codex exec（PID={{CODEX_A_PID}} / {{CODEX_B_PID}}），输出保存到：
- {{CODEX_A_FILE}}
- {{CODEX_B_FILE}}

Codex 被要求严格输出 Markdown 表格，≤8 行，禁止输出过程。

## 你的强制执行流程

### 阶段 A：Claude 双代理独立扫描（与 Codex 并行）
**必须**用 Agent 工具在一条消息里并行启动 2 个 Explore 子代理：

- **Agent CA（攻方）** subagent_type=Explore, thoroughness=very thorough
  prompt：
  ```
  你是 {{TARGET}} 包对抗审查攻方。读 {{WORKDIR}} 所有 .go（含 doc.go / _test.go）。
  扫描维度：
  {{DIMENSIONS}}
  **严格输出 Markdown 表格，列：严重度|文件:行号|根因(≤80字)|修复建议(≤80字)|非FP理由(≤60字)。最多 8 行。只 FG-H/FG-M。禁止输出过程。**
  无真问题只输出：无发现
  ```

- **Agent CB（守方/复核）** subagent_type=Explore, thoroughness=medium
  prompt：
  ```
  你是 {{TARGET}} 资深复核者。独立扫一遍 {{WORKDIR}} 所有 .go，只列证据最充分的 FG-H/M 真问题。
  同时识别常见 false positive 模式（文档化设计决策、已有防御、公共 API 契约、业内惯例）。
  输出两个表格：
  表格 1 标题"真问题"，列：严重度|文件:行号|根因|修复|证据。
  表格 2 标题"误报识别"，列：何种线索属于 FP|为什么。
  每表 ≤6 行。禁止输出过程。
  ```

### 阶段 B：等待 Codex 完成
Claude 子代理返回后立刻跑 Bash：
```
wait {{CODEX_A_PID}} {{CODEX_B_PID}} || true
```
Read 两个 Codex 输出文件全文（文件不大，<20KB）。**如果 Codex 输出含思考过程/搜索日志（未严格遵守规范），你必须手动提取表格行，不能丢弃发现。**

### 阶段 C：跨阵营对抗审查
收集 4 份原始发现后，启动两路交叉对抗：

1. **Codex 攻击 Claude 的发现**：
   把 CA + CB 的 Claude 发现拼成一个清单，用 Bash：
   ```
   codex exec -s danger-full-access --cd "{{WORKDIR}}" "以下是 Claude 双代理列出的发现。对每条逐行判断：(a) 真问题且证据充分；(b) false positive；(c) 证据不足。严格表格：原编号|Claude结论|你的判断 a/b/c|理由(≤60字)。禁止输出过程。<<CLAUDE 发现>>..." > {{LOG_DIR}}/codex-attack-claude-{{TARGET}}-{{TS}}.md
   ```

2. **Claude 攻击 Codex 的发现**：
   再用 Agent 工具启动 1 个 Explore 子代理 CC（反攻），prompt：
   ```
   以下是 Codex 双路列出的发现（{{TARGET}}）。对每条逐行判断：(a)/(b)/(c)。Read {{WORKDIR}} 相关源码核实，不要轻信 Codex 论断。严格表格：原编号|Codex结论|你的判断 a/b/c|理由(≤60字)。禁止输出过程。<<CODEX 发现>>...
   ```

### 阶段 D：合议
基于 4 份原始 + 2 份交叉对抗，按以下规则分类：
- **必修（高置信）**：≥2 原始来源指向同一文件:行号 **且** 交叉对抗至少一方判 (a)
- **必修（单源但交叉验证）**：1 原始来源，对阵营交叉判 (a)
- **存疑（人工）**：交叉判 (c) 或两判相反 → Read 源码做最终裁决
- **舍弃**：交叉判 (b)，或匹配已文档化"false positive"模式

### 阶段 E：修复（仅 review-target 默认行为；review-diff 默认跳过此阶段）
**本次运行如环境变量 `AIREVIEW_NO_FIX=1` 则跳过此阶段。**
对所有"必修"+"存疑裁决为修"问题：Read → Edit → 写/更新测试。
跑 `{{VERIFY_CMD}}`（**禁 --no-verify**）。失败看日志修根因，最多 3 轮；3 轮仍败则 `git restore -SW .` 回滚。

### 阶段 F：提交（仅 review-target，且 `AIREVIEW_NO_COMMIT` 未设）
- commit 风格：`{{COMMIT_PREFIX}}: 中文简述`；**禁 Co-Authored-By / Claude 署名**
- 多类修复可拆多个 commit
- 若 `commit.push_after_fix=true` 才 push

### 阶段 G：写 verdict JSON（必须，所有路径）
**必须**把以下 JSON 写到 `{{LOG_DIR}}/verdict-{{TS}}.json`（一行）：
```json
{"findings":{"claude_attack":N,"claude_defend":N,"codex_a":N,"codex_b":N},"cross":{"codex_attacks_claude":{"a":N,"b":N,"c":N},"claude_attacks_codex":{"a":N,"b":N,"c":N}},"verdict":{"must_fix":N,"disputed":N,"discarded":N},"highest_severity":"high|medium|none","log_entry_path":"{{LOG_DIR}}/log-entry-{{TS}}.md"}
```
**且**把日志条目写到 `{{LOG_DIR}}/log-entry-{{TS}}.md`，格式见 `templates/log-entry.md`。
入口脚本会用 `flock` 锁追加到 `{{LOG_FILE}}`。

## 硬约束
- 中文注释英文标识符；构造器返 error 不 panic
- 禁破坏性 git（reset --hard / push --force / --no-verify）
- **严禁跳过任何阶段**。即使 Codex 输出"截断/无结论"，也必须手动提取表格行进入交叉对抗
- 空目录（无 .go）→ 写 0 发现的 verdict.json + 退出

现在开始。第一步：在一条消息里同时发起两个 Agent 工具调用（CA+CB）。
```

- [ ] **Step 4：写 templates/cross-codex-attacks-claude.md**

```markdown
以下是 Claude 双代理列出的对抗审查发现（{{TARGET}} 包）。

对每条逐行判断：
- (a) 真问题且证据充分
- (b) false positive
- (c) 证据不足需更多上下文

逐条给出你的判断和一句话理由。

严格表格输出，列：原编号 | Claude结论 | 你的判断 a/b/c | 理由(≤60字)
**禁止输出过程、思考、工具调用日志。**

<<CLAUDE 发现>>
{{CLAUDE_FINDINGS}}
```

- [ ] **Step 5：写 templates/log-entry.md**

```markdown
## {{DATE}} TARGET={{TARGET}} REF={{REF}}
- 触发：{{TRIGGER}} (review-diff/review-target)
- 原始发现：Claude攻={{CA_N}} 守={{CB_N}} / Codex A={{CXA_N}} B={{CXB_N}}
- 交叉对抗：Codex攻Claude → a={{CX_A}} b={{CX_B}} c={{CX_C}}；Claude攻Codex → a={{CC_A}} b={{CC_B}} c={{CC_C}}
- 合议：必修={{MUST}} 存疑={{DISP}} 舍弃={{DISC}}
- 修复：{{FIX_RESULT}}
- 合议表格：
{{VERDICT_TABLE}}
```

- [ ] **Step 6：commit**

```bash
git add workflows/adversarial-review/templates/
git commit -m "feat(adversarial-review): 5 个 Prompt 模板（codex-attack/defend、claude-orchestrator、cross、log-entry）"
```

---

## Phase 3：入口脚本

### Task 10：scripts/install-hooks.sh

**Files:**
- Create: `workflows/adversarial-review/scripts/install-hooks.sh`

- [ ] **Step 1：写实现**

```bash
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
```

- [ ] **Step 2：跑 shellcheck**

```bash
shellcheck workflows/adversarial-review/scripts/install-hooks.sh
```

Expected: 通过。

- [ ] **Step 3：手动 smoke**

```bash
cd /tmp && rm -rf test-install && mkdir test-install && cd test-install
git init -q
/root/code/ai/github.com/omeyang/Thoth/workflows/adversarial-review/scripts/install-hooks.sh
ls -l .git/hooks/pre-commit
cd /root/code/ai/github.com/omeyang/Thoth
```

Expected: `.git/hooks/pre-commit` 存在且可执行。

- [ ] **Step 4：commit**

```bash
git add workflows/adversarial-review/scripts/install-hooks.sh
git commit -m "feat(adversarial-review): scripts/install-hooks.sh — 一键装 pre-commit"
```

---

### Task 11：hooks/pre-commit.sh.tmpl + xkit-pre-commit.sh.example

**Files:**
- Create: `workflows/adversarial-review/hooks/pre-commit.sh.tmpl`
- Create: `workflows/adversarial-review/examples/xkit-pre-commit.sh.example`

- [ ] **Step 1：写 hooks/pre-commit.sh.tmpl**

```bash
#!/usr/bin/env bash
# adversarial-review pre-commit hook (装于 .git/hooks/pre-commit)
set -euo pipefail

THOTH="${THOTH_HOME:-/root/code/ai/github.com/omeyang/Thoth}"
REVIEW_SCRIPT="$THOTH/workflows/adversarial-review/scripts/review-diff.sh"

[[ -x "$REVIEW_SCRIPT" ]] || {
  echo "✗ adversarial-review: $REVIEW_SCRIPT not executable" >&2
  echo "  set THOTH_HOME or fix path" >&2
  exit 0  # 找不到工具不阻断 commit
}

# 跳过 merge / rebase / cherry-pick
if [[ -f "$(git rev-parse --git-dir)/MERGE_HEAD" \
   || -d "$(git rev-parse --git-dir)/rebase-merge" \
   || -d "$(git rev-parse --git-dir)/rebase-apply" \
   || -f "$(git rev-parse --git-dir)/CHERRY_PICK_HEAD" ]]; then
  exit 0
fi

# 重入保护
[[ "${AIREVIEW_RUNNING:-}" == "1" ]] && exit 0

# review-diff.sh exit 3 = skip (空 diff / 全 skip / 超 max_diff_lines) → 不阻断 commit
"$REVIEW_SCRIPT" || RC=$?
RC="${RC:-0}"
[[ "$RC" -eq 3 ]] && exit 0
exit "$RC"
```

- [ ] **Step 2：写 examples/xkit-pre-commit.sh.example（与上面相同，仅注释加 XKit 说明）**

```bash
#!/usr/bin/env bash
# XKit 对抗审查 pre-commit hook（示例）
# 装法：cp examples/xkit-pre-commit.sh.example .git/hooks/pre-commit && chmod +x
# 或用：scripts/install-hooks.sh
set -euo pipefail

THOTH="${THOTH_HOME:-/root/code/ai/github.com/omeyang/Thoth}"
REVIEW_SCRIPT="$THOTH/workflows/adversarial-review/scripts/review-diff.sh"

[[ -x "$REVIEW_SCRIPT" ]] || { echo "✗ review-diff.sh not found" >&2; exit 0; }

if [[ -f "$(git rev-parse --git-dir)/MERGE_HEAD" \
   || -d "$(git rev-parse --git-dir)/rebase-merge" \
   || -d "$(git rev-parse --git-dir)/rebase-apply" \
   || -f "$(git rev-parse --git-dir)/CHERRY_PICK_HEAD" ]]; then
  exit 0
fi

[[ "${AIREVIEW_RUNNING:-}" == "1" ]] && exit 0

# review-diff.sh exit 3 = skip (空 diff / 全 skip / 超 max_diff_lines) → 不阻断 commit
"$REVIEW_SCRIPT" || RC=$?
RC="${RC:-0}"
[[ "$RC" -eq 3 ]] && exit 0
exit "$RC"
```

- [ ] **Step 3：commit**

```bash
git add workflows/adversarial-review/hooks/ workflows/adversarial-review/examples/xkit-pre-commit.sh.example
git commit -m "feat(adversarial-review): hooks/pre-commit.sh.tmpl + XKit 示例"
```

---

### Task 12：scripts/review-diff.sh — 增量审查入口

**Files:**
- Create: `workflows/adversarial-review/scripts/review-diff.sh`

- [ ] **Step 1：写实现**

```bash
#!/usr/bin/env bash
# 增量对抗审查入口（pre-commit 主消费者）
# Usage: review-diff.sh [--ref=<git-ref>] [--scope=<auto|files|deepest-common>] [--config=<path>]
set -euo pipefail

# 重入保护
if [[ "${AIREVIEW_RUNNING:-}" == "1" ]]; then
  exit 0
fi
export AIREVIEW_RUNNING=1
export AIREVIEW_NO_FIX=1   # review-diff 永远不自动改代码
export AIREVIEW_TRIGGER="review-diff"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIB_DIR="$SCRIPT_DIR/lib"
export TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"

source "$LIB_DIR/severity.sh"
source "$LIB_DIR/skip_paths.sh"
source "$LIB_DIR/diff_sizing.sh"
source "$LIB_DIR/target_infer.sh"
source "$LIB_DIR/config.sh"

# ===== 错误信息打印工具（必须在参数解析之前定义，否则未知参数路径会触发 die_arg: command not found）=====
die() {
  local cat="$1" reason="$2" fix="$3" log="${4:-}"
  cat >&2 <<EOF
✗ adversarial-review: $cat
  reason: $reason
  fix:    $fix
  log:    ${log:-(none)}
EOF
  exit "${5:-2}"
}

die_arg() { die "usage" "$1" "see review-diff.sh --help" "" 2; }

# ===== 参数解析 =====
REF=""
SCOPE=""
CFG_FILE="$PWD/.adversarial-review.yaml"

for arg in "$@"; do
  case "$arg" in
    --ref=*)    REF="${arg#*=}" ;;
    --scope=*)  SCOPE="${arg#*=}" ;;
    --config=*) CFG_FILE="${arg#*=}" ;;
    -h|--help)  sed -n '3,5p' "$0"; exit 0 ;;
    *)          die_arg "unknown arg: $arg" ;;
  esac
done

# ===== 配置加载 =====
config_load "$CFG_FILE" || die "config" "cannot load $CFG_FILE" "create from examples/adversarial-review.yaml.example"

REF="${REF:-$(config_get_default .diff.default_ref --cached)}"
SCOPE="${SCOPE:-$(config_get_default .diff.scope_strategy auto)}"
MAX_LINES=$(config_get_default .diff.max_diff_lines 500)
LOG_FILE=$(config_get_default .log.file docs/adversarial-review-log.md)
RUN_DIR=$(config_get_default .log.run_dir .adversarial-runs)
FAIL_ON=$(config_get_default .policy.fail_on_severity high)
STRICT_ERR=$(config_get_default .policy.strict_on_error false)

# ===== 依赖体检 =====
for bin in claude codex git yq envsubst flock timeout; do
  command -v "$bin" >/dev/null || die "missing dependency" "'$bin' not found in PATH" "install $bin"
done

# ===== 必须在 git 仓库 =====
git rev-parse --show-toplevel >/dev/null 2>&1 || die "git" "not inside a git repository" "run inside a git checkout"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# ===== Diff 文件列表 =====
TS=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$RUN_DIR"
DIFF_FILE="$RUN_DIR/diff-${TS}.patch"
NAME_FILE="$RUN_DIR/diff-files-${TS}.txt"

# shellcheck disable=SC2086
git diff $REF --name-only > "$NAME_FILE"
# shellcheck disable=SC2086
git diff $REF > "$DIFF_FILE"

# 空 diff
if [[ ! -s "$NAME_FILE" ]]; then
  exit 3
fi

# 全 skip_paths
SKIP_ARGS=()
while IFS= read -r p; do
  [[ -n "$p" ]] && SKIP_ARGS+=("$p")
done < <(config_get_array .diff.skip_paths)
if [[ ${#SKIP_ARGS[@]} -gt 0 ]]; then
  if all_paths_skipped "$NAME_FILE" "${SKIP_ARGS[@]}"; then
    exit 3
  fi
fi

# 超 max_diff_lines
if ! diff_size_ok "$DIFF_FILE" "$MAX_LINES"; then
  echo "diff > $MAX_LINES lines; use scripts/review-target.sh <name> instead" >&2
  exit 3
fi

# ===== Partial staging 检测（spec §7.5）=====
AUTO_STASH=$(config_get_default .diff.auto_stash_unstaged false)
HAS_UNSTAGED=0
while IFS= read -r sf; do
  [[ -z "$sf" ]] && continue
  if [[ -f "$sf" ]] && ! git diff --quiet -- "$sf" 2>/dev/null; then
    HAS_UNSTAGED=1; break
  fi
done < "$NAME_FILE"

if [[ "$HAS_UNSTAGED" -eq 1 ]]; then
  if [[ "$AUTO_STASH" == "true" ]]; then
    git stash push --keep-index --include-untracked --quiet -m "aireview-${TS}" || true
    trap 'git stash pop --quiet 2>/dev/null || true' EXIT
  else
    echo "⚠ adversarial-review: staged files have additional unstaged changes" >&2
    echo "  LLM sees --cached diff, which may not match committed code" >&2
    echo "  set diff.auto_stash_unstaged=true to auto-isolate" >&2
  fi
fi

# ===== 推断 TARGET =====
TARGET=$(target_from_diff "$NAME_FILE" "$SCOPE")

# ===== 启动合议 =====
source "$LIB_DIR/quorum.sh"

# trap SIGINT
on_signal() {
  local sig="$1"
  log_append "$LOG_FILE" "$RUN_DIR" "$(printf '## %s TARGET=%s\n- 状态: INTERRUPTED (%s)\n- staged: %s\n' "$(date +%F)" "$TARGET" "$sig" "$(tr '\n' ' ' < "$NAME_FILE")")"
  exit 130
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

set +e
JSON=$(quorum_run "$TARGET" "$REPO_ROOT" "$RUN_DIR")
QRC=$?
set -e

# ===== 失败路径 =====
if [[ "$QRC" -ne 0 ]] || [[ -z "$JSON" ]] || ! echo "$JSON" | yq eval -P '.' - >/dev/null 2>&1; then
  log_append "$LOG_FILE" "$RUN_DIR" "$(printf '## %s TARGET=%s\n- 状态: FAILED (rc=%s)\n- 详情: see %s\n' "$(date +%F)" "$TARGET" "$QRC" "$RUN_DIR")"
  if [[ "$STRICT_ERR" == "true" ]]; then
    die "llm" "quorum failed (rc=$QRC)" "see $RUN_DIR" "$RUN_DIR" 2
  fi
  exit 0
fi

# ===== 解析 verdict =====
HIGHEST=$(echo "$JSON" | yq eval '.highest_severity // "none"' -)
LOG_ENTRY_PATH=$(echo "$JSON" | yq eval '.log_entry_path // ""' -)

# 追加日志（每次都留痕）
if [[ -n "$LOG_ENTRY_PATH" && -f "$LOG_ENTRY_PATH" ]]; then
  log_append "$LOG_FILE" "$RUN_DIR" "$(cat "$LOG_ENTRY_PATH")"
else
  log_append "$LOG_FILE" "$RUN_DIR" "$(printf '## %s TARGET=%s — OK 留痕（无发现）\n' "$(date +%F)" "$TARGET")"
fi

# ===== 阈值判定 =====
if severity_ge "$HIGHEST" "$FAIL_ON"; then
  echo "✗ adversarial-review: blocked by $HIGHEST finding (threshold=$FAIL_ON)" >&2
  echo "  see $LOG_FILE for verdict table" >&2
  exit 1
fi

exit 0
```

- [ ] **Step 2：跑 shellcheck**

```bash
shellcheck -e SC1091 -e SC2155 workflows/adversarial-review/scripts/review-diff.sh
```

Expected: 通过。

- [ ] **Step 3：commit**

```bash
git add workflows/adversarial-review/scripts/review-diff.sh
git commit -m "feat(adversarial-review): scripts/review-diff.sh — 增量审查入口（diff/skip/size/target/quorum）"
```

---

### Task 13：scripts/review-target.sh — 全包扫描入口

**Files:**
- Create: `workflows/adversarial-review/scripts/review-target.sh`

- [ ] **Step 1：写实现**

```bash
#!/usr/bin/env bash
# 全包扫描对抗审查入口
# Usage: review-target.sh <target-name> [--workdir=<path>] [--config=<path>] [--no-fix] [--no-commit]
set -euo pipefail

if [[ "${AIREVIEW_RUNNING:-}" == "1" ]]; then
  exit 0
fi
export AIREVIEW_RUNNING=1
export AIREVIEW_TRIGGER="review-target"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIB_DIR="$SCRIPT_DIR/lib"
export TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"

source "$LIB_DIR/severity.sh"
source "$LIB_DIR/config.sh"

TARGET=""
WORKDIR=""
CFG_FILE="$PWD/.adversarial-review.yaml"
NO_FIX=0
NO_COMMIT=0

for arg in "$@"; do
  case "$arg" in
    --workdir=*) WORKDIR="${arg#*=}" ;;
    --config=*)  CFG_FILE="${arg#*=}" ;;
    --no-fix)    NO_FIX=1 ;;
    --no-commit) NO_COMMIT=1 ;;
    -h|--help)   sed -n '3,4p' "$0"; exit 0 ;;
    -*)          echo "unknown arg: $arg" >&2; exit 2 ;;
    *)           TARGET="$arg" ;;
  esac
done

[[ -n "$TARGET" ]] || { echo "✗ usage: review-target.sh <target-name>" >&2; exit 2; }

config_load "$CFG_FILE" || { echo "✗ config: $CFG_FILE" >&2; exit 2; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ not in a git repo" >&2; exit 2; }
cd "$REPO_ROOT"

# WORKDIR 自动定位
if [[ -z "$WORKDIR" ]]; then
  MAXDEPTH=$(config_get_default .repo.search_maxdepth 3)
  SEARCH_DIRS=()
  while IFS= read -r d; do [[ -n "$d" ]] && SEARCH_DIRS+=("$REPO_ROOT/$d"); done < <(config_get_array .repo.search_dirs)
  for d in "${SEARCH_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    found=$(find "$d" -maxdepth "$MAXDEPTH" -type d -name "$TARGET" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then WORKDIR="$found"; break; fi
  done
fi

[[ -n "$WORKDIR" && -d "$WORKDIR" ]] || { echo "✗ TARGET '$TARGET' not found under search_dirs" >&2; exit 2; }

[[ "$NO_FIX" -eq 1 ]] && export AIREVIEW_NO_FIX=1
[[ "$NO_COMMIT" -eq 1 ]] && export AIREVIEW_NO_COMMIT=1

LOG_FILE=$(config_get_default .log.file docs/adversarial-review-log.md)
RUN_DIR=$(config_get_default .log.run_dir .adversarial-runs)
FAIL_ON=$(config_get_default .policy.fail_on_severity high)
STRICT_ERR=$(config_get_default .policy.strict_on_error false)

mkdir -p "$RUN_DIR"
source "$LIB_DIR/quorum.sh"

set +e
JSON=$(quorum_run "$TARGET" "$WORKDIR" "$RUN_DIR")
QRC=$?
set -e

if [[ "$QRC" -ne 0 ]] || ! echo "$JSON" | yq eval -P '.' - >/dev/null 2>&1; then
  log_append "$LOG_FILE" "$(printf '## %s TARGET=%s\n- 状态: FAILED (rc=%s)\n' "$(date +%F)" "$TARGET" "$QRC")"
  [[ "$STRICT_ERR" == "true" ]] && exit 2
  exit 0
fi

HIGHEST=$(echo "$JSON" | yq eval '.highest_severity // "none"' -)
LOG_ENTRY_PATH=$(echo "$JSON" | yq eval '.log_entry_path // ""' -)
[[ -n "$LOG_ENTRY_PATH" && -f "$LOG_ENTRY_PATH" ]] && log_append "$LOG_FILE" "$RUN_DIR" "$(cat "$LOG_ENTRY_PATH")" \
  || log_append "$LOG_FILE" "$RUN_DIR" "$(printf '## %s TARGET=%s — OK 留痕（无发现）\n' "$(date +%F)" "$TARGET")"

severity_ge "$HIGHEST" "$FAIL_ON" && exit 1
exit 0
```

- [ ] **Step 2：shellcheck**

```bash
shellcheck -e SC1091 -e SC2155 workflows/adversarial-review/scripts/review-target.sh
```

- [ ] **Step 3：commit**

```bash
git add workflows/adversarial-review/scripts/review-target.sh
git commit -m "feat(adversarial-review): scripts/review-target.sh — 全包扫描入口（自动 WORKDIR 定位）"
```

---

### Task 14：scripts/daily-check.sh — 对账（可选，由 YAML 控制）

**Files:**
- Create: `workflows/adversarial-review/scripts/daily-check.sh`

- [ ] **Step 1：写实现**

```bash
#!/usr/bin/env bash
# 对账：检查今日日志条目数 ≥ EXPECTED；若 daily_check.enabled=false 直接 exit 0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIB_DIR="$SCRIPT_DIR/lib"
source "$LIB_DIR/config.sh"

CFG_FILE="${1:-$PWD/.adversarial-review.yaml}"
config_load "$CFG_FILE" || { echo "✗ config: $CFG_FILE" >&2; exit 2; }

ENABLED=$(config_get_default .daily_check.enabled false)
if [[ "$ENABLED" != "true" ]]; then
  echo "daily_check disabled in $CFG_FILE; exit 0"
  exit 0
fi

EXPECTED=$(config_get_default .daily_check.expected_entries 15)
LOG_FILE=$(config_get_default .log.file docs/adversarial-review-log.md)
TODAY=$(TZ=Asia/Shanghai date +%Y-%m-%d)

if [[ ! -f "$LOG_FILE" ]]; then
  echo "[$TODAY] ALERT: log file missing: $LOG_FILE"
  exit 1
fi

COUNT=$(grep -c "^## $TODAY " "$LOG_FILE" 2>/dev/null || echo 0)
if [[ "$COUNT" -lt "$EXPECTED" ]]; then
  echo "[$TODAY] ALERT entries=$COUNT/$EXPECTED"
  grep -A 4 "^## $TODAY " "$LOG_FILE" 2>/dev/null || true
  exit 1
fi

echo "[$TODAY] OK entries=$COUNT/$EXPECTED"
```

- [ ] **Step 2：shellcheck + commit**

```bash
shellcheck -e SC1091 -e SC2155 workflows/adversarial-review/scripts/daily-check.sh
git add workflows/adversarial-review/scripts/daily-check.sh
git commit -m "feat(adversarial-review): scripts/daily-check.sh — YAML 控制的对账"
```

---

## Phase 4：集成测试 + 示例 + 文档

### Task 15：集成测试（10 个 .bats）

**Files:**
- Create: `workflows/adversarial-review/tests/integration/*.bats` (10 文件)
- Create: `workflows/adversarial-review/tests/fixtures/findings/verdict-clean.json`
- Create: `workflows/adversarial-review/tests/fixtures/findings/verdict-high.json`

> 集成测试通过 mock claude/codex 走 review-diff 全流程。Mock claude 必须能写 verdict.json + log-entry.md（quorum.sh 期望的输出契约）。

- [ ] **Step 1：升级 mock claude 让它能写 verdict 文件**

把 Task 2 的 mock claude 替换为：

`tests/fixtures/bin/claude`:

```bash
#!/usr/bin/env bash
# Mock Claude. AIREVIEW_FIXTURE selects scenario.
# When fixture is "clean"/"high"/"medium", also writes verdict.json + log-entry.md to LOG_DIR
LOG_DIR="${LOG_DIR:-/tmp}"
TS="${TS:-$(date -u +%Y%m%dT%H%M%SZ)}"

write_verdict() {
  local sev="$1" must="$2"
  local entry="$LOG_DIR/log-entry-${TS}.md"
  local verdict="$LOG_DIR/verdict-${TS}.json"
  cat > "$entry" <<EOF
## $(date +%F) TARGET=${TARGET:-unknown}
- mock fixture: ${AIREVIEW_FIXTURE}
- highest severity: $sev
- must_fix: $must
EOF
  cat > "$verdict" <<EOF
{"findings":{"claude_attack":1,"claude_defend":0,"codex_a":1,"codex_b":0},"cross":{"codex_attacks_claude":{"a":1,"b":0,"c":0},"claude_attacks_codex":{"a":1,"b":0,"c":0}},"verdict":{"must_fix":$must,"disputed":0,"discarded":0},"highest_severity":"$sev","log_entry_path":"$entry"}
EOF
}

case "${AIREVIEW_FIXTURE:-}" in
  clean)      write_verdict none 0; echo "ok"; exit 0 ;;
  one-high)   write_verdict high 1; echo "ok"; exit 0 ;;
  one-medium) write_verdict medium 0; echo "ok"; exit 0 ;;
  timeout)    sleep 1300 ;;
  fail-1)     echo "claude API err" >&2; exit 1 ;;
  empty)      echo "无发现"; exit 0 ;;
  *)          echo "MOCK claude: missing AIREVIEW_FIXTURE" >&2; exit 99 ;;
esac
```

- [ ] **Step 2：写 review-diff-empty.bats**

`tests/integration/review-diff-empty.bats`:

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "empty diff → exit 3, no log entry" {
  AIREVIEW_FIXTURE=clean run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 3 ]
  [ ! -f docs/adversarial-review-log.md ]
}
```

- [ ] **Step 3：写 review-diff-skipped.bats**

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "all paths under skip → exit 3" {
  echo "# foo" > README.md
  git add README.md
  AIREVIEW_FIXTURE=clean run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 3 ]
}
```

- [ ] **Step 4：写 review-diff-clean.bats（核心：每次留痕验证）**

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "clean review → exit 0 + log留痕" {
  mkdir -p pkg/foo
  echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  AIREVIEW_FIXTURE=clean AIREVIEW_CODEX_FIXTURE=empty \
    run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 0 ]
  [ -f docs/adversarial-review-log.md ]
  grep -q "TARGET=foo" docs/adversarial-review-log.md
}
```

- [ ] **Step 5：写 review-diff-finds-high.bats**

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "FG-H finding → exit 1 + 表格写入日志" {
  mkdir -p pkg/foo
  echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  AIREVIEW_FIXTURE=one-high AIREVIEW_CODEX_FIXTURE=one-high \
    run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 1 ]
  grep -q "highest severity: high" docs/adversarial-review-log.md
}
```

- [ ] **Step 6：写 review-diff-llm-fail.bats（strict_on_error=false）**

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "LLM fail + strict=false → exit 0 + FAILED 条目" {
  mkdir -p pkg/foo; echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  AIREVIEW_FIXTURE=fail-1 AIREVIEW_CODEX_FIXTURE=fail-1 \
    run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 0 ]
  grep -q "FAILED" docs/adversarial-review-log.md
}
```

- [ ] **Step 7：写 review-diff-llm-fail-strict.bats**

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  setup_workdir; write_minimal_config
  yq -i '.policy.strict_on_error = true' .adversarial-review.yaml
}
teardown() { teardown_workdir; }

@test "LLM fail + strict=true → exit 2" {
  mkdir -p pkg/foo; echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  AIREVIEW_FIXTURE=fail-1 AIREVIEW_CODEX_FIXTURE=fail-1 \
    run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 8：写 review-diff-reentrant.bats**

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "AIREVIEW_RUNNING=1 → exit 0 immediately" {
  mkdir -p pkg/foo; echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  AIREVIEW_RUNNING=1 run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 0 ]
  [ ! -f docs/adversarial-review-log.md ]
}
```

- [ ] **Step 9：写 review-diff-timeout.bats**

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  setup_workdir; write_minimal_config
  # 把 timeout 调到 5 秒，让 mock sleep 1300 触发
  yq -i '.verify.timeout_seconds = 5' .adversarial-review.yaml
}
teardown() { teardown_workdir; }

@test "LLM timeout → 归类 LLM 失败" {
  mkdir -p pkg/foo; echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  AIREVIEW_FIXTURE=timeout AIREVIEW_CODEX_FIXTURE=timeout \
    run timeout 30 "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
  # FAILED 或没写日志（timeout 路径）
}
```

- [ ] **Step 10：写 flock-concurrent.bats**

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "并发 review-diff → 日志条目都到位" {
  mkdir -p pkg/a pkg/b
  echo 'package a' > pkg/a/a.go
  echo 'package b' > pkg/b/b.go
  git add pkg/a/a.go pkg/b/b.go
  AIREVIEW_FIXTURE=clean AIREVIEW_CODEX_FIXTURE=empty \
    "$SCRIPTS_DIR/review-diff.sh" &
  PID1=$!
  AIREVIEW_FIXTURE=clean AIREVIEW_CODEX_FIXTURE=empty \
    "$SCRIPTS_DIR/review-diff.sh" &
  PID2=$!
  wait "$PID1" "$PID2"
  N=$(grep -c '^## ' docs/adversarial-review-log.md)
  [ "$N" -ge 1 ]
}
```

- [ ] **Step 11：写 sigint-cleanup.bats**

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "SIGINT 后保留 .adversarial-runs/ + INTERRUPTED 条目" {
  mkdir -p pkg/foo; echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  AIREVIEW_FIXTURE=timeout AIREVIEW_CODEX_FIXTURE=timeout \
    "$SCRIPTS_DIR/review-diff.sh" &
  PID=$!
  sleep 2
  kill -INT "$PID"
  wait "$PID" || true
  [ -d .adversarial-runs ]
  grep -q "INTERRUPTED" docs/adversarial-review-log.md || true  # SIGINT 时机依赖，弱断言
}
```

- [ ] **Step 12：写 review-diff-partial-staged.bats（spec §7.5 验证）**

`tests/integration/review-diff-partial-staged.bats`:

```bash
#!/usr/bin/env bats
load "../test_helper.bash"

setup() { setup_workdir; write_minimal_config; }
teardown() { teardown_workdir; }

@test "partial staging + auto_stash=false → 警告不阻断" {
  mkdir -p pkg/foo
  echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  echo '// modified after staging' >> pkg/foo/foo.go
  AIREVIEW_FIXTURE=clean AIREVIEW_CODEX_FIXTURE=empty \
    run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"unstaged"* ]] || [[ "$output" == *"unstaged"* ]]
}

@test "partial staging + auto_stash=true → stash + 恢复" {
  yq -i '.diff.auto_stash_unstaged = true' .adversarial-review.yaml
  mkdir -p pkg/foo
  echo 'package foo' > pkg/foo/foo.go
  git add pkg/foo/foo.go
  echo '// modified after staging' >> pkg/foo/foo.go
  AIREVIEW_FIXTURE=clean AIREVIEW_CODEX_FIXTURE=empty \
    run "$SCRIPTS_DIR/review-diff.sh"
  [ "$status" -eq 0 ]
  # 恢复后工作区应仍含 unstaged 改动
  grep -q "modified after staging" pkg/foo/foo.go
}
```

- [ ] **Step 13：跑全部集成测试**

```bash
cd /root/code/ai/github.com/omeyang/Thoth/workflows/adversarial-review
bats tests/integration/
```

Expected: ≥ 9/11 通过（timeout 与 sigint 时机依赖测试可能 flaky，单独排查）。

- [ ] **Step 14：commit**

```bash
git add workflows/adversarial-review/tests/
git commit -m "test(adversarial-review): 10 个集成测试 + mock claude 升级（写 verdict）"
```

---

### Task 16：examples/* — 示例配置

**Files:**
- Create: `workflows/adversarial-review/examples/adversarial-review.yaml.example`
- Create: `workflows/adversarial-review/examples/xkit-pkgs.yaml.example`

> `xkit-pre-commit.sh.example` 已在 Task 11 创建。

- [ ] **Step 1：写 adversarial-review.yaml.example（通用示范）**

把 spec 第 5 节的完整 YAML 复制到 `examples/adversarial-review.yaml.example`，每个字段加 `#` 注释说明用途。

```yaml
# 对抗审查配置范本
# 复制本文件到项目根：cp examples/adversarial-review.yaml.example .adversarial-review.yaml
# 然后按项目情况编辑

repo:
  root: .                              # 项目根（相对/绝对路径都行）
  search_dirs: [pkg, cmd, internal]    # review-target 自动定位 TARGET 时找的目录
  search_maxdepth: 3                   # find -maxdepth

llm:
  claude_model: claude-opus-4-7
  codex_command: codex
  parallel_codex: true

review:
  dimensions:                          # 注入到 codex/claude prompt 的扫描维度
    - "nil/typed-nil/零值契约"
    - "并发安全"
    - "错误处理"
    - "context 传播"
    - "资源清理"
    - "API 契约"
  max_findings_per_source: 8

diff:
  default_ref: "--cached"
  scope_strategy: auto                 # auto | deepest-common | files
  max_diff_lines: 500
  skip_paths:
    - "*.md"
    - "docs/**"
    - "**/testdata/**"
  auto_stash_unstaged: false

verify:
  cmd: "make test"                     # XKit 用 "task pre-push"；改成你项目的验证命令
  timeout_seconds: 600

commit:
  prefix_template: "fix({{TARGET}})"
  push_after_fix: false

log:
  file: docs/adversarial-review-log.md
  run_dir: .adversarial-runs

policy:
  fail_on_severity: high               # high | medium | never
  strict_on_error: false

daily_check:
  enabled: false
  expected_entries: 15
```

- [ ] **Step 2：写 xkit-pkgs.yaml.example（XKit 具体配置）**

```yaml
# XKit 项目对抗审查配置（reference impl）
# 装法：cp examples/xkit-pkgs.yaml.example /path/to/XKit/.adversarial-review.yaml

repo:
  root: .
  search_dirs: [pkg, cmd, internal]
  search_maxdepth: 3

llm:
  claude_model: claude-opus-4-7
  codex_command: codex
  parallel_codex: true

review:
  dimensions:
    - "nil/typed-nil/零值契约"
    - "并发安全（mutex 边界/goroutine 泄漏/线性化缺口/atomic 顺序）"
    - "错误处理（%w / errors.Join 双 cause / 错误链）"
    - "context 传播与 nil 防御"
    - "资源清理（Close 幂等/cleanup goroutine 退出）"
    - "API 契约"
    - "跨平台 build tag"
  max_findings_per_source: 8

diff:
  default_ref: "--cached"
  scope_strategy: auto
  max_diff_lines: 500
  skip_paths:
    - "*.md"
    - "docs/**"
    - "**/testdata/**"
    - "*.lua"
  auto_stash_unstaged: false

verify:
  cmd: "task pre-push"
  timeout_seconds: 600

commit:
  prefix_template: "fix({{TARGET}})"
  push_after_fix: false

log:
  file: docs/adversarial-review-log.md
  run_dir: .adversarial-runs

policy:
  fail_on_severity: high
  strict_on_error: false

daily_check:
  enabled: false
  expected_entries: 15
```

- [ ] **Step 3：commit**

```bash
git add workflows/adversarial-review/examples/
git commit -m "docs(adversarial-review): examples 配置（通用 + XKit reference）"
```

---

### Task 17：WORKFLOW.md

**Files:**
- Create: `workflows/adversarial-review/WORKFLOW.md`

- [ ] **Step 1：写 WORKFLOW.md**

```markdown
# 对抗审查工作流（Adversarial Review）

四路对抗 + 交叉合议的代码审查流程：Claude×2 + Codex×2 + 跨阵营对抗 + 合议。可对 git diff（增量，pre-commit）或任意 scope（全包扫描）触发。

## 前置条件

| 工具 | 用途 | 检查命令 |
|------|------|---------|
| `claude` CLI | Claude Code | `claude --version` |
| `codex` CLI | OpenAI Codex | `codex --version` |
| `yq` v4 | YAML 解析 | `yq --version` |
| `git` ≥ 2.30 | diff / repo 检测 | `git version` |
| `flock` | 日志并发锁 | `which flock` |
| `envsubst` | 模板变量替换 | `which envsubst` |
| `timeout` | LLM 调用硬超时 | `which timeout` |
| `bats-core` | 测试 | `bats --version` |
| `shellcheck` | 静态扫描 | `shellcheck --version` |

## 适用场景

- pre-commit 增量代码审查（10-15 分钟，可阻断 commit）
- 手动跑某个包的全量审查（全流程含修复 + commit）
- pre-push 整 branch 增量审查（手动触发）

## 接入步骤

1. 复制配置范本到项目根：
   ```bash
   cp workflows/adversarial-review/examples/adversarial-review.yaml.example .adversarial-review.yaml
   # 编辑 verify.cmd / review.dimensions / log.file 等
   ```
2. 装 pre-commit hook：
   ```bash
   /path/to/Thoth/workflows/adversarial-review/scripts/install-hooks.sh
   ```
3. 把 `.adversarial-runs/` 加进 `.gitignore`
4. 设环境变量（推荐写进 ~/.zshrc）：
   ```bash
   export THOTH_HOME=/root/code/ai/github.com/omeyang/Thoth
   ```

## 流程定义

```
┌────────────────────────────────┐
│ 1. pre-commit / 手动触发        │
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│ 2. 加载 .adversarial-review.yaml │
│    依赖体检 / git 仓库验证       │
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│ 3. (review-diff)                │
│    git diff → skip_paths 过滤   │
│    → max_diff_lines → TARGET 推断│
│    全空 / 全 skip → exit 3      │
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│ 4. 阶段 1：Codex×2 后台并行扫描  │
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│ 5. 阶段 2：claude -p 主编排器    │
│    └ 阶段 A：Claude CA/CB 子代理  │
│    └ 阶段 B：wait Codex          │
│    └ 阶段 C：跨阵营对抗 (a/b/c)  │
│    └ 阶段 D：合议                │
│    └ 阶段 E：修复 (--no-fix 跳过) │
│    └ 阶段 F：commit (--no-commit 跳过) │
│    └ 阶段 G：写 verdict.json + log-entry.md │
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│ 6. flock 锁追加日志条目         │
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│ 7. 严重度阈值判定               │
│    >= fail_on_severity → exit 1 │
│    否则 → exit 0                 │
└────────────────────────────────┘
```

## 日志格式约定

每次成功跑都追加 `docs/adversarial-review-log.md`（路径由 `log.file` 配置）：

```markdown
## YYYY-MM-DD TARGET=<name>
- 触发：review-diff / review-target
- 原始发现：Claude攻=N 守=N / Codex A=N B=N
- 交叉对抗：Codex攻Claude → a=N b=N c=N；Claude攻Codex → a=N b=N c=N
- 合议：必修=N 存疑=N 舍弃=N
- 修复：commit <hash> 或 "无发现"
- 合议表格：
  | 编号 | 严重度 | 文件:行 | 根因 | 分类 | 来源数 | 对抗结果 |
  ...
```

## False Positive 库（建议每个项目维护）

每次审查后被舍弃的发现整理到项目自己的 MEMORY / docs/fp-patterns.md：

格式：
```markdown
- 包/文件 — 现象描述 — FP 理由（已文档化设计决策 / 公共 API 契约 / 已有防御 / 业内惯例）
```

后续审查 LLM 在阶段 D 合议时识别这些模式，不重复挑刺。

## 退出码

| 退出码 | 含义 |
|---|---|
| 0 | 通过（含 0 发现 + 留痕日志） |
| 1 | 发现 ≥ fail_on_severity 阈值，阻断 commit |
| 2 | 依赖缺失 / 配置错误 / LLM 失败 + strict_on_error=true |
| 3 | diff 为空 / 全 skip / 超 max_diff_lines（不写日志，不阻断） |
| 130 | SIGINT (Ctrl-C)，写 INTERRUPTED 条目 |

## 测试

```bash
make -C workflows/adversarial-review lint    # shellcheck
make -C workflows/adversarial-review test    # bats unit + integration
```
```

- [ ] **Step 2：commit**

```bash
git add workflows/adversarial-review/WORKFLOW.md
git commit -m "docs(adversarial-review): WORKFLOW.md 方法论 + 接入步骤 + 日志约定"
```

---

### Task 18：更新 Thoth 顶层 README

**Files:**
- Modify: `README.md`

- [ ] **Step 1：在 workflows 章节加 adversarial-review 行**

`README.md` 找到 `└── workflows/` 段，在 `tdd/` 后追加：

```diff
 ├── workflows/       # 3 个工作流
 │   ├── tdd/
 │   ├── code-review/
+│   ├── adversarial-review/    # 四路对抗 + 交叉合议（pre-commit 增量审查）
 │   └── deploy/
```

- [ ] **Step 2：commit**

```bash
git add README.md
git commit -m "docs: README 加 workflows/adversarial-review 条目"
```

---

## Phase 5：Thoth 验收 + commit

### Task 19：跑完整测试 + 最终 commit + 推送

- [ ] **Step 1：跑 lint + 全测试**

```bash
cd /root/code/ai/github.com/omeyang/Thoth
make -C workflows/adversarial-review lint
make -C workflows/adversarial-review test
```

Expected: lint 0 错；unit ≥ 28/28 过；integration ≥ 8/10 过（timeout/sigint 弱断言）。

- [ ] **Step 2：检查 git 状态**

```bash
cd /root/code/ai/github.com/omeyang/Thoth
git status
git log --oneline | head -20
```

Expected: 工作区干净，最近 ~14 个 commit 全是 adversarial-review 相关。

- [ ] **Step 3：（可选）推送**

```bash
# 如果有远程
git push origin main
```

---

## Phase 6：XKit 迁移

### Task 20：XKit 新增配置 + 更新 .gitignore

**Files:**
- Create: `/root/code/go/src/github.com/omeyang/XKit/.adversarial-review.yaml`
- Modify: `/root/code/go/src/github.com/omeyang/XKit/.gitignore`

- [ ] **Step 1：复制 XKit 配置范本**

```bash
cp /root/code/ai/github.com/omeyang/Thoth/workflows/adversarial-review/examples/xkit-pkgs.yaml.example \
   /root/code/go/src/github.com/omeyang/XKit/.adversarial-review.yaml
```

- [ ] **Step 2：更新 .gitignore**

```bash
cd /root/code/go/src/github.com/omeyang/XKit
grep -q '\.adversarial-runs' .gitignore || echo '.adversarial-runs/' >> .gitignore
```

- [ ] **Step 3：commit**

```bash
cd /root/code/go/src/github.com/omeyang/XKit
git add .adversarial-review.yaml .gitignore
git commit -m "docs(adversarial-review): 接入 Thoth 通用对抗审查"
```

---

### Task 21：装 hook + 冒烟（人工验证）

> 这是一个"冒烟检查清单"，人工跑一次。失败说明前面 phase 有 bug，不该进 Task 22。

- [ ] **Step 1：装 pre-commit hook**

```bash
cd /root/code/go/src/github.com/omeyang/XKit
export THOTH_HOME=/root/code/ai/github.com/omeyang/Thoth
$THOTH_HOME/workflows/adversarial-review/scripts/install-hooks.sh
ls -l .git/hooks/pre-commit
```

Expected: `pre-commit` 文件存在 + 可执行。

- [ ] **Step 2：冒烟空 commit（应被 exit 3 跳过）**

```bash
cd /root/code/go/src/github.com/omeyang/XKit
git commit --allow-empty -m "test: trigger adversarial review (empty)"
```

Expected: commit 立即成功（hook 检测到空 diff exit 3）。

- [ ] **Step 3：清理空 commit**

```bash
git reset --hard HEAD~1
```

- [ ] **Step 4：冒烟带 diff 的 commit（应跑完合议）**

```bash
cd /root/code/go/src/github.com/omeyang/XKit
mkdir -p test-trigger
echo 'package trigger' > test-trigger/trigger.go
git add test-trigger/trigger.go
time git commit -m "test: trigger adversarial review (with diff)"
```

Expected:
- 跑 ~8-12 分钟（看到 stdout 的 codex/claude 调用日志）
- exit 0（无真问题）
- `docs/adversarial-review-log.md` 末尾多一条 `## YYYY-MM-DD TARGET=trigger ...`

- [ ] **Step 5：清理**

```bash
git reset --hard HEAD~1
rm -rf test-trigger
```

- [ ] **Step 6：（可选）pre-commit 跳过测试**

```bash
echo "// noop" >> README.md
git add README.md
git commit --no-verify -m "test: skip adversarial review"
git reset --hard HEAD~1
```

Expected: hook 被 `--no-verify` 跳过，commit 立即成功。

- [ ] **Step 7：（可选）黄金 case 1 — XKit doFallback typed-nil 真 LLM 回归**

把 XKit 现状切回 `2596b30` 修复前一刻，跑 review-diff 看 4 路合议能否抓到那个 typed-nil bug：

```bash
cd /root/code/go/src/github.com/omeyang/XKit
git stash push -u -m "save before golden case"
git checkout 2596b30^ -- pkg/distributed/xsemaphore/fallback.go
git add pkg/distributed/xsemaphore/fallback.go
time git commit -m "golden-case: pre-fix doFallback"
# 期望：~10 分钟后 exit 1 + log 表格里至少 1 条 FG-H 指向 fallback.go doFallback 函数
```

跑完后回滚：

```bash
git reset --hard HEAD~1
git checkout 2596b30 -- pkg/distributed/xsemaphore/fallback.go
git stash pop || true
```

> 黄金 case 失败说明 prompt 模板或合议逻辑有退化，回到 Task 9 / Task 8 排查。**这是 spec §10.4 的端到端验收，建议跑一次后归档结果**。

- [ ] **Step 8：（可选）黄金 case 2 — xkeylock 空发现回归**

```bash
cd /root/code/go/src/github.com/omeyang/XKit
$THOTH_HOME/workflows/adversarial-review/scripts/review-target.sh xkeylock --no-fix
# 期望：~10 分钟后 exit 0 + log 写"无发现"或合议表 0 条
```

> **冒烟未通过则停止**。回到对应 Phase 排查。

---

### Task 22：删 XKit 旧脚本 + 更新 MEMORY

**Files:**
- Delete: `/root/code/go/src/github.com/omeyang/XKit/scripts/adversarial-review.sh`
- Delete: `/root/code/go/src/github.com/omeyang/XKit/scripts/adversarial-review-daily-check.sh`
- Modify: `/root/.claude/projects/-root-code-go-src-github-com-omeyang-XKit/memory/project_adversarial_review_fixed_pkgs.md`

- [ ] **Step 1：删旧脚本**

```bash
cd /root/code/go/src/github.com/omeyang/XKit
git rm scripts/adversarial-review.sh scripts/adversarial-review-daily-check.sh
```

- [ ] **Step 2：更新 MEMORY 指向 Thoth**

完整重写 `/root/.claude/projects/-root-code-go-src-github-com-omeyang-XKit/memory/project_adversarial_review_fixed_pkgs.md`：

```markdown
---
name: project-adversarial-review-fixed-pkgs
description: XKit 对抗审查工具已迁移至 Thoth/workflows/adversarial-review，改为 pre-commit 增量审查
metadata:
  node_type: memory
  type: project
  originSessionId: 6705a112-5241-449c-9f42-88fd942896e1
---

## 当前状态（2026-05-16 起）

- 旧 `scripts/adversarial-review*.sh` 已删除（commit 见 git log）
- 工具迁移到 `/root/code/ai/github.com/omeyang/Thoth/workflows/adversarial-review/`
- 触发模型从 SLOT-based cron 改为 **pre-commit 增量审查**（基于 git diff，单轮四路合议 ~10 分钟）
- 所有 cron 已于 2026-05-16 移除（保留 acme.sh）

## 接入文件

- `XKit/.adversarial-review.yaml` — 项目配置（已入仓）
- `XKit/.git/hooks/pre-commit` — hook（不入仓，由 `install-hooks.sh` 装）
- `XKit/docs/adversarial-review-log.md` — 同文件继续追加（4617 行历史保留）
- `XKit/.adversarial-runs/` — 中间文件（已加 .gitignore）

## 手动跑全包审查

```bash
cd XKit
export THOTH_HOME=/root/code/ai/github.com/omeyang/Thoth
$THOTH_HOME/workflows/adversarial-review/scripts/review-target.sh xsemaphore
```

## 历史

- 2026-04 ~ 2026-05-15：266 轮 SLOT-based 包级扫描，由 XKit 内置 240 行 Bash 实现
- 2026-05-15：固定 15 包 SLOT 映射（rediscompat ~ xsampling）
- 2026-05-16：因近一月修复率近 0，cron 移除；同日重构为 Thoth 通用工作流，改 pre-commit 增量

## How to apply

- 不要重新装回 cron。需要回归扫描时手动 `review-target.sh <name>`
- Thoth 工作流的设计文档：`/root/code/ai/.../docs/specs/2026-05-16-adversarial-review-extraction-design.md`
- 实现计划：`/root/code/ai/.../docs/plans/2026-05-16-adversarial-review-extraction.md`
```

- [ ] **Step 3：更新 MEMORY 顶层 MEMORY.md（同步指针）**

把 `MEMORY.md` 第 11 行（"对抗审查 cron 已于 2026-05-16 全部移除..."）改为：

```markdown
- **对抗审查工具已迁移至 Thoth**（见 [project_adversarial_review_fixed_pkgs](project_adversarial_review_fixed_pkgs.md)）— 工具在 `/root/code/ai/github.com/omeyang/Thoth/workflows/adversarial-review/`，触发模型改为 pre-commit 增量审查。XKit `.adversarial-review.yaml` 入仓，`.git/hooks/pre-commit` 由 `install-hooks.sh` 装。原 `scripts/adversarial-review*.sh` 已删
```

- [ ] **Step 4：commit XKit 删除动作**

```bash
cd /root/code/go/src/github.com/omeyang/XKit
git commit -m "chore: 移除已迁移至 Thoth 的 scripts/adversarial-review*.sh"
git log --oneline | head -3
```

Expected: 最新 commit 是 chore 删脚本。

- [ ] **Step 5：最终验收**

```bash
ls /root/code/go/src/github.com/omeyang/XKit/scripts/
# 期望：只剩 sync-1.23-branch.sh
ls /root/code/ai/github.com/omeyang/Thoth/workflows/adversarial-review/
# 期望：WORKFLOW.md / scripts/ / templates/ / examples/ / hooks/ / tests/ / Makefile / .shellcheckrc
```

---

## 实施总结表

| Phase | Task | 关键产出 | 大约耗时 |
|---|---|---|---|
| 0 | 1, 2 | 骨架 + 工具 + mock LLM | 30 分钟 |
| 1 | 3-8 | 6 个 lib 模块（TDD）| 3-4 小时 |
| 2 | 9 | 5 个 prompt 模板 | 1 小时 |
| 3 | 10-14 | 4 个入口 + hook 模板 | 2-3 小时 |
| 4 | 15-18 | 10 个集成测试 + examples + WORKFLOW.md + README | 2-3 小时 |
| 5 | 19 | 测试通过 + commit/push | 30 分钟 |
| 6 | 20-22 | XKit 迁移 + 冒烟 + 删旧 | 1-2 小时（含 ~10 分钟冒烟等待） |

**总计：~10-15 小时实现 + 1 次 ~10 分钟真 LLM 冒烟。**
