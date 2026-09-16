#!/usr/bin/env bash
# Glob 匹配（支持 ** 跨目录）。需 bash 4+ extglob/globstar。
# Note: sourcing this lib also enables extglob/globstar/nullglob in the caller's shell;
# all adversarial-review entry scripts assume these are on, so this is intentional.
shopt -s extglob globstar nullglob 2>/dev/null || true

# skip_paths_match <file> <pattern> → 0 if match
skip_paths_match() {
  local file="$1" pattern="$2"
  # shellcheck disable=SC2254
  case "$file" in
    $pattern) return 0 ;;
    *)        return 1 ;;
  esac
}

# all_paths_skipped <file-with-paths-one-per-line> <pattern>...
# → 0 if every path matches at least one pattern; 1 if any path is unmatched
all_paths_skipped() {
  local input="$1"; shift
  local patterns=("$@")
  local path matched
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    matched=0
    for p in "${patterns[@]}"; do
      if skip_paths_match "$path" "$p"; then
        matched=1; break
      fi
    done
    [[ "$matched" -eq 0 ]] && return 1
  done < "$input"
  return 0
}
