---
id: 7
slug: backups-secrets-and-disaster-recovery
title: "Backups secrets and disaster recovery"
kind: exec-plan
created_at: 2026-06-02T15:39:48Z
intention: "intention_01kt4f3svnekz80g94f2k4tthq"
master_plan: "docs/masterplans/1-bootstrap-nagare-personal-paas.md"
---

# Backups secrets and disaster recovery

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Nagare is a personal Platform-as-a-Service running on one Google Cloud Platform (GCP)
virtual machine. "Platform-as-a-Service" (PaaS) just means: you push an application and the
platform runs it for you, handling the servers, networking, and certificates underneath. The
whole point of Nagare, stated in `docs/initial-spec.md`, is that **the machine should be
disposable**: if the VM is deleted, corrupted, or you simply want to move to a bigger
instance, you should be able to rebuild the entire system from this Git repository plus a
small set of backups, and the rebuild should be *boring* — predictable, documented, and
free of surprises.

This plan, EP-7, is the last of the seven child plans of the "Bootstrap Nagare Personal
PaaS" MasterPlan (`docs/masterplans/1-bootstrap-nagare-personal-paas.md`). After EP-7 is
done, three things are true that were not true before:

1. **Secrets are managed, not scattered.** Sensitive values — database passwords, API keys,
   the Tailscale authentication key for the host — live encrypted in Git and on disk. Two
   complementary mechanisms exist. For *host* secrets (things NixOS needs at boot, like the
   Tailscale key) we use **sops-nix**, which decrypts secrets during NixOS activation. For
   *Kubernetes* secrets (things applications read, like a `DATABASE_URL`) we use the
   standalone **sops** command-line tool with **age** encryption to commit encrypted Secret
   manifests to Git, decrypting and applying them with one command. An application can then
   reference such a secret by name through the `secretRef` field of its `nagare.yaml`
   (defined in EP-6), and the value is injected as an environment variable at runtime.

2. **Application data is continuously and periodically backed up to cloud storage.** Small
   apps that use SQLite (a single-file embedded database) get **Litestream**, which streams
   every change to a Google Cloud Storage (GCS) bucket so the database can be restored from a
   recent point in time. The more important shared database, PostgreSQL ("Postgres"), gets a
   scheduled `pg_dump` (a built-in tool that writes the whole database to a single file) that
   is uploaded to the same bucket. We can list those backup objects in the bucket and we can
   restore them into a scratch database and prove the data came back.

3. **A disaster-recovery runbook exists and has been tested.** A step-by-step document
   (`docs/runbooks/disaster-recovery.md`) walks a novice through rebuilding the machine end to
   end: provision cloud resources with Pulumi, build and register the NixOS image, boot the
   VM, bootstrap the cluster, install observability, restore the data, and redeploy the apps.
   Each step has a command and an expected observation, so anyone — including a future you who
   has forgotten all the details — can follow it.

The success criterion for this plan is exactly the spec's: **rebuilding the system from Git
plus backups is boring and reproducible.** You can see it working by deleting (or simulating
the deletion of) the data, following the runbook, and watching the same data and apps come
back.

Definitions of terms used throughout this plan (each is defined here so the plan is
self-contained; do not assume the reader knows them):

- **sops**: short for "Secrets OPerationS." A command-line tool that encrypts the *values*
  inside a structured file (YAML/JSON) while leaving the *keys* readable. This means an
  encrypted Kubernetes Secret manifest still shows you `metadata.name` and which keys exist,
  so Git diffs remain meaningful, but the actual secret bytes are ciphertext. The repository
  uses sops via a `.sops.yaml` policy file at the repo root.
- **age**: a modern, simple file-encryption tool (pronounced like the Japanese "age", or
  just "age"). It uses a keypair: a *public* recipient key (safe to commit, starts with
  `age1...`) that anyone can encrypt to, and a *private* identity key (kept secret, starts
  with `AGE-SECRET-KEY-...`) that decrypts. sops uses age as its encryption backend here.
- **sops-nix**: a NixOS module (from the project `Mic92/sops-nix`) that decrypts sops-encrypted
  secrets *during NixOS activation* and places the plaintext into files under `/run/secrets`
  (a memory-backed, root-only location) for services to read. It is configured through NixOS
  options like `sops.secrets.<name>`, `sops.defaultSopsFile`, and `sops.age.keyFile`.
- **Litestream**: a tool that watches a SQLite database file and continuously copies its
  *write-ahead log* to object storage (GCS here), so the database can be reconstructed
  elsewhere. It runs alongside the application as a companion process.
- **WAL** (write-ahead log): SQLite's journal of recent changes. Instead of rewriting the
  main database file on every change, SQLite appends changes to a `-wal` file and later
  folds them in ("checkpoints"). Litestream ships these WAL segments to GCS; replaying them
  reproduces the database.
- **secretRef**: a field in Nagare's `nagare.yaml` application contract (owned by EP-6,
  `docs/plans/6-nagarectl-deploy-cli-in-haskell.md`) that says "set this environment variable
  from a Kubernetes Secret of this name." For example `DATABASE_URL: { secretRef: notes-db-url }`
  means the env var `DATABASE_URL` is read from the Secret named `notes-db-url`.
- **Application Default Credentials** (ADC): the standard way Google client tools find
  credentials without a key file. On a GCP VM, ADC automatically uses the VM's attached
  service account. Because EP-2 attaches a service account that has write access to the
  backup bucket, on-host backup tools authenticate with *no key files at all*.
- **runbook**: a plain, ordered operational procedure — "do this, observe that" — meant to be
  followed under pressure without thinking hard.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — Secrets management (sops + age, Kubernetes and host):

- [x] Generated a project age keypair; private key at `~/.config/sops/age/keys.txt` (mode 600,
  outside the repo), recipient `age1pqfv2y3u3y66y5zsr3qd7pnxstatvnlnx39nttzksg8kynn4a5tsq9vcsf`
  recorded in `.sops.yaml`. `.gitignore` guards against committing age keys. (2026-06-03)
- [x] Wrote `.sops.yaml` with rules for `cluster/secrets/.*\.ya?ml$` (encrypt only
  `data`/`stringData`) and `nixos/secrets/.*\.ya?ml$` (whole-file). (2026-06-03)
- [x] Created and encrypted `cluster/secrets/notes-db-url.yaml`; values are ciphertext, keys
  readable; committed. (2026-06-03)
- [x] Proved the round trip live: `sops -d ... | kubectl apply` → `secret/notes-db-url created`;
  `kubectl get secret notes-db-url -n personal` lists it. (2026-06-03)
- [x] Demonstrated live consumption: a pod with `secretKeyRef: {name: notes-db-url, key: DATABASE_URL}`
  logged `DATABASE_URL is set to: postgres://notes:CHANGEME@127.0.0.1:5432/notes` — the exact
  `secretRef` shape `nagarectl` (EP-6) renders. (2026-06-03)
- [~] Host sops-nix extension **documented** in this plan (M1.6 snippet) but **not applied** —
  EP-3 introduces sops-nix; wiring a second host secret + the Postgres-backup timer is left to a
  day-2 host change (deferred with the systemd timer, see M2). (2026-06-03)

Milestone 2 — Data backups (Litestream for SQLite, pg_dump for Postgres):

- [x] Authored `cluster/examples/sqlite-litestream/` (app + Litestream sidecar) and
  `litestream.yml` replicating to `gcs://tan-nb-exp-nagare-backups/litestream/app.db`. (2026-06-03)
