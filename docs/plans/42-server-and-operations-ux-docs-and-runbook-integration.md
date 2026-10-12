---
id: 42
slug: server-and-operations-ux-docs-and-runbook-integration
title: "Server and operations UX docs and runbook integration"
kind: exec-plan
created_at: 2026-06-10T04:34:52Z
intention: "intention_01ktqwqc61e519h77zqdf3ngs3"
master_plan: "docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md"
---

# Server and operations UX docs and runbook integration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the final child of the MasterPlan at
`docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md`. It documents the
operator-facing commands delivered by its four sibling plans and folds them into the
existing runbooks. It **soft-depends** on all four:
`docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md`
(`nagarectl server status`),
`docs/plans/39-nagarectl-doctor-health-checks-with-remediation-hints.md`
(`nagarectl doctor`),
`docs/plans/40-nagarectl-domains-list-with-dns-and-certificate-readiness.md`
(`nagarectl domains list`), and
`docs/plans/41-nagarectl-cleanup-for-images-previews-and-releases.md`
(`nagarectl cleanup`). A docs plan describes commands that actually work, so it can be
drafted incrementally as each command lands and finalized once all four have merged. If a
command has not yet landed when its section is written, document the intended surface from
the sibling plan and mark that section with a short "lands with EP-NN" note, then verify it
against the real `--help` once the command merges.

