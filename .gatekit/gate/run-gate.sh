#!/usr/bin/env bash
# run-gate.sh — `make gates-light` / `make gates-heavy`.
#
#   1. Make sure the scan is current for this commit (runs make scans if not).
#   2. Fetch the latest security rule sets (NIST 800-53, OWASP Top 10, DISA STIGs) and record
#      which edition is used. If the fetch fails, stop — never review against old rules quietly.
#   3. Run the mechanical checks: secrets, string-built SQL, and (heavy + CONTROLS.md) mutation.
#   4. Hand everything to the gate reviewer: Claude, in a fresh session (.claude/agents/gatekit-gate.md).
#      It writes tickets, sends them to Windshift, adds a gate-log line and writes the verdict.
#   5. Commit this branch's records and put the verdict in the PR description.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"

DEPTH="${1:-}"
case "$DEPTH" in light|heavy) ;; *) gk_die "usage: make gates-light | make gates-heavy" ;; esac
command -v claude >/dev/null || gk_die "the gate needs Claude Code ('claude' command) installed"
[ -f "$GK_ROOT/.claude/agents/gatekit-gate.md" ] || gk_die "gate reviewer not installed — run make gatekit-init"

mkdir -p "$GK_REC/tickets"
NOT_RECORDS=(. ':(exclude).gatekit/records' ':(exclude).gatekit/frameworks')

# ── 1. scan current? ──────────────────────────────────────────────────────────
stamp="$SCAN_RESULTS_DIR/.scan-stamp"
scanned="$(cut -d' ' -f1 "$stamp" 2>/dev/null)"
if [ -z "$scanned" ] || ! git cat-file -e "$scanned" 2>/dev/null \
   || [ -n "$(git diff --name-only "$scanned" HEAD -- "${NOT_RECORDS[@]}")" ] \
   || [ -n "$(git status --porcelain -- "${NOT_RECORDS[@]}" | grep -v '^??')" ]; then
  gk_say "the last scan isn't for this code — running make scans first"
  bash "$GK_DIR/scans.sh" || true
fi
SCAN_LINE="$(bash "$GK_DIR/scan/gate-line.sh" 2>/dev/null | tail -1)"

# ── 2. latest rule sets ───────────────────────────────────────────────────────
# Fetched at most once a day per machine (the STIG source is a large repo); every run records the edition used.
FW_STAMP="$GK_DIR/.state/frameworks-fetched"; mkdir -p "$GK_DIR/.state"
if [ "$(cat "$FW_STAMP" 2>/dev/null)" != "$(date +%F)" ]; then
  gk_say "fetching the latest security rule sets (once a day)"
  bash "$HERE/refresh-frameworks.sh" --adopt > "$GK_DIR/.state/frameworks-refresh.log" 2>&1; rc=$?
  if [ "$rc" -eq 1 ]; then
    sed 's/^/  /' "$GK_DIR/.state/frameworks-refresh.log" | tail -15
    gk_die "couldn't fetch the latest rule sets, so the gate won't run on old ones. Check your internet connection and try again."
  fi
  date +%F > "$FW_STAMP"
fi
FRAMEWORKS="$(python3 - "$GK_DIR/frameworks" <<'PY'
import hashlib, json, os, sys
d = sys.argv[1]
def ed(name, f, pick):
    p = os.path.join(d, f)
    if not os.path.exists(p): return f"{name} missing"
    raw = open(p, 'rb').read(); j = json.loads(raw)
    try: v = pick(j)
    except Exception: v = "?"
    return f"{name} {v} (sha {hashlib.sha256(raw).hexdigest()[:12]})"
print(", ".join([
  ed("NIST 800-53", "nist-800-53r5-index.json", lambda j: j.get("_catalog_version", "?")),
  ed("OWASP Top 10", "owasp-index.json", lambda j: j["web"]["current"]),
  ed("STIG", "stig-index.json", lambda j: "commit " + j.get("_redistributor_commit", "?")),
  ed("NIST pubs", "nist-pubs-index.json", lambda j: "retrieved " + j.get("_retrieved", "?")),
]))
PY
)"
if [ -n "$(git status --porcelain -- .gatekit/frameworks)" ]; then
  git add -- .gatekit/frameworks && git commit -q -m "gatekit: security rule sets updated" -- .gatekit/frameworks \
    && gk_say "rule sets changed since last run — committed the new editions"
fi

# ── 3. mechanical checks ──────────────────────────────────────────────────────
BASE_REF="origin/$GK_BASE"; git rev-parse -q --verify "$BASE_REF" >/dev/null || BASE_REF="$GK_BASE"
BASE="$(git merge-base "$BASE_REF" HEAD 2>/dev/null)" || gk_die "can't find where this branch split from $GK_BASE (set BASE_BRANCH in .gatekit/config.yaml)"
HEAD_SHA="$(git rev-parse HEAD)"
RANGE="$(git rev-parse --short "$BASE")..$(git rev-parse --short HEAD)"

