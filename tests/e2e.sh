#!/usr/bin/env bash
# e2e.sh — install gatekit into a throwaway sample app and run `make scans` for real.
#
# The sample has one known-vulnerable package (lodash 4.17.20, CVE-2021-23337, fixed in 4.17.21).
# Passes when:
#   - make gatekit-init writes a config with the right app folder and test command
#   - make scans finds the lodash CVE, make patch upgrades it, the tests pass, and it's committed
#   - the final scan verdict line is printed and the records folder exists
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "E2E FAIL: $*"; exit 1; }
pass() { echo "  ok: $*"; }

cd "$T"
git init -q -b main
git config user.email e2e@example.invalid; git config user.name e2e
mkdir -p backend
cat > backend/package.json <<'EOF'
{ "name": "sample-backend", "version": "1.0.0", "private": true,
  "scripts": { "test": "node test.js", "lint": "eslint ." },
  "dependencies": { "lodash": "4.17.20" },
  "devDependencies": { "eslint": "^9.0.0" } }
EOF
cat > backend/index.js <<'EOF'
const _ = require('lodash');
module.exports = { total: (xs) => _.sum(xs) };
EOF
cat > backend/test.js <<'EOF'
const assert = require('assert');
assert.strictEqual(require('./index').total([1, 2, 3]), 6);
console.log('tests passed');
EOF
cat > backend/eslint.config.js <<'JS'
module.exports = [{ files: ['**/*.js'], languageOptions: { sourceType: 'commonjs', globals: { require: 'readonly', module: 'writable', console: 'readonly' } } }];
JS
cat > backend/Dockerfile <<'EOF'
FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY . .
USER node
CMD ["node", "index.js"]
EOF
(cd backend && npm install --no-fund --no-audit >/dev/null 2>&1) || fail "npm install in the sample"
git add -A && git commit -qm "sample app"
git checkout -qb feature/demo

cp -R "$KIT/.gatekit" .gatekit
rm -rf .gatekit/records .gatekit/.state .gatekit/config.yaml .gatekit/CONTROLS.md
printf 'include .gatekit/Makefile.gatekit\n' > Makefile
export GATEKIT_NO_UPDATE=1

echo "── make gatekit-init"
make gatekit-init < /dev/null || fail "gatekit-init exited non-zero"
grep -q '^APPS: backend$' .gatekit/config.yaml || fail "APPS not detected: $(grep APPS .gatekit/config.yaml)"
grep -q '^TEST_COMMAND: (cd backend && npm test)$' .gatekit/config.yaml || fail "TEST_COMMAND not detected: $(grep TEST_COMMAND .gatekit/config.yaml)"
[ -f .claude/agents/gatekit-gate.md ] && [ -f .claude/skills/implement/SKILL.md ] || fail ".claude files not installed"
[ ! -f .gatekit/CONTROLS.md ] || fail "CONTROLS.md created without being asked"
pass "init detected the app and test command, installed .claude files"
git add -A && git commit -qm "add gatekit"

echo "── make scans"
make scans; rc=$?
echo "(make scans exit $rc)"

[ "$(git log --format=%s | grep -c '^gatekit: patch')" -gt 0 ] || fail "no patch commit (log: $(git log --format=%s | head -5 | tr '\n' '|'))"
v="$(jq -r .version backend/node_modules/lodash/package.json)"
[ "$v" != 4.17.20 ] || fail "lodash not upgraded (still $v)"
pass "make patch upgraded lodash and committed: $(git log --format=%s | grep '^gatekit: patch' | head -1)"

[ -f .gatekit/records/feature-demo/scan-verdict.txt ] || fail "no scan verdict in records"
git ls-files --error-unmatch .gatekit/records/feature-demo/scan-verdict.txt >/dev/null 2>&1 || fail "scan records not committed"
[ -z "$(git ls-files .gatekit/records/feature-demo/scan)" ] || fail "raw scanner output was committed (should be gitignored)"
pass "verdict: $(cat .gatekit/records/feature-demo/scan-verdict.txt)"
[ -n "$(git status --porcelain | grep -v '^??')" ] && fail "patch left uncommitted changes: $(git status --porcelain)"
pass "tree clean after patch"
echo "E2E PASS"
