---
type: Runbook
title: "Upgrades"
description: "Plan, apply, verify, and roll back Nagare platform, host, cluster, and observability upgrades."
docId: DOC-35
tags: [upgrades, releases, rollback, operations]
generated:
  by: human:nadeem
  at: 2026-08-25T20:53:35Z
---

# Upgrades

> **Status:** ✅ Supported procedure

Nagare treats the CLI, immutable platform payload, context, generated host
flake, and cluster marker as one versioned release. `platform status` compares
those five identities; `platform upgrade` stages and previews a new release,
persists every phase, and advances the context only after the infrastructure,
host, and cluster phases succeed.

Run cloud commands with the intended [target context](contexts.md) active. Keep
the IAP path in [Accessing the host](accessing-the-host.md) available before a
host or networking change.

## Inspect release identity

Select both the Nagare context and its matching kubeconfig, then inspect the
release before any mutation:

```bash
export NAGARE_CONTEXT=labs
export KUBECONFIG="$HOME/.config/nagare/kubeconfigs/labs.yaml"
nagarectl platform status
nagarectl platform status --json
```

The report names the CLI, payload, context, host, and cluster versions. Its
compatibility result has these meanings:

| Result | Meaning |
| --- | --- |
| `exact` | Every identity reports the payload version. |
| `patch-skew` | A patch differs; inspection and compatible mutation remain available. |
| `minor-upgrade-required` | Run the explicit upgrade workflow before platform mutation. |
| `major-incompatible` | Platform mutation is blocked until a compatible CLI and release are selected. |
| `legacy-unknown` | At least one identity is absent, old, or unreachable; inspect it before adoption or upgrade. |

Status and doctor remain read-only and useful when Kubernetes is unreachable.
An absent `nagare-platform-version` ConfigMap is reported as unknown rather
than inferred from currently running workloads.

## Adopt a legacy context

A context created before release pins has no `NAGARE_PLATFORM_VERSION`.
Adoption records the release already in use; it is not an upgrade. First read
the observations, verify that the selected kubeconfig points at this context's
cluster, and then confirm the exact payload version:

```bash
nagarectl platform status
nagarectl platform adopt --version 0.1.0 --yes
```

`platform adopt` repeats the observations before changing anything. It only
accepts an unversioned context, requires the requested version to equal the
active payload, and rejects every known CLI, host, or cluster mismatch. An
absent cluster marker is created before the context pin is committed. If that
write fails, the context remains legacy and the command can safely be retried.

## Plan and apply a release upgrade

Read the target release notes and invoke the **target release's** CLI. Its packaged payload becomes
the upgrade candidate; the currently installed CLI cannot invent or fetch a payload from a bare
version number. Planning is the default and does not change the context, host, infrastructure, or
cluster:

```bash
export TARGET_NAGARE_VERSION=0.2.0
export TARGET_NAGARE="github:shinzui/nagare/v${TARGET_NAGARE_VERSION}"
nix run "${TARGET_NAGARE}#nagarectl" -- \
  platform upgrade --to "$TARGET_NAGARE_VERSION" --dry-run --json > upgrade-plan.json
transaction_id="$(jq -r '.transactionId' upgrade-plan.json)"
nix run "${TARGET_NAGARE}#nagarectl" -- platform upgrade status "$transaction_id"
```

Review the immutable workspace and staged host-flake paths, Nix evaluation,
Pulumi preview, and Kubernetes diff recorded in the transaction. Back up any
stateful workloads when the release notes call for a migration. Apply only the
reviewed transaction:

```bash
nix run "${TARGET_NAGARE}#nagarectl" -- \
  platform upgrade --apply --resume "$transaction_id" --yes
nix run "${TARGET_NAGARE}#nagarectl" -- platform status
```

Apply runs Pulumi, switches and commits the staged host flake, reconciles the
cluster, stamps its release ConfigMap, and atomically advances the context pin
last. A failure preserves the transaction and the old context pin. Inspect and
resume the same identifier after correcting the cause:

```bash
nix run "${TARGET_NAGARE}#nagarectl" -- platform upgrade status "$transaction_id" --json
nix run "${TARGET_NAGARE}#nagarectl" -- \
  platform upgrade --apply --resume "$transaction_id" --yes
```

Resume rechecks successful phases and reruns convergent operations whose
postcondition cannot be proven. Reapplying a completed transaction is a no-op.
Each context has separate history and immutable workspaces under its XDG state
directory.

## Rollback boundaries

Rollback is available only when the target release metadata explicitly allows
the previous version and the retained old payload is still present:

```bash
nix run "${TARGET_NAGARE}#nagarectl" -- \
  platform upgrade rollback "$transaction_id" --yes
```

This creates and applies a reverse release-selection transaction. It does not
claim to delete infrastructure, reverse Pulumi schema migrations, restore
databases, or restore persistent volumes. Use the backup and recovery
procedures before attempting a release rollback involving stateful changes.

