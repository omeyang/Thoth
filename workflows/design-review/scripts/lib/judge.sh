#!/usr/bin/env bash
# design-review 闭环裁判（closure-judge）—— 异质双裁判 + 位置交换去偏
# 不要直接执行；由其他脚本 source
# 依赖：agent.sh（call_team_agent / build_*）/ vote.sh
#
# 设计动机：
#   单次 closure-judge 裁决易吃 position bias（候选项顺序影响判断）+ 单模型系统性偏差。
#   本模块对同一批待裁 cross-finding：
#     1. 异质双裁判：judge A 走一种工具/模型，judge B 走另一种（退化时同工具不同 model/seed）
#     2. 位置交换：A 看正序、B 看逆序，抵消位置偏置
#     3. 一致性合并：仅当两裁判方向一致才采信；不一致 → NEEDS-INFO（弃权/待人工）
#
# 与 vote.sh 衔接：
#   双裁判只产出「方向裁决」（uphold/reject/needs-info），不替代 4-vote 计票。
#   uphold → 交回 classify_cross_finding 按 yes/no 票算 必修/存疑/舍弃；
#   reject → 直接 舍弃；needs-info / 双裁判分歧 → NEEDS-INFO。
#
# 函数：
#   _judge_enabled                              → 0=开 1=关（DR_DUAL_JUDGE，默认开）
#   _judge_tools                                → "<toolA> <toolB>"（异质；退化同工具）
#   _judge_order_ids <cross-file> <reverse?>    → 按正/逆序输出 cross_id 列表
#   _parse_judge_verdict <judge-out> <cross-id> → uphold/reject/needs-info（stdout）
#   reconcile_judges <vA> <vB>                  → uphold/reject/needs-info（一致才采信）
#   run_dual_judge <round-dir> <round-num> <target> <run-dir>  → 写 dual-judge.yaml
#   judge_final_classification <cross-file> <dual-file> <cross-id> → 终分类（stdout）

[ -n "${_DR_JUDGE_LOADED:-}" ] && return 0
_DR_JUDGE_LOADED=1

# _judge_enabled → 双裁判是否启用（默认开；DR_DUAL_JUDGE=0 关）
_judge_enabled() {
    case "${DR_DUAL_JUDGE:-1}" in
        0|false|no|off) return 1 ;;
        *) return 0 ;;
    esac
}

# _judge_tools → 输出两裁判用的工具 "<toolA> <toolB>"
# 默认异质：A=claude、B=codex（DR_JUDGE_TOOL_A / DR_JUDGE_TOOL_B 可覆盖）。
# 若两者相同（环境只有一种 CLI 的退化方案），靠不同 model/seed 区分（见适配器层）。
_judge_tools() {
    local a="${DR_JUDGE_TOOL_A:-claude}"
    local b="${DR_JUDGE_TOOL_B:-codex}"
    printf '%s %s\n' "$a" "$b"
}

# _judge_order_ids <cross-file> <reverse>
# reverse=1 → 逆序；否则正序。输出每行一个 cross_id。
_judge_order_ids() {
    local cross="$1"
    local reverse="${2:-0}"
    local ids
    ids="$(yq eval '.cross_findings[].cross_id' "$cross" 2>/dev/null)"
    [ -n "$ids" ] || return 0
    if [ "$reverse" = "1" ]; then
        printf '%s\n' "$ids" | tac
    else
        printf '%s\n' "$ids"
    fi
}

# _build_judge_pending <cross-file> <out-pending> <reverse>
# 按指定顺序生成裁判待裁清单（{cross_findings:[{cross_id,canonical_text,severity}]}）。
# 位置交换：reverse=1 时条目逆序写入，让 judge B 看到相反顺序。
_build_judge_pending() {
    local cross="$1"
    local out="$2"
    local reverse="${3:-0}"

    {
        echo "cross_findings:"
        local cid text sev
        while IFS= read -r cid; do
            [ -n "$cid" ] || continue
            text="$(yq eval ".cross_findings[] | select(.cross_id == \"$cid\") | .canonical_text" "$cross" 2>/dev/null)"
            sev="$(yq eval ".cross_findings[] | select(.cross_id == \"$cid\") | .severity" "$cross" 2>/dev/null)"
            echo "  - cross_id: $cid"
            echo "    canonical_text: $(_yaml_dq "$text")"
            echo "    severity: $sev"
        done <<< "$(_judge_order_ids "$cross" "$reverse")"
    } > "$out"
}

