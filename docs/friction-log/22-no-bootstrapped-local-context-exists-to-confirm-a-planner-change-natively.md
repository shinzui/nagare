---
type: Friction Entry
title: "No bootstrapped local context exists to confirm a planner change natively"
description: "The plan's native steps need a local context bootstrapped on this tree's payload; the machine's local context is pinned to 0.1.0 in an agenix-managed file with no kubeconfig, and the warm drill context on the nagare-mp23 daemon has no discoverable NAGARE_DRILL_ROOT."
generated:
  by: "claude-code/claude-fable-5-2"
  at: "2026-11-24T06:04:56Z"
frictionId: FRIC-22
status: logged
impact: blocked
kind: environment
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare/docs/user/local-development.md"
plan: "docs/plans/280-make-out-of-band-kubernetes-edits-a-plan-time-decision-instead-of-a-mid-release-refusal.md"
workaround: "None; the native confirmation waits for the operator to name or allow rebuilding a disposable context"
---
# No bootstrapped local context exists to confirm a planner change natively

## Attempted

Running the plan's Concrete Steps (kubectl patch a Deployment, plan, take over) on a local context with the built nagarectl

## Encountered

platform status on the local context reports Context 0.1.0 against payload 0.28.2 and cannot read workloads; bootstrap refuses a pin that differs from the payload. A k3d-nagare-local cluster runs on the nagare-mp23 Colima daemon, but no document or state directory names the drill root that owns it, and rebuilding one needs NAGARE_DRILL_RESET=1 and images built on that daemon

```text
Context: 0.1.0 / Compatibility: minor-upgrade-required / shomei: unknown (cannot read workload objects: kubectl get deployments.apps failed)
```

## Workaround

None; the native confirmation waits for the operator to name or allow rebuilding a disposable context
