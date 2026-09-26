---
id: 154
slug: validate-installed-inventory-packages-on-every-supported-system
title: "Validate installed inventory packages on every supported system"
kind: exec-plan
created_at: 2026-09-26T20:29:54Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T20:29:54Z
---

# Validate installed inventory packages on every supported system

This ExecPlan is a living document for remaining work transferred from EP-150.


## Purpose / Big Picture


The installed operator and developer packages run the inventory commands outside the source checkout on every system in release.json. Required schemas, manifests, images, transports, and typed-config support are present; native tests produce evidence for the exact candidate revision.


## Progress


- [ ] M1: Operator/developer package boundaries and installed inventory resources pass clone-free command and missing-resource checks.
- [ ] M2: Both supported native systems pass their required build, test, durability, and clone-free gates with matching source/payload evidence.

Inherited baseline: Nix fixture-path fixes, Helm/OpenSSL test inputs, example logical keys, and one Darwin CLI package test were delivered in EP-150. Full flake validation remained incomplete at the formatting gate; no Linux success is inferred from Darwin.


## Surprises & Discoveries


No new implementation findings in this successor plan. Inherited evidence and known gaps are identified below.


## Decision Log


2026-09-26: Carry forward completed EP-150 implementation and give this remaining outcome its own acceptance boundary. The split changes ownership and tracking, not the required functionality or proof.


## Outcomes & Retrospective


Remaining-work plan created; no new acceptance run has been performed. Inherited capabilities are credited in Progress and must not be presented as newly completed work.


## Context and Orientation


This plan replaces part of [EP-150](150-integrate-resource-inventories-into-upgrades-and-release-verification.md); its 2026-09-25 implementation is already present. A scope is one owner's desired resource set. The inventory composes all scopes; an immutable review binds exact native inputs, and a private journal records verified operation receipts. Completion of one scope must not change another owner's revision. cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the shared command service; Plan.hs, Execute.hs, and Store.hs in that directory own review, execution, and history. Public evidence must exclude reusable credentials and private native plans.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires complete ownership and reviewed effects. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) permits this first release to start with fresh contexts while rejecting in-place platform version changes after admission. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps operator state outside immutable payloads. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable release evidence. The operator requested decomposition without reduced functionality or validation; temporary refusal of promised behavior is not completion.

nix/platform-package.nix, nix/nagare-packages.nix, nix/haskell-packages.nix, nix/checks/haskell.nix, nix/checks/infra.nix, nix/checks/platform.nix, and nix/checks/scripts.nix define packaging and checks. release.json currently declares x86_64-linux and aarch64-darwin. scripts/check-release.sh, scripts/test-release.sh, and scripts/rehearse-clone-free-release.sh supply existing verification. .github/workflows/release.yml records native Nix output identities. Correct earlier source-relative test assumptions instead of disabling those tests.


## Plan of Work


M1 traces the runtime resources used by bootstrap, application/data commands, publication, store recovery, and provider transports into installed outputs. Test from a directory outside the checkout with isolated operator state and an exact candidate flake reference. The developer package includes only its needed tools; the operator includes platform tools. Invalid explicit payload roots must fail instead of silently finding the source checkout. Negative public-API and secret-exclusion checks remain required.

M2 runs the current full flake and release gates on both declared native systems. Resolve the known formatting/test fixture failures in coherent batches while preserving concurrent changes. Record actual system, candidate source, payload digest, tool versions, and clone-free output. Reuse successful results only for unchanged relevant inputs; evidence for an older payload cannot be renamed to the current candidate. Keep native host activation behavior in the GCP rehearsal; a Linux package build alone does not prove activation. Do not reduce supportedSystems to avoid a failed runner.


## Concrete Steps


Run from the repository root in its existing development environment. Commands for a new runner are explicitly marked as a required interface; implement them before running.

```bash
nix flake check
bash scripts/test-release.sh
bash scripts/rehearse-clone-free-release.sh --help
# On each native runner, use the candidate's exact clean revision and version:
: "${NAGARE_CANDIDATE_VERSION:?candidate version from release.json}"
: "${NAGARE_CANDIDATE_FLAKE:?exact candidate flake reference}"
: "${NAGARE_NATIVE_EVIDENCE:?private runner output path}"
bash scripts/rehearse-clone-free-release.sh --version "$NAGARE_CANDIDATE_VERSION" --flake-ref "$NAGARE_CANDIDATE_FLAKE" --output "$NAGARE_NATIVE_EVIDENCE"
```

Expected result: relevant checks exit zero; refused negative fixtures exit nonzero before effects. Native evidence must name the exact candidate and target.


## Validation and Acceptance


Both native runs exit successfully and identify the same source revision and release contract. Installed commands resolve all reviewed native sources without a checkout, private material never enters package outputs, and context state remains writable outside the immutable payload. Negative schema/constructor/invalid-root checks still fail as intended. Darwin evidence cannot substitute for Linux locks/durability or host behavior. Keep a manifest of exact native output and rehearsal artifacts for EP-157.

Use focused checks during implementation and one relevant full acceptance gate for the coherent outcome; repeat broad checks only after a relevant change or failure. Record candidate source revision, command, fixture identity, observed result, and evidence location. Passing inherited tests is regression evidence, not proof that a newly required outcome exists. Keep Progress checkboxes directly under the Progress heading so Mina can read them. Use partial markers for actual unfinished implementation, never mark a milestone complete merely to improve a percentage.


## Idempotence and Recovery


Work against isolated test state and exact named contexts. Preserve immutable reviews and private journals after interruption; inspect/resume the same transaction rather than regenerate a changed review or blindly retry effects. An unknown provider result is not absence. Never clean a resource by broad project, namespace, or prefix merely because a test failed. No plan here authorizes publication of a real Nagare release. Do not search or read /nix/store; Nix may execute its normal builds, but source inspection uses the checkout and Mori.


## Interfaces and Dependencies


Use completed EP-146/147/149/151 implementations. [EP-152](152-complete-fresh-platform-bootstrap-through-reviewed-components.md) and [EP-148](148-route-application-and-data-lifecycles-through-independent-resource-scopes.md) supply the command code to package; [EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) supplies the registration inventory. These are integration dependencies: packaging repairs can begin now, but final evidence must cover the final code. [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md)/[EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) consume installed candidates, and [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) consumes native evidence. Initial estimate: 4–8 active hours excluding runner queues, low confidence; reforecast after the first full native gate on each system.
