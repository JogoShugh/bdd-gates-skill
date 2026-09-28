#!/usr/bin/env bash
# Shared helpers for the bdd-gates scripts. Sourced, never executed directly.
# Written for bash 3.2 (stock macOS): no mapfile, no associative arrays.
#
# Config: <repo>/.claude/bdd-gates.json (override with BDD_GATES_CONFIG).
# Paths in the config are shell case patterns matched against repo-relative
# paths; `*` also crosses `/`, so `src/main/kotlin/*.kt` covers every subfolder.

bdd_root() {
  if [ -n "${BDD_GATES_ROOT:-}" ]; then echo "$BDD_GATES_ROOT"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then echo "$CLAUDE_PROJECT_DIR"
  else git rev-parse --show-toplevel 2>/dev/null || pwd
  fi
}
bdd_config() { echo "${BDD_GATES_CONFIG:-$(bdd_root)/.claude/bdd-gates.json}"; }
bdd_log() { echo "$(bdd_root)/.claude/tdd-events.log"; }
bdd_has_config() { [ -f "$(bdd_config)" ]; }

bdd_value() { jq -r --arg k "$1" '.[$k] // empty' "$(bdd_config)"; }
bdd_list() { jq -r --arg k "$1" '.[$k] // [] | .[]' "$(bdd_config)"; }

# Loads the pattern lists once so matching does not re-run jq per path.
bdd_load() {
  PROD_PATTERNS=(); PROD_EXCLUDES=(); FEATURE_PATTERNS=(); LINT_PATTERNS=()
  local p
  while IFS= read -r p; do [ -n "$p" ] && PROD_PATTERNS+=("$p"); done < <(bdd_list prodPatterns)
  while IFS= read -r p; do [ -n "$p" ] && PROD_EXCLUDES+=("$p"); done < <(bdd_list prodExcludePatterns)
  while IFS= read -r p; do [ -n "$p" ] && FEATURE_PATTERNS+=("$p"); done < <(bdd_list featurePatterns)
  while IFS= read -r p; do [ -n "$p" ] && LINT_PATTERNS+=("$p"); done < <(bdd_list lintPatterns)
}

_bdd_any() {
  local path=$1 pat
  shift
  for pat in "$@"; do
    # Unquoted on purpose: $pat is a glob pattern.
    [[ $path == $pat ]] && return 0
  done
  return 1
}

bdd_is_prod() {
  _bdd_any "$1" ${PROD_PATTERNS[@]+"${PROD_PATTERNS[@]}"} \
    && ! _bdd_any "$1" ${PROD_EXCLUDES[@]+"${PROD_EXCLUDES[@]}"}
}
bdd_is_feature() { _bdd_any "$1" ${FEATURE_PATTERNS[@]+"${FEATURE_PATTERNS[@]}"}; }
bdd_is_lintable() { _bdd_any "$1" ${LINT_PATTERNS[@]+"${LINT_PATTERNS[@]}"}; }

# Absolute path -> repo-relative path. Relative paths pass through unchanged.
bdd_rel() {
  local root
  root=$(bdd_root)
  case "$1" in
    "$root"/*) echo "${1#"$root"/}" ;;
    *) echo "$1" ;;
  esac
}

# True when any feature file is staged, unstaged, or untracked right now.
bdd_features_dirty() {
  local line p
  while IFS= read -r line; do
    p=${line:3}
    p=${p##* -> }
    p=${p#\"}
    p=${p%\"}
    bdd_is_feature "$p" && return 0
  done < <(cd "$(bdd_root)" && git status --porcelain -uall 2>/dev/null)
  return 1
}

bdd_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Appends one fact to the event log: "<utc-timestamp> <EVENT> <detail...>".
bdd_append() {
  local log
  log=$(bdd_log)
  mkdir -p "$(dirname "$log")"
  echo "$(bdd_now) $*" >> "$log"
}

# Reads the file path from a hook's JSON payload on stdin.
bdd_hook_file_path() { jq -r '.tool_input.file_path // empty'; }
