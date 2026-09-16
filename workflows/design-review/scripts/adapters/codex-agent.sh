#!/usr/bin/env bash
# design-review 真 LLM 适配器（Codex CLI headless）
# 实现与 tests/mocks/mock-codex.sh 相同的接口，二者可互换：
#   codex-agent.sh --team T2 --stance con --round 1 --case <name> --input <prompt-file>
# 行为：把 --input prompt 文件喂给真 codex exec（bypass 审批+沙箱），
#   用 --output-last-message 取干净最终消息，stdout 即纯 yaml teamreport
#
# 环境变量：
#   DR_CODEX_BIN              真 codex 可执行（默认 codex）
#   DR_CODEX_MODEL_EFFECTIVE  模型（默认空 → 用 codex 自身配置的模型）
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

[ -n "$input" ] && [ -f "$input" ] || { echo "codex-agent: --input 缺失或非文件：'$input'" >&2; exit 2; }

REAL_BIN="${DR_CODEX_BIN:-codex}"
MODEL="${DR_CODEX_MODEL_EFFECTIVE:-}"

command -v "$REAL_BIN" >/dev/null 2>&1 || [ -x "$REAL_BIN" ] || {
    echo "codex-agent: 真 codex 不可用：$REAL_BIN" >&2; exit 2
}

model_args=()
[ -n "$MODEL" ] && model_args=(-m "$MODEL")

tmp_msg="$(mktemp -t dr-codex-msg-XXXXXX)"
trap 'rm -f "$tmp_msg"' EXIT

# codex exec：stdin 读 prompt；exec 日志噪声丢弃，最终消息落 --output-last-message
if ! "$REAL_BIN" exec \
        --dangerously-bypass-approvals-and-sandbox \
        --skip-git-repo-check \
        "${model_args[@]}" \
        --output-last-message "$tmp_msg" \
        < "$input" >/dev/null 2>&1; then
    echo "codex-agent: codex exec 调用失败（team=$team stance=$stance round=$round case=$case_name）" >&2
    exit 1
fi

[ -s "$tmp_msg" ] || { echo "codex-agent: codex 最终消息为空" >&2; exit 1; }

# 剥 ```yaml / ``` 围栏：有围栏取首个 fenced block，无则原样输出
awk '
    /^[[:space:]]*```/ {
        if (found==0)      { infence=1; found=1; next }
        else if (infence)  { infence=0; next }
        else               { next }
    }
    infence==1 { print; next }
    found==0   { buf = buf $0 "\n" }
    END        { if (found==0) printf "%s", buf }
' "$tmp_msg"