- [x] Deployed it; confirmed objects in GCS:
  `gs://.../litestream/app.db/generations/<gen>/snapshots/00000000.snapshot.lz4`. **Required a host
  networking fix** — pods could not reach the GCE metadata server for keyless ADC; see Surprises and
  the EP-3 `networking.nix` `denyInterfaces`/MASQUERADE fix. The sidecar also needs
  `GCE_METADATA_HOST=169.254.169.254`. (2026-06-03)
- [x] Authored `scripts/backup-postgres.sh` (IP-9 preflight, ADC upload, timestamped dumps). The
  NixOS systemd timer is **documented** (M2.3) but **not wired** this session — no Postgres is
  deployed yet (Postgres is implied by the data strategy, not a built component of this initiative).
  (2026-06-03)
- [~] Postgres dump object in GCS: **deferred** — requires a running host Postgres. The script is
  syntax-checked and ready; live verification waits on a Postgres deployment. (2026-06-03)
- [x] Authored `scripts/restore-sqlite.sh` and `scripts/restore-postgres.sh` (scratch-first,
  IP-9 preflight); both syntax-checked. `restore-sqlite.sh` is runnable against the live Litestream
  replica; `restore-postgres.sh` full run is deferred with the Postgres backup above. (2026-06-03)

Milestone 3 — Disaster-recovery runbook (write and test):

- [x] Wrote `docs/runbooks/disaster-recovery.md` with the full rebuild sequence (Pulumi → image/boot
  → cluster access → bootstrap → observability → secrets → data → apps), each step a command +
  expected observation. Incorporates this session's real learnings (100 GB boot disk; the DNS +
  metadata image requirements; SSH-local-forward cluster access; EP-4 HTTP-first). (2026-06-03)
- [x] Documented the backup inventory (Git config/manifests, in-repo Pulumi state, sops secrets,
  SQLite via Litestream, Postgres dumps, Grafana dashboards in Git; Victoria data non-critical; the
  age private key as the one out-of-band item). (2026-06-03)
- [x] Dashboards-in-Git is covered by `cluster/observability/grafana/dashboards/README.md` (EP-5)
  and referenced in the runbook inventory. (2026-06-03)