SECRETS="$(bash "$HERE/secrets-scan.sh" 2>&1)"
SQL="$(bash "$HERE/sql-scan.sh" 2>&1)"
MUTATION="not run — light review"
if [ "$DEPTH" = heavy ]; then
  if [ -f "$GK_DIR/CONTROLS.md" ]; then
    gk_say "breaking each control in CONTROLS.md on purpose (this runs your tests once per control)"
    MUTATION="$(MUTATE_TEST_CMD="$GK_TEST_COMMAND" bash "$HERE/mutate-controls.sh" 2>&1 | tail -40)"
  else
    MUTATION="not run — no .gatekit/CONTROLS.md (optional; make gatekit-init can create one)"
  fi
fi

LOG="$GK_REC/gate-log.md"
[ -f "$LOG" ] || printf '| date | branch | range | run | depth | findings | tickets | verdict | rule sets | reviewer |\n|---|---|---|---|---|---|---|---|---|---|\n' > "$LOG"
RUNS="$(grep -c '^| 20' "$LOG" 2>/dev/null)"; RUN=$(( ${RUNS:-0} + 1 ))

# ── 4. the reviewer ───────────────────────────────────────────────────────────
rm -f "$GK_REC/verdict.md"
WS="$(gk_cfg WINDSHIFT_MCP)"
TOOLS="Bash Read Grep Glob Edit Write"
[ -n "$WS" ] && TOOLS="$TOOLS mcp__$WS"

PROMPT="$(cat <<EOF
GATEKIT REVIEW
depth:        $DEPTH
branch:       $GK_BRANCH
range:        $BASE..$HEAD_SHA   (short: $RANGE)
run:          $RUN
records:      ${GK_REC#$GK_ROOT/}
test command: ${GK_TEST_COMMAND:-NONE SET — say so; Part 1 cannot pass without running the tests}
windshift:    ${WS:-none configured — leave windshift_id empty and say so in the verdict}
reviewer:     $(git config user.email)
date:         $(date +%Y-%m-%d)

Files changed in the range:
$(git diff --stat "$BASE" HEAD -- "${NOT_RECORDS[@]}" | tail -40)

Scan: $SCAN_LINE
Rule sets: $FRAMEWORKS

Secrets check:
$SECRETS

SQL check:
$SQL

Mutation (control check):
$MUTATION

Open tickets already on this branch:
$(grep -l '^status: \(open\|claimed\|in-review\)' "$GK_REC"/tickets/*.md 2>/dev/null | xargs -I{} sh -c 'printf "  %s  %s\n" "$(basename {} .md)" "$(sed -n "s/^title: //p" {})"' || echo "  none")
EOF
)"

gk_say "Claude is reviewing $RANGE ($DEPTH) — run $RUN"
printf '%s\n' "$PROMPT" | claude -p --agent gatekit-gate --permission-mode acceptEdits --allowedTools "$TOOLS"
echo ""

# ── 5. record and publish ─────────────────────────────────────────────────────
[ -f "$GK_REC/verdict.md" ] || gk_die "the reviewer finished without writing a verdict (${GK_REC#$GK_ROOT/}/verdict.md). Run it again."
VERDICT="$(grep -oE 'GATEKIT VERDICT: (PASS|FAIL)' "$GK_REC/verdict.md" | head -1 | awk '{print $3}')"
gk_commit_records "gatekit: $DEPTH review run $RUN — ${VERDICT:-?}"

update_pr() {
  local body new start='<!-- gatekit:verdict -->' end='<!-- /gatekit:verdict -->'
  local block; block="$(printf '%s\n```\n%s\n```\n%s' "$start" "$(cat "$GK_REC/verdict.md")" "$end")"
  splice() { python3 -c '
import sys
body, block, s, e = sys.stdin.read(), sys.argv[1], sys.argv[2], sys.argv[3]
if s in body and e in body:
    a = body.index(s); b = body.index(e) + len(e)
    print(body[:a] + block + body[b:], end="")
else:
    print((body.rstrip() + "\n\n" if body.strip() else "") + block, end="")
' "$block" "$start" "$end"; }
  if command -v gh >/dev/null && gh pr view --json number >/dev/null 2>&1; then
    new="$(gh pr view --json body -q .body | splice)"
    printf '%s' "$new" | gh pr edit --body-file - >/dev/null && gk_say "verdict added to the PR description" && return 0
  elif command -v glab >/dev/null && glab mr view >/dev/null 2>&1; then
    new="$(glab mr view -F json 2>/dev/null | jq -r '.description // ""' | splice)"
    glab mr update --description "$new" >/dev/null && gk_say "verdict added to the MR description" && return 0
  fi
  gk_say "no open PR for $GK_BRANCH yet — the verdict is in ${GK_REC#$GK_ROOT/}/verdict.md and goes into the PR the next time the gate runs after you open it"
}
update_pr

[ "$VERDICT" = PASS ]
