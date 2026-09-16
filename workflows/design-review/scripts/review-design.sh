#!/usr/bin/env bash
# design-review 主入口
# M1 阶段：仅实现 CLI 参数 + 配置加载 + --dry-run 打印计划
# M2+ 才接入真正的多轮对抗

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
export DR_TEMPLATES_DIR="$SCRIPT_DIR/../templates"
export DR_ADAPTERS_DIR="$SCRIPT_DIR/adapters"

# shellcheck source=lib/errors.sh
source "$LIB_DIR/errors.sh"
# shellcheck source=lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=lib/args.sh
source "$LIB_DIR/args.sh"
# shellcheck source=lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=lib/profile.sh
source "$LIB_DIR/profile.sh"
# shellcheck source=lib/vote.sh
source "$LIB_DIR/vote.sh"
# shellcheck source=lib/converge.sh
source "$LIB_DIR/converge.sh"
# shellcheck source=lib/stance.sh
source "$LIB_DIR/stance.sh"
# shellcheck source=lib/finding.sh
source "$LIB_DIR/finding.sh"
# shellcheck source=lib/failure.sh
source "$LIB_DIR/failure.sh"
# shellcheck source=lib/state.sh
source "$LIB_DIR/state.sh"
# shellcheck source=lib/agent.sh
source "$LIB_DIR/agent.sh"
# shellcheck source=lib/judge.sh
source "$LIB_DIR/judge.sh"
# shellcheck source=lib/budget.sh
source "$LIB_DIR/budget.sh"
# shellcheck source=lib/phases.sh
source "$LIB_DIR/phases.sh"
# shellcheck source=lib/finalize.sh
source "$LIB_DIR/finalize.sh"
# shellcheck source=lib/orchestrator.sh
source "$LIB_DIR/orchestrator.sh"

