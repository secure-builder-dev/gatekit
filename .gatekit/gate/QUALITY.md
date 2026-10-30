# Test rules

What "the tests prove the code" means for the gate.

## 1. All tests pass

The whole suite passes. One failure is a failure.

No newly added `it.skip`, `xit`, `describe.skip` or `.only`, unless a ticket says why.

## 2. Coverage on the files you changed

This is measured only on the files this PR changed, not the whole project. If no app code changed,
it's skipped.

**Server code** (line coverage):

| Layer | Minimum |
|---|---|
| Services | 80% |
| Database access code | 80% |
| Route handlers | 70% |
| Middleware | 80% |

**UI code**:

| What | Minimum |
|---|---|
| Lines, in every changed UI file | 90% |
| Branches, in a changed file with 8 or more branches | 75% |
| Branches, across all changed UI files | 85% |

To change these numbers for your repo, edit this file in its own commit so reviewers see it.

## 3. The negative tests exist

For every route the PR adds or changes:

- **No token → 401.**
- **User A can't touch user B's record → 403 or 404.**
- **If the app has admins: the last admin can't be removed or demoted** (routes that deactivate or demote users).

## 4. Real database in integration tests

Integration tests run against a real database (a test container is fine). Mocking the database
there hides the bugs that matter most: wrong queries, missing constraints, broken transactions.
