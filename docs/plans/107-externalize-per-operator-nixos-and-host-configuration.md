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
- [ ] M3: Move host image, registry, sops, and day-2 commands from checkout files to the generated host flake.
- [ ] M4: Validate two isolated contexts, migration compatibility, secret hygiene, and documentation.


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

(To be filled during and after implementation.)


## Context and Orientation

This plan hard-depends on
`docs/plans/106-make-nagare-platform-assets-resolvable-outside-a-source-checkout.md`. EP-106 defines
the installed platform payload, per-context workspace, and absolute paths used by scripts. Use those
interfaces for all host commands.

The nested `nixos/flake.nix` currently constructs one `nagare01Modules` list from the upstream GCE
module, `nixos/configuration-base.nix`, `sops-nix`, and
`nixos/hosts/nagare-01/configuration.nix`. It exposes `packages.x86_64-linux.nagare-image` and
`nixosConfigurations.nagare-01`. The host configuration imports `users.nix`, `registries.nix`,
`tailscale.nix`, storage, networking, security, and k3s modules. `users.nix` embeds a public key.
`configuration.nix` points sops-nix at a tracked encrypted YAML path and a fixed on-host age private
key location. `registries.nix` reads an optional generated file in the source tree.

`scripts/upload-images.sh` builds the nested flake, uploads the image tarball, registers a GCE image,
and writes its self-link into the active Pulumi stack. `justfile`'s `nixos-registry-host`, `host-image`,
and `host-switch` recipes assume that nested source tree. The onboarding guide instructs the operator
to edit `users.nix` before building, then manually create age/Tailscale secret material.

A generated host flake in this plan is a user-owned Nix flake below
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/hosts/<context>/`. Its `flake.nix` imports the Nagare release
as an input; its `host.nix` supplies values to the exported Nagare module; its encrypted secrets file
may live alongside it. The directory is separate from EP-106's derived workspace because it contains
long-lived operator intent that must survive payload replacement.

No local or Mori ADR covers this boundary. If the module option namespace and generated-flake model
remain after implementation, record them as a new ADR before completing the plan.


## Plan of Work

### Milestone 1 — Export a configurable Nagare host module

This milestone refactors without changing the live host result. Introduce a module such as
`nixos/modules/nagare-host.nix` that composes the existing host modules and declares a `nagare.host`
option namespace. Required options include one or more operator SSH public keys. Defaultable options
include hostname/instance name, registry host, deploy user name, and the on-host age-key path. The
sops default file is supplied by the generated flake as a path. Export the module as
`nixosModules.nagare-host` and a tested host-construction helper from `nixos/flake.nix`. Keep a
repository-local compatibility configuration that passes the current values explicitly until the
generator is proven; remove the key from `users.nix` itself.

### Milestone 2 — Generate context-owned host flakes

This milestone adds a Haskell model and CLI. Create `Nagare.Host.Config` with validated public-key and
path types plus deterministic Nix rendering. Add `nagarectl host init`, `host show`, and `host path` to
`cli/nagarectl/app/Main.hs`. `host init` resolves a named context, accepts `--ssh-public-key-file`
(repeatable), optional `--sops-file`, optional `--age-key-file` for the path that will exist on the
host, and refuses to overwrite without `--force`. It writes a staging directory, checks the rendered
flake with `nix flake check` or `nix eval`, and atomically installs it. It never reads or copies a
private key.

### Milestone 3 — Route host operations through generated configuration

This milestone updates operational consumers. Teach `scripts/upload-images.sh`, `scripts/setup-nix-builder.sh`
where relevant, and the host-related `justfile` recipes to accept `NAGARE_HOST_FLAKE` or obtain the
path from `nagarectl host path`. Build `packages.x86_64-linux.nagare-image` and
`nixosConfigurations.<host>` from the generated flake. Remove `nixos-registry-host`'s write into the
source tree. Ensure source-development compatibility uses the explicit compatibility host flake, not
a hidden fallback key.

### Milestone 4 — Validate isolation, migration, and secret hygiene

This milestone validates independence and updates operator docs. Under temporary XDG roots create two
contexts with different keys, registry hosts, and instance names; generate both host flakes; evaluate
them concurrently; and assert each closure contains only its own public configuration. Add secret
hygiene tests that reject private-key blocks and plaintext Tailscale tokens in generated output.
Update `docs/user/onboarding-bring-your-own-project.md`, `host-image-and-boot.md`, `day-2-host-changes.md`,
and `secrets.md` with the generated configuration workflow, while EP-109 later changes the top-level
installation story.


## Concrete Steps

From the repository root, inspect and evaluate the existing host before refactoring:

```bash
nix eval ./nixos#nixosConfigurations.nagare-01.config.system.build.toplevel.drvPath
nix eval ./nixos#packages.x86_64-linux.nagare-image.drvPath
```

Generate a host under isolated configuration after implementing the CLI:

```bash
cfg_root="$(mktemp -d)"
XDG_CONFIG_HOME="$cfg_root/config" XDG_STATE_HOME="$cfg_root/state" \
  nix run .#nagarectl -- context create prod \
    --project acme-prod --registry-host us-west1-docker.pkg.dev
