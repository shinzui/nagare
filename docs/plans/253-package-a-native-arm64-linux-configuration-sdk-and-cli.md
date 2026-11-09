---
id: 253
slug: package-a-native-arm64-linux-configuration-sdk-and-cli
title: "Package a native ARM64 Linux configuration SDK and CLI"
kind: exec-plan
created_at: 2026-11-09T21:45:41Z
intention: "intention_01m714rsd7ecesc6rf1mczbzhx"
master_plan: "docs/masterplans/34-extend-application-workloads-with-independent-health-checks-explicit-pod-policy-and-a-native-arm64-sdk.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-09T21:45:41Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-09T21:52:55Z
      mode: "update"
      note: "Associate the initiative and child plans with the user-requested Mina intention."
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-09T23:20:14Z
      mode: "update"
      note: "Renumbered from EP-247-250 and aligned with the MasterPlan 34 review findings."
---

# Package a native ARM64 Linux configuration SDK and CLI


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current. Record implementation friction through the repository's exec-plan workflow.

## Purpose / Big Picture


An ARM64 Linux application runner can use a packaged Nagare CLI and configuration SDK from outside the Nagare checkout, without a user Cabal database. The runner can compile an existing Application containing a service, worker and migration task. This satisfies the tooling portion of IR-42 AC-1; it does not add ARM64 production hosts.

## Progress


- [ ] M1: `packages.aarch64-linux.nagarectl` and `nagare-config-sdk` build natively, with `release.json` unchanged.
- [ ] M2: An isolated ARM64 Linux consumer executes the packaged CLI and compiles the representative Application, with revision-bound evidence.

## Surprises & Discoveries


None during implementation yet.

## Decision Log


- Decision: Publish an explicit SDK export and distinguish tooling support from host support, because adding a system to every existing release matrix would overstate the requested capability. Date: 2026-11-09.
- Decision: Leave `release.json` `supportedSystems` unchanged and list tooling systems in `flake.nix`. Rationale: that field is read by the gate, the verify step, release evidence and a candidate check requiring exactly the two current systems; extending it would need a schema change and migration tests to say something a flake output already says (operator, 2026-11-09). Date: 2026-11-09.

## Outcomes & Retrospective


Implementation has not started. Before completion, retain acceptance evidence and distill durable compatibility decisions into the relevant ADR.

## Context and Orientation


`flake.nix` currently uses `releaseMetadata.supportedSystems`; `release.json` lists x86_64-linux and aarch64-darwin. `nix/haskell-packages.nix` defines `typedConfigRuntime = haskellPackages.ghcWithPackages (hp: [ hp.nagare-dsl ])` and wraps the CLI with it. `nix/packages.nix` exports the CLI but no named SDK. `nix/hydra-jobs.nix`, `nix/dev-shells.nix` and the release harness consume system selection.

[ADR 3](../adr/0003-package-the-typed-config-runtime-with-nagarectl.md) requires the installed compiler to work without checkout-local state. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable release provenance. Preserve both; do not change compiler or library versions simply to obtain a different architecture.

## Plan of Work


M1 adds a documented `packages.aarch64-linux.nagarectl` and `packages.aarch64-linux.nagare-config-sdk` export using the same locked compiler and DSL as the CLI. Expose the SDK on existing tooling systems too. Do not change `release.json`: `supportedSystems` keeps meaning systems the platform release is gated on, and `cli/nagare-harness` (`Gate.hs`, `Verify.hs`, `Release/Candidate.hs`) reads it. Add a tooling-systems list in `flake.nix` that includes `aarch64-linux` and generate only these two package attributes from it, so no host, image or check output appears for ARM64 Linux. Start the first native build as the plan's first action and let it run unattended: no binary cache is expected for this system, so the GHC closure builds from source. Native platform outputs and x86 release images retain their existing policy. Verify attribute evaluation and package builds on the candidate revision.

M2 creates a checked-in isolated consumer fixture under `cli/nagarectl/test/fixtures/` and a repeatable native harness check. In a native ARM64 Linux Apple container, realize the candidate packages, run from a temporary directory with an empty home, no Cabal environment and no Nagare checkout, then execute `nagarectl app check` on a copied typed Application fixture and compile it using the public SDK. Disable network access for the load/compile step after artifact realization. Record architecture, source revision, package identity, compiler version and exit status. Amend ADR 3 and packaging documentation with the new public exports and tooling-only support boundary.

## Concrete Steps


From the repository root, evaluate the exports without building unrelated host outputs:

```bash
nix eval --raw .#packages.aarch64-linux.nagarectl.drvPath --no-write-lock-file
nix eval --raw .#packages.aarch64-linux.nagare-config-sdk.drvPath --no-write-lock-file
```

On the native ARM64 Linux builder, build those two attributes with `nix build --no-link --no-write-lock-file`. From the isolated fixture directory, use the resulting installed CLI:

```bash
uname -m
nagarectl --version
nagarectl app check -f nagare/Config.hs
```

Expect native aarch64 execution and a successful config check. Expose the fixture as an `aarch64-linux` flake check that runs per release candidate in the native Apple container. Keep it out of `just gate-fast` and the per-landing full gate, whose Linux builder is x86_64. Run `just gate-fast` for the candidate. EP-256 records immutable tag qualification later.

## Validation and Acceptance


Both packages build and execute natively; successful Nix evaluation alone does not pass. An intentionally invalid typed config fails. Valid config loading does not depend on translated x86 executables, network downloads, user package databases or reading private wrapper internals. Existing supported tooling builds and host eligibility stay covered. Any dependency workaround must first use Mori source lookup and authoritative upstream registry/tag verification; this plan chooses no new bounds or pins.

## Idempotence and Recovery


Builds and isolated fixture checks can be repeated. Do not create or upgrade a production context. Keep failed-build evidence without publishing support claims. Existing release publication and artifact recovery are reused by EP-256; no application inventory event is needed merely to compile a local configuration.

## Interfaces and Dependencies


No hard prerequisites. EP-256 M2 consumes the public SDK/CLI exports and this plan's M2 evidence. This plan shares no files with EP-254, so run it in its own worktree session from the start. Do not wait for a public release to mark this child complete: its output is the tested candidate source and stable package interface, not publication.
