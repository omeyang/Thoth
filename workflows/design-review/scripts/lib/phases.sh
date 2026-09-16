#!/usr/bin/env bash
# design-review 5 阶段函数（A 球队并行 / B 跨队对抗 / C 合议 / D 收敛判定）
# 不要直接执行；由其他脚本 source
# 依赖：agent.sh / vote.sh / converge.sh / finding.sh / failure.sh / state.sh

[ -n "${_DR_PHASES_LOADED:-}" ] && return 0
_DR_PHASES_LOADED=1

# _team_tool <team> — 从 CFG_TEAMS 取工具
_team_tool() {
    echo "${CFG_TEAMS[$1]:-claude}"
}

# _role_template <role> — 角色 → 角色 prompt 模板文件名（不含目录）
# 未知角色返回非零。模板与角色的固定映射（WORKFLOW.md §4.2）。
_role_template() {
    case "$1" in
        R1) echo "agent-legacy-archeologist.md" ;;
        R2) echo "agent-business-pessimist.md" ;;
        R3) echo "agent-closure-judge.md" ;;
        R4) echo "agent-impl-risk.md" ;;
        R5) echo "agent-control-audit.md" ;;
        *)  return 1 ;;
    esac
}

# _resolve_agent_template <role> <default-filename> <templates-dir>
# 优先级：yaml roles.Rn.template（CFG_ROLE_TEMPLATES）> profile 同名覆盖 > templates/ 默认
_resolve_agent_template() {
    local role="$1" name="$2" tdir="$3"
    local configured="${CFG_ROLE_TEMPLATES[$role]:-}"
    if [ -n "$configured" ] && declare -F resolve_role_template_path >/dev/null; then
        resolve_role_template_path "$configured"
        return 0
    fi
    if declare -F resolve_template >/dev/null; then
        DR_TEMPLATES_DIR="$tdir" resolve_template "$name"
        return 0
    fi
    printf '%s\n' "$tdir/$name"
}

# _enabled_roles — 本次启用的角色集合（空格分隔）
# DR_ENABLED_ROLES（来自 --enable-roles）非空则用之，否则默认 R1-R5 全 5 角色。
_enabled_roles() {
    if [ -n "${DR_ENABLED_ROLES[*]:-}" ]; then
        echo "${DR_ENABLED_ROLES[*]}"
    else
        echo "R1 R2 R3 R4 R5"
    fi
}

