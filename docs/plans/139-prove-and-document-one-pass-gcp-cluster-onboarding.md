---
id: 139
slug: prove-and-document-one-pass-gcp-cluster-onboarding
title: "Prove and document one-pass GCP cluster onboarding"
kind: exec-plan
created_at: 2026-09-14T04:16:15Z
intention: "intention_01m2f225p4e68bbf918ecvvwvr"
master_plan: "docs/masterplans/22-reliable-first-cluster-bootstrap-on-gcp.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T04:16:15Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T19:02:03Z
      mode: "implement"
      note: "Started EP-6 after all child and external dependencies completed"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T19:20:17Z
      mode: "implement"
      note: "Completed hermetic, documentation, IR-11, and repository gates; retained live authorization boundary"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T19:28:34Z
      mode: "implement"
      note: "Audited live evidence, release identity, TLS readiness, cleanup, and installed-workspace documentation"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T23:19:22Z
      mode: "implement"
      note: "Made v0.3.0 CLI output deterministic under the Linux release locale"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T23:42:10Z
      mode: "implement"
      note: "Made hermetic rehearsal assertion failures identify their command and source line"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T01:20:20Z
      mode: "implement"
      note: "Extended deterministic UTF-8 from terminal handles to generated text files"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T01:38:17Z
      mode: "implement"
      note: "Made hermetic failure diagnostics inherit through Bash functions"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T01:48:38Z
      mode: "implement"
      note: "Preserved the failing public infra-preview dry-run diagnostic in native CI"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T01:56:51Z
      mode: "implement"
      note: "Pinned hermetic fake-tool launchers to the native Bash closure"
---

# Prove and document one-pass GCP cluster onboarding

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [139-prove-and-document-one-pass-gcp-cluster-onboarding.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/139-prove-and-document-one-pass-gcp-cluster-onboarding.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare has one accurate, executable path from an installed release and empty GCP project to a Ready,
accessible, TLS-configured first cluster. A hermetic rehearsal checks command ordering, guards, and
failure behavior without cloud access; an explicitly authorized disposable-project rehearsal proves
the real path and records cleanup. User documentation no longer claims boot-disk size changes happen
in place. This integration plan implements IR-11 and accepts the composed outcome of child
ExecPlans 134–138 plus independent ExecPlans 132 and 133.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-14T19:15:20Z) Define one canonical bootstrap state machine and a hermetic rehearsal
  harness with focused refusal cases and a native flake check.
- [x] (2026-09-14T19:15:20Z) Consolidate onboarding/help, including truthful boot-disk replacement
  guidance and immutable reviewed-release placeholders.
- [ ] Run an explicitly authorized empty-project GCP rehearsal and verify cleanup/evidence.
- [x] (2026-09-14T19:20:00Z) Close IR-11, reconcile all cross-plan docs/ADRs, and run the final
  repository gate.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The latest published Nagare tag is `v0.2.2`, but it predates the completed bootstrap interfaces
  this plan composes. Hard-coding it would make the new runbook internally inconsistent, so the
  guide uses a reviewed immutable release placeholder and live mode verifies the installed version.

- Even `nagarectl init --dry-run` checks the external operator toolchain before rendering its public
  command sequence. The hermetic check therefore supplies a recording `npm` alongside cloud and
  cluster fakes; this is part of testing the packaged interface rather than bypassing it.

- Nix flake source filtering omits a new untracked rehearsal script. Staging that file before the
  first packaged build made the source closure accurate; subsequent packaged and root checks pass.

- The Linux release builder has an ASCII default text encoding, while several public CLI
  diagnostics intentionally contain Unicode punctuation. The v0.3.0 candidate passed all 552
  Haskell tests and reached the final GCP rehearsal before `nagarectl init --dry-run` failed while
  encoding its em dash. A later native run showed that setting stdout and stderr alone was too
  narrow: `context create` also writes the same documented punctuation to a newly opened context
  file. Selecting UTF-8 as the process locale encoding before parsing makes both existing and
  subsequently opened handles stable independently of the caller's locale.

- A later Linux release run still returned a bare status 1 from the hermetic rehearsal after all
  552 Haskell tests passed, but the Nix log could identify only the derivation because several
  assertions intentionally use quiet `grep`. Bash does not inherit an `ERR` trap into functions
  unless errtrace is enabled, so installing the trap inside `run_hermetic` was insufficient for
  failures in `assert_public_interfaces`. The rehearsal now enables errtrace and reports the failed
  command and source line from its own temporary, secret-free hermetic environment. That exposed
  the remaining boundary as the packaged `nagare --dry-run infra-preview` command; the harness now
  emits that command's captured output before deleting the temporary environment.

