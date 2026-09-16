#!/usr/bin/env bash
# design-review Final 阶段 3 份产物（supplement / patch / report）
# 不要直接执行；由其他脚本 source

[ -n "${_DR_FINALIZE_LOADED:-}" ] && return 0
_DR_FINALIZE_LOADED=1

# derive_topic <target.md> — 从文件名抽 topic
derive_topic() {
    local f
    f="$(basename "$1" .md)"
    # 去掉 01- 或 02-a- 之类的前缀
    f="$(echo "$f" | sed -E 's/^[0-9]+(-[a-z])?-//')"
    echo "$f"
}

# write_supplement_md <consensus> <target> <decision> <out> <run-dir>
write_supplement_md() {
    local consensus="$1"
    local target="$2"
    local decision="$3"
    local out="$4"
    local run_dir="$5"

    local topic
    topic="$(derive_topic "$target")"
    local round tokens
    round="$(state_get "$run_dir" current_round)"
    tokens="$(state_get "$run_dir" tokens_used_total)"

    local must_count needsinfo_count
    must_count="$(yq eval '[.findings[] | select(.classification == "必修")] | length' "$consensus")"
    needsinfo_count="$(yq eval '[.findings[] | select(.classification == "NEEDS-INFO")] | length' "$consensus")"

    {
        echo "# ${topic} · design-review 补充建议"
        echo ""
        echo "> **状态**：草案（待人合议合入）。"
        echo "> **被审文档**：\`${target}\`"
        echo "> **审查结果**：${decision}"
        echo "> **轮数**：${round}"
        echo "> **必修项**：${must_count} 条"
        echo "> **待核实项**：${needsinfo_count} 条"
        echo "> **token 用量**：${tokens}"
        echo ""
        echo "---"
        echo ""
        echo "## 必修项"
        echo ""

        local n i=0
        n="$(yq eval '.findings | length' "$consensus")"
        local idx=0
        while [ "$i" -lt "$n" ]; do
            local cls
            cls="$(yq eval ".findings[$i].classification" "$consensus")"
            if [ "$cls" = "必修" ]; then
                idx=$((idx + 1))
                local cid text sev
                cid="$(yq eval ".findings[$i].cross_id" "$consensus")"
                text="$(yq eval ".findings[$i].canonical_text" "$consensus")"
                sev="$(yq eval ".findings[$i].severity" "$consensus")"
                echo "### ${idx}. [${sev}] ${text}"
                echo ""
                echo "- cross_id: \`${cid}\`"
                echo "- 4 队投票："
                for t in T1 T2 T3 T4; do
                    local v
                    v="$(yq eval ".findings[$i].votes.${t}" "$consensus")"
                    echo "  - ${t}: ${v}"
                done
                echo ""
            fi
            i=$((i + 1))
        done

        # 待核实项（NEEDS-INFO）：双裁判分歧 / 存疑，不进 patch，但必须让人看到
        if [ "${needsinfo_count:-0}" -gt 0 ]; then
            echo ""
            echo "---"
            echo ""
            echo "## 待核实项（NEEDS-INFO，需人工核实后决定升必修或舍弃）"
            echo ""
            local jn=0 jidx=0
            jn="$(yq eval '.findings | length' "$consensus")"
            while [ "$jn" -gt 0 ] && [ "$jidx" -lt "$jn" ]; do
                local jcls
                jcls="$(yq eval ".findings[$jidx].classification" "$consensus")"
                if [ "$jcls" = "NEEDS-INFO" ]; then
                    local jcid jtext jsev
                    jcid="$(yq eval ".findings[$jidx].cross_id" "$consensus")"
                    jtext="$(yq eval ".findings[$jidx].canonical_text" "$consensus")"
                    jsev="$(yq eval ".findings[$jidx].severity" "$consensus")"
                    echo "- [\`${jcid}\`] [${jsev}] ${jtext}"
                fi
                jidx=$((jidx + 1))
            done
        fi

        echo ""
        echo "---"
        echo ""
        echo "（由 design-review 工具自动生成；最终合入由人合议）"
    } > "$out"
}

