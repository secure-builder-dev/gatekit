#!/usr/bin/env python3
"""build-control-index.py — build the NIST SP 800-53 rev 5 index the gate checks against.

Reads NIST's OSCAL catalogue JSON and writes .gatekit/frameworks/nist-800-53r5-index.json:
every control and enhancement ID with its title and status (withdrawn controls name what
replaced them). Run by refresh-frameworks.sh.

Usage: build-control-index.py <NIST_SP-800-53_rev5_catalog.json> <out.json>
"""
import json, hashlib, datetime, sys, os


def fmt(oscal_id):
    """ac-3.7 -> AC-3(7). Enhancements nest, so every dotted segment becomes a parenthesis."""
    parts = oscal_id.split(".")
    return parts[0].upper() + "".join(f"({p})" for p in parts[1:])


def walk(ctrl, idx):
    props = ctrl.get("props", [])
    status = next((p["value"] for p in props if p["name"] == "status"), "active")
    into = [fmt(l["href"].lstrip("#")) for l in ctrl.get("links", []) if l.get("rel") == "incorporated-into"]
    entry = {"t": ctrl.get("title", ""), "s": status}
    if into:
        entry["into"] = into
    idx[fmt(ctrl["id"])] = entry
    for child in ctrl.get("controls", []):
        walk(child, idx)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: build-control-index.py <oscal-catalog.json> <out-index.json>")
    src, out = sys.argv[1], sys.argv[2]
    raw = open(src, "rb").read()
    catalog = json.loads(raw)["catalog"]
    md = catalog["metadata"]

    idx = {}
    for group in catalog.get("groups", []):
        for ctrl in group.get("controls", []):
            walk(ctrl, idx)

    withdrawn = sum(1 for v in idx.values() if v["s"] != "active")
    doc = {
        "_source": "https://raw.githubusercontent.com/usnistgov/oscal-content/main/"
                   "nist.gov/SP800-53/rev5/json/NIST_SP-800-53_rev5_catalog.json",
        "_catalog_title": md["title"],
        "_catalog_version": md.get("version"),
        "_catalog_last_modified": md.get("last-modified"),
        "_source_sha256": hashlib.sha256(raw).hexdigest(),
        "_retrieved": datetime.date.today().isoformat(),
        "_generator": ".gatekit/gate/build-control-index.py",
        "_counts": {"controls": len(idx), "withdrawn": withdrawn},
        "controls": idx,
    }
    json.dump(doc, open(out, "w"), indent=0, sort_keys=True)
    print(f"{out}: {len(idx)} controls, {withdrawn} withdrawn, "
          f"{os.path.getsize(out)//1024} KB, catalogue {md.get('version')}")


if __name__ == "__main__":
    main()
