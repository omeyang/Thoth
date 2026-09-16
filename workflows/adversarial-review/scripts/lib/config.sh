#!/usr/bin/env bash
# YAML 配置加载（依赖 yq v4）

CFG_PATH=""

config_load() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "config: file not found: $path" >&2
    return 2
  fi
  command -v yq >/dev/null || { echo "config: 'yq' not in PATH" >&2; return 2; }
  # 验证可解析（在赋值 CFG_PATH 之前，避免失败留下 stale 状态）
  yq eval '.' "$path" >/dev/null 2>&1 || { echo "config: invalid YAML: $path" >&2; return 2; }
  CFG_PATH="$path"
}

# config_get <yq-path>  → echo value or empty
config_get() {
  [[ -n "$CFG_PATH" ]] || { echo "config: not loaded" >&2; return 2; }
  local val
  val=$(yq eval "$1 // \"\"" "$CFG_PATH" 2>/dev/null)
  # yq returns "null" for missing → normalize to empty
  [[ "$val" == "null" ]] && val=""
  echo "$val"
}

config_get_default() {
  local val
  val=$(config_get "$1")
  if [[ -z "$val" ]]; then
    echo "$2"
  else
    echo "$val"
  fi
}

# config_get_array <yq-path>  → echo each item on its own line
config_get_array() {
  [[ -n "$CFG_PATH" ]] || { echo "config: not loaded" >&2; return 2; }
  yq eval "$1 // [] | .[]" "$CFG_PATH" 2>/dev/null
}
