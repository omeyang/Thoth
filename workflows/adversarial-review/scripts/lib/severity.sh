#!/usr/bin/env bash
# Severity ordering: high > medium > low > none. "never" disables.
severity_rank() {
  case "$1" in
    high)   echo 3 ;;
    medium) echo 2 ;;
    low)    echo 1 ;;
    *)      echo 0 ;; # "never" / unknown → rank 0 (same as "none")
  esac
}

# severity_ge $actual $threshold → exit 0 if actual >= threshold
severity_ge() {
  local actual_rank threshold_rank
  actual_rank=$(severity_rank "$1")
  threshold_rank=$(severity_rank "$2")
  # threshold "never" → rank 0 with special exit (always false)
  if [[ "$2" == "never" ]]; then
    return 1
  fi
  [[ "$actual_rank" -ge "$threshold_rank" ]]
}
