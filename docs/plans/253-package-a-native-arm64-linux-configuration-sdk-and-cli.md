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
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-10T06:04:38Z
      mode: "implement"
      note: "Implement the tooling-only ARM64 Linux SDK and CLI with a native consumer check and gate override."
---

# Package a native ARM64 Linux configuration SDK and CLI


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current. Record implementation friction through the repository's exec-plan workflow.

## Purpose / Big Picture


An ARM64 Linux application runner can use a packaged Nagare CLI and configuration SDK from outside the Nagare checkout, without a user Cabal database. The runner can compile an existing Application containing a service, worker and migration task. This satisfies the tooling portion of IR-42 AC-1; it does not add ARM64 production hosts.

## Progress


- [x] M1: `packages.aarch64-linux.nagarectl` and `nagare-config-sdk` build natively, with `release.json` unchanged. Evidence, revision `5011a9b69df8c7e08bfa92957858b8ed66733984`, native arm64 Apple container (`uname`: Linux aarch64, Nix 2.35.2): `nix build` exit 0 for `/nix/store/01xfmz6mv5d1r3i3vawr74bc96a33kq4-nagarectl-0.17.0` (`nagarectl version --json` reports that revision, version 0.17.0) and `/nix/store/bpdi2nf48pn0qbgdkah6vqnxyn6iikfb-ghc-9.12.4-with-packages` (GHC 9.12.4, target `aarch64-unknown-linux`). GHC came from cache.nixos.org; the Haskell dependency closure, including nagare-dsl and nagarectl, built from source. `nagare-config-sdk` also builds on aarch64-darwin (`/nix/store/z73jpdwlx6m46r6hc9pi9xbv98vmr3av-ghc-9.12.4-with-packages`) and is listed on x86_64-linux. `aarch64-linux` outputs are exactly packages `nagare-config-sdk`, `nagarectl` and check `nagare-config-sdk-consumer`, with empty apps, devShells and legacyPackages and no hydraJobs; `release.json` is unchanged.
- [x] M2: An isolated ARM64 Linux consumer executes the packaged CLI and compiles the representative Application, with revision-bound evidence. Evidence, revision `5011a9b69df8c7e08bfa92957858b8ed66733984`: check derivation `/nix/store/j998bx72bfhwxkchjagchd0lf99csxaq-nagare-config-sdk-consumer.drv` built exit 0 on an `--internal`, `--no-dns` network (1.1.1.1:53 unreachable). `evidence.json`: system Linux-aarch64, compiler 9.12.4, DSL `nagare-dsl-0.0.0-Ld8ssASo2cMKBrgnYd02zd`, CLI and SDK store paths as in M1, `nagarectl app check` reports a service, 1 worker and 1 task, the SDK's GHC compiled and ran the same file, and the invalid config exited 1. The same check exits 1 on a networked container, by its network guard.

The evidence above predates EP-254. After merging onto master, the same run at revision `536573ea7cf3c6c9971a1e4dc170603dc1036602` passed: `nagarectl` `/nix/store/39r42dyvi0g6rj8wa95mfl0ny95qpyaq-nagarectl-0.17.0`, SDK `/nix/store/fkqac5hhp6d249qxq00vbm5ac1a66dkv-ghc-9.12.4-with-packages`, `Linux-aarch64`, GHC 9.12.4, an Application with a service, one worker and one task, and an invalid config exiting 1 on the isolated network.

## Surprises & Discoveries


- `nix flake check --all-systems` has no way to leave a system out, and evaluating `packages.aarch64-linux` needs import-from-derivation on an `aarch64-linux` builder that the landing gate does not have. A plain tooling list in `flake.nix` would have broken the full gate, so the list became a flake input that the gate overrides to empty, and `scripts/check-release.sh` no longer assumes the flake's systems equal `release.json`.
- Apple's container kernel does not support the namespaces Nix's sandbox needs (`this system does not support the kernel namespaces`, with `--cap-add ALL` too), so the sandbox cannot provide the no-network proof there. The consumer check runs in a second container on an `--internal` network with no DNS, and the script fails if the network is reachable.

## Decision Log


