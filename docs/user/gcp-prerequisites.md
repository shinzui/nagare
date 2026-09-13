---
type: Guide
title: "GCP prerequisites"
description: "Prepare authentication, billing, IAM, service APIs, and DNS before provisioning Nagare on Google Cloud."
docId: DOC-15
tags: [gcp, prerequisites, iam, dns, onboarding]
generated:
  by: human:nadeem
  at: 2026-08-23T20:57:05Z
---

# GCP prerequisites

> **Status:** ✅ Working

What you need on the Google Cloud Platform (GCP) side before nagare can touch your
project: an authenticated `gcloud`, the right Identity and Access Management (IAM)
roles, a project with billing, the service APIs turned on, and your domain delegated
to Cloud DNS. The guided command [`nagarectl init`](onboarding-bring-your-own-project.md)
checks most of these for you, but you must put them in place first.

Throughout, **`tan-nb-exp` / `us-west1` / `us-west1-a` / `apps.example.com` is the
worked default example**. Every one of those values is fully substitutable for your
own — replace `YOUR_PROJECT_ID`, your region, and your domain as you go.

---

## 1. Authenticate gcloud (and Application Default Credentials)

The pinned dev shell provides `gcloud` (run `direnv allow`, or `nix develop`, in the
repo — see [getting started](getting-started.md)). You need **two distinct logins**:

```bash
gcloud auth login                       # authenticates the gcloud CLI (interactive you)
gcloud auth application-default login    # writes Application Default Credentials (ADC) for Pulumi/tools
```

**Application Default Credentials (ADC)** are a separate credential that *programs and
libraries* — notably the Pulumi GCP provider — read to authenticate to GCP, as opposed
to the interactive `gcloud` CLI. Forgetting the second command is the single most common
"Pulumi can't authenticate" failure, because `gcloud auth login` alone does **not** write
ADC.

Confirm you have an active account:

```bash
gcloud auth list                        # shows the ACTIVE account
gcloud config get-value account
```

## 2. Create or select a project, and confirm billing

Either create a fresh project or pick an existing empty one. `tan-nb-exp` is the example
id; use your own:

```bash
gcloud projects create YOUR_PROJECT_ID   # or skip if it already exists
gcloud config set project YOUR_PROJECT_ID
```

A **billing account must be linked** to the project, or API enablement and resource
creation will fail. Link one in the Cloud Console billing page, or with
`gcloud billing projects link YOUR_PROJECT_ID --billing-account=<ACCOUNT_ID>`.

## 3. The operator IAM roles you need to provision

`nagarectl init` preflights for these roles and refuses to proceed without them (unless
you pass `--skip-preflight`). An **IAM role** is a named bundle of permissions granted to
your account *on* the project. Nagare's provisioning needs all six:

```text
roles/compute.admin                    — VPC, firewall, static IP, disks, the VM
roles/dns.admin                        — the Cloud DNS managed zone + records
roles/artifactregistry.admin           — the Docker image repository
roles/storage.admin                    — the image-staging and backup GCS buckets
roles/iam.securityAdmin                — the node service account and its bindings
roles/serviceusage.serviceUsageAdmin   — enabling the service APIs (next section)
```

A single `roles/owner` binding on your own project satisfies all of them (the `init`
preflight short-circuits to pass when you hold `roles/owner`). Grant a role like this:

```bash
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="user:you@example.com" --role="roles/compute.admin"
# …repeat per role, or grant roles/owner to yourself on your own project
```

> Note: the preflight reads *direct* user bindings. If your roles come via a Google
> group, the flat check may not see them — grant `roles/owner` or pass
> `--skip-preflight` in that case.

## 4. Enable the service APIs

A brand-new project has most APIs **off**, and they must be turned on once before any
resource using them can be created. This was a real bootstrap failure: nagare's first
bring-up found `artifactregistry` and `iam` disabled and `pulumi up` blocked on them.

Nagare codifies the API set two ways, both wired up by `nagarectl init`:

