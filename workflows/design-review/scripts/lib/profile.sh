#!/usr/bin/env bash
# design-review 项目 profile（插件）定位
# 不要直接执行；由其他脚本 source
#
# profile = 一个目录，装项目私有的东西：角色模板覆盖、项目原则追加、cron 旋钮。
# 通用引擎留在本仓库，项目内部信息放在仓库之外的 profile 根目录下：
#
#   <root>/design-review/<name>/
#   ├─ profile.env         # cron-batch.sh 读：REPO / REDESIGN_SUBDIR / MAX_ROUNDS / WINDOW_END_HOUR
#   ├─ principles.md       # 项目原则（追加在通用 principles.md 之后，优先级更高）
#   └─ agent-*.md          # 同名即覆盖 templates/ 下的角色模板
#
# 函数：
#   resolve_profile_dir <name-or-path>   打印 profile 目录；找不到返回 1
#   resolve_template <filename>          profile 覆盖优先，否则 templates/ 默认

[ -n "${_DR_PROFILE_LOADED:-}" ] && return 0
_DR_PROFILE_LOADED=1

# _profile_expand <value> → 展开 $THOTH_PROFILES / $THOTH_HOME / ~ 前缀
_profile_expand() {
    local v="$1"
    case "$v" in
        '$THOTH_PROFILES'/*|'${THOTH_PROFILES}'/*)
            v="${THOTH_PROFILES:-}/${v#*/}" ;;
        '$THOTH_HOME'/*|'${THOTH_HOME}'/*)
            v="${THOTH_HOME:-}/${v#*/}" ;;
        '~'/*)
            v="$HOME/${v#\~/}" ;;
    esac
    printf '%s\n' "$v"
}

# _profile_roots → 按优先级逐行打印 profile 根目录（design-review 子目录已拼上）
_profile_roots() {
    [ -n "${THOTH_PROFILES:-}" ] && printf '%s\n' "${THOTH_PROFILES%/}/design-review"
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/thoth/profiles/design-review"
    if [ -n "${THOTH_HOME:-}" ]; then
        printf '%s\n' "${THOTH_HOME%/}/workflows/design-review/profiles"
    else
        printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles"
    fi
}

# resolve_profile_dir <name-or-path>
# 含 / 或以 ~ / $ 开头视为路径（展开后必须是目录）；否则按名字依次查
#   $THOTH_PROFILES/design-review/<name>
#   ${XDG_CONFIG_HOME:-~/.config}/thoth/profiles/design-review/<name>
#   $THOTH_HOME/workflows/design-review/profiles/<name>   （内置）
resolve_profile_dir() {
    local v="${1:-}"
    [ -n "$v" ] || return 1

    case "$v" in
        */*|'~'*|'$'*)
            v="$(_profile_expand "$v")"
            if [ -d "$v" ]; then
                (cd "$v" && pwd)
                return 0
            fi
            return 1
            ;;
    esac

    local root
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        if [ -d "$root/$v" ]; then
            (cd "$root/$v" && pwd)
            return 0
        fi
    done < <(_profile_roots)
    return 1
}

# resolve_template <filename>
# DR_PROFILE_DIR 下同名文件存在 → 用之（项目覆盖）；否则 DR_TEMPLATES_DIR 默认
resolve_template() {
    local name="$1"
    [ -n "$name" ] || return 1
    if [ -n "${DR_PROFILE_DIR:-}" ] && [ -f "$DR_PROFILE_DIR/$name" ]; then
        printf '%s\n' "$DR_PROFILE_DIR/$name"
        return 0
    fi
    local tdir="${DR_TEMPLATES_DIR:-}"
    if [ -z "$tdir" ]; then
        tdir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../templates" && pwd)"
    fi
    printf '%s\n' "$tdir/$name"
}

# resolve_role_template_path <configured-path>
# roles.Rn.template 的路径：绝对路径原样；相对路径先按 profile 目录，再按 design-review 目录
resolve_role_template_path() {
    local p="$1"
    [ -n "$p" ] || return 1
    p="$(_profile_expand "$p")"
    case "$p" in
        /*) printf '%s\n' "$p"; return 0 ;;
    esac
    if [ -n "${DR_PROFILE_DIR:-}" ] && [ -f "$DR_PROFILE_DIR/$p" ]; then
        printf '%s\n' "$DR_PROFILE_DIR/$p"
        return 0
    fi
    local wf
    if [ -n "${DR_TEMPLATES_DIR:-}" ]; then
        wf="$(cd "$DR_TEMPLATES_DIR/.." && pwd)"
    else
        wf="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    fi
    printf '%s\n' "$wf/$p"
}
