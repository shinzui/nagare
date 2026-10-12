---
id: 106
slug: make-nagare-platform-assets-resolvable-outside-a-source-checkout
title: "Make Nagare platform assets resolvable outside a source checkout"
kind: exec-plan
created_at: 2026-08-25T14:04:15Z
intention: "intention_01m0wkm982etqsxsrrmnw419a5"
master_plan: "docs/masterplans/20-versioned-distribution-and-clone-free-multi-cluster-operations-for-nagare.md"
---

# Make Nagare platform assets resolvable outside a source checkout

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [106-make-nagare-platform-assets-resolvable-outside-a-source-checkout.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/106-make-nagare-platform-assets-resolvable-outside-a-source-checkout.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this plan, the Nagare flake distributes a `nagare-platform` payload containing the Pulumi
program, cluster manifests, scripts, NixOS source, operator recipes, and the small set of documentation
needed by runtime diagnostics. `nagarectl` locates those resources through one tested path resolver
instead of assuming it was launched from the repository root. Read-only resources can run directly
from the installed payload; resources that tools must modify are materialized atomically into a
versioned workspace under the selected context's XDG state directory.

A user can create an isolated `prod` context and run `nagarectl init --dry-run`, platform status, and
Pulumi preview preparation from an arbitrary empty directory. The same commands still work in a
source checkout for contributors. The later host-configuration and version plans build on this
immutable-payload/mutable-workspace boundary.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Inventory every repository-relative runtime path and define the payload manifest, path resolver, and workspace layout.
- [x] M2: Package `nagare-platform` and implement idempotent per-context workspace materialization.
- [x] M3: Migrate Haskell, shell, Pulumi, bootstrap, and operator-recipe call sites to resolved absolute paths.
- [x] M4: Prove clone-free dry-run operations from an empty directory while preserving source-checkout compatibility.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `nagarectl init` invokes `scripts/enable-apis.sh` and seeds `infra/pulumi`; status, cleanup, doctor,
  CDN, and Pulumi helpers contain additional relative paths. Packaging only the obvious bootstrap
  manifests would leave important admin commands checkout-dependent. Date: 2026-08-25.
- The current Pulumi config projection and NixOS registry override are written into repository-owned
  directories. Because Nix payloads are read-only and contexts may operate concurrently, installed
  operation needs a writable per-context copy rather than direct mutation of `$out/share/nagare`.
  Date: 2026-08-25.
- Nix flakes exclude untracked files from their source snapshot, so new payload modules and the
  package expression must be staged before a local package build can validate them. This is source
  visibility, not a requirement to commit an unverified milestone. Date: 2026-08-25.
- Source checkouts can contain ignored `Pulumi.<context>.yaml` projections. Including them in a
  payload digest or workspace copy would leak one context's generated configuration into another;
  both the Nix source filter and workspace copier now exclude those files while retaining the
  canonical `Pulumi.yaml`. Date: 2026-08-25.
- The status inventory documents missing tools as degradable, but a completely absent `kubectl`
  currently escapes one probe's IO wrapper. The clone-free check therefore supplies inert fake
  external tools, as its test contract already required, and still proves every path passed to
  Pulumi is workspace-absolute. Date: 2026-08-25.

## Decision Log

Record every decision made while working on the plan.

- Decision: define one payload root containing the repository-owned operational tree instead of a
  separate locator for each asset family.
  Rationale: scripts and recipes refer to one another; one validated root preserves those internal
  relationships and prevents divergent resolution rules.
  Date: 2026-08-25.
- Decision: make installed payloads immutable and materialize only commands requiring writes into a
  per-context, payload-identified state workspace.
  Rationale: this matches Nix store semantics, isolates multiple clusters, and makes rollback possible
  without overwriting a previous release workspace.
  Date: 2026-08-25.
- Decision: preserve a validated source-root fallback, but never silently treat an arbitrary current
  directory as Nagare.
  Rationale: contributor workflows remain useful, while installed commands fail with a precise
  resource error instead of operating on unrelated same-named files.
  Date: 2026-08-25.
- Decision: identify workspaces by the manifest payload id plus a SHA-256 digest over the shipped
  asset paths and contents.
  Rationale: a development payload can retain a stable human identity while any asset change still
  selects a distinct immutable workspace; repeated preparation of identical bytes is a no-op.
  Date: 2026-08-25.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The root flake now exports `nagare-platform`, a wrapped `nagarectl`, and the `nagare` operator
launcher. `Nagare.Platform.Paths` validates explicit, installed, and source roots through one
sentinel contract; `Nagare.Platform.Workspace` content-addresses shipped bytes and materializes them
atomically below the selected context's XDG state. Init, Pulumi stack selection and outputs, status,
cleanup, doctor remediation, IAP, shared shell setup, bootstrap assets, NixOS assets, and recipes now
consume those resolved paths.

Validation covers 381 Haskell tests, including invalid roots, idempotent reuse, changed digests,
generated-stack exclusion, and two-context isolation. Nix checks validate every installed sentinel
and run context create/use, platform diagnostics, init dry-run, status, and an operator-recipe
dry-run from an empty directory. Source compatibility is covered by the Cabal suite, shell syntax,
and the repository `justfile` listing. The immutable-payload/mutable-workspace decision is recorded
in [ADR 0004](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md).

This plan intentionally does not make the tracked host identity safe to distribute or define
upgrade/rollback selection. EP-107 owns external host configuration and EP-108 owns platform-version
negotiation on top of the payload and workspace boundary delivered here.