# merge_role_reports <out> <team> <stance> <round> <role-file...>
# 队内合议：把同一队多个角色（R1-R5）的输出合并成一份 teamreport。
# - 顶层 team/stance/round 用传入参数（不信任各角色文件里的自报值）
# - findings 取各角色 findings 的并集，按 canonical_text 去重（保留首次出现）
# - 跳过非法 yaml / 缺 findings 序列的角色文件（该角色视为缺席）
# - 至少 1 个合法角色文件 → 产出合法报告（即便 0 findings）+ exit 0
# - 0 个合法角色文件 → 不产出合法报告 + 返回 1（供 count_absent 判该队缺席）
merge_role_reports() {
    [ $# -ge 5 ] || { echo "merge_role_reports: 需 ≥5 参数" >&2; return 2; }
    local out="$1" team="$2" stance="$3" round="$4"
    shift 4

    local valid=0
    declare -A _seen=()
    local body
    body="$(mktemp)"
    printf 'findings: []\n' > "$body"

    local f n i
    for f in "$@"; do
        [ -f "$f" ] || continue
        yq eval '.' "$f" >/dev/null 2>&1 || continue                      # 非法 yaml → 跳过
        yq eval '.findings | tag' "$f" 2>/dev/null | grep -q '!!seq' || continue  # findings 非序列 → 跳过
        valid=$((valid + 1))
        n="$(yq eval '.findings | length' "$f" 2>/dev/null)"
        [ -n "$n" ] && [ "$n" != "null" ] && [ "$n" -gt 0 ] 2>/dev/null || continue
        i=0
        while [ "$i" -lt "$n" ]; do
            local key
            # 去重键：canonical_text 优先；缺则退 id；再缺则退整条紧凑 json
            key="$(yq eval ".findings[$i].canonical_text // \"\"" "$f" 2>/dev/null)"
            [ -n "$key" ] || key="$(yq eval ".findings[$i].id // \"\"" "$f" 2>/dev/null)"
            [ -n "$key" ] || key="$(yq eval -o=json -I=0 ".findings[$i]" "$f" 2>/dev/null)"
            if [ -n "$key" ] && [ -n "${_seen[$key]:-}" ]; then
                i=$((i + 1)); continue
            fi
            [ -n "$key" ] && _seen["$key"]=1
            DR_MRG_F="$f" DR_MRG_I="$i" yq eval -i \
                '.findings += [load(env(DR_MRG_F)).findings[env(DR_MRG_I)|tonumber]]' "$body" 2>/dev/null || true
            i=$((i + 1))
        done
    done

    if [ "$valid" -eq 0 ]; then
        rm -f "$body"
        return 1
    fi

    {
        echo "team: $team"
        echo "stance: $stance"
        echo "round: $round"
        cat "$body"
    } > "$out"
    rm -f "$body"
    return 0
}

# run_phase_a <round-dir> <stances-file> <target> <run-dir> <round-num>
# 4 队并行调 call_team_agent
run_phase_a() {
    local round_dir="$1"
    local stances_file="$2"
    local target="$3"
    local run_dir="$4"
    local round_num="$5"

    [ -d "$round_dir" ] || mkdir -p "$round_dir"

    local case_name="${DR_PHASE_CASE_OVERRIDE:-smoke}"

    local templates_dir
    if [ -n "${DR_TEMPLATES_DIR:-}" ]; then
        templates_dir="$DR_TEMPLATES_DIR"
    else
        templates_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../templates" && pwd 2>/dev/null || echo "")"
    fi

    # 启用的角色集合（默认 R1-R5）；并发上限（默认 8，防 4 队×5 角色=20 进程一次性压垮）
    local roles
    roles="$(_enabled_roles)"
    local max_parallel="${DR_MAX_PARALLEL:-8}"

    # 队内 self-review：每队 × 每个角色一个 sub-agent（R1-R5），扇出 + 并发封顶
    local running=0
    local t role
    for t in T1 T2 T3 T4; do
        local stance
        stance="$(yq eval ".${t} // \"neutral\"" "$stances_file")"
        local stance_tpl="$templates_dir/stance-${stance}.md"
        local tool
        tool="$(_team_tool "$t")"
        for role in $roles; do
            local role_tpl_name agent_tpl
            role_tpl_name="$(_role_template "$role")" || { warn "run_phase_a: 未知角色 $role，跳过"; continue; }
            agent_tpl="$(_resolve_agent_template "$role" "$role_tpl_name" "$templates_dir")"
            local prompt="$round_dir/prompt-${t}-${role}.txt"
            local out="$round_dir/role-${t}-${role}.yaml"

            (
                if [ -f "$agent_tpl" ] && [ -f "$stance_tpl" ]; then
                    build_prompt_file "$prompt" "$agent_tpl" "$stance_tpl" "$target" "$run_dir" "$round_num" "$t" 2>/dev/null || true
                fi
                local input_file
                if [ -f "$prompt" ]; then input_file="$prompt"; else input_file="$target"; fi
                call_team_agent "$tool" "$t" "$stance" "$round_num" "$case_name" "$input_file" "$out"
                exit $?
            ) &

            running=$((running + 1))
            if [ "$running" -ge "$max_parallel" ]; then
                wait -n 2>/dev/null || true
                running=$((running - 1))
            fi
        done
    done
    wait

    # 队内合议：把每队各角色输出合并成一份 teamreport（去重 + 真实身份）
    for t in T1 T2 T3 T4; do
        local stance
        stance="$(yq eval ".${t} // \"neutral\"" "$stances_file")"
        local rolefiles=()
        for role in $roles; do
            rolefiles+=("$round_dir/role-${t}-${role}.yaml")
        done
        merge_role_reports "$round_dir/teamreport-${t}.yaml" "$t" "$stance" "$round_num" "${rolefiles[@]}" 2>/dev/null || true
    done

    # 缺席统计 — 看 output 文件是否合法
    local absent
    absent="$(count_absent_teams \
        "$round_dir/teamreport-T1.yaml" \
        "$round_dir/teamreport-T2.yaml" \
        "$round_dir/teamreport-T3.yaml" \
        "$round_dir/teamreport-T4.yaml")"

    if ! should_abort_round "$absent"; then
        warn "run_phase_a: $absent 队缺席 → 中止本轮"
        return 2
    fi

    info "run_phase_a: round=$round_num absent=$absent 完成"
    return 0
}

# run_phase_b <round-dir> [round-num] [target] [run-dir]
# 先机器化归并（merge_findings），再真 LLM 跨队对抗（run_cross_attack）补 unknown 票。
# 仅 4 参全给时跑真对抗；少参（旧调用）退回纯机器化，保持向后兼容。
run_phase_b() {
    local round_dir="$1"
    local round_num="${2:-}"
    local target="${3:-}"
    local run_dir="${4:-}"

    merge_findings \
        "$round_dir/teamreport-T1.yaml" \
        "$round_dir/teamreport-T2.yaml" \
        "$round_dir/teamreport-T3.yaml" \
        "$round_dir/teamreport-T4.yaml" \
        "$round_dir/cross-attack.yaml"

    if [ -n "$round_num" ] && [ -n "$target" ] && [ -n "$run_dir" ]; then
        run_cross_attack "$round_dir" "$round_num" "$target" "$run_dir" || true
    fi
}

# _apply_cross_votes <cross-file> <team> <vote-file>
# 把 vote-file 里 {cross_id, vote} 写回 cross-file —— 仅当该队当前票为 unknown
_apply_cross_votes() {
    local cross="$1"
    local team="$2"
    local vote_file="$3"

    [ -f "$vote_file" ] || return 0
    yq eval '.' "$vote_file" >/dev/null 2>&1 || { warn "_apply_cross_votes: $team 投票非合法 yaml，跳过"; return 0; }

    local n
    n="$(yq eval '.votes | length' "$vote_file" 2>/dev/null)"
    [ -z "$n" ] || [ "$n" = "null" ] && return 0

    local i=0
    while [ "$i" -lt "$n" ]; do
        local cid vote cur
        cid="$(yq eval ".votes[$i].cross_id // \"\"" "$vote_file")"
        vote="$(yq eval ".votes[$i].vote // \"\"" "$vote_file")"
        i=$((i + 1))
        [ -n "$cid" ] || continue
        case "$vote" in
            agree|refute|covered|discard) ;;
            *) continue ;;
        esac
        cur="$(yq eval ".cross_findings[] | select(.cross_id == \"$cid\") | .votes.${team} // \"unknown\"" "$cross")"
        [ "$cur" = "unknown" ] || continue
        yq eval -i "(.cross_findings[] | select(.cross_id == \"$cid\") | .votes.${team}) = \"$vote\"" "$cross"
    done
}

