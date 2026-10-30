#!/usr/bin/env bash
# mutation-smoke.sh — a tiny app with one control and one test. Mutation must break the control,
# see the test go red (proven), and put the file back exactly as it was.
set -uo pipefail
K="$(cd "$(dirname "$0")/.." && pwd)/.gatekit"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cd "$T" && git init -q && git config user.email t@example.invalid && git config user.name t
mkdir -p backend .gatekit/gate && cp "$K/gate/mutate-controls.sh" .gatekit/gate/
cat > backend/auth.js <<'JS'
function requireAuth(req, res, next) {
  if (!req.user) { res.status = 401; return; }
  next();
}
module.exports = { requireAuth };
JS
cat > backend/auth.test.js <<'JS'
const assert = require('assert');
const { requireAuth } = require('./auth');
const res = {}; let called = false;
requireAuth({}, res, () => { called = true; });
assert.strictEqual(res.status, 401); assert.strictEqual(called, false);
JS
printf '| id | control | implementation | required artifact | proving test | note |\n|---|---|---|---|---|---|\n| CM-01 | Login required | `backend/auth.js:requireAuth` | - | `backend/auth.test.js` | |\n' > .gatekit/CONTROLS.md
git add -A && git commit -qm x
out="$(MUTATE_TEST_CMD="cd backend && node auth.test.js" bash .gatekit/gate/mutate-controls.sh 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q '✓ proven' || { echo "MUTATION SMOKE FAIL: $out"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "MUTATION SMOKE FAIL: file not restored"; exit 1; }
echo "MUTATION SMOKE PASS"
