# Bundle Update Log

## 2026-09-25
* **Add**: Record IR-25 as proposed for optional Coraza and OWASP CRS support on Nagare's direct ingress, informed by research RES-2.

## 2026-09-16
* **Add**: Record IR-24 as proposed after the unreleased 0.4.0 Attic rehearsal exposed conflicting ownership of one Kubernetes Service. Generalize the request into a versioned resource inventory spanning cloud, host, cluster, data, secrets, artifacts, and releases, with collision-free identity, explicit ownership and lifecycle, dependency-aware resumable reconciliation, drift evidence, safe adoption, and guarded garbage collection.

## 2026-09-14
* **Completed**: Correct boot-disk-size guidance and CLI help, and add a packaged regression check that rejects future in-place claims while preserving data-disk growth guidance.
* **Update**: Complete IR-18 with verified post-boot host age-key delivery.
* **Update**: Complete IR-22 and IR-23: keep internal Knative certificates on the self-signed issuer, scope public wildcards to labeled app namespaces, and ship a reproducibly patched latest net-certmanager controller inside the immutable platform payload.
* **Update**: Complete IR-19. The formatter is ordered before the generated fsck unit, a recovered mount pulls layout and k3s back in without weakening their hard dependencies, five independent blank-disk VMs reach one Ready node under the original boot ID, and the online-growth regression remains green.
* **Update**: Move IR-19 to in-progress to match MasterPlan 22 and ExecPlan 137 implementation coordination; completion remains pending first-boot acceptance evidence.
* **Update**: Audit all 23 requests against project scope, linked plans, implementation evidence, and lifecycle state; record approving content-and-metadata review provenance and OKF verification for each current revision.
* **Update**: Complete IR-15 and IR-17. Infrastructure apply now consumes an immutable context-bound reviewed plan without a second preview, upgrades retain it across resume, teardown is guarded, and host-image explicitly selects a visible context-owned builder with named foreign-project opt-in. ADRs 18 and 9 record the durable boundaries.
* **Update**: Complete IR-12 and IR-16. Init and every cloud guard now validate token-safe ADC quota evidence before Pulumi, and status plus a guarded re-pin distinguish confirmed absence from legacy or unreachable deployments. ADR 9 records the credential boundary; ADR 6 records deployment-state and pre-deployment pin semantics.
* **Update**: Complete IR-10 and IR-20. Public operator packages now exclude Haskell `lib/links`, the full package carries `socat`, a project-confined command atomically installs normalized per-context kubeconfigs, and a reusable Kubernetes identity guard runs before cloud cluster mutation recipes. ADRs 4 and 7 record the durable state and package boundaries.
* **Update**: Complete IR-21. Cloud and local bootstrap now wait for Knative admission webhooks with explicit deadlines, retry idempotent ConfigMap merge patches within a bounded window, and pass the first invocation on a new disposable k3d cluster.
* **Update**: Accept the remaining first-cluster GCP bootstrap requests under MasterPlan 22: IR-10 and IR-20 target ExecPlan 134; IR-12 and IR-16 target ExecPlan 135; IR-15 and IR-17 target ExecPlan 136; IR-19 targets ExecPlan 137; IR-22 and IR-23 target ExecPlan 138; and IR-11 targets the final integration ExecPlan 139. Other requests remain unchanged.
* **Update**: Accept IR-18 and target it at docs/plans/133-deliver-the-host-age-key-after-first-boot.md.
* **Update**: Accept IR-21 and record its target plan: docs/plans/132-make-cluster-bootstrap-wait-for-knative-webhooks.md.
* **Add**: Record IR-22 and IR-23 as proposed, from proving staging and production TLS on tan-ng-labs with v0.2.2: config-certmanager sets only issuerRef, so Knative's system-internal routing-serving-certs is sent to Let's Encrypt and rejected on every bootstrap (IR-22); and namespace-wildcard-cert-selector {} issues public wildcards for every namespace, including kube-system and kube-node-lease (IR-23).
* **Update**: Complete IR-14. Host init now derives the NixOS and Tailscale name as `<context>-nagare`, keeps the project-scoped VM instance name independent, refuses implicit collisions found in sibling generated flakes, preserves explicit recovery, and documents the two identities. Decision amended in ADR 5.
* **Update**: Complete IR-9. The context guard now distinguishes a missing Pulumi executable, command failures with stderr, invalid output, and a genuinely absent project; every refusal names its stack/backend, and hermetic human/JSON command checks cover the missing-tool and fake-Pulumi outcomes. Decision amended in ADR 9.
* **Add**: Record IR-17 through IR-21 as proposed, from booting the tan-ng-labs host and cluster on v0.2.2: host-image builds on a workstation remote builder whose proxy can start a VM in another GCP project (IR-17); the host age key has no delivery path before a GCE first boot (IR-18); the first-boot data-disk mkfs races systemd-fsck and leaves k3s failed until a reboot (IR-19); no command fetches a per-context kubeconfig, and the documented steps address nagare-01 on a multi-cluster tailnet (IR-20); and cluster-bootstrap patches Knative ConfigMaps before the Knative webhook is ready (IR-21).
* **Update**: Accept IR-9 and record its target plan: docs/plans/129-make-context-guard-diagnose-pulumi-project-probe-failures.md.
* **Update**: Accept IR-14 and record its target plan: docs/plans/130-give-every-context-a-distinct-default-host-name.md.
* **Add**: Record IR-15 and IR-16 as proposed, from the tan-ng-labs rollout on v0.2.2: infra-up ends in a bare pulumi up, so it cannot run without a TTY and the only workaround applies a recomputed rather than a reviewed plan (IR-15); and a never-deployed context moved to the next patch release reports legacy-unknown because its absent host and cluster outrank the patch skew, with no supported way to re-pin it (IR-16).
* **Update**: Complete IR-13, IR-7 and IR-8 in signed Nagare v0.2.2 at 248e5f9. Host init again renders the declared hostName option; named init is isolated from the active context and refuses foreign derived buckets; and the operator package carries its tested Pulumi with pre-side-effect tool checks and clone-free recovery guidance. Decisions amended in ADR 9 and ADR 7.
* **Update**: Accept IR-13, IR-7 and IR-8 for Nagare 0.2.2 and record their target plan: docs/plans/128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md. IR-13's fix is already in 3a107d3.

