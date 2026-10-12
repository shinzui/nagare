---
id: 140
slug: make-clone-free-platform-upgrades-carry-release-pinned-operator-tools
title: "Make clone-free platform upgrades carry release-pinned operator tools"
kind: exec-plan
created_at: 2026-09-15T14:04:02Z
intention: "intention_01m2jp34dpemna40herdgrt346"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-15T14:04:02Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T14:28:54Z
      mode: "implement"
      note: "Implemented the documented target-release operator invocation and release rehearsal regression"
---

# Make clone-free platform upgrades carry release-pinned operator tools

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [140-make-clone-free-platform-upgrades-carry-release-pinned-operator-tools.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/140-make-clone-free-platform-upgrades-carry-release-pinned-operator-tools.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

An operator following the release-upgrade guide can invoke the immutable target release from a
machine that has Nix but no ambient Pulumi installation and reach the reviewed infrastructure
preview. The same target-release invocation works for planning, status, apply, resume, and rollback,
so a recovery does not accidentally fall back to an older installed CLI or an incomplete developer
package. The defect and its reproduction are recorded in
[BUG-1](../bug-reports/upgrade-command-omits-operator-tools.md).

After this change, copying the command from `docs/user/upgrades.md` into an isolated environment
shows `pulumi` and `pulumi-language-nodejs` from the selected release and produces a planned upgrade
transaction instead of `pulumi was not found on PATH`. The native release rehearsal executes that
exact command shape and fails publication if the operator tool closure is absent.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-15 14:28Z) Milestone 1: defined `nix shell ...#nagare -c nagarectl` as the
  target-release operator invocation throughout the upgrade, multi-cluster, installation,
  reference, current release, release-maintainer, and changelog documentation.
- [x] (2026-09-15 14:36Z) Milestone 2: made the clone-free release rehearsal execute the
  documented command with a Nix-only host PATH, verify release-pinned Pulumi tools, and record one
  safe saved preview with all three planning phases successful and all apply phases pending.
- [x] (2026-09-15 14:45Z) Milestone 3: synchronized release/package documentation, amended ADR 7
  with the durable operator-shell contract, and passed the focused documentation, release,
  shellcheck, package-boundary, clone-free platform, native rehearsal, and full flake gates.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: A working-tree rehearsal through `path:$PWD` can admit ignored local build files,
  unlike the clean exact-commit release path or a Git flake view.
  Evidence: the first local rehearsal copied
  `cli/nagare-dsl/.ghc.environment.aarch64-darwin-9.12.4`; the sandboxed GHC then refused its
  host-only `/Users/shinzui/.cabal/store/.../package.db`. Retrying with `git+file://$PWD` included
  the tracked dirty changes, excluded the ignored file, and completed successfully.

## Decision Log

Record every decision made while working on the plan.

- Decision: Standardize on `nix shell "${TARGET_NAGARE}#nagare" -c nagarectl ...` for operations
  that must run the target release's CLI with its complete operator toolchain; do not add another
  public flake output merely to preserve the shorter `nix run` spelling.
  Rationale: `#nagare` already contains the operator-wrapped `nagarectl`, Pulumi, the Pulumi Node.js
  language host, `socat`, and the immutable payload. The smaller `#nagarectl` output is deliberately
  an application-developer interface under ADR 7. Reusing the existing operator package fixes the
  command without duplicating package ownership or weakening that boundary.
  Date: 2026-09-15.

- Decision: Test the literal documented invocation in the native clone-free release rehearsal, not
  only the underlying package or `nagarectl version --tools` output.
  Rationale: BUG-1 is an integration failure between documentation, flake selection, and runtime
  PATH construction. Package-level assertions passed while the copied command failed, so acceptance
  must cross the same public boundary an operator uses.
  Date: 2026-09-15.

- Decision: Let the recording `nix` double proxy only the outer `nix shell` call to the real Nix
  executable and record inner upgrade evaluation calls.
  Rationale: This preserves the literal public command boundary while ensuring the upgrade's
  `nix eval` cannot build a host or contact an external evaluator. The operator wrapper appends its
  real fallbacks, so the deliberately prepended Pulumi, npm, gcloud, and kubectl doubles still win.
  Date: 2026-09-15.

- Decision: Include `pulumiVersion` and the planned upgrade state/preview count in each native
  clone-free release artifact.
  Rationale: The rehearsal assertions already fail on a missing tool or unsafe phase, while the
  summary fields retain concise publication evidence that the release supplied Pulumi and reached
  exactly one reviewed preview.
  Date: 2026-09-15.

- Decision: Amend ADR 7 rather than create a new architecture record.
  Rationale: The durable result refines ADR 7's existing operator/developer package boundary by
  specifying how clone-free platform commands enter `#nagare`; it does not establish a separate
  architectural concern. The repository has no profile-governed `docs/adr` bundle, so the existing
  filesystem convention remains authoritative.
  Date: 2026-09-15.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Milestone 2 outcome: the native `aarch64-darwin` rehearsal completed with
`pulumiVersion: "v3.255.0"`, `platformUpgrade.state: "planned"`, and
`platformUpgrade.previewCalls: 1`. Its test double log proved the transaction invoked Nix
evaluation, one saved Pulumi preview, and Kubernetes diff, while the JSON transaction kept every
apply phase pending and the old context pin unchanged.

Final outcome: operators can now copy one immutable target-release prefix for platform re-pin,
plan, status, apply, resume, and rollback without relying on an installed Pulumi. The release
rehearsal proves the complete package supplies Pulumi and its Node.js language host before safely
recording the documented planning transaction. ADR 7 now preserves this operator-shell contract.
All current-system checks passed, including 552 `nagarectl` tests inside the full flake gate; the
only omitted outputs were the incompatible `x86_64-linux` system checks, which require their native
runner. No implementation gaps remain.

