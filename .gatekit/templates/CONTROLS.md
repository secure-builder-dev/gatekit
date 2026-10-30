# Controls

This file lists your app's important security checks: the code that stops people doing things they shouldn't.

`make gates-heavy` uses it to **break each check on purpose** and run your tests. If your tests still pass with a check broken, nothing is really testing that check, and the gate tells you.

## How to fill it in

Each row is one security check:

| Column | What to put | Example |
|---|---|---|
| id | `CM-` and a number | `CM-01` |
| control | What it does, in plain words | Every `/admin` route needs the admin role |
| implementation | `file:function` where the check lives | `backend/src/middleware/auth.ts:requireRole` |
| required artifact | Optional: a config or deploy file the check depends on, or `-` | `-` |
| proving test | The test file that should fail if the check breaks | `backend/src/__tests__/auth.test.ts` |
| note | Optional. `mutate:middleware`, `mutate:decision`, `mutate:scope` or `mutate:redact` tells gatekit how to break it. Leave it empty and gatekit guesses from the function name. | `mutate:middleware` |

Rows whose implementation still says `<path>:<symbol>` are skipped. Delete the ones you don't have.

When you add a new security check to the code, add its row in the same commit.

## Controls

| id | control | implementation | required artifact | proving test | note |
|---|---|---|---|---|---|
| CM-01 | Every route needs a valid login token | `<path>:<symbol>` | - | `<test file>` | |
| CM-02 | Users only see their own records | `<path>:<symbol>` | - | `<test file>` | |
| CM-03 | Only allowed roles can do role-restricted actions | `<path>:<symbol>` | - | `<test file>` | |
| CM-04 | The last admin can't be removed or demoted (if the app has admins) | `<path>:<symbol>` | - | `<test file>` | |
| CM-05 | Errors never leak stack traces or internals | `<path>:<symbol>` | - | `<test file>` | |
| CM-06 | Secrets and personal data are kept out of logs | `<path>:<symbol>` | - | `<test file>` | |
| CM-07 | Rate limiting on login and other sensitive routes | `<path>:<symbol>` | - | `<test file>` | |
