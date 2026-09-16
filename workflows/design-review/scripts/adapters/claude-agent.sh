#!/usr/bin/env bash
# design-review 真 LLM 适配器（Claude Code headless）
# 实现与 tests/mocks/mock-claude.sh 相同的接口，二者可互换：
#   claude-agent.sh --team T1 --stance pro --round 1 --case <name> --input <prompt-file>
# 行为：把 --input prompt 文件喂给真 claude -p（bypass 权限），stdout 即纯 yaml teamreport
#
# 环境变量：
#   DR_CLAUDE_BIN              真 claude 可执行（默认 claude）
#   DR_CLAUDE_MODEL_EFFECTIVE  模型（留空 = 继承 claude 自身默认，推荐）
#   DR_ADD_DIRS                额外可读目录，冒号分隔（refs / templates 在 cwd 外时用）
#
# 退出码：0 成功 / 2 参数或环境错误 / 1 调用失败（call_team_agent 会按 retry 重试）

set -euo pipefail

team="" stance="" round="" case_name="" input=""
while [ $# -gt 0 ]; do
    case "$1" in
        --team)   team="$2";      shift 2 ;;
        --stance) stance="$2";    shift 2 ;;
        --round)  round="$2";     shift 2 ;;
        --case)   case_name="$2"; shift 2 ;;
        --input)  input="$2";     shift 2 ;;
        --help)   sed -n '2,14p' "$0"; exit 0 ;;
        *)        shift ;;
    esac
done

[ -n "$input" ] && [ -f "$input" ] || { echo "claude-agent: --input 缺失或非文件：'$input'" >&2; exit 2; }

REAL_BIN="${DR_CLAUDE_BIN:-claude}"
MODEL="${DR_CLAUDE_MODEL_EFFECTIVE:-}"
model_args=()
[ -n "$MODEL" ] && model_args=(--model "$MODEL")

command -v "$REAL_BIN" >/dev/null 2>&1 || [ -x "$REAL_BIN" ] || {
    echo "claude-agent: 真 claude 不可用：$REAL_BIN" >&2; exit 2
}

# 额外可读目录 → --add-dir 列表（refs / templates / profile 常在被审仓库工作树外）
add_dir_args=()
if [ -n "${DR_ADD_DIRS:-}" ]; then
    IFS=':' read -r -a _dirs <<< "$DR_ADD_DIRS"
    for d in "${_dirs[@]}"; do
        [ -n "$d" ] && [ -d "$d" ] && add_dir_args+=(--add-dir "$d")
    done
fi

raw=""
if ! raw="$("$REAL_BIN" -p \
        ${model_args[@]+"${model_args[@]}"} \
        --permission-mode bypassPermissions \
        --output-format text \
        "${add_dir_args[@]}" \
        < "$input")"; then
    echo "claude-agent: claude -p 调用失败（team=$team stance=$stance round=$round case=$case_name）" >&2
    exit 1
fi

# 剥 ```yaml / ``` 围栏：有围栏取首个 fenced block，无则原样输出
printf '%s\n' "$raw" | awk '
    /^[[:space:]]*```/ {
        if (found==0)      { infence=1; found=1; next }
        else if (infence)  { infence=0; next }
        else               { next }
    }
    infence==1 { print; next }
    found==0   { buf = buf $0 "\n" }
    END        { if (found==0) printf "%s", buf }
'
