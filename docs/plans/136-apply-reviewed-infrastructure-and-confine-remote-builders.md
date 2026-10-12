---
id: 136
slug: apply-reviewed-infrastructure-and-confine-remote-builders
title: "Apply reviewed infrastructure and confine remote builders"
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
      at: 2026-09-14T13:38:21Z
      mode: "implement"
      note: "Started EP-3 implementation"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T14:18:39Z
      mode: "implement"
      note: "Completed EP-3 implementation and validation"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T22:59:26Z
      mode: "implement"
      note: "Hardened v0.3.0 release fixtures after Linux CI evidence"
---

# Apply reviewed infrastructure and confine remote builders

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [136-apply-reviewed-infrastructure-and-confine-remote-builders.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/136-apply-reviewed-infrastructure-and-confine-remote-builders.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

An operator or CI job can save, inspect, and non-interactively apply the same constrained Pulumi
plan after every Nagare guard succeeds. The saved artifact is bound to one Nagare context, GCP
project, Pulumi backend, stack, program, configuration, and Pulumi version, so a plan from another
cluster is refused before cloud mutation. `nagare host-image --dry-run` also names the effective GCP
builder, and the real build uses the selected context's builder unless the operator explicitly
allows a logged cross-project exception. This plan implements IR-15 and IR-17.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-14T13:51Z) Define a context-bound saved-plan bundle and classify its reviewed operations.
- [x] (2026-09-14T13:51Z) Implement guarded preview/apply and reuse it in the upgrade transaction.
- [x] (2026-09-14T14:05Z) Generate and select a per-context GCP builder, with visible cross-project refusal/opt-in.
- [x] (2026-09-14T14:18Z) Cover teardown and non-interactive operation in docs, close the IRs, and run all gates.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: A newly added proxy or test is invisible to Nix flake evaluation until it is staged,
  even though ordinary shell tests see the worktree file. Evidence: the first operator-tools build
  refused the untracked `scripts/nix-builder-proxy.sh`; staging the two new scripts made the same
  three-check build proceed and pass.

- Observation: The strict improvement-request structure and log pass, but the optional
  `--profile-enforce` audit now reports the same missing recommended `reviews` field on 22 of the 23
  existing records. This is bundle-wide pre-existing provenance debt, not a schema or log failure;
  adding invented reviews to unrelated records would make the history less truthful.

- Observation: The native Darwin gate did not expose fixture executables whose
  `#!/usr/bin/env bash` shebangs are unavailable in a pure Linux Nix builder. Evidence: the
  v0.3.0 candidate's first Linux CI run passed all 552 Haskell tests, then failed before exercising
  the upload logic; invoking the repository script with the check-provided Bash and rendering that
  exact Bash path into every fake tool made the focused pure-build check pass.

## Decision Log

Record every decision made while working on the plan.

- Decision: Store a Pulumi plan and a Nagare metadata sidecar as one directory bundle, and digest
  every member rather than modifying Pulumi's JSON.
  Rationale: `mori://pulumi/pulumi/packages/pulumi` serializes resource plans, configuration, and a
  manifest but no Nagare context, GCP project, backend, stack, or program digest. A sidecar preserves
  Pulumi compatibility while making those bindings explicit and independently testable.
  Date: 2026-09-14.

- Decision: Describe saved-plan apply as constrained, not atomic.
  Rationale: Pulumi permits safer operations such as `same` in place of update and update in place
  of replace, and cloud operations still execute over time. Nagare must promise that apply cannot
  exceed the reviewed plan, not that all resources change in one transaction.
  Date: 2026-09-14.

- Decision: Make the context's project the default builder project and require a named
  `--allow-shared-builder` acknowledgement for a known foreign project.
  Rationale: Cross-project builders can be useful, but an ambient `/etc/nix/machines` entry must not
  silently start and bill a VM outside the context.
  Date: 2026-09-14.

- Decision: Amend ADR 18 for context-bound saved plans and ADR 9 for builder project ownership.
  Rationale: Both are durable extensions to existing guarded-execution boundaries.
  Date: 2026-09-14.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The public infra commands now make one Pulumi preview, preserve its plan plus review and binding
metadata in a private immutable directory, and pass that exact plan to non-interactive apply. The
upgrade transaction uses the same boundary. Focused Haskell tests (508 cases) and the clone-free
packaged scenario pass.

Host-image now renders a private per-context SSH route and explicit `--builders` value. Its default
builder is in the target project; a different `NAGARE_BUILDER_PROJECT` is refused unless the command
names that exact project with `--allow-shared-builder`. Hermetic confinement, packaged-proxy, and
shellcheck gates pass without consulting ambient builder configuration.

The v0.3.0 release audit also aligned the standalone clone-free rehearsal with the public reviewed
preview boundary, made its isolated Homebrew cleanup tolerate short-lived cache writers, and made
the upload-images confinement fixture portable to the pure Linux builder. The focused native Nix
checks pass with those release-hardening corrections.

IR-15 and IR-17 are completed, ADR 18 owns the retained constrained-plan boundary, and ADR 9 owns
builder project selection. The five focused operator guides, disaster-recovery teardown, reference,
and changelog now use the public commands. `just docs-validate`, strict/logged improvement-request
validation, all 508 Haskell tests, clone-free integration, and every buildable native flake check
pass. The optional profile-enforcement audit retains the bundle-wide review-provenance advisory
described above; no live disposable-project mutation was authorized in this implementation run.

