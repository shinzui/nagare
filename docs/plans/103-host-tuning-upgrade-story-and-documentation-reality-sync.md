---
id: 103
slug: host-tuning-upgrade-story-and-documentation-reality-sync
title: "Host tuning, upgrade story, and documentation reality sync"
kind: exec-plan
created_at: 2026-07-16T04:25:03Z
master_plan: "docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md"
intention: "intention_01kzakvy1qeasagg3rpbn44749"
---

# Host tuning, upgrade story, and documentation reality sync

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


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
- [ ] M1: apply to the live host (`just host-switch`) and run the online `k3s secrets-encrypt enable` + restart + `reencrypt` procedure
- [ ] M1: verify kubeconfig mode/group on the host and encryption status `Enabled` / `reencrypt_finished`
- [x] M2: add the `nagare-registry-pull-secret` service + 30-minute timer to `nixos/hosts/nagare-01/registries.nix`
- [x] M2: delete the `nagare-registries-reload` service and timer from `registries.nix`
- [ ] M2: apply with `just host-switch`; confirm the old timer is gone and the new one fires
- [ ] M2: verify a fresh private-image pull succeeds more than 45 minutes after the last k3s start, with no k3s restart in `journalctl`
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
  were therefore checked against current upstream k3s documentation on
  2026-08-24. The pinned v1.34.6+k3s1 is the first v1.34 release supporting
  late enablement; its procedure uses `enable`, restart with the flag,
  `rotate-keys`, another restart, and a final `reencrypt_finished` status. This
  supersedes the single-restart legacy `reencrypt` sequence in the authored
  Concrete Steps and will be reflected in the upgrade guide.
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

(More to be added during implementation.)


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


## Outcomes & Retrospective

- M1 repository work completed on 2026-08-24: kubeconfig access is narrowed to
  `root:wheel` mode 0640, datastore Secret encryption is enabled for fresh
  starts, and zram/inotify/overcommit tuning is declarative. The NixOS
  configuration evaluates. Live activation, late encryption enablement, and
  host observations remain open because there is no active target context and
  the configured gcloud account requires interactive reauthentication.
- M2 repository work completed on 2026-08-24. The restart timer is removed;
  the NixOS configuration now mints a pull Secret every 30 minutes, skips absent
  namespaces, treats an unavailable API as retryable, and preserves hard
  failures for token minting or Kubernetes mutations while the API is healthy.
  Evaluation proves the new timer's `2min`/`30min`/persistent settings and the
  old timer's absence. Host activation and the >45-minute uncached pull proof
  remain open behind the same cloud authentication blocker.
- M3 repository and documentation work completed on 2026-08-24. The verified
  net-certmanager pin remains v1.14.0; the new upgrade guide covers host,
  controller, observability, verification, cadence, rollback, and the exact IAP
  fallback. The DR, secrets, kubeconfig, image, and reference docs now match the
  active-context and declarative-host reality. `just --list`, the corrected
  `host-switch` dry run, NixOS evaluation, exact-path walk, stale-string sweep,
  and whitespace check pass. The optional k3d rehearsal was skipped because no
  Docker daemon is running; an idempotent cloud re-bootstrap remains unavailable
  behind the active-context/authentication blocker.
- EP-7 remains In Progress solely for the live M1/M2 activation and observation
  checks: encryption status and datastore proof, host tuning/mode observations,
  timer replacement, and the greater-than-45-minute uncached image pull without
  a k3s restart.


## Context and Orientation

