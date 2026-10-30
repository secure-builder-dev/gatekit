# Security checklist

The gate goes through every item below on every review, light or heavy. For each one it either
points at the code that handles it (`file:line`) or says `N/A` and why.

## Logins and access

- [ ] **No secrets in the code.** No passwords, keys or tokens, including as "default" values in config.
- [ ] **Every route that should need a login does.** Public routes (health checks, the login flow
      itself) are listed on purpose, not by accident.
- [ ] **The login check runs before every route.** No route can be reached without going through it.
- [ ] **Roles are enforced on the server**, not just hidden in the UI.
- [ ] **Users can only see and change their own records** (or their team's, if that's the rule).
- [ ] **No way to give yourself more rights** (role, permissions, ownership) except through a route
      only admins can use.
- [ ] **If the app has admins: the last admin can't be removed or demoted.**
- [ ] **Login tokens and session cookies are stored safely**: cookies are `HttpOnly`, `Secure` and
      `SameSite`; tokens aren't kept in `localStorage`.

## Data

- [ ] **SQL uses parameters**, never strings glued together with user input.
- [ ] **Input is validated at every API route.** Unknown fields are rejected. Fields the server
      sets (IDs, timestamps, owner, role) can't be set by the client.
- [ ] **Deleted or archived records are filtered out** of normal queries, where the app has them.
- [ ] **Check-then-update races are prevented** (e.g. `SELECT ... FOR UPDATE` or a unique constraint)
      wherever two requests at once could both pass a check.
- [ ] **File uploads**, if any, are size-limited and type-checked, and file names from users are
      never used as paths.
- [ ] **Downloads check access.** A user can't fetch someone else's file by guessing or reusing a link.

## Errors and logs

- [ ] **Errors never leak internals**: no stack traces, database errors, file paths or internal
      messages in API responses.
- [ ] **No secrets, tokens or personal data in logs.**

## Browser

- [ ] **CORS allows only your own frontend's origin**, not `*`.
- [ ] **User content is escaped** when shown (no `dangerouslySetInnerHTML` / `innerHTML` with user data).

## Dependencies and containers

- [ ] **New packages** have no known high or critical CVE and no GPL/AGPL licence.
- [ ] **Containers don't run as root**, and Dockerfiles don't copy secrets in.

## Your own rules

- [ ] **Every check in `.gatekit/CONTROLS.md`** (if you have one) still exists and is still called.

---

## Control questions (heavy only)

A checklist asks whether a security check **exists**. These questions ask whether it **stops too
early**. On a heavy review, answer all six **in sentences** for each security check the PR touches
(login, roles, data scoping, logging/redaction, encryption, input validation). A question answered
with just "PASS" hasn't really been asked.

| # | Question | What it catches |
|---|---|---|
| 1 | Does the check look inside nested objects and arrays, or only top-level fields? | A "remove secrets" step that only cleans the outer object, so a secret nested inside gets saved anyway. |
| 2 | Is there a **second way** to change the same data, and is the check on both? | A role check on `POST` but not on `PATCH`, so you get there in two steps. |
| 3 | Which entry points does this check **not** cover? List them. | Data scoping that applies to `find` but not `count`, or not to joined records. |
| 4 | What does this check **not** verify? List it. | A token check that verifies the signature but not who the token was issued for. |
| 5 | Where in the running app is this check actually called? Give `file:line`. | A check that's written and tested but never wired in. |
| 6 | If it rejects bad input: is the schema strict, and is it actually used? | A validation schema that's written but never applied to the route. |

Write one block per security check:

```
CONTROL — <file>:<function>
  1 nested         : ...
  2 second path    : ...
  3 not covered    : <list>
  4 not verified   : <list>
  5 called from    : <file:line>
  6 strict + used  : ...
  → blocking: <what> | clear
```
