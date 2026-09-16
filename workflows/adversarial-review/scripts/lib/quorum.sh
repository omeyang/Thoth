#!/usr/bin/env bash
# 四路合议核心：被入口脚本 source。
# 依赖：lib/severity.sh、lib/config.sh、envsubst、claude、codex、flock、timeout

# 必须先 source 其他 lib（由调用方保证 LIB_DIR 已设）
: "${LIB_DIR:?LIB_DIR not set}"

# render_template <template-name> <output-file>
#   读 templates/<name>.md，envsubst 注入 export 出去的 {{VAR}}
render_template() {
  local tmpl out
  tmpl="${TEMPLATES_DIR:?TEMPLATES_DIR not set}/$1.md"
  out="$2"
  [[ -f "$tmpl" ]] || { echo "template missing: $tmpl" >&2; return 2; }
  # envsubst 不支持 {{VAR}}，用 sed 把 {{VAR}} → ${VAR} 后再 envsubst
  sed -E 's/\{\{([A-Z_][A-Z_0-9]*)\}\}/\${\1}/g' "$tmpl" | envsubst > "$out"
}

# quorum_run <TARGET> <WORKDIR> <LOG_DIR>
#   stdout: one-line JSON (verdict / highest_severity / ...)
quorum_run() {
  (
    local target="$1" workdir="$2" log_dir="$3"
    local ts
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$log_dir"

    export TARGET="$target" WORKDIR="$workdir"
    export DIMENSIONS
    DIMENSIONS=$(config_get_array .review.dimensions | sed 's/^/- /')
    export SEVERITY_DEF="FG-H（可致 panic/数据错乱/死锁/泄漏）、FG-M（契约偏离/错误丢失/竞态边缘）、FG-L（代码异味；忽略）"
    export VERIFY_CMD
    VERIFY_CMD=$(config_get_default .verify.cmd "echo verify-not-set")
    export COMMIT_PREFIX
    COMMIT_PREFIX=$(config_get_default .commit.prefix_template "fix({{TARGET}})")
    export LOG_FILE
    LOG_FILE=$(config_get_default .log.file "docs/adversarial-review-log.md")

    # ===== 阶段 1：Codex 双路后台并行 =====
    local codex_a codex_b codex_cmd codex_timeout prompt_a prompt_b
    codex_a="$log_dir/codex-A-${target}-${ts}.md"
    codex_b="$log_dir/codex-B-${target}-${ts}.md"
    codex_cmd=$(config_get_default .llm.codex_command codex)
    codex_timeout=$(config_get_default .verify.timeout_seconds 600)

    prompt_a="$log_dir/codex-attack-prompt-${ts}.md"
    prompt_b="$log_dir/codex-defend-prompt-${ts}.md"
    render_template codex-attack  "$prompt_a"
    render_template codex-defend  "$prompt_b"

    local prompt_a_content prompt_b_content
    prompt_a_content="$(cat "$prompt_a")"
    prompt_b_content="$(cat "$prompt_b")"

    timeout "$codex_timeout" "$codex_cmd" exec -s danger-full-access --cd "$workdir" \
      "$prompt_a_content" > "$codex_a" 2>&1 &
    local pid_a=$!
    timeout "$codex_timeout" "$codex_cmd" exec -s danger-full-access --cd "$workdir" \
      "$prompt_b_content" > "$codex_b" 2>&1 &
    local pid_b=$!

    # ===== 阶段 2：Claude 主编排 =====
    local claude_model claude_prompt quorum_timeout
    # .llm.claude_model 留空 → 不传 --model，继承 ~/.claude/settings.json 的当前模型。
    # （这里曾经硬编码模型名，Anthropic 一换代就变成指向不存在模型的死配置。）
    claude_model=$(config_get .llm.claude_model || true)
    local claude_model_args=()
    [[ -n "$claude_model" ]] && claude_model_args=(--model "$claude_model")
    claude_prompt="$log_dir/claude-orchestrator-prompt-${ts}.md"
    export CODEX_A_FILE="$codex_a" CODEX_B_FILE="$codex_b"
    export CODEX_A_PID="$pid_a" CODEX_B_PID="$pid_b"
    export LOG_DIR="$log_dir" TS="$ts"
    render_template claude-orchestrator "$claude_prompt"

    quorum_timeout=$(( codex_timeout * 2 ))
    local rc=0
    local claude_prompt_content
    claude_prompt_content="$(cat "$claude_prompt")"
    timeout "$quorum_timeout" claude -p "$claude_prompt_content" \
      --dangerously-skip-permissions ${claude_model_args[@]+"${claude_model_args[@]}"} \
      > "$log_dir/claude-orchestrator-${ts}.log" 2>&1 || rc=$?

    # 确保后台 codex 进程已收尸
    wait "$pid_a" 2>/dev/null || true
    wait "$pid_b" 2>/dev/null || true

    # ===== 阶段 3：解析合议结果 =====
    local verdict_file
    verdict_file="$log_dir/verdict-${ts}.json"
    if [[ -f "$verdict_file" ]]; then
      cat "$verdict_file"
      return 0
    else
      # Claude 未写 verdict → 失败
      printf '{"verdict":{"must_fix":0,"disputed":0,"discarded":0},"highest_severity":"none","error":"claude orchestrator failed (rc=%s)","log_entry_path":""}\n' "$rc"
      return "$rc"
    fi
  )
}

# quorum_apply_fixes <WORKDIR> <LOG_DIR> — 仅 review-target 调用
quorum_apply_fixes() {
  local workdir="$1"
  # 实际修复由 claude-orchestrator 阶段 E 完成；此处仅做后置验证
  local verify
  verify=$(config_get_default .verify.cmd "")
  [[ -z "$verify" ]] && return 0
  ( cd "$workdir" && eval "$verify" )
}

# log_append <log-file> <run-dir-for-late-fallback> <entry-content>  — flock 锁保护
log_append() {
  local file="$1" run_dir="$2"; shift 2
  local content="$*"
  local lock needs_header
  lock="${file}.lock"
  mkdir -p "$(dirname "$file")"
  # 检查文件是否需要 header（在打开重定向前完成，避免 SC2094 read+write 同文件）
  [[ -f "$file" ]] && needs_header=0 || needs_header=1
  {
    if flock -w 30 -x 9; then
      [[ "$needs_header" -eq 1 ]] && printf '# Adversarial Review Log\n'
      printf '\n%s\n' "$content"
      flock -u 9
    else
      # 抢锁超时 → 写到 late-log（run_dir 由调用方显式传入，不依赖环境变量）
      local late
      late="${run_dir:-/tmp}/late-log-$(date -u +%s).md"
      printf '\n%s\n' "$content" > "$late"
      printf 'WARN: log lock contention; wrote to %s\n' "$late" >&2
    fi
  } >> "$file" 9>"$lock"
}

# cleanup_runs <log-dir>  — 删 7 天前的中间文件
cleanup_runs() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -type f -mtime +7 -delete 2>/dev/null || true
}