Full plan before trimming: [42-server-and-operations-ux-docs-and-runbook-integration.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/42-server-and-operations-ux-docs-and-runbook-integration.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today an operator who wants to know "is my platform healthy, and what do I do when it is
not?" has to remember which of `gcloud`, `pulumi`, `kubectl`, `gsutil`, Grafana, and a
handful of runbook steps answers each question. The four sibling plans collapse that into
four `nagarectl` commands. But a command nobody can find — or whose runbook still tells you
to do the manual thing — is a command that does not help. This plan writes the
operator-facing documentation for those commands and rewrites the existing runbooks so the
docs and the tooling agree.

After this plan three things are true. First, a single new guide,
`docs/runbooks/server-operations.md`, walks an operator through day-2 platform operations
using `nagarectl server status` (is it healthy?), `nagarectl doctor` (what is wrong and how
do I fix it?), `nagarectl domains list` (what is my DNS/TLS state?), and `nagarectl cleanup`
(reclaim disk, prune previews and releases). Second, `docs/runbooks/cluster-access.md` keeps
its IAP-SSH access mechanics but now points "is the platform healthy?" at `server status` /
`doctor` instead of a hand-run `kubectl get nodes`. Third,
`docs/runbooks/disaster-recovery.md` keeps its full rebuild sequence, but each step's
"Observe:" assertions note that `nagarectl doctor` now checks many of them automatically,
and the backup-inventory section references `nagarectl server status` for freshness.

**You can see it working** by following the new guide's day-2 scenario top to bottom against
the real platform: the VM is `TERMINATED`; you start it with the documented `gcloud`
command; `nagarectl server status` prints a partial report with the still-cold facets as
`Unknown`/down; `nagarectl doctor` lists the `FAIL` lines, each carrying a remediation hint
and the exact command (re-apply the metadata route / MASQUERADE / coredns workarounds,
re-bootstrap, etc.); you copy-paste each fix; you re-run `nagarectl doctor` until every line
is `OK`; and `nagarectl domains list` shows the base domain and per-app DomainMappings
resolving. A newcomer recovers a dead platform to green using only the documented commands.
The guide is the acceptance test.

## Progress

- [x] M1 (2026-06-10): `docs/runbooks/server-operations.md` written — a status box, "Commands at a
  glance", one section per command (`server status`, `doctor`, `domains list`, `cleanup`) with real
  `--help`-matched transcripts and both healthy and labelled-degraded output, the end-to-end day-2
  "TERMINATED → green" recovery scenario, and a "How it works" callout.
- [x] M2 (2026-06-10): `docs/runbooks/cluster-access.md` and `docs/runbooks/disaster-recovery.md`
  updated in place — health-check pointer + top cross-link in cluster-access; in disaster-recovery a
  top cross-link, a backup-freshness pointer, `nagarectl doctor` "checks this automatically" notes on
  the step-4 rollout/ClusterIssuer and step-5 disk assertions, and a power-management note linking the
  post-reboot workarounds to the day-2 scenario. All four commands now cross-link coherently.
- [x] M3 (2026-06-10): every documented command/flag verified against the real `nagarectl ... --help`
  (`server status`, `doctor`, `domains list`, `cleanup` — copied verbatim from the binary); transcripts
  captured from the binary in healthy-shape + labelled degraded/partial form (VM `TERMINATED`, no tools
  on PATH); every opening fence carries a language tag; intra-doc links and anchors resolve.

## Surprises & Discoveries

- 2026-06-10 (M1): The shipped probe/command names differ from the plan's illustrative ones, so the
  docs follow the binary: `server status` shows 18 checks with the display labels `VM` / `k3s node` /
  `Knative controller` / `cert-manager` / `ClusterIssuer` / `Kourier ingress` / `base domain` /
  `external-domain-tls` / `Artifact Registry` / `backup <prefix>` / `boot disk` / `data disk`, and the
  table is a `STATUS / CHECK / DETAIL` grid (not the `....` leader-dot mock in the plan body). All
  transcripts were copied verbatim from the real binary.
- 2026-06-10 (M3): `nagarectl doctor` does **not** have a dedicated probe for the post-reboot host
  workarounds (metadata route / MASQUERADE / coredns) — EP-38 ships no such probe. The day-2 scenario
  was written truthfully: `doctor` flags the *downstream symptoms* (control planes not ready, Artifact
  Registry unreachable, stale backups) and the guide cross-links the actual root-cause fixes to
  `disaster-recovery.md`'s power-management section, rather than claiming `doctor` detects the
  workarounds directly.
- 2026-06-10 (M3): The naive bare-fence lint (`grep -n '^```$'`) flags every **closing** fence (closers
  are always bare in GFM), so it reports false positives on all three runbooks. A state-tracking check
  (only *opening* fences must carry a language tag) is the correct lint and passes — every opening fence
  is tagged.

## Decision Log

- Decision: Ship the operator documentation as a separate, final ExecPlan (EP-42) rather than
  folding doc edits into EP-38..EP-41.
  Rationale: this matches the sibling MasterPlans' established pattern of a dedicated closing
  docs plan (e.g. EP-32 for MasterPlan 6's app lifecycle, EP-37 for MasterPlan 7). A docs plan
  can be drafted incrementally as commands land and finalized once all four merge, and it lets
  each implementation plan stay focused on a single command surface.
  Date: 2026-06-09

- Decision: Update the existing runbooks (`cluster-access.md`, `disaster-recovery.md`) in
  place rather than duplicating their content into the new guide.
  Rationale: the runbooks are the authoritative access and rebuild procedures; the MasterPlan's
  in-scope item is to "fold these commands into" them, "replacing manual procedures with
  command invocations where the command now covers them." Duplicating would create two
  divergent sources of truth. The new guide is the day-2 operations narrative; the runbooks
  keep their distinct jobs (how to reach the cluster, how to rebuild it) and gain pointers to
  the commands.
  Date: 2026-06-09

- Decision: Document every command and flag from its real `nagarectl ... --help` output, and
  capture transcripts from the built binary, rather than transcribing the sibling plans' spec
  prose.
  Rationale: the sibling plans' final `--help` and output formats are the source of truth; flag
  names and wording can drift during implementation. A docs initiative whose acceptance is
  "every command and transcript matches actual behavior" must read the shipped CLI, not the
  plan that proposed it.
  Date: 2026-06-09

- Decision: Place the new guide at `docs/runbooks/server-operations.md` (under `runbooks/`),
  not under a `docs/cli/` directory.
  Rationale: there is no `docs/cli/` directory in this repo — the EP-32 CLI guides landed in
  `docs/user/` and the operator procedures live in `docs/runbooks/` (`cluster-access.md`,
  `disaster-recovery.md`). This guide is an operator runbook (day-2 platform operations,
  recovery scenario) and belongs beside the two runbooks it cross-links, which the MasterPlan
  names as the integration targets.
  Date: 2026-06-09

## Outcomes & Retrospective

Delivered the operator documentation for MasterPlan 8 and folded the four commands into
the existing runbooks. New: `docs/runbooks/server-operations.md` — the day-2 operations
guide with a section per command (`server status`, `doctor`, `domains list`, `cleanup`),
real `--help`-matched transcripts, healthy + labelled-degraded output, the end-to-end
"TERMINATED → green" recovery scenario (the plan's acceptance test), and a "How it works"
callout. Edited in place: `docs/runbooks/cluster-access.md` now points "is it healthy?" at
`server status` / `doctor` while keeping the SSH/kubeconfig/wrong-context access mechanics;
`docs/runbooks/disaster-recovery.md` keeps its full rebuild sequence and manual fallbacks
but notes where `nagarectl doctor` now checks a step's assertions, points at `server
status` for backup freshness and disk usage, and links the post-reboot workarounds to the
day-2 scenario. The three runbooks cross-link each other coherently.

Verification: every documented command and flag matches the real `nagarectl ... --help`
(verified against the built binary); every opening code fence carries a language tag; the
intra-doc links and section anchors resolve. The live healthy-cluster transcripts are
shown as expected-shape blocks alongside the truthfully-labelled degraded captures (VM
`TERMINATED`, no tools on PATH), matching how EP-32's guide handled a powered-down box.

With EP-42 complete, all five child plans of MasterPlan 8 are done: an operator can now
answer "is my platform healthy, what is wrong, what are my domains, and how do I reclaim
disk?" entirely from `nagarectl`, with the runbooks pointing at those commands.