Work happens in the repository root `/Users/shinzui/Keikaku/bokuno/nagare`,
inside the dev shell (`nix develop`, or automatically via `direnv allow`). All
`just` recipes and scripts run from the repo root. Cloud work targets the
**active target context** — a named `export VAR=value` file under
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env` selected by
`nagarectl context use NAME` or `NAGARE_CONTEXT=NAME`; `.envrc` exports the
canonical `CLOUDSDK_*` / `NAGARE_*` variables from it. Never hardcode a
project ID; the historic worked example is project `tan-nb-exp`.

Key terms, defined once:

- **k3s** is a single-binary Kubernetes distribution. On nagare-01 it runs as
  the systemd unit `k3s.service`, configured declaratively by
  `nixos/hosts/nagare-01/k3s.nix` (the `services.k3s.extraFlags` list becomes
  server command-line flags). Its state — including every Kubernetes `Secret`
  — lives in a sqlite database at `/var/lib/rancher/k3s/server/db/state.db`
  (k3s translates Kubernetes storage calls to sqlite via a shim called
  *kine*). Its admin kubeconfig (a credentials file granting cluster-admin) is
  written to `/etc/rancher/k3s/k3s.yaml`.
- **Artifact Registry** is GCP's container image registry. App images are
  private, hosted at the registry host in `NAGARE_REGISTRY_HOST` (worked
  example `us-west1-docker.pkg.dev`). Pulling privately requires a credential:
  either containerd-level config (`/etc/rancher/k3s/registries.yaml`, which
  k3s reads **only at start**) or a per-pod `imagePullSecrets` reference to a
  Kubernetes Secret of type `kubernetes.io/dockerconfigjson`. A short-lived
  OAuth token can be minted with no stored secret from the **GCE metadata
  server** (a link-local HTTP service at `169.254.169.254` that vends tokens
  for the VM's attached service account; Artifact Registry accepts username
  `oauth2accesstoken` with the token as password). Tokens live ~1 hour.
- **Knative tag resolution**: Knative Serving resolves image tags to digests
  from its controller. For the private registry this is *skipped* via the
  `registriesSkippingTagResolving` key patched into the `config-deployment`
  ConfigMap by `just cluster-bootstrap` (justfile lines 113–115) — that patch
  must survive this plan untouched, because the Knative controller has no
  registry credential of its own.
- **net-certmanager** is the bridge controller letting Knative request TLS
  certificates from cert-manager. Installed by `just cluster-bootstrap`
  (justfile line 110) from a Google Cloud Storage URL at pin
  `netcertmanager_version := "v1.14.0"` (justfile line 74), documented in
  `cluster/bootstrap/net-certmanager/README.md`.
- **IAP tunnel**: the VM has no public SSH; `scripts/iap-ssh.sh` wraps
  `gcloud compute start-iap-tunnel` + socat to provide `ssh`/`scp`/
  `recv-file`/`tunnel` subcommands (see the header comment of that script).
  Day-2 host changes normally apply with `just host-switch`
  (`nixos-rebuild switch --flake ./nixos#nagare-01 --target-host nagare-01
  --sudo`, resolved over Tailscale). If Tailscale is down, the fallback is an
  IAP port-22 tunnel with `--build-host` — see
  `docs/user/accessing-the-host.md` and `docs/user/day-2-host-changes.md`.
- **sops + age**: secrets are committed to Git encrypted with `sops` to an
  `age` public key; only holders of the private key can decrypt. Host secrets
  live in `nixos/hosts/nagare-01/secrets/` (decrypted at NixOS activation by
  sops-nix); cluster bootstrap secrets live in `cluster/secrets/` (currently
  one file, `notes-db-url.yaml`) and are applied with
  `sops -d FILE | kubectl apply -f -`.

Files this plan edits (full paths, current relevant lines):

- `nixos/hosts/nagare-01/k3s.nix` — line 9 has
  `"--write-kubeconfig-mode=0644"`.
- `nixos/hosts/nagare-01/registries.nix` — lines 20–46 define the boot-time
  token refresh script; lines 70–86 the `nagare-registries-refresh` oneshot;
  lines 92–111 the `nagare-registries-reload` restart service + 45-minute
  timer (the part to delete). The file reads the registry host from an
  optional generated `./registry-host.nix` (defaulting to
  `us-west1-docker.pkg.dev`); reuse that same `registryHost` binding.
- `nixos/modules/gcp.nix` — lines 41–46 hold the `boot.kernel.sysctl` block.
- `justfile` — lines 1–9 stale header ("target profile `nagare.target.env`");
  lines 70–74 version pins (`knative_version := "knative-v1.22.0"`,
  `certmanager_version := "v1.20.2"`, `netcertmanager_version := "v1.14.0"`);
  lines 110 and 210 apply net-certmanager from
  `https://storage.googleapis.com/knative-releases/net-certmanager/previous/{{netcertmanager_version}}/net-certmanager.yaml`.
- `cluster/bootstrap/net-certmanager/README.md` — lines 10–18 carry the
  "froze at v1.14.0" install rationale.
- `docs/runbooks/disaster-recovery.md` — drift detailed in Milestone 3.
- `docs/user/secrets.md` — lines 3–6 status header, 13–18 summary block,
  90–96 "Cluster bootstrap secrets — 🔭 Planned", 104–105 rotation bullet.
- `docs/user/reference.md` — line 29 documents the kubeconfig at mode `0644`.
- `docs/user/README.md` — the reading-order list gains a link to the new
  `docs/user/upgrades.md`.
- `docs/user/upgrades.md` — new file (the only new file in this plan).

Ownership boundaries with sibling plans (do not cross them):