# write_review_report <consensus> <decision> <out> <run-dir>
write_review_report() {
    local consensus="$1"
    local decision="$2"
    local out="$3"
    local run_dir="$4"

    local round tokens target
    round="$(state_get "$run_dir" current_round)"
    tokens="$(state_get "$run_dir" tokens_used_total)"
    target="$(state_get "$run_dir" target)"

    local must_count maybe_count discard_count needsinfo_count
    must_count="$(yq eval '[.findings[] | select(.classification == "必修")] | length' "$consensus")"
    maybe_count="$(yq eval '[.findings[] | select(.classification == "存疑")] | length' "$consensus")"
    discard_count="$(yq eval '[.findings[] | select(.classification == "舍弃")] | length' "$consensus")"
    needsinfo_count="$(yq eval '[.findings[] | select(.classification == "NEEDS-INFO")] | length' "$consensus")"

    {
        echo "# design-review 报告"
        echo ""
        echo "- 被审文档：\`${target}\`"
        echo "- 决策：**${decision}**"
        echo "- 跑了 ${round} 轮"
        echo "- token 用量：${tokens}"
        echo ""
        echo "## 合议统计"
        echo ""
        echo "| 分类 | 数量 |"
        echo "|---|---|"
        echo "| 必修 | ${must_count} |"
        echo "| 存疑 | ${maybe_count} |"
        echo "| 舍弃 | ${discard_count} |"
        echo "| 待核实 | ${needsinfo_count} |"
        echo ""
        for cls in 必修 存疑 舍弃 NEEDS-INFO; do
            local cls_label="$cls"
            [ "$cls" = "NEEDS-INFO" ] && cls_label="待核实（NEEDS-INFO，双裁判分歧/存疑，需人工核实后定）"
            echo "## ${cls_label}"
            echo ""
            local n i=0
            n="$(yq eval '.findings | length' "$consensus")"
            while [ "$i" -lt "$n" ]; do
                local c
                c="$(yq eval ".findings[$i].classification" "$consensus")"
                if [ "$c" = "$cls" ]; then
                    local cid text sev
                    cid="$(yq eval ".findings[$i].cross_id" "$consensus")"
                    text="$(yq eval ".findings[$i].canonical_text" "$consensus")"
                    sev="$(yq eval ".findings[$i].severity" "$consensus")"
                    echo "- [\`${cid}\`] [${sev}] ${text}"
                fi
                i=$((i + 1))
            done
            echo ""
        done
    } > "$out"
}

# write_suggested_patch <consensus> <target.md> <out.diff>
write_suggested_patch() {
    local consensus="$1"
    local target="$2"
    local out="$3"

    local must_count
    must_count="$(yq eval '[.findings[] | select(.classification == "必修")] | length' "$consensus")"

    local topic
    topic="$(derive_topic "$target")"

    local target_lines
    target_lines="$(wc -l < "$target")"

    {
        printf '%s\n' "--- ${target}"
        printf '%s\n' "+++ ${target}"
        printf '@@ -%d,0 +%d,4 @@\n' "$target_lines" "$((target_lines + 1))"
        printf '%s\n' "+"
        printf '%s\n' "+## design-review 补充（${must_count} 条必修）"
        printf '%s\n' "+"
        printf '%s\n' "+详见 \`redesign/201-${topic}-supplement.md\`"
    } > "$out"
}

# finalize_run <run-dir> <consensus> <target> <decision> <output-base-dir>
finalize_run() {
    local run_dir="$1"
    local consensus="$2"
    local target="$3"
    local decision="$4"
    local base="$5"

    local sup_dir="${CFG_OUTPUT_SUPPLEMENT_DIR:-redesign}"
    local sup_pattern
    if [ -n "${CFG_OUTPUT_SUPPLEMENT_PATTERN:-}" ]; then
        sup_pattern="$CFG_OUTPUT_SUPPLEMENT_PATTERN"
    else
        # 字面默认值 — bash 的 ${VAR:-default} 默认值含 } 会提前终结
        sup_pattern='201-{topic}-supplement.md'
    fi
    local pr_dir="${CFG_OUTPUT_PATCH_REPORT_DIR:-redesign/.design-runs}"

    local topic
    topic="$(derive_topic "$target")"
    local sup_name
    sup_name="$(printf '%s' "$sup_pattern" | sed "s|{topic}|$topic|g")"

    mkdir -p "$base/$sup_dir" "$base/$pr_dir"

    local sup_path="$base/$sup_dir/$sup_name"
    if [ -e "$sup_path" ]; then
        local seq=2
        while [ -e "$base/$sup_dir/${sup_name%.md}-r${seq}.md" ]; do
            seq=$((seq + 1))
        done
        sup_path="$base/$sup_dir/${sup_name%.md}-r${seq}.md"
    fi

    write_supplement_md "$consensus" "$target" "$decision" "$sup_path" "$run_dir"
    write_suggested_patch "$consensus" "$target" "$base/$pr_dir/suggested-patch.diff"
    write_review_report "$consensus" "$decision" "$base/$pr_dir/review-report.md" "$run_dir"

    # 追加 log entry 到 docs/design-review-log.md（不阻断）
    _finalize_append_log "$run_dir" "$consensus" "$target" "$decision" "$base" \
        "$sup_path" \
        "$base/$pr_dir/suggested-patch.diff" \
        "$base/$pr_dir/review-report.md" || warn "finalize_run: log entry 追加失败（不阻断）"

    info "finalize_run: 产物已落 $sup_path / $base/$pr_dir/"
}

