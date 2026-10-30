#!/usr/bin/env bash
# sql-scan.sh — look for SQL built by gluing strings together (template literals or +) instead of using parameters. Mark a false positive on its line with: sql-scan: allow

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
cfg() {   # $1 = key in .gatekit/config.yaml
  [ -f .gatekit/config.yaml ] || return 0
  sed -nE "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"#]*)\"?[[:space:]]*(#.*)?$/\1/p" .gatekit/config.yaml | head -1 | sed -E 's/[[:space:]]+$//'
}
APPS="${GATEKIT_APPS:-$(cfg APPS)}"; APPS="${APPS:-.}"
# shellcheck disable=SC2086
if [ -z "$(git ls-files $APPS 2>/dev/null | grep -E '\.(ts|js)$' | head -1)" ]; then
  echo "sql-scan: nothing to scan — no .ts/.js files under $APPS"; exit 0
fi
TMP="$(mktemp)"
git ls-files $APPS | grep -E '\.(ts|js)$' | grep -v '/__tests__/\|\.test\.\|/test/' | while IFS= read -r f; do
  grep -nE '\.(query|raw|execute|unsafe)\([^)]*`[^`]*\$\{' "$f" 2>/dev/null | grep -v 'sql-scan: allow' | sed "s|^|  $f:|" | tee -a "$TMP"
  grep -nE '\.(query|raw|execute|unsafe)\([^)]*["'"'"'][^"'"'"']*["'"'"'][[:space:]]*\+[[:space:]]*[A-Za-z_]' "$f" 2>/dev/null | grep -v 'sql-scan: allow' | sed "s|^|  $f:|" | tee -a "$TMP"
done
if [ -s "$TMP" ]; then echo "sql-scan: $(wc -l < "$TMP" | tr -d ' ') string-built quer(y/ies) — use parameters"; rm -f "$TMP"; exit 1; fi
rm -f "$TMP"; echo "sql-scan: clean"