- `docs/plans/99` owns the **age-key / sops-recipient** story, including the
  age-key section of the DR runbook ("The one thing that is NOT in Git or the
  bucket") and `.sops.yaml` recipients. This plan fixes the *rest* of the DR
  runbook and may correct literal wrong paths (e.g. `nixos/secrets/` →
  `nixos/hosts/nagare-01/secrets/`) even where they appear inside that
  section, but must not change key-management policy or recipients.
- `docs/plans/97` owns the justfile guardrail recipes (`vm-stop`, `vm-start`,
  `cluster-bootstrap` structure). This plan edits only the justfile *header
  comment* and the *version pins/URLs*.
- `docs/plans/100` owns image-tag pinning under `cluster/bootstrap/`.

Validation toolchain: the NixOS config is a flake in `nixos/` (see
`nixos/flake.nix`; `nixosConfigurations.nagare-01`). The workstation is
aarch64-darwin, so full builds go through the remote x86_64-linux builder that
`just host-image` / `just host-switch` already use; a pure *evaluation* check
works locally. The repo root has its own flake whose `nix flake check` runs
the offline CI checks — run it too, since the justfile is not evaluated by it
but doc/nix changes should not break anything.


## Plan of Work

The work is three milestones. M1 and M2 both change host behavior and end
with a `just host-switch` and live verification; they are separate because M1
is flag/sysctl tuning while M2 replaces a mechanism and needs its own
observation window. M3 is the upgrade story plus the documentation sync, and
depends on M1/M2 only in that the docs it fixes must describe the *new*
reality (kubeconfig mode, no restart timer).

### Milestone 1 — Host tuning and k3s hardening flags

Scope: `nixos/hosts/nagare-01/k3s.nix` and `nixos/modules/gcp.nix`, then a
live apply and the online secrets-encryption enablement. At the end, the host
kubeconfig is `0640 root:wheel`, Kubernetes Secrets are encrypted at rest in
`state.db`, and the node has zram swap plus raised inotify limits.

In `nixos/hosts/nagare-01/k3s.nix`, change the `extraFlags` list: replace
`"--write-kubeconfig-mode=0644"` with `"--write-kubeconfig-mode=0640"` and add
`"--write-kubeconfig-group=wheel"` and `"--secrets-encryption"`. Add a comment
explaining each: 0640+wheel keeps `deploy` (a wheel member) able to run
`kubectl` on the host while removing world-read of a cluster-admin credential;
`--secrets-encryption` makes k3s encrypt Kubernetes `Secret` objects (AES-CBC
envelope) before they hit the sqlite datastore, so a copied `state.db` or disk
image no longer leaks every secret in plaintext. Note in the comment that on
an *existing* cluster the flag alone does not encrypt already-stored rows —
the online procedure below does — but the flag makes any fresh bootstrap (new
image, DR rebuild, local rehearsal) encrypted from first boot.

In `nixos/modules/gcp.nix`, inside the `config = lib.mkIf cfg.enable { ... }`
block: add `zramSwap.enable = true;` (compressed-RAM swap — on a small node
this absorbs memory spikes that would otherwise OOM-kill pods, at the cost of
some CPU), and extend the `boot.kernel.sysctl` attrset (lines 41–46) with
`"fs.inotify.max_user_instances" = 512;`,
`"fs.inotify.max_user_watches" = 524288;` (Kubernetes components and log
tailers are inotify-hungry; the kernel defaults of 128 instances are routinely
exhausted on single-node clusters, surfacing as "too many open files"), and
`"vm.overcommit_memory" = 1;` (always-overcommit, the setting Redis and other
fork-heavy workloads expect; the managed-database Redis engine logs a warning
without it).

Then apply and enable encryption online. The current k3s procedure for the
pinned v1.34.6+k3s1 distinguishes a fresh cluster (the flag suffices) from an
existing one. On an existing single-node server: back up `state.db`, run
`k3s secrets-encrypt enable`, activate the flag and restart `k3s.service`,
verify the `start` stage, run `k3s secrets-encrypt rotate-keys`, restart once
more, then wait for `k3s secrets-encrypt status` to report `Encryption Status:
Enabled` and `Current Rotation Stage: reencrypt_finished`. The second restart
is required by the version-gated late-enablement workflow; the authored legacy
`reencrypt` sequence is not used. Also record in
`docs/user/secrets.md`-adjacent docs nothing yet — doc updates are M3 — but
verify mode and encryption per Validation below.

Acceptance: on the host, `stat -c '%a %U %G' /etc/rancher/k3s/k3s.yaml` prints
`640 root wheel`; `sudo k3s secrets-encrypt status` shows Enabled +
reencrypt_finished; a binary grep of `state.db` finds `k8s:enc:aescbc` markers;
`swapon --show` lists a zram device; `sysctl fs.inotify.max_user_watches`
prints 524288; `kubectl get nodes` still works as `deploy` without sudo.

### Milestone 2 — Registry credentials without k3s restarts

Scope: `nixos/hosts/nagare-01/registries.nix` only, then a live apply and an
observation window. At the end, the 45-minute `nagare-registries-reload`
restart timer is gone, and a new `nagare-registry-pull-secret` timer keeps a
`kubernetes.io/dockerconfigjson` Secret fresh and wired into the `default`
ServiceAccount of the app namespace, so kubelet pulls authenticate per-pod
with a token that is never older than ~30 minutes. The control plane is never
restarted for credential reasons again.

The mechanism, spelled out: pods whose ServiceAccount lists an
`imagePullSecrets` entry get that Secret attached to every pull; kubelet then
authenticates that pull directly with the Secret's credentials, taking
precedence over (and never consulting) containerd's `registries.yaml`. So a
Secret refreshed on the host via the cluster API reaches containerd *without*
any k3s restart — this is exactly the property the old design lacked (its own
comment, `registries.nix` lines 41–45, documents that `registries.yaml` is
read only at k3s start, which is why it restarted k3s).

Edit `nixos/hosts/nagare-01/registries.nix`:

1. Keep the `registryHostCfg`/`registryHost` let-binding and the existing
   `refreshScript` + `nagare-registries-refresh` boot-time oneshot exactly as
   they are (see Decision Log: boot-time `registries.yaml` still covers the
   window between k3s start and the first Secret sync, e.g. during a DR
   rebuild before any Secret exists). Update its comment block (lines 49–69)
   to describe the new steady-state: `registries.yaml` is now a boot-time
   bootstrap credential only; steady state is the pull-secret timer below.
2. Delete `systemd.services.nagare-registries-reload` and
   `systemd.timers.nagare-registries-reload` (lines 92–111) entirely.
3. Add a new script (a `pkgs.writeShellScript "nagare-registry-pull-secret"`)
   and a service + timer pair. The script: mints a token from the metadata
   server exactly like `refreshScript` does (same curl+jq, same failure
   check); builds a dockerconfigjson for `registryHost` with username
   `oauth2accesstoken`; then, with `KUBECONFIG=/etc/rancher/k3s/k3s.yaml` and
   k3s's bundled kubectl, for each namespace in a list (start with
   `personal`, the namespace `nagarectl deploy` targets; keep the list a Nix
   variable so more namespaces are one-line additions) it: ensures the
   namespace exists (tolerate absence — skip, do not create; bootstrap owns
   namespace creation), applies the Secret, and patches the `default`
   ServiceAccount. The kubectl idioms:

   ```bash
   kubectl -n "$ns" create secret docker-registry nagare-registry-pull \
     --docker-server="$REGISTRY_HOST" \
     --docker-username=oauth2accesstoken \
     --docker-password="$TOKEN" \
     --dry-run=client -o yaml | kubectl -n "$ns" apply -f -
   kubectl -n "$ns" patch serviceaccount default \
     -p '{"imagePullSecrets":[{"name":"nagare-registry-pull"}]}'
   ```

   The script must exit non-zero if the token mint fails, but treat "cluster
   not ready yet" (kubectl connection refused) as a soft failure logged to
   stderr with exit 0 — the timer fires again in 30 minutes and a failing
   unit would otherwise nag forever during long maintenance windows.