## 2026-09-13
* **Add**: Record IR-13 and IR-14 as proposed, from the tan-ng-labs rollout on v0.2.1: host init renders nagare.host.name, which the module does not declare, so no new host flake can be generated since a8918f9 (IR-13); and the default host name is the per-project-fixed instance name, so a second cluster collides on the tailnet (IR-14).
* **Add**: Record IR-7 through IR-12 as proposed, from the tan-ng-labs rollout on v0.2.1: init inherits derived fields from the active context (IR-7); the operator package ships no pulumi and init fails after side effects with misleading recovery hints (IR-8); the context guard misreports a missing pulumi as an unprojected stack (IR-9); the package's lib/links collides with home-manager on install (IR-10); the docs still call a boot-disk size change in-place (IR-11); and no check covers the ADC account or quota project (IR-12).
* **Add**: Record IR-6 as proposed and undecided: run the local cluster as k3s directly on Apple Container instead of k3d on Colima. A spike showed k3s reaches Ready with a /proc/sys remount and serves DNS and Service traffic; image builds still depend on Docker.
* **Update**: Complete IR-2. Every cloud-mutating path now asserts the active context's project: foreign-owned buckets are refused, the auth image builds lost their gcloud-config fallback, infra-up and infra-preview run nagarectl context guard, and the launcher exports the context's Pulumi environment. Decision recorded as ADR 9.
* **Update**: Complete IR-4: init seeds the VM shape keys and infra-up refuses an instance-replacing plan.

## 2026-09-12
* **Update**: Deliver IR-5: the data disk grows itself (ordering-cycle fix proven by a VM test), the procedure is documented with recorded previews and a live grow on nagare-01, and the DiskUsageHigh alert points at it.
* **Update**: IR-5 is in progress: docs/plans/111-automate-and-document-growing-the-data-disk.md implements the data-disk grow.
* **Update**: Complete IR-3. The ACME contact and directory endpoint are now context fields with no built-in default, the issuer renderer fails closed instead of inventing an identity, and a CI guard keeps personal defaults out of cluster/bootstrap/. Decision recorded as ADR 10.
* **Update**: Accept IR-2 and record its target plan: docs/plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md.
* **Update**: Accept IR-3 and record its target plan: docs/plans/112-make-the-acme-identity-context-owned-and-remove-the-personal-fallback-defaults.md.
* **Update**: Accept IR-5 and target it at docs/plans/111-automate-and-document-growing-the-data-disk.md.
* **Update**: Accept IR-4 and record its target plan: docs/plans/110-seed-and-pin-the-vm-shape-keys-at-init-and-guard-instance-replacing-applies.md.
* **Add**: Record IR-2 through IR-5 from the pre-flight isolation and readiness audit of v0.1.0: project confinement for cloud-mutating paths, context-owned ACME identity, seeded VM shape keys, and a real data-disk grow procedure.

## 2026-08-23
* **Migration**: Repin to okf-profiles v0.12.0 and record catalog review provenance; the new
dependency and acceptance-criteria fields are optional, so request semantics are unchanged.

## 2026-08-04
* **Migration**: Repin to okf-profiles v0.8.0 and move the bundle to OKF v0.2.

## 2026-07-30
* **Move**: Accept the diagnostics deployment-profile request from Kikan.
* **Migrate**: Assign `IR-1` and adopt the shared typed improvement-request profile.
