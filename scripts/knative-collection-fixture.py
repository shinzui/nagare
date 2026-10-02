#!/usr/bin/env python3
"""Derive the offline collection contract from frozen evidence; never contact a provider."""

import argparse
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    source = Path("docs/audits/mp23-native-bootstrap-results-2026-10-02/f15-knative-collection-exception-review.json")
    raw = (root / source).read_bytes()
    evidence = json.loads(raw)
    fixture = {
        "source": str(source),
        "sourceSha256": hashlib.sha256(raw).hexdigest(),
        "serverVersion": evidence["serverVersion"],
        "parentUid": evidence["deleteOptions"]["preconditions"]["uid"],
        "apis": evidence["descendantInspectionApiResources"],
        "descendants": evidence["observedDescendants"],
    }
    assert len(fixture["apis"]) == 75
    assert len(fixture["descendants"]) == 16
    rendered = json.dumps(fixture, indent=2) + "\n"
    target = root / "cli/nagarectl/test/fixtures/inventory/knative-collection-native.json"
    if args.check:
        assert target.read_text() == rendered, "native collection fixture drifted from frozen evidence"
        print("Native collection fixture matches frozen evidence: 16 descendants, 75 APIs")
    else:
        target.write_text(rendered)


if __name__ == "__main__":
    main()
