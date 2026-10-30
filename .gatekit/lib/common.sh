# common.sh — shared setup for every gatekit command. Sourced, never run.
#
# Sets:
#   GK_ROOT     the repo root
#   GK_DIR      $GK_ROOT/.gatekit
#   GK_BRANCH   the current branch, e.g. feature/login
#   GK_REC      this branch's records folder, e.g. .gatekit/records/feature-login
#   GK_BASE     the branch PRs merge into (BASE_BRANCH in config.yaml, default main)
# and exports the variables the scanners read.

GK_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "gatekit: run this inside a git repo" >&2; exit 1; }
cd "$GK_ROOT" || exit 1
GK_DIR="$GK_ROOT/.gatekit"
GK_CONFIG="$GK_DIR/config.yaml"

# gk_cfg KEY [default] — read one `KEY: value` line from config.yaml.
gk_cfg() {
  local v=""
  [ -f "$GK_CONFIG" ] && v="$(sed -nE "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"#]*)\"?[[:space:]]*(#.*)?$/\1/p" "$GK_CONFIG" | head -1 | sed -E 's/[[:space:]]+$//')"
  printf '%s' "${v:-${2:-}}"
}

gk_say()  { printf 'gatekit: %s\n' "$*"; }
gk_die()  { printf 'gatekit: %s\n' "$*" >&2; exit 1; }

GK_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ "$GK_BRANCH" = "HEAD" ] && GK_BRANCH="detached-$(git rev-parse --short HEAD)"
GK_REC="$GK_DIR/records/$(printf '%s' "$GK_BRANCH" | tr '/' '-')"
GK_BASE="$(gk_cfg BASE_BRANCH main)"

# The scanners read these. App folders come from APPS in config.yaml (default: the repo root).
export GATEKIT_APPS="$(gk_cfg APPS .)"
export NPM_AUDIT_APPS="$GATEKIT_APPS"
export ESLINT_APPS="$GATEKIT_APPS"
export SCAN_RESULTS_DIR="$GK_REC/scan"
export SCAN_RECEIPT_DIR="$SCAN_RESULTS_DIR"

GK_TEST_COMMAND="$(gk_cfg TEST_COMMAND)"

# gk_run_tests — run the project's tests. Returns their exit code.
gk_run_tests() {
  [ -n "$GK_TEST_COMMAND" ] || gk_die "no TEST_COMMAND in .gatekit/config.yaml — run make gatekit-init"
  gk_say "running tests: $GK_TEST_COMMAND"
  bash -c "$GK_TEST_COMMAND"
}

# gk_next_ticket_id — next free T-nnn on this branch.
gk_next_ticket_id() {
  local n
  n="$(ls "$GK_REC/tickets" 2>/dev/null | sed -nE 's/^T-([0-9]+).*/\1/p' | sort -n | tail -1)"
  printf 'T-%03d' "$(( 10#${n:-0} + 1 ))"
}

# gk_commit_records MESSAGE — commit this branch's records (and nothing else).
gk_commit_records() {
  [ -d "$GK_REC" ] || return 0
  git add -- "$GK_REC" 2>/dev/null || return 0
  git diff --cached --quiet -- "$GK_REC" && return 0
  git commit -q -m "$1" -- "$GK_REC" && gk_say "committed: $1"
}
