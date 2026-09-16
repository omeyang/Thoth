#!/usr/bin/env bash
# design-review L6 真 LLM smoke 测试
# 只断言"适配器能把 prompt 喂给真 CLI 并拿回可解析 yaml" —— 不评判输出质量。
# 耗 token，故仅手动跑：make test-smoke（或直接 bash tests/smoke/run.sh）
#
# 选项（环境变量）：
#   DR_SMOKE_TOOLS=claude,codex   要测哪些适配器（默认仅 claude，避免双倍 token）

set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_DIR="$(cd "$SMOKE_DIR/../.." && pwd)"
ADAPTERS_DIR="$WORKFLOW_DIR/scripts/adapters"

TOOLS="${DR_SMOKE_TOOLS:-claude}"

tmp="$(mktemp -d -t dr-smoke-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

# 极小 prompt：要求模型只回一段固定结构的 yaml，token 消耗最小
prompt="$tmp/prompt.txt"
cat > "$prompt" <<'EOF'
你是 design-review 的冒烟测试探针。请严格只输出如下 yaml（不要任何解释、不要 markdown 围栏以外的文字）：

```yaml
team: SMOKE
stance: neutral
round: 1
findings: []
EOF
# 注意：故意留一个未闭合的围栏让模型补全闭合 + 内容
echo '```' >> "$prompt"

run_one() {
    local tool="$1" adapter="$2"
    local out="$tmp/out-$tool.yaml"
    echo "=== smoke: $tool ($adapter) ==="
    if [ ! -x "$adapter" ]; then
        echo "SKIP $tool：适配器不存在 $adapter"
        return 0
    fi
    local rc=0
    timeout 180s "$adapter" \
        --team SMOKE --stance neutral --round 1 --case smoke \
        --input "$prompt" > "$out" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL $tool：适配器 exit=$rc"
        cat "$out" >&2 || true
        return 1
    fi
    # 断言：输出非空 + yq 能解析 + team 字段可取
    if ! yq eval '.' "$out" >/dev/null 2>&1; then
        echo "FAIL $tool：输出非合法 yaml"
        cat "$out" >&2
        return 1
    fi
    local team
    team="$(yq eval '.team // ""' "$out")"
    echo "OK $tool：yaml 可解析，team=$team"
    return 0
}

fail=0
IFS=',' read -r -a tool_list <<< "$TOOLS"
for t in "${tool_list[@]}"; do
    case "$t" in
        claude) run_one claude "$ADAPTERS_DIR/claude-agent.sh" || fail=1 ;;
        codex)  run_one codex  "$ADAPTERS_DIR/codex-agent.sh"  || fail=1 ;;
        *)      echo "未知 tool：$t（支持 claude / codex）" ;;
    esac
done

if [ "$fail" -ne 0 ]; then
    echo "=== smoke 有失败 ==="
    exit 1
fi
echo "=== smoke 全过 ==="
