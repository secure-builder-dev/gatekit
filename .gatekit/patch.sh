#!/usr/bin/env bash
# patch.sh — `make patch` (also run automatically by `make scans`).
#
#   1. Safe fixes together: `npm audit fix` and `eslint --fix` in each app, plus every
#      "npm install pkg@version" fix the scan named that is NOT a major version jump.
#      Run the tests. Green → one commit. Red → undo all of it.
#   2. Major version jumps, one at a time: install, test, commit if green, undo if red.
#   3. Re-scan. Whatever is still fixable becomes a ticket on this branch.
#
# Never commits while your tests are red. Only commits the files it changed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
. "$HERE/lib/tickets.sh"

D="$SCAN_RESULTS_DIR/dispatch.md"
[ -f "$D" ] || { gk_say "nothing to patch (run make scans first, or the last scan was clean)"; exit 0; }

# Only package and lint files are ever touched, so we can undo exactly what we changed.
PATCH_PATHS=()
for a in $GATEKIT_APPS; do
  [ -f "$a/package.json" ] && PATCH_PATHS+=("$a")
done
[ ${#PATCH_PATHS[@]} -gt 0 ] || { gk_say "no app folders with a package.json (APPS in .gatekit/config.yaml)"; GK_NO_PATCH=1 exec bash "$GK_DIR/scans.sh"; }

if ! git diff --quiet -- "${PATCH_PATHS[@]}" || ! git diff --cached --quiet -- "${PATCH_PATHS[@]}"; then
  gk_die "you have uncommitted changes in ${PATCH_PATHS[*]} — commit or stash them first, so patch only commits its own changes"
fi

undo()    { git checkout -q -- "${PATCH_PATHS[@]}"; git clean -fdq -- "${PATCH_PATHS[@]}" 2>/dev/null || true; }
changed() { ! git diff --quiet -- "${PATCH_PATHS[@]}"; }
commit()  { git add -A -- "${PATCH_PATHS[@]}"; git commit -q -m "$1" -- "${PATCH_PATHS[@]}" && gk_say "committed: $1"; }

# app_for PKG — the app folder whose package.json lists PKG (falls back to every app).
app_for() {
  local hits=()
  for a in "${PATCH_PATHS[@]}"; do grep -q "\"$1\"" "$a/package.json" && hits+=("$a"); done
  [ ${#hits[@]} -gt 0 ] && printf '%s\n' "${hits[@]}" || printf '%s\n' "${PATCH_PATHS[@]}"
}

# The fixes the scan named: "pkg@version" from the **Fix available:** lines.
SAFE=(); MAJOR=()
while IFS= read -r line; do
  spec="$(printf '%s' "$line" | sed -nE 's/.*Fix available:\*\*[[:space:]]*`([^` ]+)( \(major\))?`.*/\1/p')"
  [ -n "$spec" ] || continue
  case "$line" in *"(major)"*) MAJOR+=("$spec") ;; *) SAFE+=("$spec") ;; esac
done < "$D"
# Each fix once (a CVE found by two scanners is listed twice).
dedupe() { printf '%s\n' "$@" | awk 'NF && !seen[$0]++'; }
SAFE_U=(); while IFS= read -r x; do SAFE_U+=("$x"); done < <(dedupe ${SAFE[@]+"${SAFE[@]}"}); SAFE=(${SAFE_U[@]+"${SAFE_U[@]}"})
MAJOR_U=(); while IFS= read -r x; do MAJOR_U+=("$x"); done < <(dedupe ${MAJOR[@]+"${MAJOR[@]}"}); MAJOR=(${MAJOR_U[@]+"${MAJOR_U[@]}"})

# ── 1. safe fixes together ────────────────────────────────────────────────────
gk_say "step 1: npm audit fix, eslint --fix, and ${#SAFE[@]} named upgrade(s)"
for a in "${PATCH_PATHS[@]}"; do
  [ -f "$a/package-lock.json" ] && (cd "$a" && npm audit fix --no-fund --no-audit >/dev/null 2>&1) || true
  ls "$a"/eslint.config.* "$a"/.eslintrc* >/dev/null 2>&1 && (cd "$a" && npx --no-install eslint --fix . >/dev/null 2>&1) || true
done
for spec in ${SAFE[@]+"${SAFE[@]}"}; do
  pkg="${spec%@*}"
  for a in $(app_for "$pkg"); do (cd "$a" && npm install --no-fund --no-audit "$spec" >/dev/null 2>&1) || true; done
done

if changed; then
  if gk_run_tests; then
    commit "gatekit: patch — npm audit fix, eslint --fix${SAFE[*]:+, ${SAFE[*]}}"
  else
    gk_say "tests failed after the safe fixes — undoing them"
    undo
    gk_ticket "Patching broke the tests: ${SAFE[*]:-npm audit fix / eslint --fix}" blocking \
      "These upgrades are applied and the tests pass" \
      "make patch applied: npm audit fix, eslint --fix${SAFE[*]:+, ${SAFE[*]}}. The tests went red, so nothing was committed. Apply them by hand and fix whatever broke."
  fi
else
  gk_say "step 1 changed nothing"
fi

# ── 2. major version jumps, one at a time ─────────────────────────────────────
for spec in ${MAJOR[@]+"${MAJOR[@]}"}; do
  pkg="${spec%@*}"
  gk_say "step 2: trying major upgrade $spec"
  for a in $(app_for "$pkg"); do (cd "$a" && npm install --no-fund --no-audit "$spec" >/dev/null 2>&1) || true; done
  changed || { gk_say "  $spec: nothing changed"; continue; }
  if gk_run_tests; then
    commit "gatekit: patch — $spec (major)"
  else
    gk_say "  tests failed with $spec — undoing it"
    undo
    gk_ticket "Major upgrade breaks the tests: $spec" blocking \
      "$pkg is on $spec (or no longer flagged) and the tests pass" \
      "The scan says $pkg has a security fix in $spec. That's a major version jump, and installing it made the tests fail, so make patch undid it. Upgrade it by hand and fix what the new version changed."
  fi
done

# ── 3. re-scan; leftovers become tickets ──────────────────────────────────────
echo ""
gk_say "re-scanning after patch"
GK_NO_PATCH=1 bash "$GK_DIR/scans.sh"; rc=$?
gk_tickets_from_dispatch
gk_commit_records "gatekit: scan tickets"
exit "$rc"
