---
id: 107
slug: externalize-per-operator-nixos-and-host-configuration
title: "Externalize per-operator NixOS and host configuration"
kind: exec-plan
created_at: 2026-08-25T14:04:15Z
intention: "intention_01m0wkm982etqsxsrrmnw419a5"
master_plan: "docs/masterplans/20-versioned-distribution-and-clone-free-multi-cluster-operations-for-nagare.md"
---

# Externalize per-operator NixOS and host configuration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [107-externalize-per-operator-nixos-and-host-configuration.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/107-externalize-per-operator-nixos-and-host-configuration.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this plan, Nagare's source and released payload contain a reusable NixOS host module, not one
operator's host identity. `nagarectl host init --context prod` creates a small context-owned host flake
whose configuration explicitly supplies SSH public keys, instance/host name, registry host, sops
secret file, and age-key location. Host-image and day-2 rebuild commands consume that generated flake.

An operator can configure `prod` and `labs` independently without editing or generating files under
the Nagare release. Evaluation fails clearly when a required SSH key or secret path is absent. The
tracked personal key is removed, while an explicit compatibility fixture preserves the current
maintainer setup during migration.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-25T18:24:27Z) M1: Define reusable NixOS module options and export the module and host-construction helper from the Nagare flake.
- [x] (2026-08-25T18:33:05Z) M2: Add safe `nagarectl host init|show|path` generation for a context-owned host flake and operator config.
- [x] (2026-08-25T18:34:58Z) M3: Move host image, registry, sops, and day-2 commands from checkout files to the generated host flake.
- [x] (2026-08-25T18:45:12Z) M4: Validate two isolated contexts, migration compatibility, secret hygiene, and documentation.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `nixos/hosts/nagare-01/users.nix` contains a real maintainer SSH public key, while
  `registries.nix` optionally imports a generated `registry-host.nix`. These are two forms of the same
  problem: operator-owned inputs live in or beside distributable source. Date: 2026-08-25.
- Nix pure evaluation cannot casually import arbitrary files outside a flake source tree. A generated
  context host flake must contain its own operator module and import Nagare as a pinned flake input,
  instead of asking the immutable Nagare payload to reach outward into XDG config. Date: 2026-08-25.
- The nested flake can export a `lib.mkNagareSystem` function that closes over its pinned nixpkgs,
  sops-nix, GCE image module, and reusable Nagare module. Both image and day-2 outputs then evaluate
  from the same `nixosSystem`, while a generated flake contributes only its operator module. Evidence:
  `nix eval ./nixos#packages.x86_64-linux.nagare-image.drvPath` produced a derivation and
  `nix flake check ./nixos --no-build` accepted `nixosModules.nagare-host`. Date: 2026-08-25.
- A generated flake must omit semicolons between Nix list elements; the first end-to-end generator
  evaluation caught the invalid rendered `authorizedKeys` list before the staging directory could
  replace the destination. After correcting the renderer, an isolated `prod` host installed,
  repeated as `Unchanged`, and evaluated hostname, registry, and image derivation successfully.
  Date: 2026-08-25.
- The existing image script can use the same context guardrail and mutable Pulumi workspace while
  building from an independently resolved host flake. Isolated dry runs reported project
  `acme-prod`, registry `us-central1-docker.pkg.dev`, the context-owned flake, and the target
  `deploy@prod-node` without creating `registry-host.nix` in source. Date: 2026-08-25.
- Running `cabal test all` from `cli/nagarectl` also launches the sibling DSL suite with a package-db
  path rooted under `cli/nagare-dsl`, which fails in that combined invocation. Running the suites from
  their owning directories passes: 384 `nagarectl` tests and 384 `nagare-dsl` tests. The hermetic
  root `nix flake check --print-build-logs` also passes both packaged checks. Date: 2026-08-25.
- Strict capability-bundle validation now accepts the revised `single-node-gcp-substrate` concept and
  its model-review provenance, but the bundle-wide command still exits nonzero because the other 17
  pre-existing concepts lack the profile-recommended `reviews` field. That unrelated bundle migration
  is outside this ExecPlan. Date: 2026-08-25.

## Decision Log

Record every decision made while working on the plan.

- Decision: export a reusable NixOS module and generate one small host flake per context.
  Rationale: module options create a stable distribution boundary, while a self-contained generated
  flake satisfies Nix purity and gives each cluster an independently pinned Nagare release.
  Date: 2026-08-25.
- Decision: require SSH public keys explicitly and provide no personal or permissive fallback.
  Rationale: a published host image must never grant access to the project maintainer by default, and
  an empty immutable-user configuration can lock the actual operator out.
  Date: 2026-08-25.
- Decision: generate references to encrypted secret material but never copy age private keys,
  unencrypted Tailscale keys, kubeconfigs, or cloud credentials into the host flake.
  Rationale: the host flake is operator configuration and may be backed up or version-controlled; it
  must remain safe to inspect and share deliberately.
  Date: 2026-08-25.
- Decision: keep `nixos/hosts/nagare-01/configuration.nix` as an evaluation-only compatibility
  fixture with a conspicuously synthetic public key, while all real image and rebuild operations use
  a generated host flake.
  Rationale: preserving the old Nix output makes source evaluation and migration tests stable, but
  retaining a maintainer key anywhere in distributable source would violate the security boundary.
  Date: 2026-08-25.
- Decision: require `--sops-file` only for the first real `host init`; a dry run needs no secret file,
  and later idempotent or `--force` regeneration preserves the context's existing `secrets.yaml` when
  the flag is omitted.
  Rationale: this keeps initial secret ownership explicit while allowing safe scaffolding upgrades
  without rewriting operator-encrypted material.
  Date: 2026-08-25.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Nagare now exports a reusable `nagare.host` NixOS module and shared GCE system constructor, with no
maintainer SSH identity in the distributable source. `nagarectl host init|show|path` manages a
Nix-evaluated, context-owned flake containing public operator inputs and a sops-encrypted secret file;
generation is deterministic, idempotent, private-key aware, and atomically replaceable. Image and
day-2 scripts resolve that flake and expose dry runs instead of writing a registry override into the
checkout.

The acceptance run created `prod` and `labs` below one isolated XDG root with distinct SSH keys,
registries, instance names, and generated locks. Both NixOS configurations evaluated concurrently,
the keys did not cross contexts, `--force` preserved the encrypted secret bytes, and secret scans found
neither private-key blocks nor plaintext Tailscale tokens. Source compatibility still evaluates through
the explicit synthetic-key fixture. The operator guides and CAP-2 capability evidence now describe the
generated workflow. The durable boundary is recorded in
`docs/adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md`.

Validation passed `env -u NAGARE_PLATFORM_ROOT cabal test nagarectl-test` (384 tests), `cabal test all`
from `cli/nagare-dsl` (384 tests), `nix flake check --print-build-logs`,
`nix flake check ./nixos --no-build --all-systems`, generated-flake image/hostname/registry evaluation,
and the context-specific portion of strict capability validation. A live GCE image upload and remote
switch remain intentionally unperformed because they require operator credentials and billable cloud
mutation; command construction was verified by both script dry runs.