main() {
    parse_args "$@"

    export DR_VERBOSE DR_QUIET

    if [ -f "$DR_CONFIG_PATH" ]; then
        load_config "$DR_CONFIG_PATH"
    else
        debug "无配置文件 $DR_CONFIG_PATH；使用全默认 + placeholder ref"
        _config_init_defaults
        CFG_REFS_PATHS=("/tmp/no-refs-configured")
        CFG_REFS_TIERS=("占位")
    fi

    # CLI 值覆盖 yaml（仅当 CLI 显式提供时）
    # shellcheck disable=SC2034
    # CFG_LLM_* 在 M2+ 才被消费，M1 dry-run 不打印
    [ -n "$DR_CLAUDE_MODEL" ] && CFG_LLM_CLAUDE_MODEL="$DR_CLAUDE_MODEL"
    # shellcheck disable=SC2034
    [ -n "$DR_CODEX_CMD" ] && CFG_LLM_CODEX_COMMAND="$DR_CODEX_CMD"
    [ "$DR_MIN_ROUNDS_SET" -eq 1 ] && CFG_ROUNDS_MIN="$DR_MIN_ROUNDS"
    [ "$DR_MAX_ROUNDS_SET" -eq 1 ] && CFG_ROUNDS_MAX="$DR_MAX_ROUNDS"
    # --scope 覆盖 yaml scope.focus
    [ "$DR_SCOPE_FOCUS_SET" -eq 1 ] && CFG_SCOPE_FOCUS="$DR_SCOPE_FOCUS"

    # 项目 profile：CLI --profile > 环境变量 DR_PROFILE > yaml profile；命名了但找不到 = 配置错误
    local profile_ref="${DR_PROFILE_ARG:-${DR_PROFILE:-$CFG_PROFILE}}"
    DR_PROFILE_DIR=""
    if [ -n "$profile_ref" ]; then
        DR_PROFILE_DIR="$(resolve_profile_dir "$profile_ref")" \
            || die "profile 不存在：$profile_ref（查找顺序：\$THOTH_PROFILES/design-review、~/.config/thoth/profiles/design-review、内置 profiles/）" "$EXIT_CONFIG"
    fi
    export DR_PROFILE_DIR

    # 确定 TARGETS
    if [ "${#DR_TARGETS[@]}" -eq 0 ]; then
        if [ -n "$CFG_TARGET_DEFAULT" ]; then
            local matched
            # shellcheck disable=SC2206
            matched=( $CFG_TARGET_DEFAULT )
            if [ -e "${matched[0]:-}" ]; then
                DR_TARGETS=("${matched[@]}")
            else
                die "未指定 TARGET 且 target.default ($CFG_TARGET_DEFAULT) 无匹配" "$EXIT_NO_TARGET"
            fi
        else
            die "未指定 TARGET 且 yaml 无 target.default" "$EXIT_NO_TARGET"
        fi

        # 仅默认 glob 路径生效 exclude；显式 CLI TARGET 不被 exclude 过滤（用户已明示）
        if [ "${#CFG_TARGET_EXCLUDE[@]}" -gt 0 ]; then
            local filtered=() t e keep
            for t in "${DR_TARGETS[@]}"; do
                keep=1
                for e in "${CFG_TARGET_EXCLUDE[@]}"; do
                    # exclude 字符串支持 glob，用 bash extglob 匹配
                    # shellcheck disable=SC2053
                    if [[ "$t" == $e ]]; then
                        keep=0
                        break
                    fi
                done
                [ "$keep" -eq 1 ] && filtered+=("$t")
            done
            DR_TARGETS=("${filtered[@]}")
            [ "${#DR_TARGETS[@]}" -gt 0 ] || die "target.exclude 排除后无剩余 TARGET" "$EXIT_NO_TARGET"
        fi
    fi

    # 校验每个 TARGET
    local t
    for t in "${DR_TARGETS[@]}"; do
        [ -f "$t" ] || die "TARGET 不存在：$t" "$EXIT_NO_TARGET"
        [[ "$t" == *.md ]] || die "TARGET 必须是 .md：$t" "$EXIT_NO_TARGET"
    done

    [ -z "$DR_RUN_ID" ] && DR_RUN_ID="$(log_run_id)"

    if [ "$DR_DRY_RUN" -eq 1 ]; then
        print_dry_run_plan
        exit "$EXIT_OK"
    fi

    # 真跑：初始化 run_dir + state
    local run_dir="$CFG_OUTPUT_TEMP_DIR/$DR_RUN_ID"
    mkdir -p "$run_dir"
    state_init "$run_dir" "$DR_RUN_ID" "${DR_TARGETS[0]}" "$DR_CONFIG_PATH"

    # CFG_LLM_* 透传给 agent.sh + 适配器
    export DR_CALL_TIMEOUT_SEC="$CFG_LLM_CALL_TIMEOUT"
    export DR_CALL_RETRY="$CFG_LLM_CALL_RETRY"
    # DR_CLAUDE_BIN / DR_CODEX_BIN = 真二进制名，适配器内部用之 exec 真 CLI
    export DR_CLAUDE_BIN="$CFG_LLM_CLAUDE_BIN"
    export DR_CODEX_BIN="$CFG_LLM_CODEX_BIN"
    export DR_CLAUDE_MODEL_EFFECTIVE="$CFG_LLM_CLAUDE_MODEL"
    export DR_CODEX_MODEL_EFFECTIVE="${CFG_LLM_CODEX_MODEL:-}"
    # 参考仓库清单：从 yaml refs.manifest 生成到 run 目录，agent prompt 引用它（不再引用示例文件）
    write_refs_manifest "$run_dir/refs-manifest.yaml"
    export DR_REFS_MANIFEST="$run_dir/refs-manifest.yaml"

    # refs / templates / profile 多在被审仓库工作树外，适配器透传给 claude --add-dir
    local _add_dirs="$DR_TEMPLATES_DIR"
    [ -n "$DR_PROFILE_DIR" ] && _add_dirs="$_add_dirs:$DR_PROFILE_DIR"
    local _rp
    for _rp in "${CFG_REFS_PATHS[@]}"; do
        [ -d "$_rp" ] && _add_dirs="$_add_dirs:$_rp"
    done
    export DR_ADD_DIRS="$_add_dirs"

    # 审查范围 → prompt 注入（build_prompt_file / build_cross_attack_prompt 消费）
    export DR_SCOPE_FOCUS="$CFG_SCOPE_FOCUS"
    local _oos="" _o
    for _o in "${CFG_SCOPE_OUT_OF_SCOPE[@]}"; do
        _oos="${_oos:+$_oos$'\n'}$_o"
    done
    export DR_SCOPE_OUT="$_oos"
    export DR_SCOPE_NOTE="$CFG_SCOPE_NOTE"

    # 闭环裁判：异质双裁判 + 位置交换去偏（judge.sh 消费）
    case "$CFG_JUDGE_DUAL" in
        false|no|off|0) export DR_DUAL_JUDGE=0 ;;
        *)              export DR_DUAL_JUDGE=1 ;;
    esac
    export DR_JUDGE_TOOL_A="$CFG_JUDGE_TOOL_A"
    export DR_JUDGE_TOOL_B="$CFG_JUDGE_TOOL_B"

    # 背景文档 → prompt 注入（每行 path|role）+ 文档关系
    local _bg="" _i=0
    while [ "$_i" -lt "${#CFG_BG_PATHS[@]}" ]; do
        _bg="${_bg:+$_bg$'\n'}${CFG_BG_PATHS[$_i]}|${CFG_BG_ROLES[$_i]:-}"
        _i=$((_i + 1))
    done
    export DR_BG_DOCS="$_bg"
    export DR_BG_RELATIONS="$CFG_BG_RELATIONS"

    info "design-review 开始: run_id=$DR_RUN_ID target=${DR_TARGETS[0]} rounds=[$CFG_ROUNDS_MIN, $CFG_ROUNDS_MAX]${CFG_SCOPE_FOCUS:+ scope=$CFG_SCOPE_FOCUS}"

    # M3 阶段：单 TARGET（多 TARGET 留给 M5 扩展）
    run_design_review "$run_dir" "${DR_TARGETS[0]}" "$CFG_ROUNDS_MIN" "$CFG_ROUNDS_MAX"
    local rc=$?

    info "design-review 完成: rc=$rc"
    exit "$rc"
}

