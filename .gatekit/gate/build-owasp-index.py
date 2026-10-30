#!/usr/bin/env python3
"""build-owasp-index.py — build the OWASP Top 10 index (web and LLM) the gate checks against.

OWASP renumbers between editions, so this keeps every edition's IDs and titles, and marks which
edition is current. Reads checkouts of github.com/OWASP/Top10 and the OWASP Top 10 for LLM
Applications repo; writes .gatekit/frameworks/owasp-index.json. Run by refresh-frameworks.sh.

Usage: build-owasp-index.py <Top10 checkout> <LLM Top 10 checkout> <out.json>
"""
import json, os, re, sys, datetime, subprocess

NAV = re.compile(r"^\s+-\s+(A\d{2})\s+(.+?):\s*'.*?'\s*$")
LLM = re.compile(r"^(LLM\d{2})_(.+)\.md$")


def split_camel(name):
    """SensitiveInformationDisclosure -> Sensitive Information Disclosure"""
    return re.sub(r"(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", " ", name).strip()


def web_editions(repo):
    """Every edition directory that ships an mkdocs.yml with a Top 10 nav."""
    out = {}
    for entry in sorted(os.listdir(repo)):
        cfg = os.path.join(repo, entry, "mkdocs.yml")
        if not (entry.isdigit() and os.path.isfile(cfg)):
            continue
        items = {}
        for line in open(cfg, encoding="utf-8", errors="replace"):
            m = NAV.match(line)
            if m:
                items[m.group(1)] = m.group(2).strip()
        if items:
            out[entry] = items
    return out


def llm_editions(repo):
    """2_0_vulns is the 2025 list. Older editions live in differently named directories."""
    out = {}
    for d, edition in (("2_0_vulns", "2025"), ("1_1_vulns", "2023")):
        path = os.path.join(repo, d)
        if not os.path.isdir(path):
            continue
        items = {}
        for fn in sorted(os.listdir(path)):
            m = LLM.match(fn)
            if m and m.group(1) != "LLM00":
                items[m.group(1)] = split_camel(m.group(2))
        if items:
            out[edition] = items
    return out


def head(repo):
    try:
        return subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"],
                              capture_output=True, text=True, timeout=20).stdout.strip()[:12]
    except Exception:
        return ""


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: build-owasp-index.py <Top10-repo> <llm-repo> <out.json>")
    t10, llm, out = sys.argv[1], sys.argv[2], sys.argv[3]

    web, lm = web_editions(t10), llm_editions(llm)
    if not web or not lm:
        sys.exit("build-owasp-index: no editions parsed — check the repository paths")

    doc = {
        "_retrieved": datetime.date.today().isoformat(),
        "_generator": ".gatekit/gate/build-owasp-index.py",
        "_sources": {
            "web": {"repo": "https://github.com/OWASP/Top10",
                    "commit": head(t10), "parsed_from": "<edition>/mkdocs.yml nav"},
            "llm": {"repo": "https://github.com/OWASP/www-project-top-10-for-large-language-model-applications",
                    "commit": head(llm), "parsed_from": "2_0_vulns/ filenames"},
        },
        "web": {"current": max(web), "editions": web},
        "llm": {"current": max(lm), "editions": lm},
    }
    json.dump(doc, open(out, "w"), indent=1, sort_keys=True)
    print(f"{out}: web editions {sorted(web)} (current {max(web)}), "
          f"llm editions {sorted(lm)} (current {max(lm)}), {os.path.getsize(out)//1024} KB")


if __name__ == "__main__":
    main()
