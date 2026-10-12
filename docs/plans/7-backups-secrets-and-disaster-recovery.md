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

Full plan before trimming: [7-backups-secrets-and-disaster-recovery.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/7-backups-secrets-and-disaster-recovery.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

