---
id: 2
slug: pulumi-gcp-infrastructure
title: "Pulumi GCP infrastructure"
kind: exec-plan
created_at: 2026-06-02T15:39:48Z
intention: "intention_01kt4f3svnekz80g94f2k4tthq"
master_plan: "docs/masterplans/1-bootstrap-nagare-personal-paas.md"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T13:31:15Z
      mode: "update"
      note: "Reconcile deferred validation against tan-ng-labs and later plan evidence"
---

# Pulumi GCP infrastructure

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [2-pulumi-gcp-infrastructure.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/2-pulumi-gcp-infrastructure.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare (流れ, "flow") is a single-node personal Platform-as-a-Service (PaaS) that runs on one
Google Cloud Platform (GCP) Compute Engine virtual machine. "Personal PaaS" means: a tiny private
cloud where the owner can deploy small web projects and get back a working HTTPS URL, with metrics,
logs, and traces, and where the whole machine can be rebuilt from a Git repository plus a few
encrypted secrets. This ExecPlan builds the **cloud perimeter** for Nagare: every Google Cloud
resource that has to exist *before* the machine can boot and serve traffic. Nothing in this plan
touches the operating system, the Kubernetes cluster, or any application; those belong to later
plans (`docs/plans/3-...` through `docs/plans/7-...`). Here we use **Pulumi** — an
infrastructure-as-code tool where you describe cloud resources in a normal programming language
(here TypeScript) and a `pulumi up` command makes the real cloud match your description — to
provision a static public IP address, a private network with firewall rules, a persistent data
disk, a service account with the right permissions, a Cloud DNS zone with a wildcard record, a
container image registry, two storage buckets, and finally the virtual machine itself.

After this plan is complete, a reader who has never seen this repository can, from a clean
checkout, run two commands (`pulumi up` then — after a sibling plan builds the operating-system
image — `pulumi up` again) and end up with: a GCP virtual machine named `nagare-01` that is
RUNNING, reachable at a fixed public IP, with a data disk and a service account attached; a DNS
name `*.apps.example.com` (or whatever real domain the owner configures) that resolves to that IP;
a Docker image registry at `us-west1-docker.pkg.dev/tan-nb-exp/nagare`; and a Google Cloud Storage
(GCS) bucket ready to receive backups. They can prove it by running `pulumi stack output`, by
running `gcloud compute instances describe nagare-01`, and by resolving the wildcard DNS record.
The exact set of values this plan publishes (the "stack outputs") is the contract that three later
plans read from, so getting their names exactly right is the single most important obligation of
this plan.

The reason this matters: it makes the cloud half of Nagare reproducible and disposable. The
machine is meant to be thrown away and recreated. By owning every cloud resource declaratively in
Pulumi, a total rebuild is just `pulumi up`, and the identifiers other plans depend on
(`publicIp`, `instanceName`, and so on) never drift because they all come from one place.

## Progress

This section is the live checklist. Every stopping point must be reflected here. The work is
organized into three milestones (M1 scaffolding + preview; M2 everything except the VM; M3 the VM
after the operating-system image exists). Check items off as they are demonstrably done.

- [x] M1: `infra/pulumi/` project scaffolding created (`Pulumi.yaml`, `Pulumi.dev.yaml`,
  `package.json`, `tsconfig.json`, `index.ts`, `src/outputs.ts`, and the component files under
  `src/components/`). (2026-06-02)
- [x] M1: in-repo Pulumi state backend initialized — `cd infra/pulumi && pulumi login
  file://./.pulumi-state` (corrected from the plan's repo-root-relative path; see Decision Log) and the
  `dev` stack created; `PULUMI_HOME` and `PULUMI_CONFIG_PASSPHRASE` from `.envrc` honored via `direnv
  exec`. (2026-06-02)
- [x] M1: config keys set (`gcp:project=tan-nb-exp`, `gcp:region=us-west1`, `gcp:zone=us-west1-a`,
  `baseDomain=apps.example.com`, `imageBucket=tan-nb-exp-nagare-images`). (2026-06-02)
- [x] M1: `npm install` installed `@pulumi/pulumi` + `@pulumi/gcp` (346 packages, 0 vulnerabilities);
  `npm run build` (`tsc --noEmit`) type-checks cleanly, exit 0. (2026-06-02)
- [x] M1: `pulumi preview` runs and plans 19 perimeter resources, with the VM **omitted** because
  `nagareImageSelfLink` config is unset (no `gcp:compute:Instance` in the plan; graceful handling
  proven). All nine stack-output names present. (2026-06-02)
- [x] M2: `pulumi up` creates the network + subnet, firewall rules, static IP, data disk, service
  account + IAM members, DNS managed zone + wildcard record, Artifact Registry, and both buckets.
  (2026-06-02 — required enabling `artifactregistry`/`iam` APIs first; see Surprises.)
- [x] M2: `pulumi stack output` prints all nine output names; `publicIp` is a real IPv4 address
  (`34.145.74.203`). (2026-06-02)
- [x] M2: the wildcard DNS record resolves to `publicIp` — `gcloud dns record-sets list` shows
  `*.apps.example.com. A 34.145.74.203`; Artifact Registry `nagare` (DOCKER) and both buckets exist.
  (2026-06-02)
- [x] M3: after EP-3 set `nagareImageSelfLink`, a second `pulumi up` created `nagare-01`
  from the NixOS image. EP-3 recorded the original `tan-nb-exp` creation on 2026-06-02;
  the independent `tan-ng-labs` rollout repeated the same two-pass contract on 2026-09-13
  (`mori://tan/tan-infrastructure/docs/nagare-labs-domain-delegation`). (Reconciled 2026-09-15.)
- [x] M3: live read-only verification against `tan-ng-labs` showed `nagare-01` RUNNING with
  service account `nagare-node@tan-ng-labs.iam.gserviceaccount.com`, the boot and
  `nagare-data` disks attached, and `pulumi stack output sshCommand` returned the usable
  IAP command `gcloud compute ssh nagare-01 --project=tan-ng-labs --zone=us-west1-a
  --tunnel-through-iap`. (2026-09-15)

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during implementation,
with concise evidence (command output is ideal).

- Discovery: the in-repo Pulumi file backend must be logged into **from within `infra/pulumi`** with
  the relative URL `file://./.pulumi-state`, not from the repo root with
  `file://./infra/pulumi/.pulumi-state` + `pulumi --cwd infra/pulumi` as the plan's Step 9 wrote.
  Evidence — running `pulumi login file://./infra/pulumi/.pulumi-state` then `pulumi --cwd infra/pulumi
  stack init dev` failed with: `error: unable to open bucket
  file:///Users/.../infra/pulumi/infra/pulumi/.pulumi-state ... no such file or directory`. A relative
  `file://` backend URL is re-resolved against the **project** directory (the `--cwd`), so the
  `infra/pulumi` segment is applied twice. Resolution: adopt the reference repo's exact pattern — `cd
  infra/pulumi` and `pulumi login file://./.pulumi-state`, then run all `pulumi` commands from inside
  `infra/pulumi` (which is also what the EP-1 `justfile` recipes do: `cd infra/pulumi && pulumi …`).
  The state lives at `infra/pulumi/.pulumi-state` either way. The `.pulumi-state` directory must exist
  before `pulumi login` (login does not create it): `mkdir -p infra/pulumi/.pulumi-state`.

- Discovery: the gcp provider resolved to `gcp-8.41.1` (newer than the `^8.10.0` floor in
  `package.json`), and `pulumi preview` planned **19** resources, not the ~18 the plan estimated. The
  extra is provider-version noise (component resources are counted). The load-bearing acceptance —
  **no `gcp:compute:Instance` in the plan** while `nagareImageSelfLink` is unset — holds. All nine
  stack-output names appear; `publicIp` shows `[unknown]` at preview time (it is created during `up`).

- Discovery: the first `pulumi up` partially failed because two required GCP service APIs were **not
  enabled** on the shared `tan-nb-exp` project: `artifactregistry.googleapis.com` (Artifact Registry
  repo) and `iam.googleapis.com` (service-account creation). Result was `10 created, 2 errored` with
  `Error 403 ... SERVICE_DISABLED`. `compute`, `dns`, and `storage` were already enabled. Resolution:
  `gcloud services enable artifactregistry.googleapis.com iam.googleapis.com --project=tan-nb-exp`,
  wait ~15s for propagation, then re-run `pulumi up` (idempotent — it created the remaining 9
  resources, 10 unchanged). Lesson for downstream plans: EP-2 does not declare the API enablement as
  Pulumi resources, so a clean-project rebuild must enable these APIs first. Consider adding
  `gcp.projects.Service` resources in a future revision; for now this is a documented manual prereq.
  Final `publicIp` = `34.145.74.203`; wildcard `*.apps.example.com.` A record matches it.

- Audit discovery (2026-09-15): M3 had remained unchecked even though EP-3 already recorded
  the original VM creation and access. The later labs rollout provided a clean second-target
  repetition: image `nagare-image-f9p6raz75qjf` is READY, the stack is 31 resources unchanged,
  and the live instance, disks, service account, public IP, and `sshCommand` output all agree.

## Decision Log

Record every decision made while working on the plan. Each entry explains *why*, so a future
reader can reconstruct the reasoning from this file alone.

- Decision: provision a dedicated custom VPC network with a single subnet in `us-west1` rather than
  using GCP's auto-created default network.
  Rationale: The sibling reference repository `/Users/shinzui/Keikaku/bokuno/load-testing-infra`
  (the canonical Pulumi pattern for this workstation) creates a custom network with
  `autoCreateSubnetworks: false` plus an explicit subnet, which keeps the firewall surface small and
  the whole perimeter self-contained and reproducible. A default network would couple us to
  whatever rules already exist in the GCP project `tan-nb-exp`. Mirroring the reference repo reduces
  risk and keeps the two repos consistent.
  Date: 2026-06-02

- Decision: SSH (tcp:22) is allowed only from the GCP Identity-Aware Proxy (IAP) range
  `35.235.240.0/20`, not from the public internet.
  Rationale: The reference repo restricts SSH to the IAP range so that the only way to reach port 22
  is through an authenticated `gcloud compute ssh --tunnel-through-iap` tunnel. Nagare reuses this
  exact pattern. Day-to-day cluster access happens over Tailscale (configured by EP-3), so the VM
  never needs a publicly reachable SSH port.
  Date: 2026-06-02

- Decision: the Compute Engine instance resource is declared only when the Pulumi config key
  `nagareImageSelfLink` is present; otherwise it is skipped.
  Rationale: The VM cannot exist until EP-3 has built the NixOS GCE image on a remote x86_64-linux
  Nix builder and registered it (writing its self-link into `nagareImageSelfLink`). Declaring the
  instance unconditionally would make `pulumi preview`/`pulumi up` fail before the image exists.
  Making the instance conditional lets a reader stand up the entire perimeter first (M2) and add the
  VM later (M3) without editing code — mirroring how the reference repo treats image self-links as
  required config that the upload script fills in.
  Date: 2026-06-02

- Decision: grant IAM roles with non-authoritative `*IAMMember` resources, never with authoritative
  `*IAMBinding`/`*IAMPolicy` resources.
  Rationale: The spec's "Spec Accuracy Corrections" appendix states there is no single Pulumi "IAM
  bindings" resource and that the non-authoritative `gcp.projects.IAMMember` /
  `gcp.storage.BucketIAMMember` variants must be used so Pulumi adds exactly one member to a role
  without clobbering any existing members on the shared `tan-nb-exp` project.
  Date: 2026-06-02

- Decision: use `e2-standard-2` (2 vCPU / 8 GB) as the instance machine type.
  Rationale: The spec appendix corrects the machine-type sizing: `e2-standard-2` is 2 vCPU / 8 GB and
  is the recommended starting point. k3s + Knative + Kourier + cert-manager + the Victoria stack get
  tight on 4 GB, so the 8 GB shape is chosen over the burstable `e2-medium`.
  Date: 2026-06-02

- Decision: the image-staging bucket (`imageBucket`) is referenced from Pulumi config and created by
  Pulumi as a managed `gcp.storage.Bucket`, but EP-3's `scripts/upload-images.sh` may also create it
  with `gsutil mb` if missing.
  Rationale: IP-10 says EP-2 "creates the image-staging GCS bucket" and EP-3's upload script reads
  the bucket name from `pulumi config get imageBucket`. To keep first-boot bootstrapping unambiguous
  we make the bucket a Pulumi-managed resource (so `pulumi up` creates it) and also export/record the
  name in config so the upload script can find it. This differs slightly from the reference repo,
  which leaves the image bucket un-managed; the difference is recorded here intentionally.
  Date: 2026-06-02

- Decision: the apps base domain is the placeholder `apps.example.com`, supplied via Pulumi config
  key `baseDomain` (default `apps.example.com`) and surfaced as the `baseDomain` stack output.
  Rationale: MasterPlan Integration Point 4 and its Decision Log pin a single placeholder domain and
  a single source of truth (the Pulumi output) to prevent drift across plans. The real domain is set
  later with `pulumi config set baseDomain <real-domain>`.
  Date: 2026-06-02

- Decision: operate Pulumi from **inside `infra/pulumi`** and log into the file backend with
  `file://./.pulumi-state` (matching the reference repo), rather than the plan's Step 9 wording of
  logging in from the repo root with `file://./infra/pulumi/.pulumi-state` and using `pulumi --cwd
  infra/pulumi`.
  Rationale: A relative `file://` backend URL is re-resolved against the project directory, so the
  repo-root-relative path doubles the `infra/pulumi` segment and `pulumi` fails to open the bucket (see
  Surprises & Discoveries for the exact error). Running from `infra/pulumi` with a project-relative
  backend URL is the canonical, portable pattern the EP-1 `justfile` recipes already assume
  (`cd infra/pulumi && pulumi …`). State still lives at `infra/pulumi/.pulumi-state`.
  Date: 2026-06-02

- Decision: accept the independently provisioned labs context as current M3 acceptance evidence
  in addition to the original `tan-nb-exp` evidence already recorded by EP-3.
  Rationale: M3 validates the reusable conditional-image and instance-output contract, not a
  property unique to one project id. The labs rollout used released Nagare v0.2.2 from a fresh
  project and reproduced the same image registration, second Pulumi apply, instance attachments,
  and IAP SSH output without relying on this checkout's old local state.
  Date: 2026-09-15

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare the
result against the Purpose: can a reader run `pulumi up` and get a reproducible cloud perimeter, and
do all nine stack outputs exist with correct values?

Status: **M1, M2, and M3 complete.** The documented two-pass `pulumi up` flow from a clean checkout
reproduces the entire cloud perimeter and, after the image self-link is set, the VM; all nine Integration-Point-1 stack outputs
exist with correct values (`publicIp` = `34.145.74.203`, `artifactRegistry` =
`us-west1-docker.pkg.dev/tan-nb-exp/nagare`, `backupBucket` = `tan-nb-exp-nagare-backups`, etc.). The
wildcard `*.apps.example.com.` A record resolves to the static IP, the Artifact Registry DOCKER repo
and both GCS buckets exist, and the conditional-instance logic correctly omits the VM while
`nagareImageSelfLink` is unset. The output contract — the single most important deliverable — is
verified intact.

Two deviations from the written plan, both recorded above: (1) the in-repo file backend must be logged
into from within `infra/pulumi` with `file://./.pulumi-state` (the plan's repo-root-relative path
doubled the segment); (2) `artifactregistry.googleapis.com` and `iam.googleapis.com` had to be enabled
on `tan-nb-exp` before `pulumi up` could create the registry and service account — the plan does not
model API enablement as Pulumi resources, so this is a manual prereq for a clean-project rebuild.

M3 first completed on `tan-nb-exp` as recorded in EP-3, then repeated from a fresh project in
`tan-ng-labs`. The 2026-09-15 audit observed the labs stack at 31 unchanged resources and verified
the live instance's disks, service account, static IP, and IAP `sshCommand`. No implementation or
acceptance work remains in this plan.

