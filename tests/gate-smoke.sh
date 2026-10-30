#!/usr/bin/env bash
# gate-smoke.sh — run `make gates-light` with a fake `claude` that plays the reviewer.
#
# Proves the wiring around the reviewer, not the review itself:
#   - the handoff carries depth, range, run number, records folder, scan line and rule sets
#   - the reviewer is launched as the gatekit-gate agent
#   - a missing verdict is an error; a FAIL verdict exits 1; records get committed
#   - the run number goes up on the next run
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "GATE SMOKE FAIL: $*"; exit 1; }
pass() { echo "  ok: $*"; }

cd "$T"
git init -q -b main; git config user.email smoke@example.invalid; git config user.name smoke
mkdir -p backend && echo '{"name":"b","scripts":{"test":"true"}}' > backend/package.json
git add -A && git commit -qm base
git checkout -qb feature/x
echo 'module.exports = 1' > backend/index.js && git add -A && git commit -qm change

cp -R "$KIT/.gatekit" .gatekit; rm -rf .gatekit/records .gatekit/.state
printf 'APPS: backend\nTEST_COMMAND: true\nBASE_BRANCH: main\nWINDSHIFT_MCP:\n' > .gatekit/config.yaml
printf 'include .gatekit/Makefile.gatekit\n' > Makefile
printf '.gatekit/.state/\n.gatekit/records/*/scan/\n' > .gitignore
mkdir -p .claude/agents && cp .gatekit/agents/gatekit-gate.md .claude/agents/
git add -A && git commit -qm "add gatekit"

# Pretend the scan ran on this commit, and the rule sets were fetched today.
mkdir -p .gatekit/records/feature-x/scan .gatekit/.state
echo "$(git rev-parse HEAD) PASS now" > .gatekit/records/feature-x/scan/.scan-stamp
date +%F > .gatekit/.state/frameworks-fetched

# The fake reviewer: records its arguments and the handoff, writes a ticket, a log row and a verdict.
mkdir -p bin
cat > bin/claude <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$SMOKE_OUT/args"
cat > "$SMOKE_OUT/handoff"
rec="$(sed -nE 's/^records:[[:space:]]+//p' "$SMOKE_OUT/handoff")"
run="$(sed -nE 's/^run:[[:space:]]+//p' "$SMOKE_OUT/handoff")"
[ "${SMOKE_NO_VERDICT:-0}" = 1 ] && exit 0
mkdir -p "$rec/tickets"
printf -- '---\nid: T-00%s\ntitle: smoke finding %s\nstatus: open\n---\n' "$run" "$run" > "$rec/tickets/T-00$run.md"
echo "| 2026-01-01 | feature/x | a..b | $run | light | 1: T-00$run | T-00$run | FAIL | x | smoke |" >> "$rec/gate-log.md"
printf 'GATEKIT VERDICT: FAIL  ·  light  ·  run %s\n' "$run" > "$rec/verdict.md"
FAKE
chmod +x bin/claude
export PATH="$T/bin:$PATH" SMOKE_OUT="$T" GATEKIT_NO_UPDATE=1

SMOKE_NO_VERDICT=1 make gates-light >/dev/null 2>&1 && fail "a run with no verdict should fail"
pass "no verdict → error"

make gates-light > out1 2>&1; rc=$?
[ "$rc" -ne 0 ] || fail "a FAIL verdict should exit non-zero"
grep -q -- '--agent gatekit-gate' args || fail "reviewer not launched as gatekit-gate: $(cat args)"
for k in 'depth:        light' 'run:          1' 'records:      .gatekit/records/feature-x' 'Scan:' 'Rule sets: NIST 800-53'; do
  grep -qF "$k" handoff || fail "handoff missing '$k'"
done
pass "handoff has depth, run, records, scan and rule sets; agent is gatekit-gate"
[ "$(git log -1 --format=%s)" = "gatekit: light review run 1 — FAIL" ] || fail "records not committed: $(git log -1 --format=%s)"
git ls-files --error-unmatch .gatekit/records/feature-x/tickets/T-001.md >/dev/null 2>&1 || fail "ticket not committed"
pass "FAIL exits non-zero; ticket, log and verdict committed"
grep -q 'no open PR' out1 || fail "should say there is no PR yet: $(tail -3 out1)"
pass "no PR → says where the verdict is"

make gates-light > out2 2>&1
grep -qF 'run:          2' handoff || fail "second run should be run 2"
pass "run number advances"
echo "GATE SMOKE PASS"
