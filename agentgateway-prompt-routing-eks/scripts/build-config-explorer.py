#!/usr/bin/env python3
"""Generate this lab's config explorer on index.html from the real yaml/ files.

Config shown on a page has to come from its source or the page drifts away from what is
deployed. This reads yaml/*.yaml and yaml-oss/*.yaml, groups them, sanitises anything
that should not be published, and writes the JSON into the <script id="cfg-data"> block
in index.html. Wired into the pre-commit hook so it regenerates when the yaml changes.

Run: python3 scripts/build-config-explorer.py
"""
import json, pathlib, re, sys

LAB = pathlib.Path(__file__).resolve().parents[1]
PAGE = LAB / "index.html"

# (directory, filename prefix) -> (category key, category label). Order here is the
# order the categories appear on the page, which follows the deploy steps rather than
# the filename sort, because that is the order a reader meets them.
GROUPS = [
    ("models",  "The models",        ["00-", "01-"]),
    ("gateway", "Gateway routing",   ["10-", "20-", "30-"]),
    ("kagent",  "kagent agents",     ["40-", "50-", "60-"]),
    ("vsr",     "Semantic router",   ["70-", "80-", "81-"]),
]

# Nothing in this lab carries a credential, but the page is public, so scrub the shapes
# that would matter if one ever appeared. An account id in a bucket name is the realistic
# one: the parent lab derives it at run time and the yaml here should never hardcode it.
SCRUB = [
    (re.compile(r"\b\d{12}\b"), "<AWS_ACCOUNT_ID>"),
    (re.compile(r"(?i)(password|secret|token|apikey|api_key)(\s*:\s*)(?!\s*$)[^\s#]+"),
     r"\1\2<redacted>"),
]

def scrub(text: str) -> str:
    for pat, rep in SCRUB:
        text = pat.sub(rep, text)
    return text

def collect(subdir: str):
    d = LAB / subdir
    if not d.is_dir():
        return {}
    out = {}
    for f in sorted(d.glob("*.yaml")):
        out[f.name] = scrub(f.read_text(encoding="utf-8"))
    return out

def main() -> int:
    ent = collect("yaml")
    oss = collect("yaml-oss")
    if not ent:
        print("no yaml/ found", file=sys.stderr)
        return 1

    cats = []
    placed = set()
    for key, label, prefixes in GROUPS:
        items = []
        for name in sorted(ent):
            if any(name.startswith(p) for p in prefixes):
                items.append({
                    "file": f"yaml/{name}",
                    "tab": name,
                    "yaml": ent[name],
                    # The OSS variant rides along on the same entry so the page can offer
                    # a toggle rather than duplicating the whole tree.
                    "oss": oss.get(name),
                })
                placed.add(name)
        if items:
            cats.append({"cat": key, "label": label, "items": items})

    leftover = sorted(set(ent) - placed)
    if leftover:
        cats.append({"cat": "other", "label": "Other",
                     "items": [{"file": f"yaml/{n}", "tab": n, "yaml": ent[n],
                                "oss": oss.get(n)} for n in leftover]})

    blob = json.dumps(cats, separators=(",", ":"), ensure_ascii=False)
    page = PAGE.read_text(encoding="utf-8")
    new, n = re.subn(
        r'(<script id="cfg-data" type="application/json">).*?(</script>)',
        lambda m: m.group(1) + blob + m.group(2),
        page, count=1, flags=re.S)
    if not n:
        print('no <script id="cfg-data"> block in index.html', file=sys.stderr)
        return 1
    if new != page:
        PAGE.write_text(new, encoding="utf-8")
    files = sum(len(c["items"]) for c in cats)
    withoss = sum(1 for c in cats for i in c["items"] if i["oss"])
    print(f"build-config-explorer: {files} config files across {len(cats)} categories, "
          f"{withoss} with an OSS variant")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
