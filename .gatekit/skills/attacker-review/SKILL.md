---
name: attacker-review
description: Read a pull request's diff the way someone trying to misuse the app would. For each changed way into the app, work out who can reach it and what they could get that they shouldn't. Used by the gatekit reviewer on heavy reviews.
---

# Attacker review

The checklist asks whether each security check is there. This review asks a different question:
**with these changes in place, what can someone get away with?**

You are given a commit range. Work from `git diff <range>`, and open the surrounding files whenever
you need to see how a changed line is reached.

## 1. List the ways in

Write down every way into the app that the diff adds or changes: routes, background jobs, webhooks,
file uploads and downloads, admin actions, anything that takes data from outside. If the diff
changes a shared helper (a middleware, a permission function, a query builder), list the ways in
that call it too, because they have all changed.

If the list is empty, say so and stop. That's a complete review.

## 2. Try each one as four people

For each way in, follow the request through the code as each of these people and note where they
are stopped. Give the `file:line` that stops them.

| Who | What they have |
|---|---|
| A stranger | No login at all. |
| An ordinary user | A valid login with the lowest role. |
| A user from somewhere else | A valid login, but for a different account, team or tenant than the record belongs to. |
| A former insider | A login that used to be allowed: a demoted admin, a deactivated user, a token issued before a password change. |

If you can't find the line that stops one of them, that's a finding.

## 3. Then try to get round it

A check that works when the app is used as intended can still fail when it isn't. For each way in,
ask:

- **Other people's IDs.** Swap every ID in the path, query and body for one that belongs to someone
  else. Is ownership checked on the record that's actually loaded, or only on the ID in the URL?
- **Fields nobody offered.** Add `role`, `ownerId`, `isAdmin`, `price`, `status` or similar to the
  body. Does the server ignore them, or save them?
- **Out of order.** Call step 3 without steps 1 and 2. Call the same step twice. Go back a step
  after finishing. Does the server know where this user really is in the flow?
- **Both at once.** Send the same request twice at the same moment. Can a one-time thing (redeem,
  approve, pay, delete the last admin) happen twice?
- **The side door.** Is there another route, an export, a search, a bulk action or a related record
  that returns or changes the same data with a weaker check?
- **What the answer gives away.** Do different errors, status codes or response times tell a
  stranger whether an account, email or record exists? Does the response include fields this
  person shouldn't see?
- **What they can make the server do.** Can user input decide a URL the server fetches, a file path
  it opens, a command or query it runs, or how much work or memory one request costs?
- **What sticks around.** After logout, a password change, a role change or a deletion, does old
  access (a token, a link, a cached page) still work?

Only ask what applies. A read-only public route doesn't need the "both at once" question.

## 4. Report

Report only what you traced in the code. "This might be vulnerable" is not a finding; "user B gets
user A's invoice because `getInvoice` loads by ID and never compares the owner" is.

One entry per finding:

```
<file:line>  blocking | non-blocking
Who:      <which of the four people, or a combination>
How:      <the requests they send, in order>
Gets:     <what they see or change that they shouldn't>
```

**Blocking** means someone gets data or power they shouldn't have. **Non-blocking** means it makes
an attack easier without giving anything away by itself.

Finish with one line listing the ways in you looked at, so a review that found nothing can be told
apart from a review that looked at nothing. No findings is a fine result. Don't pad.
