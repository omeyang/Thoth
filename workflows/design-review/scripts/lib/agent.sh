#!/usr/bin/env bash
# design-review LLM 调用封装层
# 不要直接执行；由其他脚本 source
#
# 函数：
#   call_team_agent <tool> <team> <stance> <round> <case> <input> <output>

[ -n "${_DR_AGENT_LOADED:-}" ] && return 0
_DR_AGENT_LOADED=1

# _emit_background_block <target> → 若设了 DR_BG_DOCS，打印「背景文档 + 文档关系」段
# DR_BG_DOCS：每行 "path|role"；跳过与 <target> 相同的背景文档（避免与待审文档重复）
_emit_background_block() {
    local target="${1:-}"
    [ -n "${DR_BG_DOCS:-}" ] || [ -n "${DR_BG_RELATIONS:-}" ] || return 0

    echo "## 背景文档（权威上下文，判断前必读）"
    echo ""
    echo "下列文档已锁定系统闭环 / 状态权威 / 跨模块契约 / 设计准则 / 词表；待审子文档**故意不重复**这些内容。"
    echo "**按需读**：待审文档里的「父锚点」已指明对应章节，优先只读相关 § 而非全文。"
    echo ""
    if [ -n "${DR_BG_DOCS:-}" ]; then
        local _line _p _r
        while IFS= read -r _line; do
            [ -n "$_line" ] || continue
            _p="${_line%%|*}"
            _r="${_line#*|}"
            [ "$_p" = "$target" ] && continue   # 背景即当前待审文档，跳过
            if [ -n "$_r" ] && [ "$_r" != "$_p" ]; then
                echo "- \`$_p\` — $_r"
            else
                echo "- \`$_p\`"
            fi
        done <<< "$DR_BG_DOCS"
        echo ""
    fi
    if [ -n "${DR_BG_RELATIONS:-}" ]; then
        echo "### 文档关系"
        echo ""
        echo "$DR_BG_RELATIONS"
        echo ""
    fi
    echo "判断「缺失 / 越界」前：先确认该点是否已在上述背景文档锁定 / 承接——孤立审单篇易把已锁定内容误报为缺失。"
    echo ""
    echo "---"
    echo ""
}

# _emit_scope_block → 若设了 DR_SCOPE_FOCUS，打印「本次审查范围」段到 stdout（否则什么都不打印）
# 由 build_prompt_file / build_cross_attack_prompt 内嵌调用，约束 agent 只审焦点区域
_emit_scope_block() {
    [ -n "${DR_SCOPE_FOCUS:-}" ] || return 0
    echo "## 本次审查范围"
    echo ""
    echo "- 焦点：${DR_SCOPE_FOCUS}"
    if [ -n "${DR_SCOPE_OUT:-}" ]; then
        echo "- 范围外（尚未设计 / 待补，**不要把这些区域的承接缺口当本设计的必修发现**）："
        local _l
        while IFS= read -r _l; do
            [ -n "$_l" ] && echo "  - $_l"
        done <<< "$DR_SCOPE_OUT"
    fi
    [ -n "${DR_SCOPE_NOTE:-}" ] && echo "- 备注：${DR_SCOPE_NOTE}"
    echo ""
    echo "涉及范围外区域的承接缺口：**不要提**（对应区域还没设计，提了也无法处理）。聚焦「${DR_SCOPE_FOCUS}」自身的闭环、状态权威、与基线系统已验证行为的承接。"
    echo ""
    echo "---"
    echo ""
}

