#!/usr/bin/env bash
# 从 diff 涉及的文件路径推断 TARGET 名

# deepest_common <file-with-paths> → echo dir-basename, exit 0;
#   或 exit 1 if 没有公共父目录（即至少一个文件在根）
deepest_common() {
  local input="$1"
  local first prefix path
  if ! IFS= read -r first < "$input"; then
    return 1
  fi
  # 路径无 / → 根文件，无公共父
  [[ "$first" != */* ]] && return 1
  prefix="${first%/*}"
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    [[ "$path" != */* ]] && return 1
    while [[ "$path/" != "$prefix"/* ]]; do
      # 缩短 prefix 到上一级
      [[ "$prefix" != */* ]] && return 1
      prefix="${prefix%/*}"
    done
  done < "$input"
  echo "${prefix##*/}"
}

# files_basename <file-with-paths> → echo "a.go-b.go-c.go" (前 3 个 basename 用 - 拼)
files_basename() {
  local input="$1"
  local result="" path bn n=0
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    bn="${path##*/}"
    if [[ -z "$result" ]]; then
      result="$bn"
    else
      result="$result-$bn"
    fi
    n=$((n+1))
    [[ "$n" -ge 3 ]] && break
  done < "$input"
  [[ -n "$result" ]] || return 1
  echo "$result"
}

# sanitize_target <name> → echo cleaned (only alnum . _ - kept; others → -)
sanitize_target() {
  echo "$1" | tr -c 'a-zA-Z0-9._-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//'
}

# target_from_diff <file-with-paths> <strategy>
#   strategy: auto | deepest-common | files
target_from_diff() {
  local input="$1" strategy="${2:-auto}"
  local out tmpfile
  # Buffer input to a temp file so it can be read multiple times in auto mode
  tmpfile="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmpfile'" RETURN
  cat "$input" > "$tmpfile"
  case "$strategy" in
    deepest-common)
      out=$(deepest_common "$tmpfile") || return 1
      ;;
    files)
      out=$(files_basename "$tmpfile") || return 1
      ;;
    auto)
      out=$(deepest_common "$tmpfile")
      # 拒绝过浅的 common（如 pkg/cmd/internal 顶层）
      if [[ -z "$out" || "$out" =~ ^(pkg|cmd|internal|src|lib)$ ]]; then
        out=$(files_basename "$tmpfile") || true
      fi
      ;;
    *)
      echo "unknown strategy: $strategy" >&2; return 2 ;;
  esac
  if [[ -z "$out" ]]; then
    out="commit-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  fi
  sanitize_target "$out"
}