4. The systemd wiring: `systemd.services.nagare-registry-pull-secret` is a
   oneshot running the script, `after = [ "k3s.service" ]` and
   `wants = [ "k3s.service" ]`;
   `systemd.timers.nagare-registry-pull-secret` fires `OnBootSec = "2min"`
   (soon after boot, once k3s is up) and `OnUnitActiveSec = "30min"`
   (well inside the ~1h token lifetime), `Persistent = true`,
   `wantedBy = [ "timers.target" ]`.

What must keep working (from the memory of the original private-registry
bring-up): kubelet pulls of private images, and Knative resolution of those
images. Kubelet pulls move to the Secret path. Knative never had a
credential — it skips resolution for the registry via
`registriesSkippingTagResolving` in the `config-deployment` ConfigMap (set by
`just cluster-bootstrap`) — so it is unaffected; do not touch that patch.
Managed-database backup CronJobs and observability charts use public images
and are unaffected.

Apply with `just host-switch`. NixOS removes the deleted units automatically
on activation. Then verify per Validation: the decisive test is a
**fresh, uncached private-image pull succeeding more than 45 minutes after
the last k3s start** (when the boot-time `registries.yaml` token has expired,
so only the Secret path can explain success), with `journalctl` showing no
k3s restart in the window.

Acceptance: `systemctl list-timers` on the host shows
`nagare-registry-pull-secret` and no `nagare-registries-reload`;
`kubectl -n personal get secret nagare-registry-pull` exists and its
`.metadata` shows a recent apply; `kubectl -n personal get sa default -o
jsonpath='{.imagePullSecrets}'` prints `[{"name":"nagare-registry-pull"}]`;
the timed pull test passes; `journalctl -u k3s --since "-2h"` shows no unit
start after the switch settles.

### Milestone 3 — Upgrade story and documentation reality sync

Scope: `justfile` (header + net-certmanager pin), the net-certmanager README,
the new `docs/user/upgrades.md`, and the drift fixes in
`docs/runbooks/disaster-recovery.md`, `docs/user/secrets.md`,
`docs/user/reference.md`, `docs/user/README.md`. At the end, an operator has a
written upgrade procedure per component, and every touched doc matches the
tree and the M1/M2 behavior; grepping for the stale strings returns nothing.

**3a. net-certmanager pin verification and repoint.** The implementer runs:

```bash
gh release view knative-v1.22.0 -R knative/serving --json assets \
  --jq '.assets[].name'
```

(or opens https://github.com/knative/serving/releases/tag/knative-v1.22.0 and
reads the asset list). Check whether an asset named `net-certmanager.yaml`
exists. Two branches:

- **Asset exists** (expected, since the controller merged into serving
  ~v1.15): change justfile lines 110 and 210 to
  `kubectl apply -f https://github.com/knative/serving/releases/download/{{knative_version}}/net-certmanager.yaml`,
  delete the `netcertmanager_version` variable (line 74) and its stale
  comment (line 71, "net-certmanager froze at v1.14.0..."), and rewrite the
  Install section of `cluster/bootstrap/net-certmanager/README.md` (lines
  10–20) to say: the controller ships inside `knative/serving` release
  artifacts since ~v1.15, is versioned in lockstep with `knative_version`,
  and to name the new URL and the verification command above as the
  version-discovery procedure. Do not change image-tag pinning mechanics
  (owned by `docs/plans/100`).
- **Asset does not exist**: keep the v1.14.0 pin, but rewrite the README's
  rationale to record what was actually checked (the serving release asset
  list, date-stamped) so the claim is evidence-based rather than folklore,
  and add the `gh release view` command as the recurring check.

Either way, prove the installed state still reconciles: against the active
cluster (or the local rehearsal cluster in 3c), re-run `just cluster-bootstrap`
(idempotent) and `kubectl -n knative-serving rollout status
deploy/net-certmanager-controller` must succeed. Record which branch was taken
in this plan's Decision Log.

**3b. Write `docs/user/upgrades.md`.** A new operator-guide page, linked from
the "Read in this order" list in `docs/user/README.md` (near day-2 host
changes). It must cover, in prose with exact commands:

- *Host (NixOS)*: `cd nixos && nix flake update` (nixpkgs is currently locked
  at 2026-05-31 — state that the lock only moves when this is run), review
  `git diff nixos/flake.lock`, then either `just host-switch` for a running
  host (day-2 path; over Tailscale, IAP+`--build-host` fallback per
  `docs/user/accessing-the-host.md`) or `just host-image` + `pulumi up` in
  `infra/pulumi` to bake and boot a fresh image (the DR-grade path). Include
  the kernel note: a kernel/systemd bump takes effect only after reboot or
  image replacement.
- *Cluster components (Knative Serving, Kourier, cert-manager,
  net-certmanager)*: bump the pins at justfile lines 72–74 (after 3a: 72–73
  plus whatever remains of the net-certmanager pin), consult each
  `cluster/bootstrap/*/README.md` version-discovery procedure, check the
  upstream release notes for the Kubernetes minimum (the justfile's
  `k3s_image` comment records that Knative enforces one), then re-run
  `just cluster-bootstrap` — every step is `kubectl apply`/ConfigMap patch,
  so re-running at new pins upgrades in place. Bump `k3s_image` in lockstep
  when the Kubernetes minimum moves.
- *Observability charts*: `cluster/observability/install.sh` owns its chart
  pins; re-run `just observability` (`helm upgrade --install`) after bumping.
- *Cadence*: state an expected rhythm — monthly `nix flake update` +
  host-switch; cluster pins reviewed quarterly or on security advisories;
  never bump more than one layer (host vs. cluster) in the same session so a
  regression is attributable.
