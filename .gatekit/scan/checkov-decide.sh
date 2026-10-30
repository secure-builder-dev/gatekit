#!/usr/bin/env bash
# checkov-decide.sh — decide which Checkov failures block: every failed check blocks unless .gatekit/checkov-justifications.yaml has an unexpired entry for it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IN="${1:?usage: checkov-decide.sh <checkov.json>}"
JUST="${CHECKOV_JUSTIFICATIONS:-$PROJECT_ROOT/.gatekit/checkov-justifications.yaml}"
TODAY="$(date -u +%Y-%m-%d)"

command -v jq >/dev/null 2>&1 || { echo "[checkov] FAIL — jq is required to decide."; exit 1; }
if ! jq -e '.results.failed_checks' "$IN" >/dev/null 2>&1; then
  echo "[checkov] FAIL — $IN has no .results.failed_checks; nothing to decide on. The scanner did not run."
  exit 1
fi

just_json='[]'
if [ -f "$JUST" ]; then
  just_json=$(awk '
    function clean(v) { sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/["\047]/, "", v); sub(/[[:space:]]+#.*$/, "", v); sub(/[[:space:]]+$/, "", v); return v }
    function emit() { if (id != "") printf "%s\t%s\t%s\n", id, pth, expiry }
    /^[[:space:]]*-[[:space:]]*check_id:/ { emit(); id = clean($0); pth = ""; expiry = ""; next }
    /^[[:space:]]*path:/                  { pth = clean($0); next }
    /^[[:space:]]*expires:/               { expiry = clean($0); next }
    END { emit() }' "$JUST" \
    | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {check_id: .[0], path: (.[1] // ""), expires: (.[2] // "")})')
fi

tmp=$(mktemp)
jq --argjson just "$just_json" --arg today "$TODAY" '
  def iso: test("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$");
  ($just | map(select((.expires | iso) and .expires >= $today))) as $live
  | def glob_re($g): "^" + ($g | gsub("\\."; "\\.") | gsub("\\*"; ".*")) + "$";   # dot literal, star wildcard
    def covered_by($e): .check_id == $e.check_id and ($e.path == "" or ((.file_path // "") | test(glob_re($e.path))));
    def justified: . as $c | any($live[]; . as $e | $c | covered_by($e));
    .results.justified_checks      = [ .results.failed_checks[] | select(justified) ]
  | .results.failed_checks         = [ .results.failed_checks[] | select(justified | not) ]
  | .results.expired_justifications = ($just | map(select(((.expires | iso) | not) or .expires < $today)))
  | .summary.failed    = (.results.failed_checks | length)
  | .summary.justified = (.results.justified_checks | length)' "$IN" > "$tmp" 2>"$tmp.err"
if ! jq -e '.results.failed_checks' "$tmp" >/dev/null 2>&1; then
  echo "[checkov] FAIL — could not apply the justification list to $IN: $(head -3 "$tmp.err")"; rm -f "$tmp" "$tmp.err"; exit 1
fi
rm -f "$tmp.err"
mv "$tmp" "$IN"

B=$(jq '.results.failed_checks | length' "$IN")
J=$(jq '.results.justified_checks | length' "$IN")
E=$(jq '.results.expired_justifications | length' "$IN")
echo "[checkov] Decision: $B blocking (failed, not justified) · $J justified · severities are unrated (checkov emits none without a Prisma key), so every failed check counts"
[ "$E" -gt 0 ] && echo "[checkov] $E justification entr$([ "$E" -eq 1 ] && echo y || echo ies) expired, or carrying no date this script can read — no longer justif$([ "$E" -eq 1 ] && echo ies || echo y) anything: $(jq -r '[.results.expired_justifications[].check_id] | join(", ")' "$IN")"
jq -r '.results.failed_checks[]    | "  BLOCKING  \(.check_id)  \(.file_path // "?")  \(.resource // "")  \(.check_name // .check_description // "")"' "$IN"
jq -r '.results.justified_checks[] | "  justified \(.check_id)  \(.file_path // "?")  (justification entry, unexpired)"' "$IN"

if [ "$B" -gt 0 ]; then
  echo "[checkov] FAIL — $B unjustified failed check$([ "$B" -eq 1 ] || echo s). Fix the resource, suppress a per-resource false positive with a checkov.io/skip annotation carrying the reason, or add a bounded entry to $JUST."
  exit 1
fi
echo "[checkov] PASS — no unjustified failed checks"
exit 0
