---
name: edge-case-hunt
description: Go through the code a pull request changed and find the unusual inputs and situations it doesn't deal with. Used by the gatekit reviewer on heavy reviews.
---

# Edge-case hunt

Most bugs live where the input or the timing isn't what the author pictured. This review goes
through the changed code and asks, for each piece, **"what happens when it isn't the normal case?"**

It isn't a style review and it isn't the attacker review. Don't comment on naming, structure or
whether you'd have written it differently. Only report a situation the code doesn't handle.

## Scope

You are given a commit range. Look at the lines `git diff <range>` changed and the functions those
lines are in. Follow a call into unchanged code only far enough to learn what it returns or throws.
Problems that were there before this range and that the range doesn't touch are out of scope.

## 1. For each changed function, list what it depends on

- every value that comes in: arguments, request fields, config, environment
- everything it reads: database rows, files, other services, the clock
- everything it changes: rows, files, messages sent, state kept in memory

## 2. Ask the questions that apply

**About each value**

- It's missing, `null` or `undefined`.
- It's empty: `""`, `[]`, `{}`, only spaces.
- It's zero, negative, a fraction, or far bigger than expected.
- It's the wrong type: a string where a number was expected, an array where one item was expected.
- It's right at the limit: the first item, the last item, exactly the maximum, one over.
- It's text with surprises: very long, accents or emoji, different upper and lower case, leading or
  trailing spaces.
- The same thing appears twice in a list.

**About each read**

- The record isn't there, or was deleted or archived.
- There are no results, or thousands more than expected.
- The other service is slow, down, or answers with an error or with something unexpected.
- Dates: midnight, the end of a month, a different time zone, a clock change.

**About each change**

- The function does two things and the second fails. Is the first undone, or left half done?
- It runs twice: a retry, a double click, a job that's redelivered. Is the result still right?
- Two requests run it at the same moment for the same record.
- The thing it's changing is already in the state it's being moved to.

**About the flow**

- A branch with no `else`, or a `switch` with no default: what happens to everything else?
- An error is caught and then ignored, or a promise isn't awaited.
- A loop over nothing, or an early `return` that skips clean-up.

Skip a question the code already answers, either in the function or in a check that always runs
before it. Say nothing about handled cases.

## 3. Report

One entry per unhandled case:

```
<file:line>  blocking | non-blocking
When:     <the input or situation, specific enough to write a test from>
Happens:  <what the code does now>
Should:   <one line: what it ought to do>
```

**Blocking** means wrong data is saved, the request crashes, or someone sees something they
shouldn't. **Non-blocking** means the result is unhelpful but harmless, like a vague error message.

Only report a case you can point to in the code and describe an input for. Finish with one line
naming the functions you went through. No findings is a fine result. Don't pad.
