#!/usr/bin/env python3
"""Measure reviewed team-membership plan/apply latency (EP-221 M3).

Run inside the selected context's environment (`eval "$(nagarectl context env)"`) with
NAGARE_EN_API_KEY and KUBECONFIG exported. The benchmark user must already be a member of
the benchmark team: one untimed remove-member pair warms the caches, then each sample
times an add-member plan and apply, and every sample but the last is followed by an untimed
remove-member pair, so the membership ends as it began. Every saved review is checked to
hold exactly the expected operation before it is applied. A failed apply stops the run and
names its output; a stale-head refusal is recorded and the sample planned again.

  benchmark-reviewed-access.py run --nagarectl BIN --context intranet --team TEAM \\
      --user USER_ID --label baseline --output DIR [--samples 5] [--note TEXT]
  benchmark-reviewed-access.py compare BASELINE.json GROWN.json

No credential, header or environment value is written to the output.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import platform
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

PLAN_LIMIT = 5.0
APPLY_LIMIT = 15.0
STALE_RETRIES = 3
ITEM = re.compile(r"([a-z][a-z ]*?) (\d+)(?: \(([^)]*)\))?(?:, |$)")


def parse_items(body: str) -> dict:
    items = {}
    for name, count, detail in ITEM.findall(body.strip()):
        entry: dict = {"count": int(count)}
        if detail:
            seconds = re.fullmatch(r"([\d.]+) s", detail)
            transfer = re.fullmatch(r"(\d+) bodies, (\d+) bytes", detail)
            if seconds:
                entry["seconds"] = float(seconds.group(1))
            elif transfer:
                entry["bodies"] = int(transfer.group(1))
                entry["bytes"] = int(transfer.group(2))
        items[name.strip()] = entry
    return items


def parse_trace(stderr: str) -> dict:
    trace: dict = {}
    for line in stderr.splitlines():
        if not line.startswith("nagarectl trace: "):
            continue
        section, _, body = line[len("nagarectl trace: ") :].partition(": ")
        if section.startswith("stores"):
            wall = re.search(r"wall ([\d.]+) s", line)
            trace["wall"] = float(wall.group(1)) if wall else None
        elif body:
            trace[section] = parse_items(body)
    return trace


class Runner:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.raw = Path(args.output) / args.label
        self.raw.mkdir(parents=True, exist_ok=False)
        self.env = dict(os.environ, NAGARE_TRACE="1")
        self.step = 0

    def command(self, name: str, argv: list[str]) -> dict:
        self.step += 1
        stem = self.raw / f"{self.step:02d}-{name}"
        started = time.monotonic()
        done = subprocess.run(
            [self.args.nagarectl, "--context", self.args.context, *argv],
            env=self.env,
            capture_output=True,
            text=True,
        )
        seconds = round(time.monotonic() - started, 3)
        stem.with_suffix(".out").write_text(done.stdout)
        stem.with_suffix(".err").write_text(done.stderr)
        return {
            "step": self.step,
            "name": name,
            "argv": argv,
            "exit": done.returncode,
            "seconds": seconds,
            "trace": parse_trace(done.stderr),
            "stale": "stale-head" in done.stderr,
            "output": str(stem.with_suffix(".out").name),
        }

    def plan(self, verb: str, name: str) -> tuple[dict, Path]:
        review = self.raw / f"{self.step + 1:02d}-{name}-review"
        result = self.command(
            name,
            ["access", "team", verb, "--team", self.args.team, "--user", self.args.user, "--save-plan", str(review)],
        )
        if result["exit"] != 0:
            raise Stop(f"{name} refused; see {self.raw}/{result['output']}", result)
        expected = f"{'add' if verb == 'add-member' else 'remove'} {self.args.user} {'to' if verb == 'add-member' else 'from'} team {self.args.team}"
        operations = json.loads((review / "review.json").read_text())["operations"]
        summaries = [operation.get("summary") for operation in operations]
        if summaries != [expected]:
            raise Stop(f"{name} review holds {summaries}, not [{expected!r}]; nothing applied", result)
        return result, review

    def apply(self, review: Path, name: str) -> dict:
        return self.command(name, ["inventory", "apply", "--yes", str(review)])

    def pair(self, verb: str, name: str, failed: list) -> tuple[dict, dict]:
        for _ in range(STALE_RETRIES):
            plan, review = self.plan(verb, f"{name}-plan")
            applied = self.apply(review, f"{name}-apply")
            if applied["exit"] == 0:
                return plan, applied
            if not applied["stale"]:
                raise Stop(f"{name} apply failed; resume or recover from {self.raw}/{applied['output']}", applied)
            failed.append({"plan": plan, "apply": applied, "reason": "stale-head"})
        raise Stop(f"{name}: {STALE_RETRIES} stale-head refusals in a row", failed[-1]["apply"])


class Stop(Exception):
    def __init__(self, reason: str, result: dict) -> None:
        super().__init__(reason)
        self.result = result


def journal_cached(context: str) -> int | None:
    base = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    journal = base / "nagare" / context / "inventory-blobs" / "journal"
    return sum(1 for entry in journal.iterdir() if entry.is_file()) if journal.is_dir() else None


def invariants(kind: str, trace: dict) -> list[str]:
    store = trace.get("object store", {})
    phases = trace.get("phases", {})
    wanted = {"en forward": 1, "cluster guard": 1}
    if kind == "plan":
        wanted |= {"store opens": 1, "gcloud sessions": 1, "head reads": 1, "history loads": 1, "listings": 0}
    else:
        wanted |= {"listings": 0}
    problems = []
    for name, count in wanted.items():
        observed = (store.get(name) or phases.get(name) or {"count": 0})["count"]
        if observed != count:
            problems.append(f"{kind} {name} {observed}, expected {count}")
    return problems


def run(args: argparse.Namespace) -> int:
    for variable in ("NAGARE_EN_API_KEY", "KUBECONFIG"):
        if not os.environ.get(variable):
            print(f"benchmark: {variable} is not set; enter the context environment first", file=sys.stderr)
            return 2
    version = json.loads(subprocess.run([args.nagarectl, "version", "--json"], capture_output=True, text=True, check=True).stdout)
    runner = Runner(args)
    started = datetime.datetime.now(datetime.timezone.utc)
    result: dict = {
        "scenario": "reviewed access team add-member plan/apply (EP-221 M3)",
        "label": args.label,
        "context": args.context,
        "team": args.team,
        "user": args.user,
        "nagarectl": version,
        "machine": {"system": platform.system(), "machine": platform.machine(), "node": platform.node()},
        "note": args.note,
        "startedAt": started.isoformat(timespec="seconds"),
        "journalCachedBefore": journal_cached(args.context),
        "warmup": None,
        "samples": [],
        "cleanup": [],
        "failed": [],
    }
    status = 0
    try:
        plan, applied = runner.pair("remove-member", "warmup-remove", result["failed"])
        result["warmup"] = {"plan": plan, "apply": applied}
        for sample in range(1, args.samples + 1):
            plan, applied = runner.pair("add-member", f"sample{sample}-add", result["failed"])
            result["samples"].append({"sample": sample, "plan": plan, "apply": applied})
            if sample < args.samples:
                plan, applied = runner.pair("remove-member", f"sample{sample}-remove", result["failed"])
                result["cleanup"].append({"plan": plan, "apply": applied})
    except Stop as stop:
        result["stopped"] = {"reason": str(stop), "result": stop.result}
        status = 1
    result["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    result["journalCachedAfter"] = journal_cached(args.context)
    result["verdict"] = verdict(result)
    out = Path(args.output) / f"{args.label}.json"
    out.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"output": str(out), **result["verdict"]}, indent=2))
    return status or (0 if result["verdict"]["passed"] else 1)


def verdict(result: dict) -> dict:
    plans = [s["plan"]["seconds"] for s in result["samples"]]
    applies = [s["apply"]["seconds"] for s in result["samples"]]
    problems = [] if "stopped" not in result else [result["stopped"]["reason"]]
    if len(result["samples"]) < 5:
        problems.append(f"{len(result['samples'])} samples, expected at least 5")
    problems += [f"sample {s['sample']} plan {s['plan']['seconds']} s >= {PLAN_LIMIT} s" for s in result["samples"] if s["plan"]["seconds"] >= PLAN_LIMIT]
    problems += [f"sample {s['sample']} apply {s['apply']['seconds']} s >= {APPLY_LIMIT} s" for s in result["samples"] if s["apply"]["seconds"] >= APPLY_LIMIT]
    for s in result["samples"]:
        problems += [f"sample {s['sample']}: {p}" for p in invariants("plan", s["plan"]["trace"]) + invariants("apply", s["apply"]["trace"])]

    def summary(values: list[float]) -> dict:
        return {"values": values, "median": statistics.median(values), "min": min(values), "max": max(values)} if values else {}

    return {"passed": not problems, "problems": problems, "plan": summary(plans), "apply": summary(applies)}


def compare(args: argparse.Namespace) -> int:
    baseline = json.loads(Path(args.baseline).read_text())
    grown = json.loads(Path(args.grown).read_text())
    problems = [f"{run['label']}: {p}" for run in (baseline, grown) for p in run["verdict"]["problems"]]
    for field in ("context", "team", "user"):
        if baseline[field] != grown[field]:
            problems.append(f"{field} differs: {baseline[field]} / {grown[field]}")
    if baseline["nagarectl"] != grown["nagarectl"] or baseline["machine"] != grown["machine"]:
        problems.append("release or machine differs")
    growth = {}
    for kind in ("plan", "apply"):
        base = baseline["verdict"][kind].get("median")
        new = grown["verdict"][kind].get("median")
        if base is None or new is None:
            continue
        allowed = round(base + max(0.25, 0.05 * base), 3)
        growth[kind] = {"baselineMedian": base, "grownMedian": new, "allowedMedian": allowed}
        if new > allowed:
            problems.append(f"{kind} median {new} s exceeds {allowed} s")
    report = {"passed": not problems, "problems": problems, "growth": growth}
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="mode", required=True)
    measure = commands.add_parser("run")
    measure.add_argument("--nagarectl", required=True)
    measure.add_argument("--context", required=True)
    measure.add_argument("--team", required=True)
    measure.add_argument("--user", required=True)
    measure.add_argument("--label", required=True)
    measure.add_argument("--output", required=True)
    measure.add_argument("--samples", type=int, default=5)
    measure.add_argument("--note", default="")
    judge = commands.add_parser("compare")
    judge.add_argument("baseline")
    judge.add_argument("grown")
    args = parser.parse_args()
    return run(args) if args.mode == "run" else compare(args)


if __name__ == "__main__":
    sys.exit(main())
