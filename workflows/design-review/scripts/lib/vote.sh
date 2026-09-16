#!/usr/bin/env bash
# design-review 4-vote 分类与 cross-finding 归并
# 不要直接执行；由其他脚本 source
#
# 函数：
#   classify_votes <yes> <no>            → 必修/存疑/舍弃（stdout）
#   tally_votes <cross-file> <cross-id>  → "<yes> <no>"
#   classify_cross_finding <file> <id>   → 上述两个组合
#   merge_findings <T1-yaml> <T2-yaml> <T3-yaml> <T4-yaml> <out-yaml>
#     → 把 4 份 teamreport 中 canonical_text 相同的归一到同一 cross-finding

[ -n "${_DR_VOTE_LOADED:-}" ] && return 0
_DR_VOTE_LOADED=1

# classify_votes <yes_count> <no_count>
classify_votes() {
    local yes="$1"
    local no="$2"
    local total=$((yes + no))

    if [ "$total" -ne 4 ]; then
        printf 'classify_votes: 票数和 %d != 4 (yes=%s no=%s)\n' "$total" "$yes" "$no" >&2
        return 1
    fi
    if [ "$yes" -lt 0 ] || [ "$no" -lt 0 ]; then
        printf 'classify_votes: 票数不可为负\n' >&2
        return 1
    fi

    if [ "$yes" -ge 3 ]; then
        echo "必修"
    elif [ "$yes" -eq 2 ]; then
        echo "存疑"
    else
        echo "舍弃"
    fi
}

# tally_votes <cross-file> <cross-id>
# 输出 "<yes> <no>"
tally_votes() {
    local file="$1"
    local cid="$2"
    local yes=0 no=0 v

    for t in T1 T2 T3 T4; do
        v="$(yq eval ".cross_findings[] | select(.cross_id == \"$cid\") | .votes.${t} // \"unknown\"" "$file")"
        case "$v" in
            agree|covered)  yes=$((yes + 1)) ;;
            refute|discard) no=$((no + 1)) ;;
            unknown|"") ;;
            *) printf 'tally_votes: 未知 vote 值 %s\n' "$v" >&2; return 1 ;;
        esac
    done

    printf '%d %d\n' "$yes" "$no"
}

# classify_cross_finding <cross-file> <cross-id>
classify_cross_finding() {
    local file="$1"
    local cid="$2"
    local tally yes no

    tally="$(tally_votes "$file" "$cid")" || return 1
    yes="${tally%% *}"
    no="${tally##* }"
    classify_votes "$yes" "$no"
}

# 近义去重阈值（char-bigram Jaccard %）；DR_DEDUP_THRESHOLD 可覆盖
_DR_DEDUP_THRESHOLD_DEFAULT=30

# _text_similarity <a> <b> → char-bigram Jaccard 相似度（0-100 整数）
# 字节级 bigram，无 locale 依赖；对两串一致地切片，相似度可比
_text_similarity() {
    awk -v a="$1" -v b="$2" '
      function shingles(s, set,   n,i,g){ n=length(s); delete set; for(i=1;i<=n-1;i++){g=substr(s,i,2); set[g]=1} }
      BEGIN{
        shingles(a,A); shingles(b,B)
        inter=0; for(g in A) if(g in B) inter++
        uni=0; for(g in A) uni++; for(g in B) if(!(g in A)) uni++
        if(uni==0){print 0; exit}
        printf "%d\n", inter*100/uni
      }'
}

# merge_findings <T1.yaml> <T2.yaml> <T3.yaml> <T4.yaml> <out.yaml>
# 归并 4 队 finding 到 cross-finding：同 severity 且（文本精确相等 或 相似度≥阈值）即合并；
# 合并后该 cross-finding 的提出队都标 agree（近义对一起参与同一次投票）。
merge_findings() {
    [ $# -eq 5 ] || { echo "merge_findings: 需 5 参数" >&2; return 1; }
    local out="$5"
    local threshold="${DR_DEDUP_THRESHOLD:-$_DR_DEDUP_THRESHOLD_DEFAULT}"

    # 并行数组：每个 group 一项（代表文本取首见队的措辞）
    local g_cid=() g_text=() g_sev=() g_votes=()
    local counter=0

    local team_files=("$1" "$2" "$3" "$4")
    local teams=(T1 T2 T3 T4)

    local i
    for i in 0 1 2 3; do
        local tf="${team_files[$i]}"
        local tk="${teams[$i]}"
        local n
        n="$(yq eval '.findings | length' "$tf" 2>/dev/null)"
        [ -z "$n" ] || [ "$n" = "null" ] && continue
        [ "$n" -eq 0 ] && continue

        local j=0
        while [ "$j" -lt "$n" ]; do
            local text sev
            text="$(yq eval ".findings[$j].canonical_text" "$tf")"
            sev="$(yq eval ".findings[$j].severity" "$tf")"
            j=$((j + 1))

            # 找匹配 group：同 severity 且（精确相等 或 相似度≥阈值）
            local matched=-1 gi=0
            while [ "$gi" -lt "${#g_text[@]}" ]; do
                if [ "${g_sev[$gi]}" = "$sev" ]; then
                    if [ "${g_text[$gi]}" = "$text" ]; then
                        matched=$gi; break
                    fi
                    local s
                    s="$(_text_similarity "$text" "${g_text[$gi]}")"
                    if [ "$s" -ge "$threshold" ]; then
                        matched=$gi; break
                    fi
                fi
                gi=$((gi + 1))
            done

            if [ "$matched" -ge 0 ]; then
                case " ${g_votes[$matched]} " in
                    *" ${tk}:agree "*) ;;  # 同队已投，不重复
                    *) g_votes[$matched]="${g_votes[$matched]} ${tk}:agree" ;;
                esac
            else
                counter=$((counter + 1))
                g_cid+=("$(printf 'cf-%03d' "$counter")")
                g_text+=("$text")
                g_sev+=("$sev")
                g_votes+=(" ${tk}:agree")
            fi
        done
    done

    {
        echo "cross_findings:"
        local k=0
        while [ "$k" -lt "${#g_cid[@]}" ]; do
            echo "  - cross_id: ${g_cid[$k]}"
            echo "    canonical_text: $(_yaml_dq "${g_text[$k]}")"
            echo "    severity: ${g_sev[$k]}"
            echo "    votes:"
            local t
            for t in T1 T2 T3 T4; do
                if [[ " ${g_votes[$k]} " == *" $t:agree "* ]]; then
                    echo "      $t: agree"
                else
                    echo "      $t: unknown"
                fi
            done
            k=$((k + 1))
        done
    } > "$out"
}