# run_cross_attack <round-dir> <round-num> <target> <run-dir>
# 对每队的 unknown 票真调 LLM 投票（agree/refute/covered/discard），写回 cross-attack.yaml
run_cross_attack() {
    local round_dir="$1"
    local round_num="$2"
    local target="$3"
    local run_dir="$4"

    local cross="$round_dir/cross-attack.yaml"
    [ -f "$cross" ] || return 0

    local ncf
    ncf="$(yq eval '.cross_findings | length' "$cross" 2>/dev/null)"
    [ -z "$ncf" ] || [ "$ncf" = "null" ] && return 0
    [ "$ncf" -gt 0 ] || return 0

    local templates_dir
    if [ -n "${DR_TEMPLATES_DIR:-}" ]; then
        templates_dir="$DR_TEMPLATES_DIR"
    else
        templates_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../templates" && pwd 2>/dev/null || echo "")"
    fi
    local xattack_tpl="$templates_dir/cross-attack.md"
    [ -f "$xattack_tpl" ] || { warn "run_cross_attack: 缺 cross-attack.md，退回机器化"; return 0; }

    local case_name="${DR_XATTACK_CASE_OVERRIDE:-${DR_PHASE_CASE_OVERRIDE:-smoke}-xattack}"
    local stances_file="$round_dir/stances.yaml"

    local t
    for t in T1 T2 T3 T4; do
        local pending="$round_dir/xattack-pending-${t}.yaml"
        yq eval "{\"cross_findings\": [.cross_findings[] | select(.votes.${t} == \"unknown\") | {\"cross_id\": .cross_id, \"canonical_text\": .canonical_text, \"severity\": .severity}]}" "$cross" > "$pending"

        local cnt
        cnt="$(yq eval '.cross_findings | length' "$pending" 2>/dev/null)"
        [ -n "$cnt" ] && [ "$cnt" != "null" ] && [ "$cnt" -gt 0 ] || continue

        local prompt="$round_dir/xattack-prompt-${t}.txt"
        build_cross_attack_prompt "$prompt" "$xattack_tpl" "$t" "$round_num" "$pending" "$round_dir" "$target" 2>/dev/null || continue

        local tool stance out
        tool="$(_team_tool "$t")"
        stance="$(yq eval ".${t} // \"neutral\"" "$stances_file" 2>/dev/null)"
        [ -n "$stance" ] && [ "$stance" != "null" ] || stance="neutral"
        out="$round_dir/xattack-vote-${t}.yaml"

        if call_team_agent "$tool" "$t" "$stance" "$round_num" "$case_name" "$prompt" "$out"; then
            _apply_cross_votes "$cross" "$t" "$out"
        else
            warn "run_cross_attack: $t 投票调用失败，票留 unknown"
        fi
    done
}

