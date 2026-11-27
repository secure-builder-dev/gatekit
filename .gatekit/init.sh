#!/usr/bin/env bash
# init.sh — `make gatekit-init`. First-time setup. Safe to run again.
#
#   1. Checks the tools gatekit needs are installed.
#   2. Works out where your apps are, how to run your tests, and your main branch.
#   3. Asks which Claude Code connection is your ticket tracker, if you have one (optional).
#   4. Writes .gatekit/config.yaml and shows it to you.
#   5. Asks whether to create a controls manifest (.gatekit/CONTROLS.md).
#   6. Installs the gate reviewer and /implement into .claude/, and updates .gitignore.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
. "$HERE/lib/update.sh"

ask() {   # ask "question" default(y|n) → 0 for yes
  local q="$1" def="$2" a
  if [ ! -t 0 ]; then [ "$def" = y ]; return; fi
  read -r -p "$q $([ "$def" = y ] && echo '[Y/n]' || echo '[y/N]') " a
  a="${a:-$def}"; case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

echo ""
echo "  gatekit setup"
echo "  ─────────────"
echo ""

# ── 1. tools ──────────────────────────────────────────────────────────────────
missing=()
for t in git curl jq python3 npm; do command -v "$t" >/dev/null || missing+=("$t"); done
command -v docker >/dev/null || command -v podman >/dev/null || missing+=("docker (or podman)")
if [ ${#missing[@]} -gt 0 ]; then
  echo "  Missing tools: ${missing[*]}"
  echo "  Install them, then run make gatekit-init again."
  exit 1
fi
command -v claude >/dev/null || echo "  Note: no 'claude' command found. make scans works without it; the gates need Claude Code installed."
command -v gh >/dev/null || command -v glab >/dev/null \
  || echo "  Note: no 'gh' or 'glab' command found. The gate can't put its verdict in your PR without one."

# ── 2. apps, tests, main branch ───────────────────────────────────────────────
apps=()
while IFS= read -r p; do
  d="$(dirname "$p")"; d="${d#./}"
  [ "$d" = "." ] && continue
  apps+=("$d")
done < <(find . -maxdepth 3 -name package.json -not -path '*/node_modules/*' -not -path './.gatekit/*' | sort)
[ ${#apps[@]} -gt 0 ] || { [ -f package.json ] && apps=(.); }
APPS="${apps[*]:-.}"

has_test_script() { [ -f "$1/package.json" ] && jq -e '.scripts.test // empty' "$1/package.json" >/dev/null 2>&1; }
TEST_COMMAND=""
if has_test_script .; then
  TEST_COMMAND="npm test"
else
  parts=()
  for a in "${apps[@]}"; do has_test_script "$a" && parts+=("(cd $a && npm test)"); done
  [ ${#parts[@]} -gt 0 ] && TEST_COMMAND="$(printf '%s && ' "${parts[@]}")" && TEST_COMMAND="${TEST_COMMAND% && }"
fi

BASE="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
BASE="${BASE:-main}"

# ── 3. ticket tracker (optional) ──────────────────────────────────────────────
# Any tracker with a connection (MCP server) in Claude Code works. Without one, tickets are
# files on your branch and nothing else changes.
TRACKER="$(gk_cfg TRACKER_MCP)"
if [ -t 0 ] && command -v claude >/dev/null; then
  conns="$(claude mcp list 2>/dev/null | sed -nE 's/^[[:space:]]*([A-Za-z0-9_.-]+):[[:space:]].*/\1/p' | tr '\n' ' ')"
  if [ -n "${conns// /}" ]; then
    echo "  Tickets are files on your branch. Gatekit can also copy them to a ticket tracker"
    echo "  through one of your Claude Code connections: $conns"
    a=""
    read -r -p "  Which one is your ticket tracker? (Enter for ${TRACKER:-none}, or type none) " a
    case "$a" in "") ;; none|NONE) TRACKER="" ;; *) TRACKER="$a" ;; esac
    if [ -n "$TRACKER" ]; then
      case " $conns " in *" $TRACKER "*) ;; *) echo "  Note: '$TRACKER' isn't in that list. Check the name with: claude mcp list" ;; esac
    fi
    echo ""
  fi
fi

# ── 4. config.yaml ────────────────────────────────────────────────────────────
if [ -f "$GK_CONFIG" ] && ! ask "  .gatekit/config.yaml already exists. Replace it with what was detected?" n; then
  echo "  Keeping your config.yaml."
else
  cat > "$GK_CONFIG" <<EOF
# gatekit settings. Written by make gatekit-init; edit freely.

# Folders that hold your apps (each with its own package.json), separated by spaces.
APPS: $APPS

# The command that runs ALL your tests. Gatekit runs it after patching and during the gate.
TEST_COMMAND: $TEST_COMMAND

# The branch your pull requests merge into.
BASE_BRANCH: $BASE

# Optional: your ticket tracker's connection in Claude Code (a name from: claude mcp list).
# Set it and the review copies its tickets there. Empty = tickets stay as files only.
TRACKER_MCP: $TRACKER
EOF
fi

echo ""
echo "  .gatekit/config.yaml:"
grep -vE '^\s*(#|$)' "$GK_CONFIG" | sed 's/^/    /'
echo ""
for a in $(gk_cfg APPS); do
  [ -f "$a/package.json" ] || continue
  jq -r '.scripts.lint // ""' "$a/package.json" | grep -q '^eslint' \
    || echo "  ⚠ $a/package.json has no \"lint\": \"eslint ...\" script. make scans needs one to lint $a."
done
[ -n "$(gk_cfg TEST_COMMAND)" ] || echo "  ⚠ Couldn't find how to run your tests. Set TEST_COMMAND in .gatekit/config.yaml."
[ -n "$(gk_cfg TRACKER_MCP)" ] || echo "  No ticket tracker set: tickets are files on your branch. To copy them to a tracker later, set TRACKER_MCP."
echo "  If anything above is wrong, edit .gatekit/config.yaml."
echo ""

# ── 5. controls manifest ──────────────────────────────────────────────────────
CONTROLS="$GK_DIR/CONTROLS.md"
if [ -f "$CONTROLS" ]; then
  echo "  You already have a controls manifest (.gatekit/CONTROLS.md)."
else
  echo "  A controls manifest lists your app's security checks (login required, users only see"
  echo "  their own data, ...). With one, make gates-heavy breaks each check on purpose to prove"
  echo "  your tests catch it. It's optional; you can add it later by running this again."
  echo ""
  if ask "  Create a controls manifest now?" n; then
    cp "$GK_DIR/templates/CONTROLS.md" "$CONTROLS"
    if command -v claude >/dev/null && ask "  Let Claude read your code and fill it in for you to review?" y; then
      echo "  Claude is reading your code (this takes a minute or two)..."
      claude -p --permission-mode acceptEdits --allowedTools "Read Grep Glob Edit" <<EOF >/dev/null
Fill in the Controls table in .gatekit/CONTROLS.md for this repository.

Read the code under: $APPS. Find the real security checks: authentication middleware, role and
permission checks, per-user or per-tenant data scoping, last-admin guards, error handlers that hide
internals, log redaction, rate limiting, input validation.

For each one you actually find, write one row: plain-words description, \`file:functionName\` where
it is defined, and the test file that tests it (or \`-\` if there is none). Replace the example rows.
Delete example rows for checks this code doesn't have. Never invent a file or function: every
implementation must exist exactly as written. Edit only .gatekit/CONTROLS.md.
EOF
      echo ""
      echo "  Claude's draft (check every row — a wrong row proves nothing):"
      grep -E '^\| CM-' "$CONTROLS" | sed 's/^/    /'
    else
      echo "  Created .gatekit/CONTROLS.md from the template. Replace each <path>:<symbol> with your real code."
    fi
  else
    echo "  Skipped. The gate uses the generic checklist."
  fi
fi
echo ""

# ── 6. .claude files and .gitignore ───────────────────────────────────────────
gk_install_claude_files
touch .gitignore
for line in ".gatekit/.state/" ".gatekit/records/*/scan/"; do
  grep -qxF "$line" .gitignore || echo "$line" >> .gitignore
done
mkdir -p "$GK_STATE"; date +%s > "$GK_STATE/last-ok"

echo "  Done. Installed the gate reviewer and /implement into .claude/."
echo ""
echo "  Next:"
echo "    1. commit:  git add .gatekit .claude .gitignore Makefile && git commit -m 'add gatekit'"
echo "    2. on any branch:  make scans   then   make gates-light   (or make gates-heavy)"
echo ""
