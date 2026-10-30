#!/usr/bin/env python3
"""build-stig-index.py — build the DISA STIG rule index the gate checks against.

DISA's STIGs are republished openly by the ComplianceAsCode project. This reads a checkout of
github.com/ComplianceAsCode/content and writes .gatekit/frameworks/stig-index.json: each STIG's
rule IDs and titles. Run by refresh-frameworks.sh.

Usage: build-stig-index.py <ComplianceAsCode checkout> <out.json>
"""
import glob, json, os, re, subprocess, sys, datetime
import xml.etree.ElementTree as ET

STIG_ID = re.compile(r"""^(?:
      [A-Z][A-Z0-9]{3}-\d{2}-\d{6}                      # RHEL-08-010000, OL07-00-010020, PGS9-00-…
    | [A-Z]{2,4}-[A-Z]{2}-\d{6}                          # CNTR-OS-000010, APSC-DV-002000
    | SRG-[A-Z]{2,3}-\d{6}(?:-[A-Z]{2,4}-\d{5,6})?      # SRG-APP-000001-AS-000001, SRG-OS-…-GPOS-…
  )$""", re.X)


def rules(path):
    """Yield (stig_id, title) from an XCCDF manual. The <version> element carries the STIG ID."""
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        return
    for rule in root.iter():
        if not rule.tag.endswith("}Rule"):
            continue
        ver = title = None
        for child in rule:
            if child.tag.endswith("}version"):
                ver = (child.text or "").strip()
            elif child.tag.endswith("}title"):
                title = (child.text or "").strip()
        if ver and STIG_ID.match(ver):
            yield ver, (title or "")


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: build-stig-index.py <ComplianceAsCode-repo> <out.json>")
    repo, out = sys.argv[1], sys.argv[2]
    refs = os.path.join(repo, "shared", "references")
    if not os.path.isdir(refs):
        sys.exit(f"build-stig-index: {refs} not found — is that a ComplianceAsCode checkout?")

    files = sorted(glob.glob(os.path.join(refs, "disa-*.xml")))
    manuals = {os.path.basename(f).replace("-xccdf-manual.xml", "") for f in files if f.endswith("-manual.xml")}
    idx, sources = {}, {}
    for f in files:
        base = os.path.basename(f)
        stem = base.replace("-xccdf-manual.xml", "").replace("-xccdf-scap.xml", "").replace(".xml", "")
        if base.endswith("-xccdf-scap.xml") and stem in manuals:
            continue
        n = 0
        for sid, title in rules(f):
            idx[sid] = {"t": title, "s": stem}
            n += 1
        if n:
            sources[stem] = n

    if not idx:
        sys.exit("build-stig-index: no STIG rules parsed — check the checkout")

    try:
        commit = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"],
                                capture_output=True, text=True, timeout=20).stdout.strip()[:12]
    except Exception:
        commit = ""

    doc = {
        "_retrieved": datetime.date.today().isoformat(),
        "_generator": ".gatekit/gate/build-stig-index.py",
        "_redistributor": "https://github.com/ComplianceAsCode/content",
        "_redistributor_commit": commit,
        "_publisher": "DISA; this index is built from the ComplianceAsCode redistribution",
        "_not_covered": ["DISA Application Security and Development STIG, APSC-DV-* (not redistributed here)",
                         "browser STIGs, e.g. Chrome DTBC-0001 / Firefox DTBF003 (id shape collides with prose)",
                         "end-of-life platforms, e.g. Ubuntu 20.04"],
        "_counts": {"rules": len(idx), "stigs": len(sources)},
        "sources": sources,
        "rules": idx,
    }
    json.dump(doc, open(out, "w"), indent=0, sort_keys=True)
    print(f"{out}: {len(idx)} rules from {len(sources)} STIGs, {os.path.getsize(out)//1024} KB")


if __name__ == "__main__":
    main()