# write_refs_manifest <out> — 把 CFG_REFS_PATHS / CFG_REFS_TIERS 写成 refs-manifest.yaml
write_refs_manifest() {
    local out="$1"
    {
        echo "# design-review 参考仓库清单（由 .design-review.yaml 的 refs.manifest 生成）"
        echo "refs:"
        echo "  manifest:"
        local i=0
        while [ "$i" -lt "${#CFG_REFS_PATHS[@]}" ]; do
            printf '    - {path: %s, tier: "%s"}\n' "${CFG_REFS_PATHS[$i]}" "${CFG_REFS_TIERS[$i]}"
            i=$((i + 1))
        done
    } > "$out"
}

print_dry_run_plan() {
    cat <<EOF
=== design-review DRY RUN ===
run_id=$DR_RUN_ID
config=$DR_CONFIG_PATH
profile=${DR_PROFILE_DIR:-（none）}
scope=${CFG_SCOPE_FOCUS:-（未指定）}
EOF
    if [ "${#CFG_SCOPE_OUT_OF_SCOPE[@]}" -gt 0 ]; then
        local o
        for o in "${CFG_SCOPE_OUT_OF_SCOPE[@]}"; do
            printf "  scope-out: %s\n" "$o"
        done
    fi
    if [ "${#CFG_BG_PATHS[@]}" -gt 0 ]; then
        local b
        for b in "${CFG_BG_PATHS[@]}"; do
            printf "  background: %s\n" "$b"
        done
    fi

    cat <<EOF

[Targets]
EOF
    local t
    for t in "${DR_TARGETS[@]}"; do
        printf "  - %s\n" "$t"
    done

    cat <<EOF

[Rounds]
  min_rounds=$CFG_ROUNDS_MIN
  max_rounds=$CFG_ROUNDS_MAX

[Teams]
EOF
    local tk
    for tk in T1 T2 T3 T4; do
        printf "  %s -> %s\n" "$tk" "${CFG_TEAMS[$tk]}"
    done

    cat <<EOF

[Orchestrator] tool=$CFG_ORCHESTRATOR_TOOL template=$CFG_ORCHESTRATOR_TEMPLATE
[Consolidator] tool=$CFG_CONSOLIDATOR_TOOL template=$CFG_CONSOLIDATOR_TEMPLATE

[Budget]
  tokens_per_subagent=$CFG_BUDGET_TOKENS_PER_SUBAGENT
  tokens_per_team_round=$CFG_BUDGET_TOKENS_PER_TEAM_ROUND
  tokens_per_round_total=$CFG_BUDGET_TOKENS_PER_ROUND_TOTAL
  tokens_per_run_total=$CFG_BUDGET_TOKENS_PER_RUN_TOTAL

[Verify]
  enabled=$CFG_VERIFY_ENABLED
  cmd=$CFG_VERIFY_CMD

[Output]
  supplement_dir=$CFG_OUTPUT_SUPPLEMENT_DIR
  temp_dir=$CFG_OUTPUT_TEMP_DIR

[Refs] (${#CFG_REFS_PATHS[@]} items)
EOF
    local i=0
    while [ "$i" -lt "${#CFG_REFS_PATHS[@]}" ]; do
        printf "  %s [%s]\n" "${CFG_REFS_PATHS[$i]}" "${CFG_REFS_TIERS[$i]}"
        i=$((i + 1))
    done
    echo ""
    echo "(--dry-run 仅打印计划；去掉 --dry-run 触发真对抗流程)"
}

main "$@"
