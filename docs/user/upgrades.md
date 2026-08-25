# Upgrades

> **Status:** ✅ Supported procedure

Nagare pins the host, Kubernetes distribution, cluster controllers, and
observability charts independently. Upgrade one layer at a time, verify it, and
commit its lock or pin change before moving to the next layer. That separation
makes a regression attributable and keeps rollback straightforward.

Run cloud commands with the intended [target context](contexts.md) active. Keep
the IAP path in [Accessing the host](accessing-the-host.md) available before a
host or networking change.

## NixOS host

The NixOS inputs move only when the lock file is updated. The current nixpkgs
lock dates from 2026-05-31; ordinary `nixos-rebuild` runs do not advance it.

```bash
cd nixos
nix flake update
cd ..
git diff -- nixos/flake.lock
nix eval ./nixos#nixosConfigurations.nagare-01.config.system.build.toplevel.drvPath
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
