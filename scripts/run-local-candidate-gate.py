#!/usr/bin/env python3
"""Run the MP-23 C1 installed local platform gate against a retained local context.

The gate runs the candidate's public `platform bootstrap plan` and `apply` through an
operator wrapper (an `env -i` script that pins XDG roots, the kubeconfig, the
platform payload and the candidate binary; see docs/runbooks/native-verification-harness.md).
It passes only when the review is verification-only, the accepted scope digests
and the idle head are unchanged, and it records a proof file.

    scripts/run-local-candidate-gate.py --operator-root /tmp/nagare-mp23-cp3.1EQ78L \\
        --wrapper /tmp/nagare-mp23-cp3.1EQ78L/runctl-db808a74.sh --revision db808a74 \\
        --payload nagare-0.4.0-705716b7bdb7 --colima-profile nagare-mp23-cp3

Take the cp3 claim before running it (the runbook's claim protocol); the apply step
writes verification journal entries to the shared store.
"""

import argparse
import collections
import hashlib
import json
import os
import signal
import subprocess
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--operator-root", type=Path, required=True)
    parser.add_argument("--wrapper", type=Path, required=True)
    parser.add_argument("--revision", required=True, help="candidate revision prefix the CLI must report")
    parser.add_argument("--payload", required=True, help="accepted payload id, e.g. nagare-0.4.0-705716b7bdb7")
    parser.add_argument("--context", default="local")
    parser.add_argument("--project", default="tan-nb-exp")
    parser.add_argument("--colima-profile", default="nagare-mp23-cp3")
    parser.add_argument("--evidence-dir", type=Path, help="new directory (default: <root>/candidate-<revision>-c1)")
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()

    os.umask(0o077)
    root = args.operator_root
    evidence = args.evidence_dir or root / f"candidate-{args.revision}-c1"
    evidence.mkdir(mode=0o700, parents=True, exist_ok=False)
    runner = ["bash", str(args.wrapper)]
    head_path = root / f"state/nagare/{args.context}/inventory/head.json"
    before = json.loads(head_path.read_text())
    assert before["binding"] == {"identity": args.context, "project": args.project}, before["binding"]
    version = json.loads(subprocess.check_output(runner + ["version", "--json"]))
    assert version["revision"].startswith(args.revision), version
    assert before["accepted"] == before["converged"], "accepted and converged differ before the gate"
    assert not any(before.get(k) for k in ["activeTransaction", "executorClaim", "dataFence", "migration"]), "store is not idle"
    (evidence / "before-head.json").write_text(json.dumps(before, indent=2) + "\n")
    profiles = subprocess.run(["colima", "list", "--json"], check=True, capture_output=True, text=True, timeout=20)
    running = {json.loads(line)["name"] for line in profiles.stdout.splitlines() if json.loads(line)["status"] == "Running"}
    assert running == {args.colima_profile}, f"exactly {args.colima_profile} must be running, found {running}"

    def run(label, command):
        started = time.monotonic()
        with (evidence / f"{label}.stdout").open("x") as out, (evidence / f"{label}.stderr").open("x") as err:
            process = subprocess.Popen(command, stdout=out, stderr=err, start_new_session=True, cwd=REPO)
            print(json.dumps({"step": label, "pid": process.pid}), flush=True)
            try:
                code = process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=15)
                code = 124
        result = {"exit": code, "seconds": round(time.monotonic() - started, 3)}
        (evidence / f"{label}.result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps({"step": label, **result}), flush=True)
        assert code == 0, f"{label} failed; private evidence retained in {evidence}"
        return result

    plan = run("plan", runner + ["platform", "bootstrap", "plan", "--out", str(evidence / "review")])
    review_raw = (evidence / "review/review.json").read_bytes()
    review = json.loads(review_raw)
    assert review["context"] == {"identity": args.context, "project": args.project}
    assert review["payloadIdentity"] == f"nagare-bootstrap:{args.payload}", review["payloadIdentity"]
    assert review["headGeneration"] == before["generation"] and review["headSequence"] == before["sequence"]
    actions = collections.Counter(entry["operation"]["action"]["tag"] for entry in review["operations"])
    (evidence / "actions.json").write_text(json.dumps(actions, indent=2) + "\n")
    assert set(actions) == {"VerifyResource"}, f"review is not verification-only: {dict(actions)}"
    assert not any(review.get(k) for k in ["barriers", "retentions", "collections", "migrations"])

    def content(entries):
        return {json.dumps(entry["scope"], sort_keys=True): entry["revision"]["digest"] for entry in entries}

    accepted = content(before["accepted"])
    assert all(accepted.get(scope) == digest for scope, digest in content(review["desiredRevisions"]).items()), \
        "a desired platform digest differs from accepted history"
    assert json.loads(head_path.read_text()) == before, "planning changed the head"
    apply = run("apply", runner + ["platform", "bootstrap", "apply", str(evidence / "review"), "--yes"])
    after = json.loads(head_path.read_text())
    assert content(after["accepted"]) == accepted and after["accepted"] == after["converged"]
    assert not any(after.get(k) for k in ["activeTransaction", "executorClaim", "dataFence", "migration"])
    assert after.get("retained") == before.get("retained") and after.get("collected") == before.get("collected")
    kubeconfig = root / f"config/nagare/kubeconfigs/{args.context}.yaml"
    pods = subprocess.run(["kubectl", "--kubeconfig", str(kubeconfig), "--context", args.context, "get", "pods", "-A",
                           "-o", "json", "--request-timeout=10s"], capture_output=True, text=True, check=True, timeout=30)
    items = json.loads(pods.stdout)["items"]

    def healthy(pod):
        status = pod.get("status", {})
        if status.get("phase") == "Succeeded":
            return True
        containers = status.get("containerStatuses", [])
        return len(containers) == len(pod["spec"]["containers"]) and all(c["ready"] for c in containers)

    unhealthy = [f"{p['metadata']['namespace']}/{p['metadata']['name']}" for p in items if not healthy(p)]
    proof = {
        "operatorRevision": version["revision"],
        "colimaProfile": args.colima_profile,
        "acceptedPayloadPreserved": args.payload,
        "gate": "MP-23 C1 installed public local platform bootstrap plan/apply on retained accepted cluster",
        "reviewDigest": hashlib.sha256(review_raw).hexdigest(),
        "operations": sum(actions.values()),
        "actions": sorted(actions),
        "providerMutations": 0,
        "planSeconds": plan["seconds"],
        "applySeconds": apply["seconds"],
        "acceptedScopeContentDigestsUnchanged": True,
        "head": {k: after.get(k) for k in ["generation", "sequence", "activeTransaction", "executorClaim"]},
        "acceptedScopeCount": len(after["accepted"]),
        "podsReadyOrSucceeded": len(items) - len(unhealthy),
        "podsNotReady": unhealthy,
        "freshCandidatePayloadBootstrap": False,
    }
    (evidence / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
    print(json.dumps(proof), flush=True)


if __name__ == "__main__":
    main()