The sections below are for contributors and release maintainers working in a source checkout. They
describe how release maintainers update the individual pins
that are assembled into a Nagare platform payload. Operators should normally
use the transaction workflow above rather than changing those pins in place.

## NixOS host

The NixOS inputs move only when the lock file is updated. The current nixpkgs
lock dates from 2026-05-31; ordinary `nixos-rebuild` runs do not advance it.

```bash
cd nixos
nix flake update
cd ..
git diff -- nixos/flake.lock
nagarectl host init --force --ssh-public-key-file "$HOME/.ssh/id_ed25519.pub"
host_flake="$(nagarectl host path)"
nix eval "path:$host_flake#packages.x86_64-linux.nagare-image.drvPath"
```

Read the nixpkgs and NixOS release notes covered by the diff. In particular,
check renamed options, bootloader changes, and the k3s package version. Do not
change `system.stateVersion` as part of a routine update.

For a healthy running host, activate the reviewed closure through the day-2
path:

```bash
just host-switch
```

That uses Tailscale SSH. If Tailscale is unavailable, use the IAP tunnel and
`nixos-rebuild --build-host` fallback in
[Day-2 host changes](day-2-host-changes.md#break-glass-switch-over-iap). For
risky networking or SSH changes, replace `switch` with `test` first so a reboot
returns to the prior boot generation.

For a DR-grade refresh, bake and register a new image, review the Pulumi
replacement, and boot it:

```bash
just host-image
pulumi -C infra/pulumi preview
pulumi -C infra/pulumi up
```

A kernel or systemd upgrade is present in the switched closure, but the running
kernel and PID 1 change only after a reboot or VM replacement. Verify the host
returns through both Tailscale and IAP before deleting an older image or boot
generation.

If enabling k3s Secret encryption on an existing v1.34.6+k3s1 host, use the
version-gated upstream sequence: back up `state.db`, run `secrets-encrypt
enable`, restart with `--secrets-encryption`, verify stage `start`, run
`secrets-encrypt rotate-keys`, restart again, and wait for status `Enabled` /
`reencrypt_finished`. Do not substitute the older
`prepare`/`rotate`/`reencrypt` workflow.

## Cluster components

The `justfile` pins Knative Serving, Kourier, cert-manager, and the local k3s
image. net-certmanager currently has an independent v1.14.0 GCS pin because the
Knative Serving v1.22.0 release does not ship a `net-certmanager.yaml` asset.
Each `cluster/bootstrap/*/README.md` records the source and discovery command.

Before changing a pin:

1. Read the upstream release notes and supported Kubernetes-version matrix.
2. Inspect the release assets rather than constructing a URL from memory.
3. If Knative raises its Kubernetes minimum, bump `k3s_image` in lockstep so
   local rehearsal covers the same API surface as the cloud host.
4. Change one component family at a time and review the rendered upstream
   manifests for new permissions, CRDs, or security defaults.

Then reconcile the new release in place:

```bash
just cluster-bootstrap
kubectl -n cert-manager rollout status deploy/cert-manager-webhook
kubectl -n knative-serving rollout status deploy/controller
kubectl -n knative-serving rollout status deploy/net-certmanager-controller
kubectl -n kourier-system rollout status deploy/3scale-kourier-gateway
```

The bootstrap recipe uses `kubectl apply` and ConfigMap patches, so re-running
it upgrades the controllers without recreating application resources. Preserve
the `registriesSkippingTagResolving` patch for the private registry.

Rehearse a cluster-pin change locally before the cloud apply when Docker is
available:

```bash
just local-up
just local-bootstrap
just local-minio
# change one pin, then repeat local-bootstrap
just local-bootstrap
just local-smoke
```

## Observability charts

`cluster/observability/install.sh` owns the VictoriaMetrics, VictoriaLogs,
VictoriaTraces, and OpenTelemetry chart versions. Discover candidates with the
`helm search repo ... --versions` commands in that script, read the chart's
upgrade notes and values diff, update one chart pin and its values comments,
then run:

```bash
just observability
helm list -A
kubectl get pods -n monitoring -n logging -n tracing
```

The installer uses `helm upgrade --install`; keep every explicit resource,
retention, datasource, and security override when adopting a new chart default.

## Verification and rollback

After any layer upgrade:

```bash
nagarectl doctor
just status
just local-smoke # zero-cloud regression path
just smoke       # live GCP/IAP/GCS path, when credentials and the VM are available
```

Also exercise the capability touched by the upgrade: an uncached private-image
pull after host work, a Knative Service rollout after cluster work, or a Grafana
query after observability work. If verification fails, revert only that layer's
lock or pin commit and re-run its convergent apply command.

## Cadence

- Monthly: update the NixOS lock, review, switch, and schedule a reboot when the
  kernel or systemd changed.
- Quarterly: review the Knative, Kourier, cert-manager, net-certmanager, local
  k3s, and observability pins.
- Immediately: assess security advisories that affect an exposed or privileged
  component.

Never combine host and cluster pin changes in one maintenance session. A quiet
quarter is a valid outcome when the reviewed releases do not justify the risk.
