---
type: Improvement Request
title: Make nagarectl host init render the host option the NixOS module declares
description: Since the semantic-record-label refactor, host init writes nagare.host.name, which the packaged module does not declare, so v0.2.0 and v0.2.1 cannot generate any new host flake.
timestamp: "2026-09-14T00:12:08Z"
generated:
  by: process:claude-code
  at: "2026-09-13T23:54:44Z"
requestId: IR-13
status: accepted
targetPlan: docs/plans/128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md
origin: mori://shinzui/nagare
---

# Improvement Request: make `nagarectl host init` render `nagare.host.hostName`

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout on `v0.2.1`
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** accepted; the fix is in `3a107d3` and ships in 0.2.2, planned as [ExecPlan 128](../plans/128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md).
**Created:** 2026-09-13.


## Why

On `v0.2.1`, `nagarectl host init --context labs --ssh-public-key-file ~/.ssh/id_ed25519.pub
--sops-file hosts/labs/secrets.yaml --host-name labs-nagare` passed its `--dry-run`, then failed
flake validation on the real run:

```text
error: The option `nagare.host.name' does not exist. Definition values:
- In `/nix/store/…-source/host.nix': "labs-nagare"
Did you mean `nagare.host.hostName', `nagare.host.instanceName' or `nagare.host.ageKeyFile'?
```

The failure is not specific to `--host-name`: the renderer emits the wrong attribute for every host.
So no operator can create a host flake for a new context on `v0.2.0` or `v0.2.1`, which blocks
`nagare host-image` and therefore every new cloud cluster. The generator stages into a temporary
directory and validates before moving it into place (`cli/nagarectl/src/Nagare/Host/Config.hs:236-240`),
so nothing was written — the failure is safe, just total.


## What is missing

`renderHostModule` writes `"    name = " <> nixString (config ^. #name) <> ";"`
(`cli/nagarectl/src/Nagare/Host/Config.hs:135` at `v0.2.1`), but the packaged module declares only
`hostName` (`nixos/modules/nagare-host.nix:30`, consumed as `networking.hostName = cfg.hostName;` at
line 111).

`git log -S` places the change in `a8918f9` (2026-09-13, "refactor(nagarectl): adopt semantic record
labels"), which renamed the Haskell field `hostName` to `name` and, with it, the rendered Nix
attribute (`-    , "    hostName = " …` / `+    , "    name = " …`). Both `v0.2.0` and `v0.2.1` contain
that commit, and `HEAD` (`a375059`) still renders `name =`.

Existing host flakes generated before the refactor (for example the operator's `tan-nb-exp` flake,
whose `host.nix` still says `hostName = "nagare-01";`) keep working, because the upgrade path copies
`host.nix` verbatim (`stageHostFlake`). That is why the regression went unnoticed on the one live
cluster. A `host init --force` against such a context would now also fail validation.

No test catches it. `cli/nagarectl/test/HostSpec.hs` asserts substrings of the rendered text (the
flake input, the output name, the key, `sopsDefaultFile`) but never the host-name attribute, and
nothing under `nix/checks` evaluates a freshly rendered host flake against the packaged module.


## Requested change

- Render `hostName = …;` in `renderHostModule` (keep the Haskell label `name` if preferred; the Nix
  attribute is a contract with `nixos/modules/nagare-host.nix`, not a record label).
- Add a `nix/checks` check that runs the real renderer for a fixture context and evaluates the
  resulting flake's `nixosConfigurations.<name>.config.networking.hostName` against the packaged
  module, so any drift between renderer and module fails CI.
- Add a `HostSpec` assertion that the rendered module contains `hostName = "<name>";`.
- Cut a patch release; `v0.2.0` and `v0.2.1` cannot onboard a new host.


## Required verification

- The new check fails on `a375059` and passes with the fix.
- `nagarectl host init` for a new context succeeds end to end (validation included), and
  `nagarectl host init --force` for a context generated before `a8918f9` reports unchanged scaffolding
  or a `hostName`-only diff.


## Acceptance

A fresh `nagarectl host init` on the patched release writes a host flake that evaluates, and CI
proves the renderer and the module agree on every `nagare.host.*` attribute the renderer emits.


## Non-goals

Renaming the module option. Operator flakes in the wild already use `hostName`.