- Decision: Publish an explicit SDK export and distinguish tooling support from host support, because adding a system to every existing release matrix would overstate the requested capability. Date: 2026-11-09.
- Decision: Leave `release.json` `supportedSystems` unchanged and list tooling systems in `flake.nix`. Rationale: that field is read by the gate, the verify step, release evidence and a candidate check requiring exactly the two current systems; extending it would need a schema change and migration tests to say something a flake output already says (operator, 2026-11-09). Date: 2026-11-09.
- Decision: `aarch64-linux` gets no platform payload, so its `nagarectl` wrapper sets no `NAGARE_PLATFORM_ROOT`. Rationale: the payload embeds an x86_64 controller image that would need a cross toolchain on ARM64, and platform commands are outside a tooling-only promise. Date: 2026-11-09.
- Decision: `nagarectl`'s test suite stays out of the `aarch64-linux` package derivation, as on `aarch64-darwin`. Rationale: `x86_64-linux` remains the tested derivation; the consumer check is the ARM64 evidence. Date: 2026-11-09.
- Decision: The tooling list is the `tooling-systems` flake input (`nix/tooling-systems`), and the full gate passes `--override-input tooling-systems path:./nix/tooling-systems/none`. Rationale: a pure flake has no other channel for the gate to narrow `--all-systems`, and the override leaves release-system derivations unchanged (compared `drvPath` for `checks.x86_64-linux.nagarectl-external-config`, `checks.aarch64-darwin.nagare-api-server-build-test` and `packages.x86_64-linux.nagare-platform`: identical). Date: 2026-11-09.

## Outcomes & Retrospective


The tooling-only SDK and CLI build natively on ARM64 Linux and pass the isolated consumer check from the candidate source; ADR 3 records the public exports and the support boundary. A release candidate still has to run the check by hand in a native Apple container, since the harness candidate flow is unchanged; EP-256 M2 consumes it.

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

Evaluating these attributes needs import-from-derivation on an `aarch64-linux` builder, so a Mac without one cannot produce the drvPaths; evaluate and build inside the container. The native run:

```bash
container volume create nagare-ep253-nix
container run -d --name nagare-ep253-arm64 --arch arm64 --cpus 8 --memory 20G \
  -v nagare-ep253-nix:/nix docker.io/nixos/nix:2.35.2 sleep infinity
# Seed the volume from the image's /nix on first use, enable flakes, then:
nix build --no-link --no-write-lock-file \
  "git+file:///work/nagare?rev=$REV#packages.aarch64-linux.nagare-config-sdk" \
  "git+file:///work/nagare?rev=$REV#packages.aarch64-linux.nagarectl"
# Then stop that container and rerun on an isolated network for the check:
container network create --internal nagare-ep253-isolated
container run -d --name nagare-ep253-offline --arch arm64 --cpus 8 --memory 20G --no-dns \
  --network nagare-ep253-isolated -v nagare-ep253-nix:/nix docker.io/nixos/nix:2.35.2 sleep infinity
# Flake fetches need the network, so evaluate on the first container and build the .drv here:
nix build --offline --option substitute false --print-build-logs "$CHECK_DRV^out"
```

The check's `evidence.json` output records architecture, compiler, package identity and exit statuses. The Mac's full gate omits `aarch64-linux`, so this run is the only proof of the check.

## Validation and Acceptance


Both packages build and execute natively; successful Nix evaluation alone does not pass. An intentionally invalid typed config fails. Valid config loading does not depend on translated x86 executables, network downloads, user package databases or reading private wrapper internals. Existing supported tooling builds and host eligibility stay covered. Any dependency workaround must first use Mori source lookup and authoritative upstream registry/tag verification; this plan chooses no new bounds or pins.

## Idempotence and Recovery


Builds and isolated fixture checks can be repeated. Do not create or upgrade a production context. Keep failed-build evidence without publishing support claims. Existing release publication and artifact recovery are reused by EP-256; no application inventory event is needed merely to compile a local configuration.

## Interfaces and Dependencies


No hard prerequisites. EP-256 M2 consumes the public SDK/CLI exports and this plan's M2 evidence. This plan shares no files with EP-254, so run it in its own worktree session from the start. Do not wait for a public release to mark this child complete: its output is the tested candidate source and stable package interface, not publication.
