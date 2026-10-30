#!/usr/bin/env bash
# refresh-frameworks.sh — download the latest published security rule sets and rebuild the
# indexes in .gatekit/frameworks/ that the gate checks against.
#
#   NIST SP 800-53 rev 5        from NIST's official OSCAL catalogue
#   OWASP Top 10 (web and LLM)  from the OWASP project repos
#   DISA STIGs                  from ComplianceAsCode, which republishes them openly
#   NIST publication list       from NIST, to tell whether a cited SP/FIPS is current
#
# Always adopts what it downloads. If any source can't be reached it exits 1 and changes nothing
# for that source: the gate then refuses to run rather than quietly use old rules.
#
# Exit: 0 = all current or updated · 1 = a source could not be fetched or built
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1
SELF="$(cd "$(dirname "$0")" && pwd)"
OUT=".gatekit/frameworks"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAILED=0

# adopt NAME NEW_FILE DEST KEY — replace DEST with NEW_FILE when its KEY section differs.
adopt() {
  if [ -f "$3" ] && python3 -c 'import json,sys;a=json.load(open(sys.argv[1]));b=json.load(open(sys.argv[2]));k=sys.argv[3];sys.exit(0 if a.get(k)==b.get(k) else 1)' "$3" "$2" "$4"; then
    say "  $1: current"
  else
    cp "$2" "$3"; say "  $1: UPDATED"
  fi
}

clone() {   # clone URL DIR — shallow, quiet; 1 on failure
  git clone --depth 1 --filter=blob:none --quiet "$1" "$2" 2>"$TMP/err" && return 0
  say "  could not reach $1: $(head -1 "$TMP/err" 2>/dev/null)"; return 1
}

say "── security rule sets ─────────────────────────────────────────"

# NIST SP 800-53 rev 5
NIST_URL="https://raw.githubusercontent.com/usnistgov/oscal-content/main/nist.gov/SP800-53/rev5/json/NIST_SP-800-53_rev5_catalog.json"
if curl -sSL --fail --max-time 300 -o "$TMP/oscal.json" "$NIST_URL" 2>"$TMP/err" \
   && python3 "$SELF/build-control-index.py" "$TMP/oscal.json" "$TMP/nist.json" >/dev/null; then
  adopt "NIST 800-53" "$TMP/nist.json" "$OUT/nist-800-53r5-index.json" controls
else
  say "  NIST 800-53: could not fetch or build ($(head -1 "$TMP/err" 2>/dev/null))"; FAILED=1
fi

# OWASP Top 10 — web and LLM
if clone https://github.com/OWASP/Top10.git "$TMP/top10" \
   && clone https://github.com/OWASP/www-project-top-10-for-large-language-model-applications.git "$TMP/llm" \
   && python3 "$SELF/build-owasp-index.py" "$TMP/top10" "$TMP/llm" "$TMP/owasp.json" >/dev/null; then
  if [ -f "$OUT/owasp-index.json" ] && cmp -s <(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps({k:d[k] for k in ("web","llm")},sort_keys=True))' "$OUT/owasp-index.json") \
                                             <(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps({k:d[k] for k in ("web","llm")},sort_keys=True))' "$TMP/owasp.json"); then
    say "  OWASP Top 10: current"
  else
    cp "$TMP/owasp.json" "$OUT/owasp-index.json"; say "  OWASP Top 10: UPDATED"
  fi
else
  say "  OWASP Top 10: could not fetch or build"; FAILED=1
fi

# DISA STIGs
if clone https://github.com/ComplianceAsCode/content.git "$TMP/stig-src" \
   && python3 "$SELF/build-stig-index.py" "$TMP/stig-src" "$TMP/stig.json" >/dev/null; then
  adopt "DISA STIGs" "$TMP/stig.json" "$OUT/stig-index.json" rules
else
  say "  DISA STIGs: could not fetch or build"; FAILED=1
fi

# NIST publication list
if clone https://github.com/usnistgov/NIST-Tech-Pubs.git "$TMP/ntp" \
   && python3 "$SELF/build-nistpubs-index.py" "$TMP/ntp" "$TMP/pubs.json" >/dev/null; then
  adopt "NIST publications" "$TMP/pubs.json" "$OUT/nist-pubs-index.json" pubs
else
  say "  NIST publications: could not fetch or build"; FAILED=1
fi

exit "$FAILED"
