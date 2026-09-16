#!/usr/bin/env bash
# design-review CLI 参数解析
# 不要直接执行；由其他脚本 source
#
# 用法：parse_args "$@"
# 设置 DR_* 全局变量（详见 _args_init_defaults）
#
# shellcheck disable=SC2034
# 多数变量被 source 后的脚本消费 — SC2034 在此误报

[ -n "${_DR_ARGS_LOADED:-}" ] && return 0
_DR_ARGS_LOADED=1

readonly DR_VERSION="0.1.0-m1"

print_usage() {
    cat <<'EOF'
USAGE:
    review-design.sh [OPTIONS] [TARGET]

OPTIONS:
    --target FILES              被审文档（可多次，可逗号分隔）
    --min-rounds N              最小轮数（默认 2）
    --max-rounds N              最大轮数（默认 5）
    --rounds N                  等价 min=max=N
    --claude-model M            Claude 模型名
    --codex-cmd CMD             codex CLI 命令名
    --enable-roles R1,R3,R5     仅启用指定角色
    --add-role NAME=PATH        临时加角色模板（可多次）
    --skip-verify               跳文档自洽 lint
    --no-patch                  不出 suggested-patch.diff
    --no-supplement             不出 201-*-supplement.md
    --resume RUN-ID             从 /tmp/.../<RUN-ID>/ 续跑
    --dry-run                   不调 LLM，打印计划
    --verbose / -v              详细日志
    --quiet / -q                仅错误
    --run-id ID                 覆盖自动生成的 run id
    --config PATH               自定义配置（默认 .design-review.yaml）
    --profile NAME|PATH         项目 profile（覆盖 yaml profile / 环境变量 DR_PROFILE）
    --principles PATH           覆盖原则文件
    --refs PATH                 覆盖参考仓库清单
    --scope FOCUS               本次审查焦点（覆盖 yaml scope.focus，如 "调度模块"）
    --version                   打印版本
    --help / -h                 本帮助

EXAMPLES:
    review-design.sh design/01-core.md
    review-design.sh design/01-core.md --rounds 1 --verbose
    review-design.sh design/01-core.md --enable-roles R1,R3 --dry-run
    review-design.sh design/01-core.md --profile my-project --dry-run
EOF
}

print_version() {
    echo "design-review $DR_VERSION"
}

_args_init_defaults() {
    DR_TARGETS=()
    DR_MIN_ROUNDS=2
    DR_MAX_ROUNDS=5
    DR_MIN_ROUNDS_SET=0
    DR_MAX_ROUNDS_SET=0
    DR_CLAUDE_MODEL=""
    DR_CODEX_CMD=""
    DR_ENABLED_ROLES=()
    DR_ADD_ROLES=()
    DR_SKIP_VERIFY=0
    DR_NO_PATCH=0
    DR_NO_SUPPLEMENT=0
    DR_RESUME_RUN_ID=""
    DR_DRY_RUN=0
    DR_VERBOSE=0
    DR_QUIET=0
    DR_RUN_ID=""
    DR_CONFIG_PATH=".design-review.yaml"
    DR_PROFILE_ARG=""
    DR_PRINCIPLES_PATH=""
    DR_REFS_PATH=""
    DR_SCOPE_FOCUS=""
    DR_SCOPE_FOCUS_SET=0
}

parse_args() {
    _args_init_defaults

    local rounds_set=0
    local _tmp

    while [ $# -gt 0 ]; do
        case "$1" in
            --target)
                IFS=',' read -r -a _tmp <<< "$2"
                DR_TARGETS+=("${_tmp[@]}")
                shift 2
                ;;
            --min-rounds)
                [ "$rounds_set" -eq 1 ] && die "--rounds 与 --min-rounds/--max-rounds 互斥"
                DR_MIN_ROUNDS="$2"; DR_MIN_ROUNDS_SET=1; shift 2
                ;;
            --max-rounds)
                [ "$rounds_set" -eq 1 ] && die "--rounds 与 --min-rounds/--max-rounds 互斥"
                DR_MAX_ROUNDS="$2"; DR_MAX_ROUNDS_SET=1; shift 2
                ;;
            --rounds)
                rounds_set=1
                DR_MIN_ROUNDS="$2"; DR_MAX_ROUNDS="$2"
                DR_MIN_ROUNDS_SET=1; DR_MAX_ROUNDS_SET=1
                shift 2
                ;;
            --claude-model) DR_CLAUDE_MODEL="$2"; shift 2 ;;
            --codex-cmd)    DR_CODEX_CMD="$2";    shift 2 ;;
            --enable-roles)
                IFS=',' read -r -a DR_ENABLED_ROLES <<< "$2"
                shift 2
                ;;
            --add-role)        DR_ADD_ROLES+=("$2");      shift 2 ;;
            --skip-verify)     DR_SKIP_VERIFY=1;          shift ;;
            --no-patch)        DR_NO_PATCH=1;             shift ;;
            --no-supplement)   DR_NO_SUPPLEMENT=1;        shift ;;
            --resume)          DR_RESUME_RUN_ID="$2";     shift 2 ;;
            --dry-run)         DR_DRY_RUN=1;              shift ;;
            --verbose|-v)      DR_VERBOSE=1;              shift ;;
            --quiet|-q)        DR_QUIET=1;                shift ;;
            --run-id)          DR_RUN_ID="$2";            shift 2 ;;
            --config)          DR_CONFIG_PATH="$2";       shift 2 ;;
            --profile)         DR_PROFILE_ARG="$2";       shift 2 ;;
            --principles)      DR_PRINCIPLES_PATH="$2";   shift 2 ;;
            --refs)            DR_REFS_PATH="$2";         shift 2 ;;
            --scope)           DR_SCOPE_FOCUS="$2"; DR_SCOPE_FOCUS_SET=1; shift 2 ;;
            --version) print_version; exit "$EXIT_OK" ;;
            --help|-h) print_usage;  exit "$EXIT_OK" ;;
            -*) die "未知参数：$1" ;;
            *)
                IFS=',' read -r -a _tmp <<< "$1"
                DR_TARGETS+=("${_tmp[@]}")
                shift
                ;;
        esac
    done

    if [ "$DR_VERBOSE" -eq 1 ] && [ "$DR_QUIET" -eq 1 ]; then
        die "--verbose 与 --quiet 互斥"
    fi

    if ! [[ "$DR_MIN_ROUNDS" =~ ^[0-9]+$ ]] || [ "$DR_MIN_ROUNDS" -lt 1 ]; then
        die "--min-rounds 必须是正整数：$DR_MIN_ROUNDS"
    fi
    if ! [[ "$DR_MAX_ROUNDS" =~ ^[0-9]+$ ]] || [ "$DR_MAX_ROUNDS" -lt 1 ]; then
        die "--max-rounds 必须是正整数：$DR_MAX_ROUNDS"
    fi
    if [ "$DR_MIN_ROUNDS" -gt "$DR_MAX_ROUNDS" ]; then
        die "min-rounds 不可大于 max-rounds"
    fi

    return 0
}