# _parse_judge_verdict <judge-out> <cross-id>
# 从裁判输出 yaml 取该 cross_id 的 verdict，规整到 uphold/reject/needs-info。
# 容错：缺字段 / 非法值 → needs-info（不确定即弃权，绝不硬判）。
_parse_judge_verdict() {
    local f="$1"
    local cid="$2"
    [ -f "$f" ] || { echo "needs-info"; return 0; }
    yq eval '.' "$f" >/dev/null 2>&1 || { echo "needs-info"; return 0; }

    local v
    v="$(yq eval ".verdicts[] | select(.cross_id == \"$cid\") | .verdict // \"\"" "$f" 2>/dev/null)"
    case "$v" in
        uphold|reject|needs-info) echo "$v" ;;
        *) echo "needs-info" ;;
    esac
}

# reconcile_judges <verdictA> <verdictB>
# 一致性合并：仅当两裁判方向一致才采信；不一致 → needs-info（不强行多数碾压）。
reconcile_judges() {
    local a="$1"
    local b="$2"
    if [ "$a" = "$b" ]; then
        case "$a" in
            uphold|reject|needs-info) echo "$a"; return 0 ;;
            *) echo "needs-info"; return 0 ;;
        esac
    fi
    echo "needs-info"
}

# run_dual_judge <round-dir> <round-num> <target> <run-dir>
# 对 cross-attack.yaml 的全部 cross-finding 跑异质双裁判 + 位置交换，
# 把每条 reconcile 后的方向裁决写到 dual-judge.yaml：
#   verdicts: [{cross_id, judge_a, judge_b, reconciled}]
# 任一裁判调用失败该条记 needs-info（保守弃权）。返回 0=已产出 / 1=跳过（未启用/无条目/缺模板）。
run_dual_judge() {
    local round_dir="$1"
    local round_num="$2"
    local target="$3"
    local run_dir="$4"   # 与其他 phase 函数签名对齐；当前仅用于 debug 上下文

    _judge_enabled || return 1
    debug "run_dual_judge: run_dir=$run_dir round=$round_num"

    local cross="$round_dir/cross-attack.yaml"
    [ -f "$cross" ] || return 1

    local ncf
    ncf="$(yq eval '.cross_findings | length' "$cross" 2>/dev/null)"
    [ -n "$ncf" ] && [ "$ncf" != "null" ] && [ "$ncf" -gt 0 ] || return 1

    local templates_dir
    if [ -n "${DR_TEMPLATES_DIR:-}" ]; then
        templates_dir="$DR_TEMPLATES_DIR"
    else
        templates_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../templates" && pwd 2>/dev/null || echo "")"
    fi
    local judge_tpl="$templates_dir/agent-closure-judge.md"
    [ -f "$judge_tpl" ] || { warn "run_dual_judge: 缺 agent-closure-judge.md，跳过双裁判"; return 1; }

    local tools toolA toolB
    tools="$(_judge_tools)"
    toolA="${tools%% *}"
    toolB="${tools##* }"

    local case_name="${DR_JUDGE_CASE_OVERRIDE:-${DR_PHASE_CASE_OVERRIDE:-smoke}-judge}"

    # judge A 正序、judge B 逆序（位置交换去偏）
    local pendingA="$round_dir/judge-pending-A.yaml"
    local pendingB="$round_dir/judge-pending-B.yaml"
    _build_judge_pending "$cross" "$pendingA" 0
    _build_judge_pending "$cross" "$pendingB" 1

    local promptA="$round_dir/judge-prompt-A.txt"
    local promptB="$round_dir/judge-prompt-B.txt"
    local outA="$round_dir/judge-out-A.yaml"
    local outB="$round_dir/judge-out-B.yaml"

    # 复用 cross-attack prompt 构造器（同样喂 pending + 全证据），裁判模板含双裁判去偏指令
    build_cross_attack_prompt "$promptA" "$judge_tpl" "JUDGE_A" "$round_num" "$pendingA" "$round_dir" "$target" 2>/dev/null || true
    build_cross_attack_prompt "$promptB" "$judge_tpl" "JUDGE_B" "$round_num" "$pendingB" "$round_dir" "$target" 2>/dev/null || true

    local okA=1 okB=1
    if [ -f "$promptA" ]; then
        call_team_agent "$toolA" "JUDGE_A" "neutral" "$round_num" "$case_name" "$promptA" "$outA" && okA=0
    fi
    if [ -f "$promptB" ]; then
        call_team_agent "$toolB" "JUDGE_B" "neutral" "$round_num" "$case_name" "$promptB" "$outB" && okB=0
    fi

    {
        echo "round: $round_num"
        echo "judge_a_tool: $toolA"
        echo "judge_b_tool: $toolB"
        echo "verdicts:"
        local cid va vb rec
        while IFS= read -r cid; do
            [ -n "$cid" ] || continue
            if [ "$okA" -eq 0 ]; then va="$(_parse_judge_verdict "$outA" "$cid")"; else va="needs-info"; fi
            if [ "$okB" -eq 0 ]; then vb="$(_parse_judge_verdict "$outB" "$cid")"; else vb="needs-info"; fi
            rec="$(reconcile_judges "$va" "$vb")"
            echo "  - cross_id: $cid"
            echo "    judge_a: $va"
            echo "    judge_b: $vb"
            echo "    reconciled: $rec"
        done <<< "$(_judge_order_ids "$cross" 0)"
    } > "$round_dir/dual-judge.yaml"

    [ "$okA" -eq 0 ] || warn "run_dual_judge: judge A ($toolA) 调用失败，相关条目记 needs-info"
    [ "$okB" -eq 0 ] || warn "run_dual_judge: judge B ($toolB) 调用失败，相关条目记 needs-info"
    return 0
}