- *Verification after any upgrade*: `nagarectl doctor`, `just status`, and
  the smoke tests (`just local-smoke` needs no cloud; `just smoke` is the
  live test).

**3c. Optional local upgrade rehearsal (prototyping).** To prove the
"re-bootstrap upgrades in place" claim without touching the cloud: with
Docker running and a `mode=local` context (or `nagare.local.env`), run
`just local-up && just local-bootstrap && just local-minio`, confirm
`kubectl get pods -n knative-serving` is all Running; then bump the pins
(e.g. the next knative patch release) in a scratch working copy of the
justfile and re-run `just local-bootstrap`; confirm the deployments roll to
the new image versions and end Running, and `just local-smoke` passes
(`scripts/local-smoke.sh` — it stands the cluster up itself if needed and
ends with `local smoke: OK`). Discard the scratch pin bump afterwards; the
rehearsal validates the *procedure*, not a particular version. If this
rehearsal is skipped (e.g. no Docker), say so in Progress; it is optional.

**3d. justfile header.** Rewrite lines 1–9: replace the "target profile
`nagare.target.env`" description with the target-context model — commands
target the **active target context**, a named env file in
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env` selected via
`nagarectl context use NAME` or `NAGARE_CONTEXT`/`--context`, with
`nagare.target.env` / `nagare.local.env` as lower-precedence back-compat
fallbacks; with nothing configured the defaults reproduce
`tan-nb-exp` / `us-west1` / `us-west1-a`. Keep the pointer to `.envrc`,
`CLAUDE.md`, and `docs/user/contexts.md`. Do not touch any recipe body
(recipes are owned by `docs/plans/97`); the `vm-stop` comment's "target
profile" phrasing (line 31) belongs to 97 — leave it.

**3e. Disaster-recovery runbook fixes** in
`docs/runbooks/disaster-recovery.md`, each with the current line number:

- Lines 30 and 41: `nixos/secrets/` does not exist; the host secrets live at
  `nixos/hosts/nagare-01/secrets/`. Fix both occurrences (the line-30 one is
  inside the age-key section owned by plan 99 — correcting the literal wrong
  path is in scope; changing the key policy is not).
- Line 45 (backup inventory): the `Postgres data ... gcs://<backupBucket>/postgres/`
  row describes the removed host-Postgres model. Fold it into the managed
  database row (`gs://<backupBucket>/databases/<name>/`), which already
  exists at line 48–49.
- Lines 57–59: replace the literal `gs://tan-nb-exp-nagare-backups/` with
  "the active context's backup bucket" plus the lookup command
  `pulumi -C infra/pulumi stack output backupBucket`. Keep the prefix list
  matching what the tool actually probes (`postgres`, `litestream`,
  `volumes` — `cli/nagarectl/src/Nagare/Ops/Status.hs:72-74`), with a
  parenthetical that `postgres/` is the legacy prefix and managed-database
  dumps land under `databases/` (the probe rewrite is owned by
  `docs/plans/101-alerting-and-backup-freshness-monitoring.md`, Milestone 2;
  if that plan has landed first, describe the new `databases/<name>` probing
  instead of the legacy list).
- Line 67: change the example `# e.g. tan-nb-exp-nagare-backups` to
  `# e.g. <project>-nagare-backups`.
- Step 3 (lines 108–116): after M1 the kubeconfig is no longer world-readable,
  so `'cat /etc/rancher/k3s/k3s.yaml'` must become
  `'sudo cat /etc/rancher/k3s/k3s.yaml'` (the `deploy` user has passwordless
  sudo; `scripts/iap-ssh.sh recv-file` already streams via `sudo cat`).
  Delete the no-op `sed` on line 114 (it replaces a string with itself).
- Step 7 (lines 182–196): remove the duplicated Postgres restore block (lines
  188–191 duplicate 194–195); the single managed-database restore under
  `databases/` remains, first in the list after Litestream.
- Power management (lines 265–302): the section contradicts the committed
  config. `nixos/hosts/nagare-01/networking.nix` now **bakes in** the
  nameservers (line 13), the `/32` metadata route (lines 31–39), and the
  MASQUERADE (lines 50–56), so on any boot disk generation containing those
  commits nothing is "runtime-only and lost on reboot". Rewrite: a plain
  `start` boots the existing generation; if that generation includes the
  committed networking config (verify with
  `ip route get 169.254.169.254` showing `dev eth0` and `cat
  /etc/resolv.conf` showing `8.8.8.8`), no manual re-application is needed —
  keep the three-command re-apply block only as a demoted "if you are booting
  a pre-fix generation" footnote, and drop the `chattr +i` claim (the
  resolv.conf content is declarative, not held by an immutable-file hack).
  Point `nagarectl doctor` as the post-start check as it already does.
- Lines 272–273: drop `--project=tan-nb-exp`; use
  `just vm-stop` / `just vm-start` (which read the active context) as the
  primary commands, with the raw `gcloud` form using
  `--project="$CLOUDSDK_CORE_PROJECT"` as the spelled-out equivalent.
- Line 300: replace the literal image name `nagare-image-gnq7zw6pwd1a` with
  "the image recorded in the active context's Pulumi config key
  `nagareImageSelfLink`" plus the lookup
  `pulumi -C infra/pulumi config get nagareImageSelfLink`.

