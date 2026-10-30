#!/usr/bin/env bash
# run-npm-audit.sh — npm audit for each app. High/Critical advisories in production dependencies block; dev-only ones and lower severities are reported. Exceptions go in .gatekit/npm-audit-allowlist.yaml with a reason, an owner and an expiry date.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROOT="${NPM_AUDIT_ROOT:-$PROJECT_ROOT}"
RESULTS_DIR="${SCAN_RESULTS_DIR:-$PROJECT_ROOT/.gatekit/records/scan-latest}"
ALLOWLIST="${NPM_AUDIT_ALLOWLIST:-$PROJECT_ROOT/.gatekit/npm-audit-allowlist.yaml}"
APPS="${NPM_AUDIT_APPS:-.}"
NPM="${NPM_AUDIT_NPM:-npm}"
TODAY="$(date -u +%Y-%m-%d)"
LOG="$RESULTS_DIR/audit.log"

# shellcheck source=scan-receipt.sh
. "$SCRIPT_DIR/scan-receipt.sh"

scan_begin npm-audit

say() { printf '%s\n' "$*" | tee -a "$LOG"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "[npm-audit] FAIL — jq is required. The scanner did not run."; exit 1
fi
if ! command -v "$NPM" >/dev/null 2>&1; then
  echo "[npm-audit] FAIL — '$NPM' not found on PATH. The scanner did not run."; exit 1
fi

mkdir -p "$RESULTS_DIR"
rm -f "$RESULTS_DIR/audit.json" "$RESULTS_DIR"/audit-*.json
: > "$LOG"

allow_json='[]'
if [ -f "$ALLOWLIST" ]; then
  allow_json=$(awk '
    function clean(v) { sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/["\047]/, "", v); sub(/[[:space:]]+#.*$/, "", v); sub(/[[:space:]]+$/, "", v); return v }
    function emit() { if (id != "") printf "%s\t%s\t%s\n", id, pkg, expiry }
    /^[[:space:]]*-[[:space:]]*id:/  { emit(); id = clean($0); pkg = ""; expiry = ""; next }
    /^[[:space:]]*package:/          { pkg = clean($0); next }
    /^[[:space:]]*expires:/          { expiry = clean($0); next }
    END { emit() }' "$ALLOWLIST" \
    | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {id: .[0], package: .[1], expires: (.[2] // "")})')
fi

ran=0; failed=0; apps_json='[]'
for app in $APPS; do
  dir="$ROOT/$app"
  if [ ! -f "$dir/package-lock.json" ]; then
    say "[npm-audit] $app: no package-lock.json — not an app dir here, skipped"
    continue
  fi
  safe="$(printf '%s' "$app" | tr '/.' '__')"
  raw="$RESULTS_DIR/audit-$safe.json"
  (cd "$dir" && "$NPM" audit --json > "$raw" 2>>"$LOG")
  if ! jq -e '.metadata.vulnerabilities' "$raw" >/dev/null 2>&1; then
    say "[npm-audit] FAIL — $app: npm audit produced no parseable report (see $LOG). The scanner did not run."
    failed=1
    continue
  fi
  prodraw="$RESULTS_DIR/audit-$safe-prod.json"
  (cd "$dir" && "$NPM" audit --omit=dev --json > "$prodraw" 2>>"$LOG")
  if jq -e '.metadata.vulnerabilities' "$prodraw" >/dev/null 2>&1; then
    prod_graded=true
  else
    prod_graded=false
    say "[npm-audit] $app: the --omit=dev pass produced no parseable report — grading every advisory as production-reachable (fail-safe)."
    prodraw=/dev/null
  fi
  ran=$((ran + 1))
  apps_json=$(jq -n --arg app "$app" --slurpfile raw "$raw" --slurpfile prod "$prodraw" \
                    --argjson graded "$prod_graded" --argjson apps "$apps_json" '
    ([ ($prod[0].vulnerabilities // {}) | to_entries[] | .key as $pkg | .value as $v
       | ($v.via // [])[] | select(type == "object")
       | ((.url // "" | split("/") | last) + "|" + $pkg) ] | unique) as $prodkeys
    | $apps + [{
      app: $app,
      prod_graded: $graded,
      prod_counts: ($prod[0].metadata.vulnerabilities // null),
      counts: $raw[0].metadata.vulnerabilities,
      advisories: ([ $raw[0].vulnerabilities | to_entries[] | .key as $pkg | .value as $v
                     | ($v.via // [])[] | select(type == "object")
                     | { app: $app,
                         id: (.url // "" | split("/") | last),
                         url: (.url // ""),
                         severity: (.severity // "unknown"),
                         package: $pkg,
                         range: (.range // ""),
                         title: (.title // ""),
                         direct: ($v.isDirect // false),
                         fix: ($v.fixAvailable
                               | if type == "object" then "\(.name)@\(.version)" + (if .isSemVerMajor then " (major)" else "" end)
                                 elif . == true then "available" else "none" end),
                         prod: (if $graded
                                then (((.url // "" | split("/") | last) + "|" + $pkg) as $k
                                      | ($prodkeys | index($k)) != null)
                                else true end) } ]
                   | unique_by(.id + "|" + .package)) }]')
done

[ "$failed" -eq 0 ] || exit 1
if [ "$ran" -eq 0 ]; then
  say "[npm-audit] FAIL — no app dir with a package-lock.json under $ROOT (looked for: $APPS). The scanner did not run."
  exit 1
fi

jq -n --argjson apps "$apps_json" --argjson allow "$allow_json" --arg today "$TODAY" '
  def rank: {critical: 4, high: 3, moderate: 2, low: 1, info: 0}[.] // 0;
  def iso: test("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$");
  ($apps | map(.advisories[])) as $all
  | ($allow | map(select((.expires | iso) and .expires >= $today))) as $live
  | ($allow | map(select(((.expires | iso) | not) or .expires < $today))) as $dead
  | def allowed: . as $c | any($live[]; .id == $c.id);
    { scanner: "npm-audit",
      generated: $today,
      policy: "High and Critical block when reachable in the production dependency tree; a High or Critical that is dev or build-time only is reported, not blocking; Moderate and Low are reported",
      apps: $apps,
      blocking:    [ $all[] | select((.severity | rank) >= 3) | select(.prod) | select(allowed | not) ],
      allowlisted: [ $all[] | select((.severity | rank) >= 3) | select(.prod) | select(allowed) ],
      dev_only:    [ $all[] | select((.severity | rank) >= 3) | select(.prod | not) ],
      expired_allowlist: $dead,
      reported:    [ $all[] | select((.severity | rank) < 3) ] }' > "$RESULTS_DIR/audit.json" 2>>"$LOG"

if ! jq -e '.blocking' "$RESULTS_DIR/audit.json" >/dev/null 2>&1; then
  rm -f "$RESULTS_DIR/audit.json"
  say "[npm-audit] FAIL — could not write the decision file (see $LOG). The scanner did not run."
  exit 1
fi

B=$(jq '.blocking | length' "$RESULTS_DIR/audit.json")
A=$(jq '.allowlisted | length' "$RESULTS_DIR/audit.json")
R=$(jq '.reported | length' "$RESULTS_DIR/audit.json")
E=$(jq '.expired_allowlist | length' "$RESULTS_DIR/audit.json")
D=$(jq '.dev_only | length' "$RESULTS_DIR/audit.json")
UNGRADED=$(jq -r '[.apps[] | select(.prod_graded | not) | .app] | join(", ")' "$RESULTS_DIR/audit.json")

say "[npm-audit] Results: $ran app(s) audited · $B blocking (High/Critical reachable in production, not allowlisted) · $A allowlisted · $D dev/build-only (High/Critical, reported) · $R reported (Moderate/Low, not blocking)"
[ -n "$UNGRADED" ] && say "[npm-audit] production grading UNAVAILABLE for: $UNGRADED — every advisory in those apps was treated as production-reachable (fail-safe)."
[ "$E" -gt 0 ] && say "[npm-audit] $E allowlist entr$([ "$E" -eq 1 ] && echo y || echo ies) expired, or carrying no date this scanner can read — no longer suppress anything: $(jq -r '[.expired_allowlist[].id] | join(", ")' "$RESULTS_DIR/audit.json")"
jq -r '.blocking[]    | "  BLOCKING  \(.app)  \(.id)  \(.severity)  \(.package) \(.range)  fix: \(.fix)"' "$RESULTS_DIR/audit.json" | tee -a "$LOG"
jq -r '.allowlisted[] | "  allowed   \(.app)  \(.id)  \(.severity)  \(.package) \(.range)  (allowlist entry, unexpired)"' "$RESULTS_DIR/audit.json" | tee -a "$LOG"
jq -r '.dev_only[]    | "  dev-only  \(.app)  \(.id)  \(.severity)  \(.package) \(.range)  fix: \(.fix)  (not in the production tree — reported, not blocking)"' "$RESULTS_DIR/audit.json" | tee -a "$LOG"
jq -r '.reported[]    | "  reported  \(.app)  \(.id)  \(.severity)  \(.package) \(.range)  fix: \(.fix)"' "$RESULTS_DIR/audit.json" | tee -a "$LOG"

if [ "$B" -gt 0 ]; then
  say "[npm-audit] FAIL — $B blocking advisor$([ "$B" -eq 1 ] && echo y || echo ies). Remedy: \`make patch\` for a non-major fix, a manual bump for a major; one with no fix needs an allowlist entry with a reason, an owner and an expiry ($ALLOWLIST)."
  exit 1
fi
scan_ran npm-audit "$ran app(s)"
say "[npm-audit] PASS — nothing blocking"
exit 0