# judge_final_classification <cross-file> <dual-file> <cross-id>
# 双裁判 reconcile 结果叠加 4-vote 计票，得终分类：
#   reject     → 舍弃（双裁判一致否决，碾过票数）
#   needs-info → NEEDS-INFO（分歧/弃权，待人工，不强判）
#   uphold     → 交回 classify_cross_finding 按票数算 必修/存疑/舍弃
# dual-file 缺该条 / 不存在 → 退回纯票数分类（向后兼容单裁判路径）。
judge_final_classification() {
    local cross="$1"
    local dual="$2"
    local cid="$3"

    local rec=""
    if [ -f "$dual" ]; then
        rec="$(yq eval ".verdicts[] | select(.cross_id == \"$cid\") | .reconciled // \"\"" "$dual" 2>/dev/null)"
    fi

    case "$rec" in
        reject)    echo "舍弃"; return 0 ;;
        needs-info)
            # 裁判分歧 / 弃权：不再无条件埋。团队跨队共识是主分类器——
            # 4-0 / 3-1 强共识(classify→必修) 压过单个保守裁判，直接定必修；
            # 否则（弱共识 / 票不齐）才落 NEEDS-INFO 交人工。
            local team_cls
            if team_cls="$(classify_cross_finding "$cross" "$cid" 2>/dev/null)" && [ "$team_cls" = "必修" ]; then
                echo "必修"
            else
                echo "NEEDS-INFO"
            fi
            return 0
            ;;
        uphold|""|null)
            # uphold 或无双裁判记录 → 按票数分类
            classify_cross_finding "$cross" "$cid"
            return $?
            ;;
        *)
            classify_cross_finding "$cross" "$cid"
            return $?
            ;;
    esac
}