**3f. Secrets doc reality.** In `docs/user/secrets.md`: the status header
(lines 3–6) currently says Git-encrypted cluster bootstrap secrets are "still
planned", yet the DR runbook step 6 already relies on
`for f in cluster/secrets/*.yaml; do sops -d "$f" | kubectl apply -f -; done`
and `cluster/secrets/notes-db-url.yaml` exists, encrypted per the repo-root
`.sops.yaml` rule (`path_regex: cluster/secrets/.*\.ya?ml$`, values-only
encryption). Declare the sops loop the **supported** mechanism: update the
header status, change the summary block line from "(planned decrypt…)" to the
actual `sops -d | kubectl apply` flow, rewrite the "Cluster bootstrap secrets
— 🔭 Planned" section (lines 90–96) as ✅ with the loop command, the file
naming convention (a normal Kubernetes Secret manifest, `sops -e`'d in place,
values-only so diffs stay readable), and `notes-db-url.yaml` as the worked
example; update the rotation bullet (lines 104–105) to "edit with
`sops cluster/secrets/<file>.yaml`, re-apply with the loop".
Also update `docs/user/reference.md` line 29 (kubeconfig mode `0644` →
`0640 root:wheel`) and sweep other user docs that state mode 0644
(`docs/user/accessing-the-host.md` line ~90) to match M1.

Acceptance for M3 is the grep-clean check plus a runbook walk — see
Validation and Acceptance.


## Concrete Steps

All commands run from the repo root `/Users/shinzui/Keikaku/bokuno/nagare`
inside the dev shell unless stated. Remote host commands are shown via
`scripts/iap-ssh.sh ssh nagare-01 -- '<cmd>'`; plain `ssh deploy@nagare-01`
over Tailscale is equivalent when the tailnet is up. The VM must be running
(`just vm-start` if it was stopped).

**M1 edits and checks:**

```bash
# 1. Edit nixos/hosts/nagare-01/k3s.nix and nixos/modules/gcp.nix per Plan of Work.

# 2. Offline evaluation of the host config (works on aarch64-darwin, no builder):
nix eval ./nixos#nixosConfigurations.nagare-01.config.system.build.toplevel.drvPath

# 3. Repo-wide offline CI:
nix flake check
```

Expected: step 2 prints a `/nix/store/....drv` path (evaluation success);
step 3 ends without error. An evaluation error names the offending file/line —
fix before proceeding.

```bash
# 4. Confirm the group flag exists on the host's k3s before switching:
scripts/iap-ssh.sh ssh nagare-01 -- 'k3s server --help 2>&1 | grep -o -- --write-kubeconfig-group'

# 5. Apply (builds on the remote x86_64-linux builder, activates over Tailscale):
just host-switch

# 6. Enable encryption on this existing single-server cluster. The pinned
#    v1.34.6+k3s1 uses the version-gated late-enablement procedure:
scripts/iap-ssh.sh ssh nagare-01 -- 'sudo cp /var/lib/rancher/k3s/server/db/state.db /var/lib/rancher/k3s/server/db/state.db.pre-encryption.bak'
scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s secrets-encrypt enable'
scripts/iap-ssh.sh ssh nagare-01 -- 'sudo systemctl restart k3s'
scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s secrets-encrypt status' # Disabled, stage start
scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s secrets-encrypt rotate-keys'
scripts/iap-ssh.sh ssh nagare-01 -- 'sudo systemctl restart k3s'
scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s secrets-encrypt status'
```

Expected final status output includes:

```text
Encryption Status: Enabled
Current Rotation Stage: reencrypt_finished
```

If the first post-switch status already reports Enabled and
`reencrypt_finished`, the cluster was already encrypted and the enable/rotation
steps are unnecessary. Do not mix this procedure with the legacy
`prepare`/`rotate`/`reencrypt` workflow.

```bash
# 7. Verify M1 acceptance:
scripts/iap-ssh.sh ssh nagare-01 -- 'stat -c "%a %U %G" /etc/rancher/k3s/k3s.yaml'   # 640 root wheel
scripts/iap-ssh.sh ssh nagare-01 -- 'kubectl get nodes'                              # works as deploy, no sudo
scripts/iap-ssh.sh ssh nagare-01 -- 'sudo grep -ac "k8s:enc:aescbc" /var/lib/rancher/k3s/server/db/state.db'  # > 0
scripts/iap-ssh.sh ssh nagare-01 -- 'swapon --show'                                  # zram0 listed
scripts/iap-ssh.sh ssh nagare-01 -- 'sysctl fs.inotify.max_user_watches vm.overcommit_memory'
```

Commit M1 (stage explicit paths only — never `git add -A` in this repo):

```text
feat(host): harden k3s kubeconfig, encrypt secrets at rest, tune small node

MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
ExecPlan: docs/plans/103-host-tuning-upgrade-story-and-documentation-reality-sync.md
```

**M2 edits and checks:**

```bash
# 1. Edit nixos/hosts/nagare-01/registries.nix per Plan of Work.
# 2. Re-run the offline checks:
nix eval ./nixos#nixosConfigurations.nagare-01.config.system.build.toplevel.drvPath
nix flake check
# 3. Apply:
just host-switch
# 4. Old timer gone, new timer live:
scripts/iap-ssh.sh ssh nagare-01 -- 'systemctl list-timers | grep nagare || true'
# 5. Force the first sync rather than waiting for the timer:
scripts/iap-ssh.sh ssh nagare-01 -- 'sudo systemctl start nagare-registry-pull-secret && journalctl -u nagare-registry-pull-secret -n 20 --no-pager'
# 6. Secret + ServiceAccount wiring:
scripts/iap-ssh.sh ssh nagare-01 -- 'kubectl -n personal get secret nagare-registry-pull -o jsonpath="{.type}"; echo; kubectl -n personal get sa default -o jsonpath="{.imagePullSecrets}"; echo'
```

Expected in step 4: one `nagare-registry-pull-secret.timer` line and **no**
`nagare-registries-reload` line. Step 6 prints
`kubernetes.io/dockerconfigjson` and `[{"name":"nagare-registry-pull"}]`.