- [~] Full DR dry run: **partial.** Most steps were exercised end-to-end this session on a freshly
  rebuilt VM — `pulumi up` (VM replace), `just host-image`, `just cluster-bootstrap` (EP-4 from
  scratch), `just observability` (EP-5), sops decrypt+apply (M1), and Litestream backup to GCS (M2).
  A single clean-room top-to-bottom rebuild-from-nothing and the Postgres restore were not run.
  (2026-06-03)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Keyless ADC did NOT work in-cluster until a host networking bug was fixed.** The plan assumed
  Litestream (and any GCP-using pod) authenticates via Application Default Credentials = the node's
  service account. On this self-managed k3s that failed: first `could not find default credentials`
  (the Go metadata library probes `metadata.google.internal`, which pods can't resolve — only the
  host's `/etc/hosts` has it; coredns forwards to public DNS → NXDOMAIN), then, after setting
  `GCE_METADATA_HOST=169.254.169.254`, `dial tcp 169.254.169.254:80: connect: no route to host`.
  **Root cause:** dhcpcd assigned IPv4 link-local `169.254.0.0/16` addresses to the flannel/veth
  interfaces, and the resulting on-link route hijacked `169.254.169.254` onto `flannel.1`
  (`ip route get 169.254.169.254 → dev flannel.1`) instead of eth0 to the real metadata server.
  **Fix (EP-3 `networking.nix`):** `networking.dhcpcd.denyInterfaces = [veth* flannel* cni* kube*
  datapath*]` (removes the /16 hijack) + a MASQUERADE for pod → `169.254.169.254` (SNAT to the node
  IP). Validated at runtime (`/32` metadata route via eth0 + MASQUERADE): a pod then read
  `nagare-node@tan-nb-exp.iam.gserviceaccount.com` from metadata and Litestream replicated to GCS.
  The Litestream sidecar still sets `GCE_METADATA_HOST=169.254.169.254` so the Go library skips the
  unresolvable `metadata.google.internal` name. **This same gap blocks EP-4's deferred DNS-01
  wildcard TLS** (cert-manager pods need GCP creds to write the Cloud DNS TXT record) — the
  `networking.nix` fix unblocks both. The durable fix is baked into the rebuilt image; the running
  host carries the validated runtime route+MASQUERADE until it next boots the new image. (2026-06-03)
- **Litestream's GCS replica URL is `gcs://<bucket>/<path>`** (confirmed working), distinct from the
  `gs://` scheme `gsutil` uses. The VM service account's `roles/storage.objectAdmin` on the bucket
  (EP-2) is correctly scoped — once pods could reach metadata, the write succeeded with no key file.
  (2026-06-03)
- **sops round-trip is clean.** `sops -e -i` with `encrypted_regex: ^(data|stringData)$` leaves
  `metadata`/keys readable and only the value as `ENC[...]`; `sops -d | kubectl apply` produces a
  normal Secret and is idempotent. No annotation issues observed. (2026-06-03)


## Decision Log

Record every decision made while working on the plan.

- Decision: Use two distinct secret mechanisms — sops-nix for *host* secrets and standalone
  sops+age for *Kubernetes* secrets committed to Git — rather than a single mechanism.
  Rationale: They solve different problems at different layers. sops-nix decrypts at NixOS
  activation into `/run/secrets` for host services (e.g. the Tailscale key, already introduced
  in EP-3, `docs/plans/3-nixos-host-nagare-01-with-k3s.md`); it cannot create Kubernetes
  Secret objects. The standalone sops tool encrypts Secret *manifests* whose decrypted form is
  applied to the cluster with `kubectl`. Both share the same age key material, keeping key
  management simple. The spec's "Secrets" section explicitly recommends exactly this pairing
  for v1.
  Date: 2026-06-02

- Decision: For Kubernetes secrets in v1, use *manual* `sops -d ... | kubectl apply -f -`
  rather than the External Secrets Operator or an in-cluster sops controller.
  Rationale: The MasterPlan's Non-Goals (and `docs/initial-spec.md`) list the External Secrets
  Operator as explicitly out of scope for v1. Manual decrypt-and-apply is the simplest path
  that still keeps encrypted secrets in Git and is trivially scriptable into `nagarectl`/`just`
  later. We can graduate to an operator later without changing how secrets are *stored*.
  Date: 2026-06-02

- Decision: Encrypt only the *values* of Secret manifests using sops
  `encrypted_regex: ^(data|stringData)$`, leaving keys and metadata readable.
  Rationale: This keeps Git diffs reviewable (you can see which secret changed and which keys
  exist) while never exposing secret bytes. It is the standard, well-documented sops pattern
  for Kubernetes Secrets.
  Date: 2026-06-02

- Decision: On-host backup tools (the Postgres dump uploader) authenticate to GCS via
  Application Default Credentials (the VM's attached service account), with no key files.
  Rationale: EP-2 attaches a service account (`serviceAccountEmail`) to the VM and grants it
  `roles/storage.objectAdmin` on the backup bucket (Integration Points 1 and 2). On a GCP VM,
  `gsutil`/`gcloud` automatically use that identity. Avoiding key files removes a class of
  secret-leak and rotation problems entirely.
  Date: 2026-06-02

- Decision: Litestream for SQLite (Tier 2 apps); scheduled `pg_dump` to GCS for Postgres
  (Tier 3) in v1, rather than Postgres WAL archiving.
  Rationale: `docs/initial-spec.md`'s "Data Strategy" defines exactly these tiers. WAL
  archiving for Postgres is more powerful (point-in-time recovery) but materially more
  complex to operate and restore; a nightly logical `pg_dump` is simple, easy to verify, and
  sufficient for a single-node personal platform. Point-in-time Postgres recovery is a
  documented future upgrade, not a v1 requirement.
  Date: 2026-06-02

- Decision: All `gsutil`/`gcloud` calls in this plan's scripts target `tan-nb-exp`,
  `us-west1`, `us-west1-a`, carry the Integration-Point-9 preflight assertion, and pass
  `--project=tan-nb-exp` explicitly.
  Rationale: Integration Point 9 of the MasterPlan and the reference repo
  `/Users/shinzui/Keikaku/bokuno/load-testing-infra/CLAUDE.md` mandate single-project
  isolation enforced by `.envrc`, a per-script preflight, and the explicit flag. Backups touch
  cloud storage, so they must obey the same policy.
  Date: 2026-06-02

- Decision: Keep keyless in-cluster GCP auth (node ADC) by fixing host networking, rather than
  switching to a mounted service-account key.
  Rationale: The plan's keyless-ADC assumption initially failed because pods could not reach the GCE
  metadata server (dhcpcd IPv4LL hijacked the metadata route onto flannel.1 — see Surprises). The two
  candidate fixes were (a) make the metadata server reachable from pods (host networking) or (b)
  mount a sops-encrypted GCP service-account key into GCP-using pods. We chose (a): a one-time
  `networking.dhcpcd.denyInterfaces` + MASQUERADE fix in EP-3's `networking.nix` restores keyless ADC
  for *all* pods (Litestream now, cert-manager DNS-01 TLS later), avoiding long-lived key files and
  their rotation/leak risk — consistent with the plan's original intent. Litestream additionally sets
  `GCE_METADATA_HOST=169.254.169.254` so the Go metadata library skips the pod-unresolvable
  `metadata.google.internal` hostname.
  Date: 2026-06-03

- Decision: Restores always write to a *scratch* target first (a temporary local file or a
  freshly created scratch database), never over a live database, and only after verification
  does the operator promote them.
  Rationale: Idempotence and safety (a PLANS.md requirement). A restore that clobbers live
  data on a typo would itself be a disaster. Writing to scratch and diffing makes the restore
  repeatable and provably correct before any destructive promotion.
  Date: 2026-06-02


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Status (2026-06-03): substantially complete; secrets and SQLite backups verified live; Postgres
live-test and a clean-room full DR dry-run deferred.**

Delivered and verified:
- **Secrets (M1):** `.sops.yaml` + encrypted `cluster/secrets/notes-db-url.yaml`; round-trip proven
  live (`sops -d | kubectl apply` → Secret → pod env via `secretKeyRef`). The age private key lives
  only at `~/.config/sops/age/keys.txt` (gitignored class) and must be backed up offline.
- **SQLite backups (M2):** the Litestream sample replicates to
  `gcs://tan-nb-exp-nagare-backups/litestream/app.db/...` via keyless ADC — verified by listing the
  snapshot object. This required (and drove) the EP-3 metadata-routing fix.
- **DR runbook (M3):** `docs/runbooks/disaster-recovery.md` with the full sequence, backup inventory,
  and the age-key warning. Most steps were exercised live this session during the EP-5 VM rebuild +
  EP-4/EP-5 re-bootstrap.

Deferred / gaps (each non-blocking, with a clear reason):
- **Postgres backup + restore are authored but not live-tested** — no Postgres is deployed (Postgres
  is part of the data strategy but not a built component of this initiative). `backup-postgres.sh`,
  `restore-postgres.sh`, and the systemd-timer snippet are ready; run them once Postgres exists.
- **Host sops-nix second secret + the Postgres systemd timer are documented, not wired** — they are a
  day-2 host change layered on EP-3's sops-nix.
- **A clean-room top-to-bottom rebuild-from-nothing was not performed** (it would destroy the running
  cluster). Component steps were each validated; a true DR drill remains a worthwhile future exercise.

Against the success criterion ("rebuilding from Git + backups is boring and reproducible"): the
mechanisms exist and the reproducibility-critical infra bugs found this session (boot-disk sizing,
clean-boot DNS, the metadata-routing/ADC gap) are fixed in source and baked into the rebuilt image —
so a rebuild is materially more boring than at the session's start. The remaining un-boring risk is
that the running host still carries runtime workarounds (the immutable resolv.conf and the runtime
metadata route/MASQUERADE) until it next boots the final image; a future VM replacement onto
`nagareImageSelfLink` should be done to confirm a fully clean boot and then drop those workarounds.


## Context and Orientation

This plan assumes the reader knows nothing about Nagare. Here is the landscape, with full
repository-relative paths.

The repository root is `/Users/shinzui/Keikaku/bokuno/nagare`. All paths below are relative to
that root unless stated otherwise. The development environment is a Nix flake dev shell entered
with `nix develop` (defined by EP-1, `docs/plans/1-repository-scaffolding-and-nix-flake-dev-environment.md`).
Integration Point 8 of the MasterPlan guarantees this shell provides the tools this plan needs:
`sops`, `age`, `kubectl`, `gcloud`/`gsutil`, `jq`, and `just`. Litestream is run *inside the
cluster* as a container image, so it does not need to be in the dev shell, but a copy in the
shell is convenient for local testing; if it is not present, the plan notes how to invoke it
via its container image instead.

GCP isolation (Integration Point 9, mirrored from
`/Users/shinzui/Keikaku/bokuno/load-testing-infra/CLAUDE.md`): every cloud resource and every
`gcloud`/`gsutil`/`pulumi` invocation targets **project `tan-nb-exp`, region `us-west1`, zone
`us-west1-a`**. A repo-root `.envrc` (from EP-1) exports `CLOUDSDK_CORE_PROJECT=tan-nb-exp`,
`CLOUDSDK_COMPUTE_REGION=us-west1`, and `CLOUDSDK_COMPUTE_ZONE=us-west1-a`. Every script under
`scripts/` that calls `gcloud`/`gsutil` must include the preflight assertion (refuse to run
unless the active project equals `tan-nb-exp`) and pass `--project=tan-nb-exp` explicitly. The
exact preflight snippet appears in Concrete Steps below and is copied verbatim from the
reference repo.

What earlier plans have produced that this plan builds on (each is a checked-in plan file you
may reference; consult it if you need detail beyond what is restated here):

- EP-2 (`docs/plans/2-pulumi-gcp-infrastructure.md`) owns cloud resources and exports the
  stack outputs this plan consumes (Integration Point 1). The two outputs that matter here are
  **`backupBucket`** (the GCS bucket name for backups) and **`serviceAccountEmail`** (the VM's
  attached service account). EP-2 also grants that service account
  **`roles/storage.objectAdmin` scoped to the backup bucket** (Integration Point 2), which is
  what lets on-host backups write via Application Default Credentials. You read these outputs
  with `pulumi stack output backupBucket` and `pulumi stack output serviceAccountEmail` from
  inside `infra/pulumi/`.
- EP-3 (`docs/plans/3-nixos-host-nagare-01-with-k3s.md`) owns the host. It mounts the
  persistent data disk at **`/var/lib/nagare`** with the subdirectory layout from Integration
  Point 3: `/var/lib/nagare/sqlite`, `/var/lib/nagare/postgres`, `/var/lib/nagare/backups`, and
  the Victoria/local-path directories. EP-3 also introduces **sops-nix** for the Tailscale
  authentication key; this plan *extends* that existing sops-nix configuration with one more
  host secret, rather than introducing sops-nix from scratch. EP-3 writes the cluster
  kubeconfig at `/etc/rancher/k3s/k3s.yaml` (Integration Point 7); you copy it locally and
  point `KUBECONFIG` at it to run `kubectl`.
- EP-4 (`docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md`) establishes the
  cluster platform and the `personal` namespace where apps live (Integration Point 5), and ships
  a sample app under `cluster/examples/hello-knative-service/`. The secrets pattern apps use —
  `secretRef` in `nagare.yaml` — is the pattern this plan's example Kubernetes Secret feeds.
- EP-5 (`docs/plans/5-victoria-observability-stack-and-grafana.md`) owns observability and the
  Grafana dashboards under `cluster/observability/grafana/dashboards/`. This plan adds a note
  there reaffirming that dashboards are committed to Git (so they survive a rebuild) and treats
  the Victoria *time-series data* as non-critical (re-derivable, not restored).
- EP-6 (`docs/plans/6-nagarectl-deploy-cli-in-haskell.md`) owns `nagarectl` and the `nagare.yaml`
  contract that includes `secretRef`. The apps deployed by `nagarectl` are what this plan backs
  up and restores.

New files and directories this plan creates (none exist yet — verified by listing the tree):

- `.sops.yaml` — repo-root sops policy (age recipients and which files/values to encrypt).
- `cluster/secrets/notes-db-url.yaml` — an example encrypted Kubernetes Secret (a `DATABASE_URL`
  referenced by an app's `secretRef`).
- `cluster/examples/sqlite-litestream/` — a sample SQLite app with a Litestream sidecar and its
  `litestream.yml`.
- `scripts/backup-postgres.sh`, `scripts/restore-postgres.sh`, `scripts/restore-sqlite.sh` —
  backup/restore scripts with the IP-9 preflight.
- `cluster/observability/grafana/dashboards/README.md` — a short note that dashboards are
  committed to Git (cross-references EP-5).
- `docs/runbooks/disaster-recovery.md` — the rebuild runbook.
- An extension (documented, applied in EP-3's NixOS files) adding a Postgres-backup systemd
  timer and a second sops-nix host secret.


## Plan of Work

The work is three milestones, each independently verifiable. They are ordered so the reader
always has something concrete to observe at the end of each.

### Milestone 1 — Secrets management

Scope: stand up the whole secrets story and prove a Kubernetes Secret round-trips from Git to
the cluster and into a running pod, and document extending the host's sops-nix secrets.

What will exist at the end: an age keypair (private key stored locally, public recipient
recorded in the plan and `.sops.yaml`); a `.sops.yaml` policy at the repo root; an encrypted
`cluster/secrets/notes-db-url.yaml`; a demonstrated decrypt-and-apply that creates the
`notes-db-url` Secret in the `personal` namespace; a demonstration that an app reading
`DATABASE_URL` via `secretRef: notes-db-url` sees the value; and a documented procedure for
adding a host secret to EP-3's sops-nix configuration.

Sequence of edits. First, generate the age key with `age-keygen` and capture both halves: the
private identity (kept out of Git, stored where sops-nix and your laptop expect it) and the
public recipient. Second, create `.sops.yaml` with a `creation_rules` entry whose `path_regex`
matches `cluster/secrets/.*\.ya?ml$`, whose `age:` lists the public recipient, and whose
`encrypted_regex` is `^(data|stringData)$` so only the secret values are encrypted. Third,
write a plaintext Kubernetes Secret manifest for `notes-db-url` (using `stringData` so the
value is human-readable before encryption), then encrypt it in place with `sops -e -i`. Fourth,
prove the round trip by decrypting and applying it. Fifth, write the host-secret extension as
prose plus a Nix snippet showing the new `sops.secrets.<name>` entry that joins the existing
Tailscale key in EP-3.

Acceptance: `sops -d cluster/secrets/notes-db-url.yaml | kubectl apply -f -` prints
`secret/notes-db-url created` (or `configured` on a re-run); `kubectl get secret notes-db-url
-n personal` lists it; and a pod that mounts it via `secretRef` shows the env var set.

### Milestone 2 — Data backups

Scope: continuous SQLite backups via Litestream and scheduled Postgres dumps, both to the GCS
backup bucket, plus restore scripts that prove the data comes back.

What will exist at the end: a deployed sample SQLite app whose database is replicated to
`gcs://<backupBucket>/litestream/`; a Postgres backup script and NixOS systemd timer writing
dumps to `gcs://<backupBucket>/postgres/`; backup objects visible via `gsutil ls`; and restore
scripts that recover into a scratch target and diff the result against the source.

Sequence of edits. First, author `cluster/examples/sqlite-litestream/` containing a Kubernetes
Deployment with two containers sharing a volume: the app container (any tiny image that writes
to a SQLite file at `/data/app.db`) and a `litestream` sidecar container running
`litestream replicate` against a mounted `litestream.yml`. The `litestream.yml` points the db
at the replica URL `gcs://<backupBucket>/litestream/app.db`. Litestream authenticates to GCS
via Application Default Credentials, which on this single-node cluster means the node's
(VM's) service account — the same identity EP-2 grants bucket write access. Second, author
`scripts/backup-postgres.sh`: it runs the IP-9 preflight, then `pg_dump` against the host
Postgres (data dir `/var/lib/nagare/postgres`), compresses, and `gsutil cp`s the dump to
`gs://<backupBucket>/postgres/<timestamp>.sql.gz`. Third, document a NixOS systemd timer (added
to EP-3's host files) that runs that script nightly. Fourth, author `scripts/restore-sqlite.sh`
and `scripts/restore-postgres.sh` that restore into scratch and diff.

Acceptance: after writing a known row to the SQLite app and to Postgres,
`gsutil ls gs://<backupBucket>/litestream/` and `gsutil ls gs://<backupBucket>/postgres/` show
objects; running each restore script reproduces the known row in a scratch target and the diff
is empty.

### Milestone 3 — Disaster-recovery runbook

Scope: write and test the full rebuild procedure and the backup inventory.

What will exist at the end: `docs/runbooks/disaster-recovery.md` with a numbered sequence,
each step a command plus an expected observation, following the spec's recovery flow; an
explicit inventory of what is backed up and where; the Grafana-dashboards-in-Git note; and a
tested (or documented partial) dry run captured in Outcomes & Retrospective.

Sequence of edits. Write the runbook so a novice can execute it top to bottom. The sequence
mirrors `docs/initial-spec.md`'s "Recovery should look like" and the MasterPlan's wave order:
`pulumi up` (EP-2) → build and register the NixOS image and boot the VM (EP-3 pipeline,
Integration Point 10) → `nixos-rebuild switch` for any day-2 host config (EP-3) →
cluster bootstrap (EP-4) → install observability (EP-5) → apply sops-decrypted secrets (this
plan, M1) → restore data (this plan, M2) → `nagarectl deploy` the apps (EP-6). Each step names
the exact command, the working directory, and what success looks like.

Acceptance: a reader who has only this repo and the backup bucket can follow the runbook and
end with the apps serving and the data present. The dry run (full or partial) is captured.


## Concrete Steps

All commands assume you are in the repo root `/Users/shinzui/Keikaku/bokuno/nagare` inside the
Nix dev shell (`nix develop`) unless a different working directory is given. Cluster commands
assume `KUBECONFIG` points at a local copy of `/etc/rancher/k3s/k3s.yaml` whose `server:` field
has been rewritten to the VM's Tailscale name or `publicIp` (Integration Point 7).

### M1.1 Generate the age key and record the recipient

```bash
# In the repo root. age-keygen creates a private identity and prints the public recipient.
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
# Print the public recipient (the only half safe to commit / put in .sops.yaml):
age-keygen -y ~/.config/sops/age/keys.txt
```

Expected output (your key will differ): the second command prints one line beginning with
`age1...`, for example:

```text
age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8j
```

Record that `age1...` recipient; it goes verbatim into `.sops.yaml`. The file
`~/.config/sops/age/keys.txt` is the *private* identity — never commit it. sops finds it
automatically via the `SOPS_AGE_KEY_FILE` environment variable or the default path
`~/.config/sops/age/keys.txt`. On the NixOS host, sops-nix reads its own copy via
`sops.age.keyFile` (see M1.6).

### M1.2 Write `.sops.yaml`

Create `.sops.yaml` at the repo root. Replace the `age:` value with the recipient you
recorded.

```yaml
# .sops.yaml — sops policy for the Nagare repository.
# creation_rules are matched top-to-bottom; the first whose path_regex matches a file
# decides how that file is encrypted when you run `sops -e`.
creation_rules:
  # Kubernetes Secret manifests committed to Git. Encrypt ONLY the data/stringData values
  # so keys and metadata stay readable in diffs.
  - path_regex: cluster/secrets/.*\.ya?ml$
    encrypted_regex: "^(data|stringData)$"
    age: >-
      age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8j
```

### M1.3 Create and encrypt the example Kubernetes Secret

Create `cluster/secrets/notes-db-url.yaml` in plaintext first. Using `stringData` (not `data`)
means the value is written as a normal string rather than base64, which is friendlier to read
before encryption.

```yaml
# cluster/secrets/notes-db-url.yaml (plaintext, BEFORE encryption)
apiVersion: v1
kind: Secret
metadata:
  name: notes-db-url
  namespace: personal
type: Opaque
stringData:
  DATABASE_URL: "postgres://notes:CHANGEME@127.0.0.1:5432/notes"
```

Encrypt it in place:

```bash
sops -e -i cluster/secrets/notes-db-url.yaml
```

Now inspect it; the keys are readable but `DATABASE_URL`'s value is ciphertext:

```bash
cat cluster/secrets/notes-db-url.yaml
```

Expected (abridged) — note `metadata`/`name`/`namespace` readable, value encrypted, and a
`sops:` metadata block appended:

```yaml
apiVersion: v1
kind: Secret
metadata:
    name: notes-db-url
    namespace: personal
type: Opaque
stringData:
    DATABASE_URL: ENC[AES256_GCM,data:....,iv:....,tag:....,type:str]
sops:
    age:
        - recipient: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8j
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            ...
            -----END AGE ENCRYPTED FILE-----
    encrypted_regex: ^(data|stringData)$
    ...
```

This encrypted file is safe to commit.

### M1.4 Prove decrypt-and-apply (the round trip)

Ensure the `personal` namespace exists (EP-4 creates it; create it here if testing in
isolation), then decrypt and apply:

```bash
kubectl create namespace personal --dry-run=client -o yaml | kubectl apply -f -
sops -d cluster/secrets/notes-db-url.yaml | kubectl apply -f -
kubectl get secret notes-db-url -n personal
```

Expected transcript:

```text
namespace/personal configured
secret/notes-db-url created
NAME           TYPE     DATA   AGE
notes-db-url   Opaque   1      3s
```

Re-running the `sops -d ... | kubectl apply -f -` line a second time prints
`secret/notes-db-url configured` (apply is idempotent — see Idempotence and Recovery).

### M1.5 Prove an app consumes it via `secretRef`

The `nagare.yaml` contract (EP-6) maps `secretRef: notes-db-url` to an environment variable
sourced from that Secret. To prove consumption without the full CLI, apply a minimal pod that
references the Secret the same way `nagarectl` would render it:

```yaml
# /tmp/secret-consumer.yaml — a throwaway pod to prove the Secret is consumable.
apiVersion: v1
kind: Pod
metadata:
  name: secret-consumer
  namespace: personal
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: busybox:1.36
      command: ["sh", "-c", "echo DATABASE_URL is set to: $DATABASE_URL; sleep 2"]
      env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: notes-db-url
              key: DATABASE_URL
```

```bash
kubectl apply -f /tmp/secret-consumer.yaml
kubectl wait --for=condition=Ready pod/secret-consumer -n personal --timeout=60s || true
kubectl logs secret-consumer -n personal
kubectl delete pod secret-consumer -n personal
```

Expected log line (the value comes from the decrypted Secret):

```text
DATABASE_URL is set to: postgres://notes:CHANGEME@127.0.0.1:5432/notes
```

This is the literal proof that an app's `secretRef` (Integration Point 6) consumes a
sops-managed Kubernetes Secret. When `nagarectl deploy` renders a Knative Service from a
`nagare.yaml` whose `env.DATABASE_URL.secretRef` is `notes-db-url`, it produces the same
`secretKeyRef` shape.

### M1.6 Extend sops-nix host secrets (documentation + Nix snippet)

EP-3 already configures sops-nix for the Tailscale key. Adding another host secret is additive.
The existing EP-3 host configuration sets the decryption key location and the default encrypted
file once:

```nix
# In EP-3's host module (e.g. nixos/hosts/nagare-01/security.nix). Already present from EP-3:
sops.defaultSopsFile = ../../secrets/nagare-01.sops.yaml;  # host-secrets file (sops-encrypted)
sops.age.keyFile = "/var/lib/sops-nix/age-key.txt";        # private age identity on the host
sops.secrets.tailscale-authkey = { };                      # existing secret from EP-3
```

To add a second host secret — for example a backup-encryption passphrase or an additional
service token — add another `sops.secrets.<name>` entry and put its encrypted value in the same
host secrets file:

```nix
# Extension added by EP-7: one more host secret beside the Tailscale key.
sops.secrets.backup-extra-token = {
  # Optional: restrict who can read the decrypted file under /run/secrets.
  owner = "root";
  mode = "0400";
};
```

At NixOS activation, sops-nix decrypts `backup-extra-token` into
`/run/secrets/backup-extra-token` (a root-only, memory-backed file). A systemd service that
needs it references `config.sops.secrets.backup-extra-token.path`. The host's age identity at
`/var/lib/sops-nix/age-key.txt` must correspond to a recipient listed when the host secrets
file was encrypted; reuse the same age recipient from M1.1 (or a dedicated host recipient) and
list it in the host secrets file's sops metadata. No new mechanism is introduced — this is the
same sops-nix already in EP-3 with one more named secret.

### M2.1 Author the Litestream-backed SQLite sample app

Create `cluster/examples/sqlite-litestream/litestream.yml`. Replace `<backupBucket>` with the
actual bucket from `pulumi stack output backupBucket`.

```yaml
# cluster/examples/sqlite-litestream/litestream.yml
# Litestream watches the SQLite db and ships its WAL to GCS continuously.
dbs:
  - path: /data/app.db
    replicas:
      # The gcs:// scheme is Litestream's Google Cloud Storage replica type.
      # Auth uses Application Default Credentials = the node/VM service account.
      - url: gcs://<backupBucket>/litestream/app.db
```

Create the Deployment `cluster/examples/sqlite-litestream/deployment.yaml`:

```yaml
# cluster/examples/sqlite-litestream/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sqlite-litestream
  namespace: personal
spec:
  replicas: 1
  selector:
    matchLabels: { app: sqlite-litestream }
  template:
    metadata:
      labels: { app: sqlite-litestream }
    spec:
      volumes:
        - name: data
          emptyDir: {}            # for the demo; a real app uses a PVC on the data disk
        - name: litestream-config
          configMap:
            name: sqlite-litestream-config
      containers:
        # App: writes a row to /data/app.db every few seconds so there is data to back up.
        - name: app
          image: keinos/sqlite3:latest
          command:
            - sh
            - -c
            - |
              sqlite3 /data/app.db "CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY, body TEXT);"
              while true; do
                sqlite3 /data/app.db "INSERT INTO notes(body) VALUES ('hello at '||datetime('now'));"
                sleep 10
              done
          volumeMounts:
            - { name: data, mountPath: /data }
        # Sidecar: Litestream replicates /data/app.db to GCS.
        - name: litestream
          image: litestream/litestream:0.3
          args: ["replicate", "-config", "/etc/litestream.yml"]
          volumeMounts:
            - { name: data, mountPath: /data }
            - { name: litestream-config, mountPath: /etc/litestream.yml, subPath: litestream.yml }
```

Create the ConfigMap that carries `litestream.yml` (so the sidecar can read it):

```bash
kubectl create configmap sqlite-litestream-config \
  --namespace personal \
  --from-file=litestream.yml=cluster/examples/sqlite-litestream/litestream.yml \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f cluster/examples/sqlite-litestream/deployment.yaml
```

Confirm the sidecar is replicating and objects appear in GCS:

```bash
kubectl logs deploy/sqlite-litestream -n personal -c litestream | tail -n 5
gsutil ls "gs://$(cd infra/pulumi && pulumi stack output backupBucket)/litestream/"
```

Expected: the Litestream log shows lines like `initialized db` and `write wal segment`, and
the `gsutil ls` lists generation/WAL objects under `litestream/app.db/`, for example:

```text
gs://nagare-backups-tan-nb-exp/litestream/app.db/generations/
```

### M2.2 Author `scripts/backup-postgres.sh`

Create `scripts/backup-postgres.sh`. It carries the verbatim IP-9 preflight and passes
`--project=tan-nb-exp`. It uses the VM service account via ADC (no key file).

```bash
#!/usr/bin/env bash
# scripts/backup-postgres.sh — dump the host Postgres and upload to the GCS backup bucket.
# Runs on the NixOS host (via systemd timer) or manually from the dev shell.
set -euo pipefail

# --- Integration Point 9 preflight: refuse to run outside tan-nb-exp ---
PROJECT=tan-nb-exp
ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
  exit 1
fi

# Bucket name is passed in (from `pulumi stack output backupBucket`) or via $BACKUP_BUCKET.
BUCKET="${BACKUP_BUCKET:?set BACKUP_BUCKET to the backupBucket stack output}"
DB="${PGDATABASE:-notes}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/var/lib/nagare/backups/postgres-${DB}-${STAMP}.sql.gz"

mkdir -p /var/lib/nagare/backups
# pg_dump writes the whole database; gzip compresses it. Adjust connection via PG* env vars.
pg_dump --no-owner --no-privileges "$DB" | gzip -9 > "$OUT"

# Upload via ADC (the VM's attached service account has roles/storage.objectAdmin on the bucket).
gsutil -o "GSUtil:parallel_composite_upload_threshold=150M" \
  cp "$OUT" "gs://${BUCKET}/postgres/$(basename "$OUT")"

echo "uploaded gs://${BUCKET}/postgres/$(basename "$OUT")"
```

Make it executable and confirm it is syntactically valid:

```bash
chmod +x scripts/backup-postgres.sh
bash -n scripts/backup-postgres.sh && echo "syntax OK"
```

Run it once (on the host, or from the dev shell with `BACKUP_BUCKET` set) and list the result:

```bash
BACKUP_BUCKET="$(cd infra/pulumi && pulumi stack output backupBucket)" \
  PGDATABASE=notes scripts/backup-postgres.sh
gsutil ls "gs://$(cd infra/pulumi && pulumi stack output backupBucket)/postgres/"
```

Expected:

```text
uploaded gs://nagare-backups-tan-nb-exp/postgres/postgres-notes-20260602T120000Z.sql.gz
gs://nagare-backups-tan-nb-exp/postgres/postgres-notes-20260602T120000Z.sql.gz
```

### M2.3 NixOS systemd timer for the Postgres dump (documentation + Nix snippet)

This runs the script nightly on the host. Add it to EP-3's host files (e.g.
`nixos/hosts/nagare-01/storage.nix` or a new `backups.nix` imported by `configuration.nix`).
The timer needs no key file because the VM's service account is used via ADC.

```nix
# Postgres backup: a systemd service + a daily timer. Added by EP-7.
systemd.services.nagare-backup-postgres = {
  description = "Dump host Postgres and upload to the GCS backup bucket";
  path = [ pkgs.postgresql pkgs.gzip pkgs.google-cloud-sdk pkgs.coreutils ];
  serviceConfig = {
    Type = "oneshot";
    # BACKUP_BUCKET is the Pulumi backupBucket value; inject it at build time or via an
    # EnvironmentFile written by the deploy. CLOUDSDK_CORE_PROJECT enforces project isolation.
    Environment = [
      "CLOUDSDK_CORE_PROJECT=tan-nb-exp"
      "BACKUP_BUCKET=REPLACE_WITH_backupBucket"
      "PGDATABASE=notes"
    ];
    ExecStart = "${../../scripts/backup-postgres.sh}";
    User = "postgres";   # has access to the local Postgres socket
  };
};

systemd.timers.nagare-backup-postgres = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "*-*-* 03:30:00";   # nightly at 03:30 UTC
    Persistent = true;              # run on next boot if a scheduled run was missed
  };
};
```

After `nixos-rebuild switch`, verify the timer is scheduled:

```bash
systemctl list-timers nagare-backup-postgres.timer
```

Expected: one line showing the next scheduled run time and the unit name.

### M2.4 Restore scripts (scratch-first)

Create `scripts/restore-sqlite.sh` — it pulls the latest Litestream replica into a *scratch*
file, never over a live db:

```bash
#!/usr/bin/env bash
# scripts/restore-sqlite.sh — restore a Litestream-backed SQLite db into a scratch file.
set -euo pipefail
PROJECT=tan-nb-exp
ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
  exit 1
fi
BUCKET="${BACKUP_BUCKET:?set BACKUP_BUCKET}"
SCRATCH="${1:-/tmp/restore-app.db}"   # scratch target; default is a temp file
# -if-replica-exists exits 0 with no error if there is no backup yet (safe for automation).
litestream restore -if-replica-exists -o "$SCRATCH" "gcs://${BUCKET}/litestream/app.db"
echo "restored into $SCRATCH; row count:"
sqlite3 "$SCRATCH" "SELECT count(*) FROM notes;"
```

Create `scripts/restore-postgres.sh` — it creates a *scratch* database and loads a chosen dump
into it, then prints a row count so you can compare to the source:

```bash
#!/usr/bin/env bash
# scripts/restore-postgres.sh — restore a pg_dump from GCS into a SCRATCH database.
set -euo pipefail
PROJECT=tan-nb-exp
ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
  exit 1
fi
BUCKET="${BACKUP_BUCKET:?set BACKUP_BUCKET}"
OBJECT="${1:?usage: restore-postgres.sh gs://BUCKET/postgres/<dump>.sql.gz}"
SCRATCH_DB="${SCRATCH_DB:-notes_restore_scratch}"
# Pull the dump locally.
TMP="$(mktemp --suffix=.sql.gz)"
gsutil cp "$OBJECT" "$TMP"
# Create a fresh scratch database (drop first so the script is repeatable).
dropdb --if-exists "$SCRATCH_DB"
createdb "$SCRATCH_DB"
gunzip -c "$TMP" | psql "$SCRATCH_DB"
echo "restored into scratch db '$SCRATCH_DB'; row count of notes:"
psql -At "$SCRATCH_DB" -c "SELECT count(*) FROM notes;"
rm -f "$TMP"
```

```bash
chmod +x scripts/restore-sqlite.sh scripts/restore-postgres.sh
bash -n scripts/restore-sqlite.sh scripts/restore-postgres.sh && echo "syntax OK"
```

Run and verify (the row counts should match what the source had):

```bash
BACKUP_BUCKET="$(cd infra/pulumi && pulumi stack output backupBucket)" \
  scripts/restore-sqlite.sh /tmp/restore-app.db
```

Expected:

```text
restored into /tmp/restore-app.db; row count:
42
```

### M3.1 Grafana dashboards-in-Git note

Create `cluster/observability/grafana/dashboards/README.md`:

```text
# Grafana dashboards are source-controlled

Every dashboard Nagara cares about lives here as a JSON file and is committed to Git, so it
survives a full rebuild (see docs/runbooks/disaster-recovery.md). Grafana is provisioned to
load these from disk (configured in EP-5, docs/plans/5-victoria-observability-stack-and-grafana.md).

These dashboards, the datasource definitions under ../datasources/, and the Helm values under
cluster/observability/ are the complete, restorable definition of the observability UI. The
Victoria time-series DATA (metrics/logs/traces) is treated as non-critical and is NOT backed
up: it is re-derived from live workloads after a rebuild.
```

### M3.2 The disaster-recovery runbook

Create `docs/runbooks/disaster-recovery.md`. Its full intended content is specified in the
Validation section below (the runbook itself is the deliverable); author it so each step is a
command plus an expected observation, in the order: Pulumi → image/boot → host switch →
cluster bootstrap → observability → secrets → data restore → deploy apps.


## Validation and Acceptance

Acceptance is phrased as behavior a human can verify. The three milestones each have a
concrete, observable proof.

Milestone 1 is accepted when this transcript is reproduced (the Secret round-trips from
encrypted Git file to a live cluster Secret to a running pod's environment):

```text
$ sops -d cluster/secrets/notes-db-url.yaml | kubectl apply -f -
secret/notes-db-url created
$ kubectl get secret notes-db-url -n personal
NAME           TYPE     DATA   AGE
notes-db-url   Opaque   1      2s
$ kubectl logs secret-consumer -n personal
DATABASE_URL is set to: postgres://notes:CHANGEME@127.0.0.1:5432/notes
```

Milestone 2 is accepted when backup objects exist in the bucket and a restore reproduces the
data:

```text
$ gsutil ls gs://nagare-backups-tan-nb-exp/litestream/
gs://nagare-backups-tan-nb-exp/litestream/app.db/
$ gsutil ls gs://nagare-backups-tan-nb-exp/postgres/
gs://nagare-backups-tan-nb-exp/postgres/postgres-notes-20260602T120000Z.sql.gz
$ BACKUP_BUCKET=nagare-backups-tan-nb-exp scripts/restore-postgres.sh \
    gs://nagare-backups-tan-nb-exp/postgres/postgres-notes-20260602T120000Z.sql.gz
restored into scratch db 'notes_restore_scratch'; row count of notes:
17
```

The number of rows restored into the scratch database must equal the number of rows in the
source database at dump time (compare with `psql -At notes -c "SELECT count(*) FROM notes;"`).

Milestone 3 is accepted when `docs/runbooks/disaster-recovery.md` exists and a novice can
follow it to a working system. The runbook must contain at least this sequence, each step a
command + expected observation (this is the canonical content the implementer writes into the
runbook):

```text
1. Provision cloud resources (EP-2):
   $ cd infra/pulumi && pulumi up
   Observe: "Resources: + N created"; `pulumi stack output backupBucket` prints the bucket.

2. Build & register the NixOS image, then boot the VM (EP-3, Integration Point 10):
   $ scripts/setup-nix-builder.sh         # provision the x86_64-linux remote builder
   $ scripts/upload-images.sh             # build packages.x86_64-linux.nagare-image, upload,
                                          # register as a GCE image, write nagareImageSelfLink
   $ cd infra/pulumi && pulumi up         # instance boots from the registered image
   Observe: `pulumi stack output sshCommand` connects; the VM is RUNNING.

3. Apply any day-2 host config (EP-3):
   $ nixos-rebuild switch --flake .#nagare-01 --target-host nagare-01 --sudo
   Observe: activation succeeds; `systemctl status k3s` is active.

4. Reach the cluster (Integration Point 7):
   $ scp nagare-01:/etc/rancher/k3s/k3s.yaml /tmp/kubeconfig   # rewrite server: to the IP/Tailscale name
   $ export KUBECONFIG=/tmp/kubeconfig
   $ kubectl get nodes
   Observe: one node, STATUS Ready.

5. Bootstrap the cluster platform (EP-4):
   $ just cluster-bootstrap
   Observe: knative-serving, kourier-system, cert-manager pods Running; sample ksvc answers HTTPS.

6. Install observability (EP-5):
   $ just observability
   Observe: Grafana reachable; dashboards (from cluster/observability/grafana/dashboards/) load.

7. Restore secrets (this plan, M1):
   $ kubectl create namespace personal --dry-run=client -o yaml | kubectl apply -f -
   $ for f in cluster/secrets/*.yaml; do sops -d "$f" | kubectl apply -f -; done
   Observe: each prints "secret/<name> created".

8. Restore data (this plan, M2):
   $ BACKUP_BUCKET=$(cd infra/pulumi && pulumi stack output backupBucket) \
       scripts/restore-postgres.sh gs://.../postgres/<latest>.sql.gz
   # then promote the scratch db, or restore SQLite via Litestream into the app's volume:
   $ litestream restore -if-replica-exists -o /var/lib/nagare/sqlite/app.db \
       gcs://$BACKUP_BUCKET/litestream/app.db
   Observe: row counts match the source; the app sees its data.

9. Redeploy the apps (EP-6):
   $ nagarectl deploy            # run in each app repo containing a nagare.yaml
   Observe: the tool prints a live HTTPS URL; `curl` returns the app's response.
```

The runbook must also include the **backup inventory** — what is backed up, where it lives, and
how it is restored:

```text
NixOS config .............. Git (this repo, nixos/)               -> git clone
Pulumi infra (TypeScript) . Git (this repo, infra/pulumi/src/)    -> git clone
Pulumi state .............. infra/pulumi/.pulumi-state (in-repo,
                            committed/synced)                      -> restored with the repo
Kubernetes manifests ...... Git (this repo, cluster/)             -> git clone
Secrets ................... sops-encrypted in Git (.sops.yaml,
                            cluster/secrets/, host secrets file)   -> sops -d | kubectl apply
SQLite app data ........... Litestream replica in
                            gcs://<backupBucket>/litestream/       -> litestream restore (scratch)
Postgres data ............. pg_dump in
                            gcs://<backupBucket>/postgres/         -> restore-postgres.sh (scratch)
Grafana dashboards ........ Git (cluster/observability/grafana/
                            dashboards/)                           -> provisioned by EP-5
Victoria metrics/logs/traces  NOT backed up (non-critical;
                            re-derived from live workloads)        -> nothing to restore
The age PRIVATE key ....... NOT in Git; kept in a password
                            manager / offline. Without it, nothing
                            above decrypts.                        -> restore from your vault
```

That last line is critical and must be stated plainly in the runbook: the age private key is
the one thing that is *not* in Git and *not* in the bucket. Losing it means the encrypted
secrets cannot be decrypted. It must be stored in a separate, durable place (a password manager
or offline copy) and is the true root of the recovery's trust.


## Idempotence and Recovery

Every step in this plan is designed to be safely repeatable.

- **sops encrypt/decrypt** are repeatable: `sops -d` never modifies the file, and re-running
  `sops -e -i` on an already-encrypted file re-encrypts cleanly (or is a no-op for unchanged
  values). To change a value, run `sops cluster/secrets/notes-db-url.yaml` (opens an editor with
  the value decrypted, re-encrypts on save).
- **`kubectl apply`** is declarative and idempotent: applying the same decrypted Secret twice
  yields `created` the first time and `configured` (or `unchanged`) afterwards; it never
  duplicates the object.
- **Backups are append-only and repeatable.** Litestream continuously appends WAL segments;
  re-running the SQLite app does not corrupt prior backups. `scripts/backup-postgres.sh` names
  each dump with a UTC timestamp, so repeated runs add new objects rather than overwriting; old
  dumps remain for point-in-time choice. (A lifecycle rule on the bucket can later expire old
  dumps; that is a future bucket-policy decision in EP-2, not required for v1.)
- **Restores write to scratch first.** `scripts/restore-sqlite.sh` writes to `/tmp/restore-app.db`
  (or an explicit scratch path) and `scripts/restore-postgres.sh` loads into a *scratch*
  database (`notes_restore_scratch`), dropping it first so the script can be re-run. Neither
  touches a live database. Only after you compare row counts and are satisfied do you *promote*
  the scratch result (rename the scratch db, or copy the scratch SQLite file into the app's
  volume). This makes a botched restore harmless.
- **Scripts refuse to run against the wrong project.** The IP-9 preflight aborts before any
  `gcloud`/`gsutil` call if the active project is not `tan-nb-exp`, so a misconfigured shell
  cannot accidentally read or write another project's storage.
- **The systemd timer is `Persistent`**, so a missed nightly run (VM was off) executes on next
  boot rather than being silently skipped.
- **If a step fails halfway**: for the image/boot step, re-running `scripts/upload-images.sh` and
  `pulumi up` is safe (Pulumi reconciles to the desired state). For a partial restore, simply
  drop the scratch target and re-run the restore script. For secrets, re-apply is idempotent.


## Interfaces and Dependencies

This plan consumes and produces the following interfaces. Full module/file paths are given so a
novice can locate every piece.

Consumed from EP-2 (`docs/plans/2-pulumi-gcp-infrastructure.md`), via Integration Points 1 and 2:

- Stack output **`backupBucket`** — the GCS bucket name. Read with `pulumi stack output
  backupBucket` from `infra/pulumi/`. Used as the destination for Litestream (`gcs://<bucket>/litestream/`)
  and Postgres dumps (`gs://<bucket>/postgres/`).
- Stack output **`serviceAccountEmail`** — the VM's attached service account. Not referenced by
  name in scripts (ADC resolves it implicitly), but it is the identity that authorizes all
  backup writes.
- IAM grant **`roles/storage.objectAdmin` on `backupBucket`** for that service account. This is
  what makes on-host `gsutil cp` and in-cluster Litestream succeed without key files. If backups
  fail with `403`, the missing piece is this grant in EP-2.

Consumed from EP-3 (`docs/plans/3-nixos-host-nagare-01-with-k3s.md`), via Integration Point 3
and 7:

- Data-disk mount **`/var/lib/nagare`** with subdirectories `/sqlite`, `/postgres`, `/backups`.
  `scripts/backup-postgres.sh` stages dumps in `/var/lib/nagare/backups`; SQLite restores land in
  `/var/lib/nagare/sqlite`.
- The existing **sops-nix** configuration (`sops.defaultSopsFile`, `sops.age.keyFile`,
  `sops.secrets.tailscale-authkey`). This plan extends it with `sops.secrets.backup-extra-token`
  and the Postgres backup systemd units. The host age identity lives at
  `/var/lib/sops-nix/age-key.txt`.
- Kubeconfig at `/etc/rancher/k3s/k3s.yaml` (mode 0644), copied locally for `kubectl`.

Consumed from EP-4 (`docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md`):

- The `personal` namespace (Integration Point 5) where the example Secret, the SQLite sample,
  and apps live.

Consumed from EP-5 (`docs/plans/5-victoria-observability-stack-and-grafana.md`):

- The Grafana dashboards directory `cluster/observability/grafana/dashboards/`, into which this
  plan adds a `README.md` affirming dashboards are Git-tracked and restorable.

Consumed from EP-6 (`docs/plans/6-nagarectl-deploy-cli-in-haskell.md`):

- The `nagare.yaml` `secretRef` contract (Integration Point 6). This plan's example Secret
  `notes-db-url` is exactly the kind of value an app references via
  `env.DATABASE_URL.secretRef: notes-db-url`, which `nagarectl` renders into a `secretKeyRef`.

Tools and their schemas (define the shapes that must exist at the end of each milestone):

- **`.sops.yaml`** (repo root). Schema: a top-level `creation_rules` list; each rule has
  `path_regex` (a regex matched against the file path), `age` (one or more `age1...` recipient
  public keys), and optionally `encrypted_regex` (which top-level keys to encrypt). This plan's
  rule targets `cluster/secrets/.*\.ya?ml$` with `encrypted_regex: ^(data|stringData)$`.
- **`sops`** CLI. `sops -e -i <file>` encrypts in place; `sops -d <file>` prints plaintext to
  stdout; `sops <file>` opens an editor on the decrypted content and re-encrypts on save. The
  private age identity is found via `SOPS_AGE_KEY_FILE` or `~/.config/sops/age/keys.txt`.
- **sops-nix** NixOS module. Options used: `sops.defaultSopsFile` (path to the host's encrypted
  secrets file), `sops.age.keyFile` (path to the host's private age identity), and
  `sops.secrets.<name>` (declares a secret; its decrypted plaintext appears at
  `config.sops.secrets.<name>.path`, by default `/run/secrets/<name>`).
- **`litestream.yml`** schema. A top-level `dbs` list; each entry has `path` (the SQLite file)
  and `replicas` (a list); each replica is `{ url: gcs://<bucket>/<path> }` (or the expanded
  `type: gcs`, `bucket:`, `path:` form). Commands used: `litestream replicate -config <file>`
  (the long-running sidecar) and `litestream restore -if-replica-exists -o <out> <url>` (the
  scratch-first restore; `-if-replica-exists` exits 0 when no backup exists yet).
- **`scripts/backup-postgres.sh`**, **`scripts/restore-postgres.sh`**, **`scripts/restore-sqlite.sh`**.
  Each begins with the verbatim IP-9 preflight, requires `BACKUP_BUCKET`, and passes
  `--project=tan-nb-exp` to gcloud where applicable. Backup names dumps by UTC timestamp;
  restores target scratch only.
- The GCS bucket layout this plan establishes: `gs://<backupBucket>/litestream/app.db/...`
  (Litestream generations/WAL) and `gs://<backupBucket>/postgres/<db>-<timestamp>.sql.gz`
  (logical dumps).


---

Revision note (2026-06-02): Initial authoring of EP-7 from the skeleton. The skeleton body was
replaced with a full, self-contained plan while preserving the frontmatter (lines 1–9) and the
required section headings in order. Content was derived from the MasterPlan's Integration Points
1, 2, 3, 6, 9, and 10; the `docs/initial-spec.md` Secrets/Data Strategy/Backup Strategy sections
and the "Spec Accuracy Corrections" appendix; and the reference repo's GCP-isolation preflight
pattern. The two-mechanism secrets decision (sops-nix for host, sops+age for Kubernetes),
manual decrypt-and-apply for v1, value-only encryption, ADC-based on-host backups, Litestream +
pg_dump tiering, and scratch-first restores were recorded in the Decision Log. Three milestones
were defined, each independently verifiable.