- **`scripts/enable-apis.sh`** — the tracked script `init` runs for you. It sources the
  guardrail, asserts the effective project agrees with the declared target (or
  gcloud's stored configuration when no target declares one), then enables the
  six APIs with an explicit `--project`.
- **`gcp.projects.Service` resources** in `infra/pulumi/index.ts` — so every later
  `pulumi up` keeps the APIs on.

The six APIs:

```text
compute.googleapis.com
dns.googleapis.com
storage.googleapis.com
artifactregistry.googleapis.com
iam.googleapis.com
servicenetworking.googleapis.com
```

If you are not yet running `nagarectl init`, enable them by hand:

```bash
gcloud services enable compute.googleapis.com dns.googleapis.com storage.googleapis.com \
  artifactregistry.googleapis.com iam.googleapis.com servicenetworking.googleapis.com \
  --project=YOUR_PROJECT_ID
```

## 5. Register and delegate a domain to Cloud DNS

Nagare serves apps under a wildcard `*.<baseDomain>` (the example base domain is
`apps.example.com`). You bring a domain you own. During provisioning Pulumi creates the
Cloud DNS **managed zone** and the wildcard A record; you then perform **DNS delegation**:
copy the four nameservers Cloud DNS assigns your zone into NS (nameserver) records at your
domain registrar, so the world's resolvers consult Cloud DNS for your domain.

Until delegation propagates, Let's Encrypt's DNS-01 challenge cannot issue the wildcard
certificate and real traffic will not resolve — so this is a prerequisite for working
HTTPS, even though the VM boots without it. The exact nameservers exist only after the
zone is created, so you read them *after* `just infra-up`:

```bash
pulumi -C infra/pulumi stack output dnsZoneName
gcloud dns managed-zones describe "$(pulumi -C infra/pulumi stack output dnsZoneName)"
```

The [onboarding runbook](onboarding-bring-your-own-project.md) places this step in the
correct order (after the zone exists, before HTTPS is expected to work).

## What keeps Nagare inside your project

If your organization also holds production projects, this is the part to read. Nagare
enforces project confinement at **every place it writes to the cloud**, not only when a
command starts, and every check fails closed — it refuses rather than guessing.

**The project comes only from the active context.** No Nagare command derives its target
from `gcloud config get-value project`. Your local `gcloud` can stay pointed at a
production project; Nagare will not use it. Where a command does consult `gcloud`'s
configured project — the cross-check that runs when no context declares one — it reads it
with `CLOUDSDK_CORE_PROJECT` stripped from the environment, because `gcloud` lets that
variable shadow its own configuration and the comparison would otherwise be a tautology.

**Bucket operations compare owning project numbers.** Cloud Storage bucket names are unique
across all of Google Cloud, so a bucket named `<your-project>-nagare-images` may already
exist in someone else's project. "The bucket exists" is therefore not evidence that it is
yours. Before creating, reconfiguring, granting IAM on, or uploading to a bucket, Nagare
reads the bucket's owning project number and your project's, and proceeds only when both
are present and equal. A number it cannot read — missing permission, missing tool, network
failure — counts as a mismatch:

```text
refusing: gs://acme-prod-nagare-images is owned by project number '111111111111', not the
target project 'acme-prod' (number '999999999999').
  GCS bucket names are global; set a unique nagare:imageBucket with 'pulumi --cwd
  infra/pulumi config set imageBucket <unique-name>'.
```

**`just infra-up` and `just infra-preview` refuse before Pulumi runs** when the selected
Pulumi stack's `gcp:project`, the ambient `CLOUDSDK_CORE_PROJECT`, or `gcloud`'s configured
project disagrees with your context. See
[Provisioning with Pulumi](provisioning-with-pulumi.md) for that preflight and what to do
when it stops you, and [Target contexts](contexts.md) for the
`nagarectl context guard` command behind it.

**Two mechanisms keep the APIs and resources project-scoped**, both wired up by
`nagarectl init`: `scripts/enable-apis.sh`, which asserts the target before enabling
anything, and the `gcp.projects.Service` resources in `infra/pulumi/index.ts`. Every
resource the Pulumi program creates is project-scoped — there are no organization, folder,
billing, shared-VPC or peering resources, no provider override, and no `import:` option
that could adopt something you already own.

**A local context is exempt, and calls no cloud tool at all.** A context with `mode=local`
points everything at loopback substitutes, so there is no project to protect; the guards
return immediately without invoking `gcloud`, after asserting that the local target really
is loopback.

---

## Choosing a VM shape

The default `e2-standard-2` machine has two virtual CPUs and is suitable for a
couple of small applications. If this cluster will also run Nagare's
observability stack, start at `e2-standard-4` (four virtual CPUs). On the
two-CPU shape, the observability components' CPU requests alone once left no
room to schedule workloads, and Kubernetes reported
`0/1 nodes are available: Insufficient cpu`; the evidence is recorded in
[`docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md`](../plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md).

The machine type can be raised later with an in-place stop/start resize. The
boot-disk type cannot be converted in place: changing it replaces the instance
and its boot disk. `nagarectl init` records both choices in the target context,
and `infra-up` refuses an instance-replacing plan unless you explicitly allow a
deliberate rebuild.

## Where to next

- **[Bring-your-own-project onboarding](onboarding-bring-your-own-project.md)** — the
  single ordered zero-to-running runbook that uses these prerequisites.
- [`CLAUDE.md`](../../CLAUDE.md) — the configurable project-isolation policy.
- [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) —
  the decision behind the confinement checks described above.
- [MasterPlan 12](../masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md) —
  the architectural decision behind bring-your-own-project.
