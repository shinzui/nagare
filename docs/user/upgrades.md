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
For a cloud context, a project- and zone-scoped GCE lookup that explicitly returns NotFound renders
both `Host: not deployed` and `Cluster: not deployed`; those absent identities do not hide real
CLI/context patch skew. An existing unversioned host, an unreachable cluster, and every failed GCE
lookup remain `legacy-unknown` rather than being inferred as absent.

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

## Re-pin a context before its first deployment

If you initialized a versioned context with an older patch but have not created its VM, select the
current release's CLI and re-pin the context before provisioning:

```bash
export TARGET_NAGARE_VERSION=0.3.0
export TARGET_NAGARE="github:shinzui/nagare/v${TARGET_NAGARE_VERSION}"
nix shell "${TARGET_NAGARE}#nagare" -c nagarectl \
  platform repin --version "$TARGET_NAGARE_VERSION" --yes
```

Re-pin is narrower than adoption or upgrade. It requires the requested version to match the active
immutable payload, runs the platform, ADC, and project guards, and proceeds only when an explicit
GCE NotFound proves the context's named instance does not exist. Authentication, permission,
network, or malformed-output failures refuse. If a generated context-owned host flake exists, its
Nagare input and release comments advance with the context while `host.nix` and `secrets.yaml`
remain untouched. Unrecognized generated files refuse before either pin changes. Once the instance
exists, use the normal upgrade workflow; there is no force option.

## Plan and apply a release upgrade

Read the target release notes and invoke the **target release's** CLI. Its packaged payload becomes
the upgrade candidate; the currently installed CLI cannot invent or fetch a payload from a bare
version number. Infrastructure operations use the target release's complete `#nagare` operator
package, which puts the release-pinned Pulumi CLI and Pulumi Node.js language host on the invoked
`nagarectl` process's `PATH`. The smaller `#nagarectl` output remains the right choice for
application-only commands, but it deliberately omits those operator tools. Planning is the default
and does not change the context, host, infrastructure, or cluster:

```bash
export TARGET_NAGARE_VERSION=0.2.0
export TARGET_NAGARE="github:shinzui/nagare/v${TARGET_NAGARE_VERSION}"
nix shell "${TARGET_NAGARE}#nagare" -c nagarectl \
  platform upgrade --to "$TARGET_NAGARE_VERSION" --dry-run --json > upgrade-plan.json
transaction_id="$(jq -r '.id' upgrade-plan.json)"
nix shell "${TARGET_NAGARE}#nagare" -c nagarectl platform upgrade status "$transaction_id"
```

Review the immutable workspace and staged host-flake paths, Nix evaluation,
Pulumi review bundle, and Kubernetes diff recorded in the transaction. Back up any
stateful workloads when the release notes call for a migration. Apply only the
reviewed transaction:

```bash
nix shell "${TARGET_NAGARE}#nagare" -c nagarectl \
  platform upgrade --apply --resume "$transaction_id" --yes
nix shell "${TARGET_NAGARE}#nagare" -c nagarectl platform status
```

The Pulumi preview phase runs the project and protected-resource guards and stores a private
context-bound plan bundle inside the transaction directory. Pulumi apply reruns the guards, verifies
the exact retained bundle against the current context, project, stack, backend, payload, program,
config, and Pulumi version, and passes it to `pulumi up --plan --yes --non-interactive` without a
second preview. A plan that would replace the GCE instance, the Cloud DNS zone, or a bucket fails
the phase; set `NAGARE_ALLOW_VM_REPLACEMENT=1` for both planning and apply only after reviewing a
deliberate rebuild. Do not run `platform upgrade`
with Nagare 0.2.0 on a real cloud context: its Pulumi phases ran without the
context's stack config and applied without a guarded preview.

The Kubernetes diff phase also stores a private `kubernetes-plan/` bundle in the transaction. For
a TLS-enabled cluster that still has the Nagare 0.2.2 namespace wildcard selector `{}`, its review
names the selector change, each compliant application wildcard that will be preserved, and each
exact obsolete Knative Certificate, cert-manager Certificate, and generated TLS Secret proposed for
removal. The bundle is mode `0700`, its files are mode `0600`, and its metadata binds the review to
the transaction, selected context, target payload, and file digests. TLS-disabled and
already-narrowed clusters record a no-op review and remain HTTP-first or unchanged respectively.

