#!/usr/bin/env python3
"""Prove the UK PII regexes in yaml/34-uk-pii-guard.yaml actually work.

Run this before every rehearsal:

    python3 scripts/test-pii-regex.py

The patterns are read out of the YAML rather than duplicated here, so this tests
what the gateway is actually handed after YAML unquoting. That matters: the
patterns are written in a double-quoted YAML scalar, so "\\\\b" in the file becomes
"\\b" by the time anything compiles it. A comment claiming the regex is fine proves
nothing. This does.

Note on engines: the gateway is Rust and uses the regex crate, which has no
lookahead or lookbehind. Python's re is close enough for the features used here
(character classes, bounded repetition, word boundaries, inline case-insensitivity)
and it will reject anything that strays, because if you add a lookahead this script
will happily accept it and the gateway will not. Keep the patterns simple.
"""

import re
import sys
from pathlib import Path

YAML = Path(__file__).resolve().parent.parent / "yaml" / "34-uk-pii-guard.yaml"

# (label, specimen, should_match, why)
NI_CASES = [
    ("NI", "JM501345D", True, "canonical form"),
    ("NI", "JM 50 13 45 D", True, "spaced, as printed on an HMRC letter"),
    ("NI", "AB123456C", True, "valid prefix AB"),
    ("NI", "jm501345d", True, "lowercase, as a person types it"),
    ("NI", "my NI is JM501345D thanks", True, "embedded in prose"),
    ("NI", "DA123456A", False, "D is excluded in position 1"),
    ("NI", "QQ123456C", False, "Q is excluded in position 1"),
    ("NI", "JM501345E", False, "suffix must be A-D"),
    ("NI", "JO501345D", False, "O is excluded in position 2"),
    ("NI", "XJM501345DX", False, "must not match inside a longer token"),
    ("NI", "JM50134D", False, "only five digits"),
]

NHS_CASES = [
    ("NHS", "943 476 5919", True, "NHS published test number, 3-3-4"),
    ("NHS", "9434765919", True, "unspaced"),
    ("NHS", "943-476-5919", True, "hyphenated"),
    ("NHS", "patient 943 476 5919.", True, "embedded in prose"),
    ("NHS", "07700 900123", False, "Ofcom drama mobile, eleven digits"),
    ("NHS", "94347659199", False, "eleven digits, must not match a subrun"),
    ("NHS", "ref 12345", False, "short numeric reference"),
]


def patterns_from_yaml(path):
    """Pull the `matches:` regexes out of the policy, unquoted as YAML would."""
    try:
        import yaml as pyyaml
    except ImportError:
        pyyaml = None

    if pyyaml:
        doc = pyyaml.safe_load(path.read_text())
        guard = doc["spec"]["backend"]["ai"]["promptGuard"]
        found = []
        for phase in ("request", "response"):
            for item in guard.get(phase, []):
                found.extend(item.get("regex", {}).get("matches", []))
        return found

    # No PyYAML: fall back to reading the quoted scalars directly and applying the
    # one YAML escape that matters here.
    found = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line.startswith('- "') and line.endswith('"'):
            found.append(line[3:-1].replace("\\\\", "\\"))
    return found


def main():
    if not YAML.exists():
        sys.exit(f"cannot find {YAML}")

    pats = patterns_from_yaml(YAML)
    ni = [p for p in pats if "A-CEGHJ" in p]
    nhs = [p for p in pats if p.startswith("\\b[0-9]{3}")]

    if not ni or not nhs:
        sys.exit(
            f"expected to find both UK patterns in {YAML.name}, "
            f"got {len(ni)} NI and {len(nhs)} NHS out of {len(pats)} total"
        )

    # The request and response guards should carry identical patterns. If they have
    # drifted, the demo masks something on the way out that it did not reject on the
    # way in, which is confusing to explain live.
    if len(set(ni)) != 1 or len(set(nhs)) != 1:
        sys.exit("request and response guards have drifted apart, reconcile them")

    checks = [(ni[0], NI_CASES), (nhs[0], NHS_CASES)]
    failures = 0

    for pattern, cases in checks:
        label = cases[0][0]
        print(f"\n=== {label}\n    {pattern}")
        try:
            rx = re.compile(pattern)
        except re.error as exc:
            print(f"    DOES NOT COMPILE: {exc}")
            failures += len(cases)
            continue
        if "(?=" in pattern or "(?<" in pattern:
            print("    REJECTED: lookaround is not supported by the Rust regex crate")
            failures += 1
        for _, specimen, want, why in cases:
            got = rx.search(specimen) is not None
            ok = got == want
            failures += 0 if ok else 1
            print(
                f"  {'PASS' if ok else 'FAIL'}  "
                f"want={str(want):5} got={str(got):5}  {specimen!r:28} {why}"
            )

    print()
    if failures:
        print(f"{failures} failure(s). Do not rehearse act 4 until this is clean.")
        return 1
    print("All specimens behave. Act 4's regexes are sound.")
    print("Still send one real blocked request through the gateway: a passing")
    print("regex does not prove the guard is attached and enforcing.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