# build_prompt_file <out> <agent_template> <stance_template> <target> <run_dir> <round_num> <team>
# 拼出完整 prompt 文件（身份 + 角色 + 立场 + 引用段 + 历史包 + 输出指令）
# team 必传：注入真实 team/stance/round 身份块，模型据此填 yaml，避免照抄 schema 示例里的 T1
build_prompt_file() {
    [ $# -eq 7 ] || { echo "build_prompt_file: 需 7 参数" >&2; return 1; }
    local out="$1"
    local agent_tpl="$2"
    local stance_tpl="$3"
    local target="$4"
    local run_dir="$5"
    local round_num="$6"
    local team="$7"
    local t  # 防止下方 for t 循环泄漏污染调用方的 $t

    [ -f "$agent_tpl" ] || { echo "build_prompt_file: agent 模板不存在 $agent_tpl" >&2; return 1; }
    [ -f "$stance_tpl" ] || { echo "build_prompt_file: stance 模板不存在 $stance_tpl" >&2; return 1; }
    [ -n "$team" ] || { echo "build_prompt_file: team 不能为空" >&2; return 1; }

    # stance 从模板文件名推导（stance-pro.md → pro）
    local stance
    stance="$(basename "$stance_tpl" .md)"
    stance="${stance#stance-}"

    local templates_dir
    templates_dir="$(dirname "$agent_tpl")"
    local principles="$templates_dir/principles.md"
    local refs="${DR_REFS_MANIFEST:-$templates_dir/refs-manifest.example.yaml}"
    local project_principles=""
    if [ -n "${DR_PROFILE_DIR:-}" ] && [ -f "$DR_PROFILE_DIR/principles.md" ]; then
        project_principles="$DR_PROFILE_DIR/principles.md"
    fi

    {
        # 1. 角色 prompt
        cat "$agent_tpl"
        echo ""
        echo "---"
        echo ""
        # 2. 立场片段
        cat "$stance_tpl"
        echo ""
        echo "---"
        echo ""
        # 3. 引用段
        echo "## 待审文档"
        echo ""
        echo "路径：\`$target\`"
        echo ""
        echo "## 工作原则"
        echo ""
        echo "路径：\`$principles\`"
        echo ""
        if [ -n "$project_principles" ]; then
            echo "## 项目原则（追加，优先级高于通用原则）"
            echo ""
            echo "路径：\`$project_principles\`"
            echo ""
        fi
        echo "## 参考仓库清单"
        echo ""
        echo "路径：\`$refs\`"
        echo ""
        # 4. 历史包（R≥2）
        if [ "$round_num" -gt 1 ]; then
            echo "## 上一轮历史包"
            echo ""
            local prev_dir="$run_dir/R$((round_num - 1))"
            for t in T1 T2 T3 T4; do
                echo "- 上一轮 ${t} teamreport：\`$prev_dir/teamreport-${t}.yaml\`"
            done
            echo "- 上一轮跨队对抗：\`$prev_dir/cross-attack.yaml\`"
            echo "- 上一轮合议：\`$prev_dir/consensus.yaml\`"
            echo ""
        fi
        # 5. 输出指令 + 身份块
        echo "---"
        echo ""
        echo "## 你的身份（输出 yaml 必须用这些值）"
        echo ""
        echo "- team: $team"
        echo "- stance: $stance"
        echo "- round: $round_num"
        echo ""
        echo "---"
        echo ""
        _emit_background_block "$target"
        _emit_scope_block
        echo "## 输出指令"
        echo ""
        echo "按本文上方 \"输出 schema\" 段的 yaml 格式输出到 stdout。"
        echo "**顶层 team / stance / round 必须用「你的身份」段的值，不要照抄 schema 示例里的 T1 / pro / 1。**"
        echo "findings[].source_agent 用你的 team 值；findings[].id 前缀用你的 team（如 ${team}-f1）。"
        echo "stdout 仅 yaml，不写 prose / explanation。"
    } > "$out"
}

# build_cross_attack_prompt <out> <xattack_tpl> <team> <round_num> <pending_file> <round_dir> <target>
# 拼跨队对抗投票 prompt：角色 + 身份 + 待投 cross-findings（pending_file，含 cross_id/canonical_text/severity）
#   + 4 份 teamreport / 待审文档 / refs 路径（供 LLM 读全证据）+ 投票输出 schema
# pending_file：yq 可读的 yaml，结构 { cross_findings: [{cross_id, canonical_text, severity}] }
build_cross_attack_prompt() {
    [ $# -eq 7 ] || { echo "build_cross_attack_prompt: 需 7 参数" >&2; return 1; }
    local out="$1"
    local xattack_tpl="$2"
    local team="$3"
    local round_num="$4"
    local pending_file="$5"
    local round_dir="$6"
    local target="$7"

    [ -f "$xattack_tpl" ] || { echo "build_cross_attack_prompt: 模板不存在 $xattack_tpl" >&2; return 1; }
    [ -f "$pending_file" ] || { echo "build_cross_attack_prompt: 待投文件不存在 $pending_file" >&2; return 1; }
    [ -n "$team" ] || { echo "build_cross_attack_prompt: team 不能为空" >&2; return 1; }

    local templates_dir
    templates_dir="$(dirname "$xattack_tpl")"
    local refs="${DR_REFS_MANIFEST:-$templates_dir/refs-manifest.example.yaml}"
    local t  # 防止下方 for t 循环泄漏污染调用方的 $t

    {
        cat "$xattack_tpl"
        echo ""
        echo "---"
        echo ""
        echo "## 你的身份（输出 yaml 必须用这些值）"
        echo ""
        echo "- team: $team"
        echo "- round: $round_num"
        echo ""
        echo "---"
        echo ""
        _emit_background_block "$target"
        _emit_scope_block
        echo "## 待投票的跨队发现（仅这些，均非本队 $team 提出）"
        echo ""
        echo "逐条对下列 cross_id 表态（agree / refute / covered / discard）："
        echo ""
        echo '```yaml'
        yq eval '.cross_findings[] | "- cross_id: " + .cross_id + "\n  canonical_text: \"" + .canonical_text + "\"\n  severity: " + .severity' "$pending_file"
        echo '```'
        echo ""
        echo "## 全证据来源（按需读取判断）"
        echo ""
        for t in T1 T2 T3 T4; do
            echo "- ${t} teamreport：\`$round_dir/teamreport-${t}.yaml\`"
        done
        echo "- 待审文档：\`$target\`"
        echo "- 参考仓库清单：\`$refs\`"
        echo ""
        echo "---"
        echo ""
        echo "## 输出指令"
        echo ""
        echo "按本文 \"输出 schema\" 段的 yaml 格式输出到 stdout。"
        echo "**team 用「你的身份」段的 $team；votes 仅含上面列出的 cross_id，每条一个 vote。**"
        echo "refute / discard 必须给 reason。stdout 仅 yaml，不写 prose。"
    } > "$out"
}

# _adapters_dir → scripts/adapters（DR_ADAPTERS_DIR 优先）
_adapters_dir() {
    if [ -n "${DR_ADAPTERS_DIR:-}" ]; then
        echo "$DR_ADAPTERS_DIR"
    else
        (cd "$(dirname "${BASH_SOURCE[0]}")/../adapters" && pwd 2>/dev/null || echo "")
    fi
}

# _resolve_bin <tool> → 实际可执行路径
# 优先级：测试 mock（DESIGN_REVIEW_*_BIN）> 真 LLM 适配器（scripts/adapters/*.sh）
# 适配器内部再用 DR_CLAUDE_BIN / DR_CODEX_BIN 找真二进制（默认 claude / codex）
_resolve_bin() {
    local tool="$1"
    local adapters
    adapters="$(_adapters_dir)"
    case "$tool" in
        claude|claude-orchestrator|claude-consolidator)
            echo "${DESIGN_REVIEW_CLAUDE_BIN:-$adapters/claude-agent.sh}"
            ;;
        codex)
            echo "${DESIGN_REVIEW_CODEX_BIN:-$adapters/codex-agent.sh}"
            ;;
        *)
            return 2
            ;;
    esac
}

