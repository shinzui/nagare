---
id: 103
slug: host-tuning-upgrade-story-and-documentation-reality-sync
title: "Host tuning, upgrade story, and documentation reality sync"
kind: exec-plan
created_at: 2026-07-16T04:25:03Z
master_plan: "docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md"
intention: "intention_01kzakvy1qeasagg3rpbn44749"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T13:31:15Z
      mode: "update"
      note: "Reconcile deferred validation against tan-ng-labs and later plan evidence"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T21:44:52Z
      mode: "implement"
      note: "Audit EP-7 live state and preserve wheel traversal to the hardened kubeconfig"
---

# Host tuning, upgrade story, and documentation reality sync

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [103-host-tuning-upgrade-story-and-documentation-reality-sync.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/103-host-tuning-upgrade-story-and-documentation-reality-sync.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare is a personal PaaS: one NixOS VM on GCP ("nagare-01", configured under
`nixos/`) runs a single-node k3s Kubernetes cluster with Knative Serving on top
(installed by `just cluster-bootstrap` at version pins held in the `justfile`).
A platform review found three clusters of problems that this plan fixes:

1. **Host hardening and tuning gaps.** The k3s kubeconfig on the host is
   world-readable (`--write-kubeconfig-mode=0644` in
   `nixos/hosts/nagare-01/k3s.nix`), which hands cluster-admin to any local
   process. Kubernetes Secrets sit unencrypted in k3s's sqlite datastore.
   Worst of all, `nixos/hosts/nagare-01/registries.nix` restarts the entire k3s
   server every 45 minutes just to refresh an Artifact Registry pull token —
   roughly 32 control-plane interruptions per day. The small node also lacks
   standard small-node tuning (zram swap, inotify limits, memory overcommit).

2. **No upgrade story.** There is no documented procedure for upgrading the
   host (nixpkgs is pinned at 2026-05-31 in `nixos/flake.lock` and only drifts
   further), nor for bumping the Knative/cert-manager/net-certmanager pins in
   the `justfile`. The net-certmanager pin (v1.14.0) rests on a claim in
   `cluster/bootstrap/net-certmanager/README.md` that its release line froze —
   in reality the controller moved *into* the `knative/serving` release
   artifacts around v1.15, so the pin is likely both stale and pointing at an
   abandoned artifact location.

3. **Documentation drift.** `docs/runbooks/disaster-recovery.md` — the document
   you would follow under maximum stress — references paths that do not exist,
   contradicts the committed NixOS config, and hardcodes resource names from
   before the target-context model. The `justfile` header still describes the
   superseded "target profile" model. `docs/user/secrets.md` calls the sops
   cluster-secrets mechanism "Planned" even though the DR runbook already
   depends on it and `cluster/secrets/notes-db-url.yaml` exists.

After this plan, an operator can observe: the kubeconfig on the host is not
world-readable and Secrets are encrypted at rest in the datastore; `journalctl`
on the host shows **zero** timer-driven k3s restarts while private-registry
pulls keep working; `docs/user/upgrades.md` exists and walks each component's
upgrade; and grepping the docs for the known-stale strings returns nothing
while every runbook step matches the real tree.

## Progress

- [x] M1: change `--write-kubeconfig-mode` to `0640` with `--write-kubeconfig-group=wheel` in `nixos/hosts/nagare-01/k3s.nix`
- [x] M1: add `--secrets-encryption` to the k3s server flags
- [x] M1: add zram swap and the three sysctls to `nixos/modules/gcp.nix`
- [x] M1: build-check the NixOS config (eval of `nixosConfigurations.nagare-01`)
- [x] M1 repository correction: declare `/etc/rancher/k3s` as `0750 root:wheel` and make the
  pre-k3s registry bootstrap preserve that ownership and mode; focused evaluation/build checks pass.
- [x] M1 live activation and operator-access verification: approved same-version transaction
  `20260916T23151494502-0.4.0-9d8c3017` left all 37 Pulumi resources unchanged, armed the rollback
  window, activated the reviewed closure, verified a fresh login, and committed it as the boot
  generation. `/etc/rancher/k3s` is `750 root wheel`, `k3s.yaml` is `640 root wheel`, bare
  `kubectl get nodes` works as `deploy`, and `nobody` cannot read the kubeconfig. k3s retains its
  2026-09-14 start time, so activation did not restart the control plane. The later Kubernetes
  phase failed before cluster stamp/context commit on a false certificate-policy result; that
  operator defect is corrected and requires a fresh immutable-payload transaction, but it does not
  invalidate the completed host acceptance. (2026-09-16)
- [x] Final transaction completion: exact-commit payload `nagare-0.4.0-1c55d6f54a3c` completed as
  transaction `20260917T04034279927-0.4.0-ca71a77c`. The reviewed Pulumi plan kept all 37 resources
  unchanged; host apply recognized the intended closure as already active; Kubernetes reconciliation,
  certificate policy, cluster stamp, and context commit all succeeded. (2026-09-16)
- [x] M1 encryption-at-rest verification: labs reports `Encryption Status: Enabled`; its datastore
  and encryption config were created within the same first-boot second, and the first API-server
  invocation already carried `--encryption-provider-config`. Current upstream k3s documentation
  treats `Enabled` + stage `start` as the normal pre-key-rotation state. No late-enable migration or
  forced key rotation is required on this fresh host. (2026-09-16)
- [x] M2: add the `nagare-registry-pull-secret` service + 30-minute timer to `nixos/hosts/nagare-01/registries.nix`
- [x] M2: delete the `nagare-registries-reload` service and timer from `registries.nix`
- [x] M2 live activation: the fresh labs host runs the released configuration. The old
  `nagare-registries-reload` unit is absent; `nagare-registry-pull-secret.timer` is enabled and
  active, fires every 30 minutes, and repeatedly configures the pull Secret and patches the default
  ServiceAccount without restarting k3s. (2026-09-15)
- [x] M2: an approved one-shot canary proved digest
  `sha256:179db2cb40c631bfebd59e4692ff2e2c4a155bc8575eca83663b5dfb28fa0612` absent from the
  node cache, then pulled it from the private Artifact Registry in 599 ms through the default
  ServiceAccount's `nagare-registry-pull` Secret. `atticd --help` exited 0, the Pod reached
  `Succeeded`, and the Pod was deleted. k3s retained its 2026-09-14 start timestamp, its journal
  contained no start event during the transaction/canary, and the refresh timer remained enabled,
  active, and successful. (2026-09-16)
- [x] M3: verify the `knative-v1.22.0` release assets; retain the independently verified v1.14.0 GCS pin and rewrite its README
- [x] M3: write `docs/user/upgrades.md` (host, cluster components, observability, cadence) and link it from `docs/user/README.md`
- [~] M3: optional in-place local re-bootstrap rehearsal skipped because no Docker daemon is running
- [x] M3: rewrite the `justfile` header comment (lines 1–9) for the target-context model
- [x] M3: fix all drift in `docs/runbooks/disaster-recovery.md` (paths, power-management section, image name, bucket literals, step 7, step 3 `sudo cat`)
- [x] M3: promote the sops cluster-secrets loop to supported status in `docs/user/secrets.md`
- [x] M3: update `docs/user/reference.md` (kubeconfig mode row) and any other doc naming mode `0644`
- [x] M3: grep-verify that the stale strings are gone; walk the DR runbook against the real tree
- [x] Final: Outcomes & Retrospective written; all commits carry the MasterPlan/ExecPlan trailers

## Surprises & Discoveries

- `cli/nagarectl/src/Nagare/Ops/Status.hs` lines 72–74 probe backup freshness
  under the prefixes `postgres`, `litestream`, `volumes` — the `postgres/`
  prefix is the legacy host-Postgres location that the managed-database model
  (`databases/`) replaced. The DR runbook fix in M3 must describe what the tool
  *actually reports* today; changing the CLI probe itself is out of scope here —
  it is owned by `docs/plans/101-alerting-and-backup-freshness-monitoring.md`
  (Milestone 2), which rewrites the probe to enumerate `databases/<name>`.
- Mori has no registered k3s corpus. The flags and online encryption procedure
  were therefore checked against current upstream k3s documentation. The `k3s_image`
  v1.34.6 pin in the `justfile` is for local k3d rehearsal, not the NixOS host; labs currently
  runs the nixpkgs-provided v1.35.8+k3s1. Supported existing-cluster late enablement uses
  `enable`, restart with the flag, `rotate-keys`, and another restart. A fresh cluster that
  reports `Enabled` at stage `start` is already encrypted; `reencrypt_finished` is the result
  of key rotation, not a universal healthy-state requirement.
- The NixOS host evaluation passes. The repo-wide `nix flake check` reaches the
  build phase but currently fails in the unrelated `nagare-access-build-test`
  because its sandboxed Cabal build cannot authenticate while cloning an
  upstream Git dependency; the other checks are cancelled after that failure.
  No M1-owned NixOS file is implicated.
- Walking the upgrade guide exposed that `just host-switch` referenced the
  repository-root flake (`.#nagare-01`), which has no `nixosConfigurations`
  output; the host configuration lives in `./nixos`. M3 corrects this single
  path to `./nixos#nagare-01` and synchronizes the user docs.
- The authoritative `knative/serving` `knative-v1.22.0` release has six serving
  manifests but no `net-certmanager.yaml` asset. The independently hosted
  v1.14.0 GCS manifest still returns HTTP 200, so verification selected the
  plan's retain-and-document branch rather than an unresolvable repoint.
- The optional k3d pin-rehearsal cannot run on this workstation: the Docker CLI
  is present, but its configured Colima socket does not exist. M3 records the
  skip instead of presenting an unexecuted rehearsal as evidence.

- Live labs audit (2026-09-15): the released host configuration is active on
  `labs-nagare`. The kubeconfig is `640 root wheel`; encryption is Enabled with matching
  hashes at the normal pre-rotation stage `start`; the replacement pull-secret timer is enabled,
  active, and firing every 30 minutes; the old reload unit is absent; and its journal repeatedly
  shows the Secret configured and ServiceAccount patched. The only recorded k3s starts are the
  initial 2026-09-14 bootstrap/reboot, so the timer is not restarting the control plane.

- Live labs audit (2026-09-16): the kubeconfig file's `640 root wheel` metadata was insufficient
  because `/etc/rancher/k3s` remained `700 root root`. The boot-time registry refresh script
  explicitly created that directory at `0700`, preventing `deploy` (a wheel member) from reaching
  the file; bare `kubectl get nodes` consequently fell back to localhost and failed. The repository
  now declares `0750 root wheel` in `k3s.nix`, preserves it in the registry script, and has a focused
  flake check for both invariants. The same audit reconfirmed `Enabled` encryption, 47 encrypted
  datastore markers, first-boot use of the encryption config, the expected zram/sysctls,
  successful 30-minute pull-secret refresh, and zero
  k3s starts in the preceding two hours. The exact private Attic digest is cached and available as
  the bounded M2 canary candidate; it was not evicted or run during the read-only audit.

- The first approved direct host switch made no change: the platform guard found the ambient
  profile's `nagarectl` at 0.2.2 while the checkout, labs context, and host are 0.4.0. The full
  checkout-built operator package passed the current guard, but the context-owned host flake was
  correctly pinned to the previously deployed 0.4.0 payload and therefore could not see the new
  commit. The supported `platform upgrade` rehearsal initially refused an unrelated ambient GKE
  kube context; after `nagarectl kubeconfig fetch --context labs`, its explicit labs gate passed.
  The final plan is same-version, has no GCE/DNS/bucket replacement and no Kubernetes migration,
  and stages the corrected host flake. No cloud or host mutation occurred during these refusals or
  previews.

- The approved platform transaction applied its reviewed no-change Pulumi plan, built and copied
  the corrected host closure, then failed before arming rollback or activating it. macOS `/bin/bash`
  3.2 treats `"${empty_array[@]}"` as an unbound variable under `set -u`; current Bash does not,
  which is why the original VM test missed the workstation failure. The switch reported
  `arm failed; nothing was changed`, and a guarded host audit confirmed the prior generation and
  `0700 root:root` directory remained active. The client now branches before expanding empty
  `NIX_SSHOPTS`; a direct Bash 3.2 reproduction, shellcheck, formatting, flake evaluation, and the
  complete commit/lockout/crash rollback VM test all pass.

- The replacement transaction safely activated and committed the corrected host generation, then
  failed during `cluster-bootstrap` because `nagarectl cluster certificate-policy` queried the
  ambiguous resource name `certificates`. On a cluster carrying both Knative and cert-manager
  Certificate CRDs, kubectl selected Knative Certificates; those objects intentionally lack
  `spec.issuerRef`, so the diagnostic falsely reported the `personal` wildcard as non-ACME. The
  corresponding cert-manager Certificate already names `letsencrypt-dns`. The operator now queries
  `certificates.cert-manager.io` explicitly, an injected-capture regression locks that command,
  all 572 tests pass under the pinned GHC 9.12.4 shell, and the corrected operator passes against
  the live inventory. The failed transaction did not stamp the cluster or advance the context.
  Fresh exact-commit transaction `20260917T04034279927-0.4.0-ca71a77c` then passed its host,
  Pulumi, and Kubernetes plan phases before the approved apply completed it.

- Invoking the exact packaged operator by absolute path did not put that package first in `PATH`.
  The first approved apply therefore consumed the reviewed no-change Pulumi plan, then the host
  script found the ambient 0.2.2 CLI and failed on `nagarectl host name` before host mutation. Resume
  with the exact operator directory prepended to `PATH` used the durable Pulumi success receipt,
  skipped reapplying infrastructure, recognized the host closure as already active, and completed
  every remaining phase. Clone-free operational commands must make the selected operator visible
  to subprocesses, not merely invoke its outer command by absolute path.

## Decision Log

- Decision: kubeconfig hardening uses `--write-kubeconfig-mode=0640` plus
  `--write-kubeconfig-group=wheel`, not the 0600+sudo pattern.
  Rationale: the `deploy` operator user is already in `wheel`
  (`nixos/hosts/nagare-01/users.nix`, `nixos/modules/gcp.nix`), so day-2
  `kubectl` on the host keeps working without sudo, while non-wheel local
  processes lose read access. k3s gained `--write-kubeconfig-group` in 2024
  (v1.29.4+); the pinned k3s is ≥ v1.34 (see `k3s_image` in the `justfile`,
  which is pinned "to reproduce the cloud's Kubernetes API surface"), so the
  flag is available. The implementer must still confirm the flag on the host
  (`k3s server --help | grep write-kubeconfig-group`); the documented fallback
  is dropping the mode flag entirely (default 0600) and using `sudo`.
  Date: 2026-07-15 (authoring).

- Decision: pair the `0640 root:wheel` kubeconfig with an explicitly managed
  `/etc/rancher/k3s` directory at `0750 root:wheel`, and require every pre-k3s writer to preserve
  that mode.
  Rationale: file permission checks happen only after every parent directory permits traversal.
  The registry bootstrap's `install -d -m 0700` silently defeated the intended operator access even
  though the kubeconfig's own metadata looked correct. `registries.yaml` remains `0600 root:root`,
  so allowing wheel to traverse the directory does not expose the short-lived registry credential.
  Date: 2026-09-16.

- Decision: the registry-credential refresh is replaced by a **host systemd
  timer** that writes a `kubernetes.io/dockerconfigjson` Secret and patches it
  into the `default` ServiceAccount of the app namespace, using the node's own
  root kubeconfig. The two alternatives — an in-cluster CronJob, and packaging
  the kubelet GCP credential provider — were evaluated and rejected.
  Rationale: the in-cluster CronJob needs a public container image with
  curl/jq/kubectl (a new supply-chain dependency), RBAC objects, and has a
  bootstrap chicken-and-egg (the CronJob must exist before the first private
  pull); the kubelet credential provider (`auth-provider-gcp` from
  `kubernetes/cloud-provider-gcp`) is the cleanest mechanism but is not
  packaged in nixpkgs and upstream builds with Bazel, making the packaging
  effort disproportionate for a single node (the existing comment in
  `registries.nix` already records this; it remains the recommended long-term
  follow-up). The systemd timer is declarative in NixOS, needs no new images
  or RBAC, runs as root with `/etc/rancher/k3s/k3s.yaml`, and is directly
  observable with `systemctl`/`journalctl`.
  Date: 2026-07-15 (authoring).

- Decision: keep the existing boot-time `nagare-registries-refresh` unit
  (which writes `/etc/rancher/k3s/registries.yaml` before k3s starts); delete
  only the `nagare-registries-reload` restart service + timer.
  Rationale: the boot-time token makes node-level pulls work for ~1 hour after
  every k3s start — useful during bootstrap before the Secret exists — and it
  is harmless afterwards (an expired token fails a pull exactly like no
  credential; pods carrying the imagePullSecret never consult it). Removing
  only the restart machinery is the minimal change that eliminates the ~32
  daily control-plane interruptions.
  Date: 2026-07-15 (authoring).

- Decision: the net-certmanager repoint is **conditional on verification**,
  and the plan states exactly what to check rather than asserting the answer.
  Rationale: the claim in `cluster/bootstrap/net-certmanager/README.md` (line
  10–15, "diverged from Knative's and froze at v1.14.0") contradicts upstream
  history (the controller was folded into `knative/serving` releases ~v1.15).
  Both cannot be right; the implementer verifies against the
  `knative/serving` `knative-v1.22.0` release assets and takes the branch that
  matches reality.
  Date: 2026-07-15 (authoring).

- Decision: retain the independent net-certmanager v1.14.0 GCS pin.
  Rationale: `gh release view knative-v1.22.0 -R knative/serving --json assets`
  showed no net-certmanager manifest on 2026-08-24, while the exact pinned GCS
  URL returned HTTP 200. The README and justfile now record that evidence and
  the recurring asset check rather than claiming the release line merely
  "froze."
  Date: 2026-08-24.

- Decision: `vm.swappiness = 10` in `nixos/modules/gcp.nix` is left unchanged
  when zram is enabled.
  Rationale: zram guidance often raises swappiness, but this plan makes one
  behavioral change at a time; raising swappiness is a tuning experiment, not
  a remediation, and can be revisited with observability data.
  Date: 2026-07-15 (authoring).

- Decision: correct the `host-switch` flake path even though the authored M3
  boundary reserved recipe bodies to EP-1.
  Rationale: this is not a guardrail or behavior rewrite; the existing body
  names an output the root flake does not provide, so the upgrade guide's main
  apply command would be unusable. Pointing it at the already-authoritative
  `nixos/flake.nix` is the smallest reality-sync fix and preserves every target
  and sudo argument.
  Date: 2026-08-24.

- Decision: count a fresh released-host activation as evidence for the M1 configuration and M2
  timer activation, but initially not as evidence for late-datastore reencryption or a private
  image pull.
  Rationale: labs directly proved the desired units and encryption flag, while the initial audit
  had not yet inspected first-start evidence or exercised a private pull. The encryption caveat is
  superseded by the 2026-09-16 decision below; the private-pull caveat remains.
  Date: 2026-09-15 (partially superseded 2026-09-16).

- Decision: do not rotate encryption keys merely to change labs from stage `start` to
  `reencrypt_finished`.
  Rationale: current upstream k3s documentation shows `Enabled` + `start` as a normal status and
  reserves `reencrypt_finished` for completed key rotation. Labs' datastore and encryption config
  were created within the same first-boot second, and its first API server already used the
  encryption provider. There are no pre-flag rows to migrate; an unnecessary rotation would rewrite
  the datastore and restart k3s without closing a real security gap.
  Date: 2026-09-16.

- Decision: deliver the host correction through the persisted same-version platform-upgrade
  transaction, not by editing the context-owned flake or suppressing `nagarectl platform guard`.
  Rationale: the context host flake intentionally pins the deployed immutable payload. The supported
  transaction evaluates the new host closure, previews infrastructure, gates the exact labs cluster,
  applies the host, stamps release identity, and commits the context pin as one resumable workflow.
  The successful rehearsal reports no replacement and no Kubernetes migration, but its broader apply
  boundary still requires explicit operator approval.
  Date: 2026-09-16.

- Decision: make the rollback client portable to macOS Bash 3.2 by routing SSH through a helper
  that expands `NIX_SSHOPTS` only when the array is non-empty.
  Rationale: injecting a dummy option would hide the compatibility defect, and bypassing the
  rollback client would discard the host's principal lockout protection. The explicit branch keeps
  option ordering and every existing SSH safety flag intact while supporting ordinary SSH config.
  Date: 2026-09-16.

- Decision: when resuming an exact packaged upgrade transaction, prepend that package's `bin`
  directory to `PATH` in addition to invoking its outer `nagarectl`.
  Rationale: upgrade scripts deliberately invoke `nagarectl` subprocesses. Absolute-path invocation
  alone can let an older ambient CLI handle those nested calls; PATH confinement keeps the entire
  transaction on the reviewed operator while the durable receipt prevents duplicate Pulumi apply.
  Date: 2026-09-16.

## Outcomes & Retrospective

- M1's original repository work completed on 2026-08-24 and live steady state was inspected on
  labs on 2026-09-15 and 2026-09-16. Datastore Secret encryption is enabled for fresh starts and
  zram/inotify/overcommit tuning is active. The follow-up audit found that `0700 root:root` on the
  kubeconfig's parent directory defeated the intended wheel access despite the file being
  `0640 root:wheel`; the activated correction now keeps the directory `0750 root:wheel`.
  Encryption-at-rest and live operator-access acceptance are complete. The fixed-payload transaction
  also completed Kubernetes reconciliation, cluster stamp, and context commit.
- M2 repository work completed on 2026-08-24. The restart timer is removed;
  the NixOS configuration now mints a pull Secret every 30 minutes, skips absent
  namespaces, treats an unavailable API as retryable, and preserves hard
  failures for token minting or Kubernetes mutations while the API is healthy.
  Evaluation proves the new timer's `2min`/`30min`/persistent settings, and labs proves the
  old unit's absence plus repeated successful 30-minute executions without k3s restarts. The final
  live canary proved an uncached digest pull through the managed Secret more than three days after
  k3s start, exited successfully, was deleted, and caused no control-plane restart.
- M3 repository and documentation work completed on 2026-08-24. The verified
  net-certmanager pin remains v1.14.0; the new upgrade guide covers host,
  controller, observability, verification, cadence, rollback, and the exact IAP
  fallback. The DR, secrets, kubeconfig, image, and reference docs now match the
  active-context and declarative-host reality. `just --list`, the corrected
  `host-switch` dry run, NixOS evaluation, exact-path walk, stale-string sweep,
  and whitespace check pass. The optional k3d rehearsal was skipped because no
  Docker daemon is running; an idempotent cloud re-bootstrap remains unavailable
  behind the active-context/authentication blocker.
- EP-7 is Complete. Labs proves encryption at rest, small-node tuning, wheel-only operator access,
  restart-free credential refresh, an uncached private-image pull long after boot, and consistent
  payload/host/cluster/context commit points.