- Symlinking the recording fakes back to this repository script preserved the script's
  `#!/usr/bin/env bash` interpreter. Linux `posix_spawnp` therefore refused the fake `npm` in a pure
  Nix closure where `/usr/bin/env` is intentionally absent, although invoking the top-level harness
  explicitly with Bash remained valid. Each fake is now a tiny generated launcher whose shebang is
  the exact Bash already running the check and whose explicit program identity preserves dispatch.

## Decision Log

Record every decision made while working on the plan.

- Decision: Make the bring-your-own-project guide the canonical end-to-end narrative; focused guides
  link to its stages instead of maintaining competing full sequences.
  Rationale: The current contradiction arose because installation, provisioning, secrets, access,
  bootstrap, TLS, and upgrades each encode part of the order independently.
  Date: 2026-09-14.

- Decision: Separate hermetic acceptance from an opt-in live GCP rehearsal.
  Rationale: Guards and orchestration should be deterministic in CI, while proving real provider,
  IAP, boot, DNS, and certificate behavior costs money and mutates external infrastructure.
  Date: 2026-09-14.

- Decision: Require a purpose-created disposable project and explicit environment acknowledgement
  for live rehearsal; never infer a project from gcloud defaults.
  Rationale: End-to-end proof must preserve the same project-confinement safety it is validating.
  Date: 2026-09-14.

- Decision: Keep boot-disk resizing out of scope and state that changing `bootDiskSizeGb` replaces
  the instance.
  Rationale: That is the behavior observed by Nagare's protected replacement preview and requested
  by IR-11. The safe initial path is to size the boot disk for the VM lifetime.
  Date: 2026-09-14.

- Decision: Keep the plan In Progress after hermetic and repository acceptance pass.
  Rationale: The plan explicitly requires a billable disposable-project run from an installed
  release. No project, delegated domain, protected-project list, secret inputs, acknowledgement, or
  interactive authorization was supplied, and hermetic evidence cannot substitute for that run.
  Date: 2026-09-14.

- Decision: Set the process locale encoding and both terminal handles to UTF-8 at the start of each
  public Haskell executable.
  Rationale: Nagare owns Unicode diagnostics, generated context files, and JSON text, so their
  encodability must not depend on whether a pure builder or minimal operator environment exports a
  UTF-8 locale. Setting only stdout and stderr leaves later text-file handles locale-dependent.
  Date: 2026-09-14.

- Decision: Keep an ERR diagnostic active in hermetic mode only.
  Rationale: A failed release assertion must be actionable on a remote native builder, while live
  mode may handle operator inputs and therefore must not gain an indiscriminate command dump.
  Enable Bash errtrace globally so the hermetic trap reaches nested assertion functions, but do not
  install that trap anywhere in the live path.
  Date: 2026-09-14.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Hermetic and documentation outcomes are complete. `scripts/rehearse-gcp-bootstrap.sh --hermetic`
drives the packaged public command surfaces and an explicit fake state machine from empty state. It
passes the happy path with exactly two reviewed applies and one bootstrap invocation, and proves
refusals for foreign project/ADC identity, stale plan, foreign builder, non-Ready VM, missing age
key, wrong kubeconfig node, absent webhooks, and leaked certificate scope. The native
`gcp-bootstrap-rehearsal` and `shellcheck-scripts` checks pass.

The v0.3.0 release audit made that hermetic evidence portable across native systems: both Haskell
executables now select UTF-8 as their process and terminal encoding before option parsing, covering
help, dry-run diagnostics, and generated context files.
Hermetic failures also identify the exact failed command and source line without weakening any
assertion or exposing live operator values.

The canonical onboarding guide now identifies release, project, context/stack, builder, and cluster
targets; its boot-disk guidance agrees with packaged help and focused references. IR-11 is completed.
All 527 Haskell tests, strict user/improvement-request OKF validation, NixOS all-system evaluation,
and all 29 buildable native root-flake checks pass.

The authorized live rehearsal remains outstanding. Live mode is implemented, requires a clean
installed release and empty stack, validates gcloud plus ADC confinement, prints its inventory,
records release revision and saved-plan digests, invokes bootstrap once, requires a Ready staging
certificate, and separately confirms guarded teardown without deleting the project. Until an
operator supplies its explicit inputs and runs it, this plan is not complete.

