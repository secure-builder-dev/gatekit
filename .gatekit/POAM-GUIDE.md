# POAM guide

A **POAM** (Plan of Action and Milestones) is the official list of security problems you can't fix
yet, with the reason why and the plan for fixing them.

## What gatekit does

When `make scans` finds a vulnerability with **no fix published yet**, it doesn't block your PR. It
writes the problem to:

```
.gatekit/records/<your-branch>/poam-candidates.md
```

Each entry has the CVE ID, the package, the version you have, how serious it is, and why there's
no fix.

## What you do

1. **Check it's really unfixable.** Is there a newer base image, or a different package that does
   the same job? If so, that's a fix. Do it.
2. **Copy the entries into your real POAM** by hand, the way your organisation does it.
3. **Write the mitigation.** Why the risk is acceptable for now: the vulnerable code isn't
   reachable, a firewall blocks it, it only matters on a feature you don't use, and so on.
   Claude can help you draft this wording. Give it only the CVE ID, package and version.

## The one rule

**Never open your real POAM file in an editor with an AI assistant running, and never paste it
into one.** Real POAMs contain system names, hostnames and device details that must stay offline.
`poam-candidates.md` is safe because it has only CVE IDs, package names and versions.
