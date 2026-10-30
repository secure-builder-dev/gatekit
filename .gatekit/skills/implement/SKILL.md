---
name: implement
description: Fix one gatekit ticket on the current branch — write a failing test for its done_when, make it pass, commit. Use as `/implement T-003`. Tickets are in .gatekit/records/<branch>/tickets/.
---

# Fix a gatekit ticket

Argument: a ticket ID, like `T-003`.

## 1. Find and read the ticket

It's at `.gatekit/records/<branch>/tickets/T-003.md`, where `<branch>` is the current branch with
`/` replaced by `-` (`feature/login` → `feature-login`). If it isn't there, say so and stop.

`done_when` is the whole job. Read the body for where and why.

## 2. Claim it

In the ticket's front-matter, set `status: claimed`. If it says `claimed`, `in-review` or `done`
already, ask before going on.

## 3. Fix it, test first

1. **Write a test that fails** until `done_when` is true. Run it and watch it fail.
2. **Make it pass** with the smallest honest change. Then tidy up.
3. **Add the negative case** next to it: no token → 401, someone else's record → 403/404, or
   whatever this fix must never allow.
4. **Run the full test suite** (`TEST_COMMAND` in `.gatekit/config.yaml`). It has to stay green.
5. **Commit** with the ticket ID first: `T-003 require admin role on /api/admin`.

If you hit a decision the ticket doesn't answer, stop and ask, with options and your recommendation.

If the fix adds or changes a security check (login, roles, data scoping, log redaction) and the
repo has `.gatekit/CONTROLS.md`, add or update its row in the same commit.

## Never touch

Secrets and environment files (`.env*`), and deployment or CI configuration, unless the ticket is
about them. If the fix needs one of those changed, write what and why in the ticket under
`## Config change needed`, and do the rest.

## 4. Finish

When `done_when` is true and the suite is green:
- set the ticket to `status: in-review`
- commit the ticket file with the fix (or right after it)
- say in two lines what changed and which test proves it

The next gate run checks it and marks it `done` in Windshift.
