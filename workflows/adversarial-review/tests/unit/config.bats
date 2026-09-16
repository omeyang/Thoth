#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  source "$LIB_DIR/config.sh"
  TMPCFG="$(mktemp --suffix=.yaml)"
  cat > "$TMPCFG" <<'EOF'
repo: { root: /tmp/proj, search_dirs: [pkg, cmd], search_maxdepth: 3 }
diff: { default_ref: "--cached", scope_strategy: auto, max_diff_lines: 500 }
policy: { fail_on_severity: high, strict_on_error: false }
log: { file: docs/log.md, run_dir: .runs }
verify: { cmd: "task pre-push", timeout_seconds: 600 }
llm: { claude_model: "", codex_command: codex }
EOF
}

teardown() { rm -f "$TMPCFG"; }

@test "config_load: missing file → exit 2" {
  run config_load /nonexistent.yaml
  [ "$status" -eq 2 ]
}

@test "config_get: top-level path" {
  config_load "$TMPCFG"
  [ "$(config_get .repo.root)" = "/tmp/proj" ]
  [ "$(config_get .policy.fail_on_severity)" = "high" ]
}

@test "config_get: missing key returns empty + status 0" {
  config_load "$TMPCFG"
  run config_get .nope.nope
  [ "$status" -eq 0 ]
  [ -z "$output" ] || [ "$output" = "null" ]
}

@test "config_get_default: returns default if missing" {
  config_load "$TMPCFG"
  [ "$(config_get_default .nope.nope FALLBACK)" = "FALLBACK" ]
  [ "$(config_get_default .repo.root WRONG)" = "/tmp/proj" ]
}

@test "config_get_array: returns one-per-line" {
  config_load "$TMPCFG"
  run config_get_array .repo.search_dirs
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "pkg" ]
  [ "${lines[1]}" = "cmd" ]
}

@test "config_load: invalid YAML → exit 2 + CFG_PATH not set" {
  local bad
  bad="$(mktemp --suffix=.yaml)"
  echo ":: not valid yaml ::" > "$bad"
  unset CFG_PATH
  run config_load "$bad"
  rm -f "$bad"
  [ "$status" -eq 2 ]
  # CFG_PATH must remain unset → config_get should fail with exit 2
  run config_get .anything
  [ "$status" -eq 2 ]
}