```bash
# 7. THE decisive pull test, > 45 min after the last k3s start (boot token expired).
#    Check when k3s last started, wait out the window if needed:
scripts/iap-ssh.sh ssh nagare-01 -- 'systemctl show k3s -p ExecMainStartTimestamp'
#    Evict the cached image so kubelet must pull, then run a fresh pod from the
#    private registry (substitute a real image path from the active context's
#    registry, e.g. one printed by a previous `nagarectl deploy`):
scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s crictl rmi <REGISTRY_HOST>/<project>/<repo>/<image>:<tag> || true'
scripts/iap-ssh.sh ssh nagare-01 -- 'kubectl -n personal run pull-canary --restart=Never --image=<REGISTRY_HOST>/<project>/<repo>/<image>:<tag> --command -- sleep 5 && kubectl -n personal wait pod/pull-canary --for=jsonpath="{.status.phase}"=Succeeded --timeout=180s; kubectl -n personal delete pod pull-canary'
# 8. No k3s restarts in the window:
scripts/iap-ssh.sh ssh nagare-01 -- 'journalctl -u k3s --since "-2h" --no-pager | grep -c "Starting Lightweight Kubernetes" || true'
```

Expected: the canary pod reaches `Succeeded` (pull worked via the Secret);
step 8 prints `0` once the post-switch window contains no restarts. If the
pull fails with 401/403, inspect `journalctl -u nagare-registry-pull-secret`
and the Secret's age; see Idempotence and Recovery for rollback.

Commit M2:

```text
feat(host): refresh registry pull credentials without restarting k3s

MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
ExecPlan: docs/plans/103-host-tuning-upgrade-story-and-documentation-reality-sync.md
```

**M3 edits and checks:**

```bash
# 1. net-certmanager verification (record the output in this plan):
gh release view knative-v1.22.0 -R knative/serving --json assets --jq '.assets[].name'
# 2. Make the 3a/3d justfile edits, 3b upgrades.md, 3e/3f doc edits per Plan of Work.
# 3. justfile still parses:
just --list
# 4. Stale-string sweep must return NOTHING (each line's silence is an acceptance check):
grep -rn "nixos/secrets/" docs/runbooks/ docs/user/
grep -rn "nagare-image-gnq7zw6pwd1a" docs/
grep -rn "tan-nb-exp-nagare-backups" docs/runbooks/
grep -rn "target profile" justfile | sed -n '1,9p'    # header lines only; line ~31 is plan 97's
grep -n "0644" docs/user/reference.md docs/user/accessing-the-host.md docs/runbooks/disaster-recovery.md
grep -n "Planned" docs/user/secrets.md                # cluster-bootstrap section no longer Planned
# 5. Runbook walk (paper check): follow disaster-recovery.md top to bottom and
#    confirm every named path exists in the tree and every command names real
#    recipes/flags (ls the paths, `just --list` the recipes).
# 6. If a cluster is reachable (cloud or `just local-up && just local-bootstrap`):
just cluster-bootstrap        # idempotent re-apply at the (possibly repointed) pins
kubectl -n knative-serving rollout status deploy/net-certmanager-controller
# 7. Optional rehearsal (3c): bump pins in a scratch copy, re-run local-bootstrap,
#    then:
just local-smoke              # ends with: local smoke: OK
```

Commit M3 (docs and pins may be split into `docs(...)` and `feat(cluster)`
commits as natural; every commit carries the trailers):

```text
docs: sync runbooks and secrets docs with reality; add upgrade guide

MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
ExecPlan: docs/plans/103-host-tuning-upgrade-story-and-documentation-reality-sync.md
```


## Validation and Acceptance

Acceptance is behavior, observed:

1. **Kubeconfig hardening:** on nagare-01,
   `stat -c '%a %U %G' /etc/rancher/k3s/k3s.yaml` prints `640 root wheel`;
   `kubectl get nodes` as `deploy` (wheel member) returns the node `Ready`
   without sudo; a non-wheel test (`sudo -u nobody cat /etc/rancher/k3s/k3s.yaml`)
   is denied.
2. **Secrets at rest:** `sudo k3s secrets-encrypt status` prints
   `Encryption Status: Enabled` and `Current Rotation Stage:
   reencrypt_finished`; `sudo grep -ac 'k8s:enc:aescbc'
   /var/lib/rancher/k3s/server/db/state.db` prints a positive count, and
   creating a canary secret (`kubectl create secret generic canary
   --from-literal=x=supersecretvalue`) followed by
   `sudo grep -ac supersecretvalue .../state.db` prints `0` (then delete the
   canary).
3. **Node tuning:** `swapon --show` lists `/dev/zram0`;
   `sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches
   vm.overcommit_memory` prints `512`, `524288`, `1`.
4. **No restart-based credential refresh:** `systemctl list-timers` shows
   `nagare-registry-pull-secret.timer` and no `nagare-registries-reload`;
   over any 2-hour observation window
   `journalctl -u k3s --since "-2h" | grep -c 'Starting Lightweight
   Kubernetes'` prints `0`; and the decisive test — evict the cached image,
   start a fresh pod from the private registry **more than 45 minutes after
   the last k3s start** — reaches `Succeeded`. Before this plan the same
   window necessarily contained at least two k3s restarts.
5. **Upgrade story:** `docs/user/upgrades.md` exists, is linked from
   `docs/user/README.md`, and its cluster procedure is proven by an idempotent
   `just cluster-bootstrap` re-run ending with
   `deploy/net-certmanager-controller successfully rolled out` (cloud or k3d).
   If the optional rehearsal ran, `just local-smoke` printed `local smoke: OK`
   after the re-bootstrap at bumped pins.