# _finalize_append_log <run_dir> <consensus> <target> <decision> <base> <sup_path> <patch_path> <report_path>
_finalize_append_log() {
    local run_dir="$1"
    local consensus="$2"
    local target="$3"
    local decision="$4"
    local base="$5"
    local sup_path="$6"
    local patch_path="$7"
    local report_path="$8"

    local templates_dir
    if [ -n "${DR_TEMPLATES_DIR:-}" ]; then
        templates_dir="$DR_TEMPLATES_DIR"
    else
        templates_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../templates" && pwd 2>/dev/null || echo "")"
    fi

    local tpl="$templates_dir/log-entry.md"
    [ -f "$tpl" ] || { warn "log-entry.md 模板不存在 $tpl"; return 1; }

    # 抽 ENTRY_START / ENTRY_END 之间内容
    local entry_template
    entry_template="$(awk '/<!-- ENTRY_START -->/{flag=1; next} /<!-- ENTRY_END -->/{flag=0} flag' "$tpl")"
    [ -z "$entry_template" ] && { warn "log-entry.md 抽不到模板段"; return 1; }

    # 准备 envsubst 变量
    export DR_LOG_DATE
    DR_LOG_DATE="$(date -u +'%Y-%m-%d %H:%M:%S')"
    export DR_RUN_ID
    DR_RUN_ID="$(state_get "$run_dir" run_id)"
    export DR_TARGET="$target"
    export DR_DECISION="$decision"
    export DR_TOTAL_ROUNDS
    DR_TOTAL_ROUNDS="$(state_get "$run_dir" current_round)"
    export DR_MIN="${CFG_ROUNDS_MIN:-2}"
    export DR_MAX="${CFG_ROUNDS_MAX:-5}"
    export DR_ENABLED_ROLES
    DR_ENABLED_ROLES="$(state_get "$run_dir" enabled_roles)"
    export DR_TOKENS_USED
    DR_TOKENS_USED="$(state_get "$run_dir" tokens_used_total)"
    export DR_EXIT_CODE="${DR_EXIT_CODE:-0}"

    # 4 队立场（从 final round 的 stances.yaml 读）
    local final_round_dir="$run_dir/R${DR_TOTAL_ROUNDS}"
    local stances_str=""
    if [ -f "$final_round_dir/stances.yaml" ]; then
        for t in T1 T2 T3 T4; do
            local s
            s="$(yq eval ".${t} // \"?\"" "$final_round_dir/stances.yaml")"
            stances_str+=" ${t}=${s}"
        done
    fi
    export DR_STANCES="${stances_str# }"

    # 合议统计
    export DR_MUST_COUNT
    DR_MUST_COUNT="$(yq eval '[.findings[] | select(.classification == "必修")] | length' "$consensus")"
    export DR_MAYBE_COUNT
    DR_MAYBE_COUNT="$(yq eval '[.findings[] | select(.classification == "存疑")] | length' "$consensus")"
    export DR_DISCARD_COUNT
    DR_DISCARD_COUNT="$(yq eval '[.findings[] | select(.classification == "舍弃")] | length' "$consensus")"

    # 严重度分布（必修项内）
    export DR_P0
    DR_P0="$(yq eval '[.findings[] | select(.classification == "必修" and .severity == "P0")] | length' "$consensus")"
    export DR_P1
    DR_P1="$(yq eval '[.findings[] | select(.classification == "必修" and .severity == "P1")] | length' "$consensus")"
    export DR_P2
    DR_P2="$(yq eval '[.findings[] | select(.classification == "必修" and .severity == "P2")] | length' "$consensus")"
    export DR_P3
    DR_P3="$(yq eval '[.findings[] | select(.classification == "必修" and .severity == "P3")] | length' "$consensus")"

    # 产物路径
    export DR_SUPPLEMENT_PATH="$sup_path"
    export DR_PATCH_PATH="$patch_path"
    export DR_REPORT_PATH="$report_path"

    # envsubst 替换 + 追加
    local entry
    entry="$(printf '%s\n' "$entry_template" | envsubst)"

    local log_file="${CFG_LOGGING_FILE:-docs/design-review-log.md}"
    if [[ "$log_file" != /* ]]; then
        log_file="$base/$log_file"
    fi

    log_append "$log_file" "$entry"
}
