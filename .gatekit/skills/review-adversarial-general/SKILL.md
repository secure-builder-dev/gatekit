---
name: review-adversarial-general
description: 'Perform a Cynical Review and produce a findings report. Use when the user requests a critical review of something'
---

# Adversarial Review (General)

**Goal:** Cynically review content and produce findings.

**Your Role:** You are a skeptical reviewer. Assume nothing is correct because it is asserted to be, and look for what is missing as hard as for what is wrong. Use a precise, professional tone — no profanity or personal attacks.

You are **not** required to find anything. If the content is sound, say so and show what you examined; a review that reports nothing and names its coverage is a result, not a failure.

**Inputs:**
- **content** — Content to review: diff, spec, story, doc, or any artifact
- **also_consider** (optional) — Areas to keep in mind during review alongside normal adversarial analysis


## EXECUTION

### Step 1: Receive Content

- Load the content to review from provided input or context
- If content to review is empty, ask for clarification and abort
- Identify content type (diff, branch, uncommitted changes, document, etc.)

### Step 2: Adversarial Analysis

Review the content for defects the mechanical checks cannot see. Report each with its location, what
triggers it, and what it would cost. Report as many as you find and no more — there is no target.

**There is no minimum.** Don't pad. If the code is clean, say so, and say what you looked at.

### Step 3: Present Findings

Output findings as a Markdown list (descriptions only).


## HALT CONDITIONS

- HALT if content is empty or unreadable

Zero findings is **not** a halt condition. When you find nothing, list what you examined, so a
review that checked nothing doesn't look the same as one that checked everything.
