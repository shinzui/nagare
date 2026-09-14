---
type: Improvement Request
title: Make host-image show, and confine, the GCP project its Nix remote builder runs in
description: nagare host-image passes every project guard, but the image is built by the workstation's Nix remote builder, whose SSH proxy can start and use a VM in a different GCP project that no nagare guard can see.
timestamp: "2026-09-14T04:26:09Z"
generated:
  by: process:claude-code
  at: "2026-09-14T02:40:00Z"
requestId: IR-17
status: accepted
acceptedAt: "2026-09-14T04:26:09Z"
targetPlan: docs/plans/136-apply-reviewed-infrastructure-and-confine-remote-builders.md
origin: mori://shinzui/nagare
---

# Improvement Request: confine or at least surface the host-image builder's project

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** accepted for implementation by
[ExecPlan 136](../plans/136-apply-reviewed-infrastructure-and-confine-remote-builders.md).
**Created:** 2026-09-14.


## Why

The operator's rule for the `labs` rollout was that nothing may affect a GCP project other than
`tan-ng-labs`. `scripts/upload-images.sh` (`v0.2.2`) honours that for everything it does itself: it
runs `_require_target_project`, asserts bucket ownership, and passes `--project tan-ng-labs` to every
`gcloud` call. But the image is built by a plain `nix build` of an `x86_64-linux` attribute, which on
an `aarch64-darwin` workstation goes to the Nix remote builder. That builder is not part of the
context at all.

On the operator workstation, `/etc/nix/machines` lists one builder, `ssh://builder@nix-gcp-builder`.
Its `ProxyCommand`, the per-workstation wiring that `scripts/setup-nix-builder.sh`'s header refers to
as "managed in dotfiles.nix", hard-codes `PROJECT=tan-nb-exp` and runs
`gcloud compute instances start nix-builder-x86` if the VM is not running. The builder was
`TERMINATED`; `nagare host-image --context labs` would have started it and billed compute in
`tan-nb-exp`. Only a read of the dotfiles found this. The operator accepted it as a deliberate
exception, and on 2026-09-14 the build did start `nix-builder-x86` in `tan-nb-exp`.

The docs present the builder as per-project: `setup-nix-builder.sh` provisions it inside the context's
`TARGET_PROJECT`, and `docs/user/host-image-and-boot.md` calls it "on-demand GCP VM". The actual
connection is per-workstation, so after onboarding a second context every image build keeps using the
first project's builder, silently. The same gap exists in the other direction: running
`setup-nix-builder.sh` for the new context creates a builder there, but the workstation never uses it.


## What is missing

- `host-image` never says where the build will run. Its `--dry-run` prints context, project, registry,
  flake and attribute, but not the builders Nix will use.
- No guard compares the builder's project with the context's project.
- No supported way to route one context's builds to that context's builder.
- The reference proxy the scripts rely on is not shipped or documented in nagare, so its hard-coded
  project is invisible from the nagare docs.


## Requested change

- In `upload-images.sh --dry-run` and before the build, print the effective Nix builders
  (`nix config show builders`, plus `/etc/nix/machines` when `builders = @/etc/nix/machines`).
- Ship the builder proxy with nagare (or document it fully) with the project, zone and instance as
  parameters read from the context, not literals. Give each context its own SSH host alias, e.g.
  `nagare-builder-<context>`.
- Make `host-image` pass that builder explicitly for the build (`--builders` or `NIX_CONFIG`), so a
  context's image builds on that context's builder by default.
- Allow an explicit, logged opt-in to a shared builder in another project (for example
  `NAGARE_BUILDER_PROJECT=tan-nb-exp`), refusing otherwise when the builder's project is known and differs.


## Required verification

- A script check that `--dry-run` prints the builder list.
- A test that the rendered proxy for context `labs` names that context's project and instance, and
  that `host-image` refuses when a known builder project differs without the opt-in.


## Acceptance

An operator reading `nagare host-image --dry-run` for any context can see which GCP project the image
build will start and use, and by default that is the context's own project.


## Non-goals

Replacing the remote-builder approach, or supporting builders outside GCP.
