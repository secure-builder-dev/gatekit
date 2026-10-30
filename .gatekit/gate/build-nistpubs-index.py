#!/usr/bin/env python3
"""build-nistpubs-index.py — which revision of each NIST SP and FIPS is the current one.

Reads a checkout of github.com/usnistgov/NIST-Tech-Pubs and writes
.gatekit/frameworks/nist-pubs-index.json, so the gate can tell a current publication from a
superseded one. Drafts are listed separately and never counted as current. Run by
refresh-frameworks.sh.

Usage: build-nistpubs-index.py <NIST-Tech-Pubs checkout> <out.json>
"""
import datetime, json, os, re, subprocess, sys

NAME = re.compile(r"^NIST\.(SP|FIPS)\.(\d.*?)(?:r(\d+))?(?:\.(ipd|fpd|2pd|3pd|upd\d*))?\.ris$")


def names(repo):
    """Filenames under bib/, straight from the git tree — no blobs are fetched."""
    out = subprocess.run(["git", "-C", repo, "ls-tree", "-r", "--name-only", "HEAD", "--", "bib/"],
                         capture_output=True, text=True, timeout=180)
    if out.returncode != 0:
        sys.exit(f"build-nistpubs-index: git ls-tree failed — {out.stderr.strip()[:200]}")
    return [os.path.basename(l) for l in out.stdout.splitlines() if l.endswith(".ris")]


def head(repo):
    try:
        return subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"],
                              capture_output=True, text=True, timeout=20).stdout.strip()[:12]
    except Exception:
        return ""


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: build-nistpubs-index.py <NIST-Tech-Pubs-repo> <out.json>")
    repo, out = sys.argv[1], sys.argv[2]
    if not os.path.isdir(os.path.join(repo, ".git")):
        sys.exit(f"build-nistpubs-index: {repo} is not a git checkout")

    pubs = {}
    for fn in names(repo):
        m = NAME.match(fn)
        if not m:
            continue
        series, number, rev, stage = m.group(1), m.group(2), m.group(3), m.group(4)
        key = f"{series} {number}"
        e = pubs.setdefault(key, {"revisions": [], "drafts": []})
        label = f"r{rev}" if rev else ""
        if stage:
            e["drafts"].append(f"{label}.{stage}" if label else stage)
        elif label not in e["revisions"]:
            e["revisions"].append(label)

    if len(pubs) < 100:
        sys.exit(f"build-nistpubs-index: only {len(pubs)} publications parsed — bib/ has changed shape")

    for e in pubs.values():
        e["revisions"].sort(key=lambda r: int(r[1:]) if r else 0)
        e["drafts"].sort()
        e["latest"] = e["revisions"][-1] if e["revisions"] else ""

    doc = {
        "_retrieved": datetime.date.today().isoformat(),
        "_generator": ".gatekit/gate/build-nistpubs-index.py",
        "_source": {
            "repo": "https://github.com/usnistgov/NIST-Tech-Pubs",
            "commit": head(repo),
            "parsed_from": "bib/ filenames via git ls-tree (blobless clone; no file contents read)",
        },
        "_note": ("`latest` is the newest PUBLISHED revision. Drafts (.ipd/.fpd/.2pd) are listed "
                  "separately and never counted as one — citing a draft as current would point a "
                  "project at a document that does not exist yet."),
        "_counts": {"publications": len(pubs)},
        "pubs": dict(sorted(pubs.items())),
    }
    json.dump(doc, open(out, "w"), indent=0, sort_keys=True)
    print(f"{out}: {len(pubs)} NIST publications, {os.path.getsize(out)//1024} KB")


if __name__ == "__main__":
    main()