6. **Docs match reality:** every grep in Concrete Steps M3 step 4 behaves as
   annotated (stale strings absent; `0644` no longer claimed for the
   kubeconfig; the secrets doc's cluster-bootstrap section no longer says
   Planned); a top-to-bottom read of `docs/runbooks/disaster-recovery.md`
   names only paths that exist (`ls` each) and recipes that `just --list`
   shows; the power-management section no longer instructs re-applying routes
   that `nixos/hosts/nagare-01/networking.nix` bakes in.
7. **Nothing regressed:** `nix flake check` passes at every milestone;
   `nagarectl doctor` (workstation, cluster reachable) reports OK lines for
   the control-plane and registry probes after M1 and M2.


## Idempotence and Recovery

Every `just host-switch` is idempotent — NixOS activation converges the host
to the committed config, and re-running after a partial failure is the
recovery action. `nix eval` / `nix flake check` are read-only. All kubectl
steps are `apply`/`patch`-shaped and safe to repeat; the pull-secret script is
designed to be re-run every 30 minutes forever.

Risky step: **secrets-encrypt reencrypt** rewrites Secret rows in
`state.db`. Mitigation: the pre-step `cp` backup
(`state.db.pre-encryption.bak`). If the datastore is damaged, stop k3s
(`sudo systemctl stop k3s`), restore the backup over `state.db`, start k3s.
To back the feature out entirely: `sudo k3s secrets-encrypt disable`, restart
k3s, `sudo k3s secrets-encrypt reencrypt` (which decrypts), and drop the flag
from `k3s.nix`. Note the encryption keys live under
`/var/lib/rancher/k3s/server/cred/` — they are part of the host, not of Git;
a DR rebuild that restores workloads via the runbook (re-applying sops
secrets) does not need them, but a raw `state.db` copied to a fresh host does.

M2 rollback: `git revert` the M2 commit and `just host-switch` — the reload
timer returns and the pull-secret units are removed. The patched
`imagePullSecrets` entry on the `default` ServiceAccount is harmless to leave
(a dangling or stale secret is simply an extra failed auth attempt before
other credentials), but can be removed with
`kubectl -n personal patch serviceaccount default --type=json -p
'[{"op":"remove","path":"/imagePullSecrets"}]'`.

The kubeconfig mode change can strand a workflow that read
`/etc/rancher/k3s/k3s.yaml` without sudo; the known consumers were audited
(`scripts/iap-ssh.sh recv-file` already uses `sudo cat`; `scripts/live-test.sh`
uses recv-file; the DR runbook step 3 is fixed in M3). If something else
breaks, the immediate unblock is `sudo cat`, not reverting the mode.

Doc edits are plain text and safe to redo; the grep sweep in M3 is the
convergence check.


## Interfaces and Dependencies

No new external services, libraries, or packages. Everything uses what the
repo already depends on:

- `nixos/hosts/nagare-01/k3s.nix`: `services.k3s.extraFlags` ends the plan
  containing `--disable=traefik`, `--write-kubeconfig-mode=0640`,
  `--write-kubeconfig-group=wheel`, `--secrets-encryption`,
  `--default-local-storage-path=/var/lib/nagare/local-path`.
- `nixos/hosts/nagare-01/registries.nix`: ends the plan defining exactly three
  systemd objects — `services.nagare-registries-refresh` (unchanged boot-time
  oneshot), `services.nagare-registry-pull-secret` (new oneshot; script uses
  `pkgs.curl`, `pkgs.jq`, `pkgs.coreutils`, and k3s's kubectl with
  `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`), and
  `timers.nagare-registry-pull-secret` (`OnBootSec=2min`,
  `OnUnitActiveSec=30min`, `Persistent=true`). The `registryHost` value keeps
  coming from the optional generated `registry-host.nix`
  (`just nixos-registry-host` regenerates it from the active context). The
  Secret is named `nagare-registry-pull`, type
  `kubernetes.io/dockerconfigjson`, in namespace `personal` (namespace list is
  a Nix variable).
- `nixos/modules/gcp.nix`: gains `zramSwap.enable = true;` and the three
  sysctls alongside the existing four.
- `justfile`: variables `knative_version` / `certmanager_version` remain; the
  net-certmanager install line(s) point wherever 3a's verification dictates.
- `docs/user/upgrades.md`: new page; consumes only existing commands
  (`nix flake update`, `just host-image`, `just host-switch`,
  `just cluster-bootstrap`, `just observability`, `just local-smoke`,
  `nagarectl doctor`).
- GCE metadata server (`http://metadata.google.internal/computeMetadata/v1/
  instance/service-accounts/default/token`, reachable per the `/32` route in
  `nixos/hosts/nagare-01/networking.nix`) remains the sole credential source
  for registry pulls — no stored secrets are introduced.

Commit conventions for all work under this plan: Conventional Commits, each
message carrying the two trailers
`MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md`
and
`ExecPlan: docs/plans/103-host-tuning-upgrade-story-and-documentation-reality-sync.md`.
Stage files by explicit path (repo rule: never `git add -A`).

---

Revision note (2026-07-15): initial authoring — replaced the skeleton with the
full plan. Research verified against the tree at commit `28a67ef`: k3s.nix:9
(`--write-kubeconfig-mode=0644`), registries.nix:92–111 (restart timer),
gcp.nix:41–46 (sysctls), justfile:5–9 (stale header), :70–74 (pins), :110/:210
(net-certmanager URLs), net-certmanager/README.md:10–18 ("froze" claim),
disaster-recovery.md lines 30/41/45/57–59/67/108–116/188–195/265–302,
secrets.md:3–6/90–96, reference.md:29, `nixos/flake.lock` nixpkgs
lastModified 2026-05-31, `Nagare/Ops/Status.hs:72–74` legacy `postgres`
freshness prefix.