Apply runs Pulumi, switches and commits the staged host flake, reconciles the
cluster, stamps its release ConfigMap, and atomically advances the context pin
last. Before any phase runs, the transaction reads the generated host name from its staged
`host.nix`. That name selects both `nixosConfigurations.<host-name>` and the Tailscale SSH target;
the context's `NAGARE_INSTANCE_NAME` remains the GCE resource used only by cloud and IAP commands.
For example, upgrading context `labs` may apply `nixosConfigurations.labs-nagare` through
`deploy@labs-nagare` while its GCE VM is still named `nagare-01`. Ambient `NAGARE_HOST_ATTR` or
`NAGARE_SSH_HOST` values cannot redirect an upgrade transaction.

For a reviewed legacy TLS migration, Kubernetes apply reruns the cluster guard, verifies the
untouched bundle and every reviewed live UID, owner relationship, and Secret digest, and installs
the narrowed selector before bootstrap reaches `cluster certificate-policy`. It waits for Knative
and cert-manager to remove the obsolete Certificate objects, then deletes only a still-identical
generated Secret that no live Certificate references. A valid wildcard in an opted-in namespace,
such as `personal`, is not replaced or deleted. Reapplying a completed transaction performs no
additional cleanup.

A missing, unreadable, absent, or duplicate `hostName` assignment refuses before host evaluation
or transport. Inspect the authoritative values with `nagarectl host name [--context NAME] [--json]`
and repair or regenerate the context-owned host flake before resuming. A failure preserves the
transaction and the old context pin. Inspect and
resume the same identifier after correcting the cause:

```bash
nix shell "${TARGET_NAGARE}#nagare" -c nagarectl platform upgrade status "$transaction_id" --json
nix shell "${TARGET_NAGARE}#nagare" -c nagarectl \
  platform upgrade --apply --resume "$transaction_id" --yes
```

Resume rechecks successful phases and reruns convergent operations whose
postcondition cannot be proven. The Pulumi plan is never recomputed during resume: changed inputs
make it stale and require a newly planned transaction. A cloud update remains constrained by the
reviewed plan, not atomic; after partial failure, inspect the stack before retrying the unchanged
transaction. Reapplying a completed transaction is a no-op.
Each context has separate history and immutable workspaces under its XDG state
directory.

If Kubernetes apply reports that an object UID, content, ownership, or Secret reference differs
from the review, Nagare leaves it untouched. Inspect the named object and the transaction's
`kubernetes-plan/review.json`. If another actor legitimately changed the object, abandon that stale
transaction and create a new upgrade plan; there is no force-delete option. If controller deletion
times out without an identity mismatch, diagnose Knative or cert-manager and resume the same
transaction. The context pin remains on the old release until convergence and the final policy gate
succeed.

## Rollback boundaries

Rollback is available only when the target release metadata explicitly allows
the previous version and the retained old payload is still present:

```bash
nix shell "${TARGET_NAGARE}#nagare" -c nagarectl \
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
lock dates from 2026-09-11; ordinary `nixos-rebuild` runs do not advance it.

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
plan_dir="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/reviews/host-refresh"
nagare infra-preview --save-plan "$plan_dir" --allow-replacement
nagare infra-up --plan "$plan_dir" --yes --allow-replacement
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

## Replacement cutovers

Replacement upgrades use a second host and an independent copy of state. Their cutover executor
starts a monotonic downtime clock when production writes are first denied, reserves recovery time
before the total budget expires, and keeps candidate writes fenced until public verification and
context promotion succeed. Write-gate observation—not command exit status—is the irreversible commit
point. The old host is stopped and retained until explicit guarded cleanup.

The provider-independent executor is implemented, but the operator command remains gated on the
candidate, rehearsal, state-transfer, and disposable address-handoff prerequisites. Until a
replacement transaction can reach `ready`, continue using the supported in-place workflow above and
do not assemble a cutover from hand-written cloud commands. The complete acceptance and recovery
procedure is in [Replacement cutover and rollback drill](../runbooks/replacement-cutover-drill.md).