# call_team_agent <tool> <team> <stance> <round> <case> <input-file> <output-file>
call_team_agent() {
    [ $# -eq 7 ] || { echo "call_team_agent: 需 7 参数" >&2; return 2; }

    local tool="$1"
    local team="$2"
    local stance="$3"
    local round="$4"
    local case_name="$5"
    local input="$6"
    local output="$7"

    local bin
    if ! bin="$(_resolve_bin "$tool")"; then
        echo "call_team_agent: invalid tool $tool" >&2
        return 2
    fi
    if ! command -v "$bin" >/dev/null 2>&1 && [ ! -x "$bin" ]; then
        echo "call_team_agent: tool binary not found: $bin (missing)" >&2
        return 2
    fi

    local timeout_sec="${DR_CALL_TIMEOUT_SEC:-1200}"
    local retry="${DR_CALL_RETRY:-1}"

    local attempt=0
    local rc=0
    while [ "$attempt" -le "$retry" ]; do
        attempt=$((attempt + 1))
        debug "call_team_agent attempt=$attempt tool=$tool team=$team stance=$stance round=$round case=$case_name"

        # 直接捕获 timeout 退出码 — 不能用 `if cmd; then` 否则 $? 是 if 块的
        timeout "${timeout_sec}s" "$bin" \
            --team "$team" --stance "$stance" --round "$round" \
            --case "$case_name" --input "$input" > "$output"
        rc=$?

        if [ "$rc" -eq 0 ]; then
            return 0
        fi

        # 99 = mock 缺 fixture（不重试）
        if [ "$rc" -eq 99 ]; then
            return 99
        fi

        if [ "$attempt" -le "$retry" ]; then
            warn "call_team_agent retry attempt=$attempt rc=$rc"
        fi
    done

    return "$rc"
}