# run_phase_c <round-dir> [round-num] [target] [run-dir]
# 全参时先跑异质双裁判 + 位置交换（run_dual_judge），分类按双裁判叠加票数（judge_final_classification）；
# 少参（旧调用）退回纯 4-vote 分类，保持向后兼容（单裁判路径）。
run_phase_c() {
    local round_dir="$1"
    local round_num="${2:-}"
    local target="${3:-}"
    local run_dir="${4:-}"
    local cross="$round_dir/cross-attack.yaml"
    local consensus="$round_dir/consensus.yaml"

    [ -f "$cross" ] || { echo "run_phase_c: 缺 cross-attack.yaml" >&2; return 1; }

    local round
    round="$(basename "$round_dir" | tr -d 'R')"

    # 异质双裁判 + 位置交换（仅全参且启用时；run_dual_judge 内部自判开关/条目数）
    local dual="$round_dir/dual-judge.yaml"
    if [ -n "$round_num" ] && [ -n "$target" ] && [ -n "$run_dir" ]; then
        run_dual_judge "$round_dir" "$round_num" "$target" "$run_dir" || true
    fi

    {
        echo "round: $round"
        echo "findings:"
        local n
        n="$(yq eval '.cross_findings | length' "$cross")"
        local i=0
        while [ "$i" -lt "$n" ]; do
            local cid cls text sev
            cid="$(yq eval ".cross_findings[$i].cross_id" "$cross")"
            # 有双裁判结果 → judge_final_classification（reject→舍弃 / 分歧→NEEDS-INFO / uphold→按票数）；
            # 否则纯票数分类。票不齐（含 unknown 弃权）兜底标「存疑」而非丢弃。
            if [ -f "$dual" ]; then
                if ! cls="$(judge_final_classification "$cross" "$dual" "$cid" 2>/dev/null)"; then
                    cls="存疑"
                fi
            elif ! cls="$(classify_cross_finding "$cross" "$cid" 2>/dev/null)"; then
                cls="存疑"
            fi
            text="$(yq eval ".cross_findings[$i].canonical_text" "$cross")"
            sev="$(yq eval ".cross_findings[$i].severity" "$cross")"
            echo "  - cross_id: $cid"
            echo "    classification: $cls"
            echo "    canonical_text: $(_yaml_dq "$text")"
            echo "    severity: $sev"
            echo "    votes:"
            for t in T1 T2 T3 T4; do
                local v
                v="$(yq eval ".cross_findings[$i].votes.${t}" "$cross")"
                echo "      $t: $v"
            done
            i=$((i + 1))
        done
    } > "$consensus"
}

# run_phase_d <curr.yaml> <prev.yaml> <round> <min> <max> <run-dir>
run_phase_d() {
    local curr="$1"
    local prev="$2"
    local round="$3"
    local min="$4"
    local max="$5"
    local run_dir="$6"

    local stuck dispute
    stuck="$(state_get "$run_dir" stuck_count)"
    dispute="$(state_get "$run_dir" dispute_count)"
    [ -z "$stuck" ] && stuck=0
    [ -z "$dispute" ] && dispute=0

    local deltas
    deltas="$(compute_deltas "$prev" "$curr")"

    local counters
    # shellcheck disable=SC2086
    counters="$(update_stuck_dispute_counters "$stuck" "$dispute" $deltas)"
    local new_stuck="${counters%% *}"
    local new_dispute="${counters##* }"

    state_set "$run_dir" stuck_count "$new_stuck"
    state_set "$run_dir" dispute_count "$new_dispute"

    local decision
    # shellcheck disable=SC2086
    decision="$(decide_convergence "$round" "$min" "$max" "$new_stuck" "$new_dispute" $deltas)"
    echo "$decision"
}