XDG_CONFIG_HOME="$cfg_root/config" XDG_STATE_HOME="$cfg_root/state" \
  nix run .#nagarectl -- host init --context prod \
    --ssh-public-key-file test/fixtures/operator.pub --dry-run
```

The dry run should list only intended public paths and values. A real isolated fixture run should
then support:

```bash
host_root="$(XDG_CONFIG_HOME="$cfg_root/config" nix run .#nagarectl -- host path --context prod)"
nix flake check "path:$host_root"
nix eval "path:$host_root#packages.x86_64-linux.nagare-image.drvPath"
```

Finish with Haskell, Nix, and secret scans:

```bash
cd cli/nagarectl && cabal test all
cd ../.. && nix flake check --print-build-logs
rg -n 'BEGIN .*PRIVATE KEY|tailscale.*authkey.*=' "$cfg_root/config/nagare/hosts" && exit 1 || true
```


## Validation and Acceptance

The exported Nagare NixOS module must evaluate when supplied a valid operator module and must fail
with a clear assertion when `authorizedKeys` is empty. The repository compatibility host must
evaluate to the same essential hostname, deploy user, registry configuration, sops secret names, k3s
settings, and image output as before; compare targeted `nix eval` values rather than relying only on a
successful build.

`nagarectl host init` must be deterministic, refuse invalid context names and invalid SSH public-key
lines, avoid overwriting by default, and leave no partial directory on failed Nix evaluation. Two
contexts must generate different flake roots and evaluate without writing the Nagare source or each
other's configuration. `git status --short` after generation must show no new NixOS override or secret
files in the repository.

Search the tracked tree to ensure the former personal public key is absent and no private keys or
plaintext enrollment tokens were added. The host image script's `--dry-run` must print the generated
flake path and correct context project/registry. A live image build is optional and requires explicit
operator/GCP authority; evaluation and command-construction tests are mandatory and offline.


## Idempotence and Recovery

Generation uses staging plus atomic rename. Repeating `host init` with identical inputs reports no
change. `--force` first writes and validates a replacement beside the old directory, then swaps it; a
failed validation keeps the old flake. Do not delete or rewrite the operator's encrypted sops file
when regenerating Nix scaffolding.

Keep the explicit repository compatibility host through this plan so existing image and day-2
operations have a fallback. Rollback means selecting that compatibility flake or restoring the prior
context host directory from its generated backup; it never means restoring a maintainer key as an
implicit module default.


## Interfaces and Dependencies

This plan hard-depends on EP-106's payload/path/workspace contract. The generated flake input must
reference the payload's release identity in a form EP-108 can update without rewriting `host.nix`.

`nixos/flake.nix` exports `nixosModules.nagare-host`. The module provides options equivalent to:

```nix
nagare.host = {
  hostName = lib.mkOption { type = lib.types.str; };
  instanceName = lib.mkOption { type = lib.types.str; };
  registryHost = lib.mkOption { type = lib.types.str; };
  deployUser = lib.mkOption { type = lib.types.str; default = "deploy"; };
  authorizedKeys = lib.mkOption { type = lib.types.nonEmptyListOf lib.types.str; };
  sopsDefaultFile = lib.mkOption { type = lib.types.path; };
  ageKeyFile = lib.mkOption { type = lib.types.str; default = "/var/lib/sops-nix/age-key.txt"; };
};
```

Use the exact option form supported by the pinned nixpkgs after inspecting its source through the
project's flake input; do not search `/nix/store`.

`cli/nagarectl/src/Nagare/Host/Config.hs` owns validated rendering with an interface equivalent to:

```haskell
data HostConfig = HostConfig
  { hostContext :: ContextName
  , hostName :: Text
  , registryHost :: Text
  , authorizedKeys :: NonEmpty Text
  , sopsFile :: FilePath
  , ageKeyFile :: FilePath
  }

renderHostFlake :: HostConfig -> BuildVersion -> Text
renderHostModule :: HostConfig -> Text
```

`NAGARE_HOST_FLAKE` is an explicit process override for scripts. Stored contexts do not embed the
absolute generated path; `nagarectl host path` derives it from XDG config and the context name.
