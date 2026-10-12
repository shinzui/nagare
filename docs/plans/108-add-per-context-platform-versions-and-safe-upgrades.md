---
id: 108
slug: add-per-context-platform-versions-and-safe-upgrades
title: "Add per-context platform versions and safe upgrades"
kind: exec-plan
created_at: 2026-08-25T14:04:16Z
intention: "intention_01m0wkm982etqsxsrrmnw419a5"
master_plan: "docs/masterplans/20-versioned-distribution-and-clone-free-multi-cluster-operations-for-nagare.md"
---

# Add per-context platform versions and safe upgrades

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [108-add-per-context-platform-versions-and-safe-upgrades.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/108-add-per-context-platform-versions-and-safe-upgrades.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this plan, Nagare can answer four distinct version questions: which CLI is running, which
platform payload supplies operational assets, which release a context intends to manage, and which
release last bootstrapped the selected cluster. `nagarectl platform status --context labs` compares
those identities and explains compatible, legacy, drifted, and incompatible states. Mutating platform
commands refuse a major-version mismatch instead of silently applying one checkout's desired state to
another release.

`nagarectl platform upgrade --context labs --to 0.2.0` stages an immutable payload and generated host
flake, validates compatibility, shows Pulumi and Kubernetes changes, and updates the context pin only
after an explicit apply succeeds. Production and labs can therefore move independently. Failed or
interrupted upgrades preserve the prior pin and workspace and can be retried safely.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-25T19:03:00Z) M1: Define semantic platform versions, release metadata, context persistence, and compatibility rules.
- [x] (2026-08-25T19:50:27Z) M2: Stamp and inspect cluster and host release identities and integrate version checks into doctor/status.
- [x] (2026-08-25T20:02:13Z) M3: Implement staged upgrade planning, apply, history, retry, and supported rollback behavior.
- [x] (2026-08-25T20:14:24Z) M4: Validate legacy migration, multi-context skew, failure recovery, and operator upgrade documentation.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Existing capability records use `since: unreleased`, the capability index states that Nagare has no
  release tags, and all three Cabal packages report `0.1.0.0`. There is currently no single platform
  identity to compare. Date: 2026-08-25.
- Context files are deliberately a flat `export VAR=value` schema shared by Haskell and bash. The
  platform version must extend that schema through both resolvers rather than living only in Haskell
  JSON state. Date: 2026-08-25.
- An ambient `NAGARE_PLATFORM_ROOT` from the packaged wrapper can leak into Cabal tests that intend to
  exercise source-root discovery. The source-fallback test now clears and restores that variable,
  while installed-root precedence remains covered separately. Evidence: all 386 `nagarectl-test`
  cases pass under the packaged development environment. Date: 2026-08-25.
- The root `justfile` is the existing executable aggregation of the cloud and local Kubernetes
  bootstrap; there is no separate complete rendered manifest set to apply during an upgrade. The
  transaction therefore previews the version-marker diff, replays the idempotent bootstrap recipe
  under an internal upgrade marker, and stamps the release separately as the penultimate phase.
  This keeps the pre-existing bootstrap behavior visible and prevents its ordinary guard/final stamp
  from committing early. Date: 2026-08-25.
- A wrapped executable's `NAGARE_PLATFORM_ROOT` applies only to that child process; it is not exported
  back into the calling shell. The installed empty-directory test must read `payloadRoot` from
  `platform root --json` before passing an explicit payload to upgrade planning. Evidence: the
  clone-free Nix check failed against its empty working directory when it expanded the unset shell
  variable, then passed with the reported absolute payload root. Date: 2026-08-25.

## Decision Log

Record every decision made while working on the plan.

- Decision: use semantic `major.minor.patch` platform versions and retain the Git revision as separate
  provenance.
  Rationale: compatibility policy needs structured major/minor meaning, while two builds of a release
  may need exact source traceability. A raw Git SHA alone cannot express upgrade compatibility.
  Date: 2026-08-25.
- Decision: treat an absent context or cluster version as legacy/unmanaged with a warning, not as the
  running CLI version.
  Rationale: inventing a version would hide the very skew this feature exists to expose. Legacy users
  need a non-destructive adoption path, so read-only inspection remains available.
  Date: 2026-08-25.
- Decision: block platform mutations on major-version mismatch, warn on patch skew, and require an
  explicit upgrade plan for minor-version changes.
  Rationale: this is conservative enough to prevent incompatible schema/application while permitting
  diagnostic access and normal same-release day-2 operations.
  Date: 2026-08-25.
- Decision: update the context version only after all selected apply phases succeed.
  Rationale: the context is operator intent and the recovery anchor. Advancing it before infrastructure
  and bootstrap success would turn a partial failure into misleading desired state.
  Date: 2026-08-25.
- Decision: keep semantic-version parsing in `Nagare.Version` and add no new package dependency.
  Rationale: the required release grammar and compatibility matrix are small, strict, and now table
  tested; avoiding another library keeps EP-105's hermetic package closure unchanged.
  Date: 2026-08-25.
- Decision: use the resolved payload as the comparison anchor and one shared grader for status,
  doctor, and mutation guards.
  Rationale: every operational asset comes from that immutable payload, so comparing all other
  identities against it detects the release actually attempting the operation. One grader prevents
  diagnostics and guards from disagreeing about safety.
  Date: 2026-08-25.
- Decision: persist a schema-versioned transaction after every preview/apply phase and make context
  version persistence the final phase.
  Rationale: phase evidence makes interruption diagnosable, retained payload/host staging makes retry
  idempotent, and the old context pin remains a truthful recovery anchor until Pulumi, host,
  Kubernetes, and cluster stamping all succeed.
  Date: 2026-08-25.
- Decision: permit automated release rollback only when the completed transaction records that the
  target release explicitly allowed its previous version.
  Rationale: reselecting a retained payload and host input can be automated, but application data and
  Pulumi schema migrations cannot be inferred reversible. An absent allowlist produces a refusal and
  manual recovery guidance rather than a false rollback claim.
  Date: 2026-08-25.
- Decision: make legacy adoption a confirmed observed-state commit that accepts unknown historical
  markers but rejects every known mismatch.
  Rationale: old hosts and clusters may truthfully lack version metadata, so absence cannot identify
  a release. Requiring the requested payload and all present CLI/host/cluster observations to agree,
  then stamping the cluster before the context, records only what the operator has inspected without
  concealing real skew.
  Date: 2026-08-25.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

EP-108 is complete. Nagare now carries one semantic platform identity across the CLI, immutable
payload, context intent, generated host flake, and cluster completion marker. Status and doctor
explain exact, patch, minor, major, and legacy relationships; unsafe platform mutations fail before
external changes.

Upgrades are schema-versioned per-context transactions. Planning retains an immutable payload and
host staging area and records Nix, Pulumi, and Kubernetes evidence. Apply persists each phase,
preserves operator-owned host configuration, commits context intent last, resumes after every
injected apply-phase failure, and refuses unsupported rollback claims. Explicit adoption covers old
unversioned contexts without inventing their history.

Validation includes 394 Haskell tests, both executable builds, shell syntax checks, the full native
`nix flake check`, and an installed empty-directory scenario that adopts a legacy context and plans a
different release without a source checkout. Cross-system Linux builds remain CI's responsibility;
the local flake check reported `x86_64-linux` as incompatible with the Darwin evaluator. The durable
contract and adoption/transaction boundaries are recorded in
`docs/adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md`. EP-109 still
owns tag publication, released install commands, and release consistency checks.

