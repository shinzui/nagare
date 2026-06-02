---
id: 2
slug: pulumi-gcp-infrastructure
title: "Pulumi GCP infrastructure"
kind: exec-plan
created_at: 2026-06-02T15:39:48Z
intention: "intention_01kt4f3svnekz80g94f2k4tthq"
master_plan: "docs/masterplans/1-bootstrap-nagare-personal-paas.md"
---

# Pulumi GCP infrastructure

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


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
- [ ] M3 (blocked on EP-3): after EP-3 sets `nagareImageSelfLink` via `scripts/upload-images.sh`,
  a second `pulumi up` creates the `nagare-01` instance booting from the NixOS image.
- [ ] M3: `gcloud compute instances describe nagare-01` shows it RUNNING with the data disk and the
  service account attached; `pulumi stack output sshCommand` prints a usable command.


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare the
result against the Purpose: can a reader run `pulumi up` and get a reproducible cloud perimeter, and
do all nine stack outputs exist with correct values?

Status: **M1 and M2 complete; M3 deferred (blocked on EP-3).** A `pulumi up` from a clean checkout
reproduces the entire cloud perimeter except the VM, and all nine Integration-Point-1 stack outputs
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

Remaining: **M3** creates the `nagare-01` VM and is intentionally blocked until EP-3
(`docs/plans/3-nixos-host-nagare-01-with-k3s.md`) builds and registers the NixOS GCE image and sets
the `nagareImageSelfLink` config key. The perimeter is ready for EP-3 to upload its image into
`gs://tan-nb-exp-nagare-images`.


## Context and Orientation

This plan assumes you are a newcomer to this repository. Here is everything you need to know.

**The repository.** The working tree is at `/Users/shinzui/Keikaku/bokuno/nagare`. It is a Git
repository on branch `master`. The overarching design lives in two checked-in documents you should
skim once: `docs/initial-spec.md` (the original specification, whose "Spec Accuracy Corrections"
appendix at the very end overrides the prose above it) and
`docs/masterplans/1-bootstrap-nagare-personal-paas.md` (the MasterPlan, which coordinates seven
child plans and defines ten "Integration Points" — cross-plan contracts). This plan is child plan
EP-2. You do not need to read the other child plans to execute this one, but this plan references
them by path where a dependency exists.

**The toolchain.** Nagare reuses the conventions of a sibling repository on the same workstation,
`/Users/shinzui/Keikaku/bokuno/load-testing-infra` (referred to below as "the reference repo"). It
runs the same tool family (NixOS + GCP + Pulumi + Haskell). EP-1 (a separate plan) provides a Nix
development shell — entered with `nix develop` or automatically via `direnv` and a repo-root
`.envrc` — that puts `pulumi`, `node`, `tsc`, `gcloud`, `gsutil`, and `jq` on your PATH, pinned to
specific versions. If EP-1 is not yet done, you can still execute this plan provided you have a
recent Pulumi CLI, Node.js 20+, and the Google Cloud SDK (`gcloud`/`gsutil`) installed and
authenticated against GCP project `tan-nb-exp`. Everything in this plan runs from inside that shell.

**GCP project isolation (Integration Point 9 — non-negotiable).** Every cloud resource and every
`gcloud`/`gsutil`/`pulumi` invocation in this repository targets exactly one GCP project,
**`tan-nb-exp`**, in region **`us-west1`**, default zone **`us-west1-a`**. The repo-root `.envrc`
(created by EP-1; mirror the reference repo's `.envrc` if it is not present yet) exports:

```bash
export CLOUDSDK_CORE_PROJECT=tan-nb-exp
export CLOUDSDK_COMPUTE_REGION=us-west1
export CLOUDSDK_COMPUTE_ZONE=us-west1-a
export PULUMI_HOME="$PWD/infra/pulumi/.pulumi-home"
export PULUMI_CONFIG_PASSPHRASE=""
use flake
```

`PULUMI_HOME` points at an in-repo directory so Pulumi's credentials, plugins, and templates never
collide with any global `~/.pulumi` other projects on this workstation use.
`PULUMI_CONFIG_PASSPHRASE=""` is an intentionally empty passphrase: this stack uses Pulumi's
"passphrase" secrets provider (which encrypts secret config values with a passphrase) initialized
with an empty value, because the IAP-gated, single-VPC threat model does not justify per-stack
secret management. To tighten later, run `pulumi stack change-secrets-provider passphrase` with a
real value. The Pulumi **state** (the record of what resources exist) is kept inside the repo via a
file backend, configured per-stack with `pulumi login file://./infra/pulumi/.pulumi-state`, so this
project's state never mixes with other projects on the workstation.

**What Pulumi is, in this repo's terms.** Pulumi reads `infra/pulumi/Pulumi.yaml` to learn the
project name and runtime (`nodejs`), reads `infra/pulumi/Pulumi.dev.yaml` for the `dev` stack's
configuration values, then executes `infra/pulumi/index.ts` (TypeScript) which constructs resource
objects. `pulumi preview` computes the difference between your code and the recorded state and
prints what *would* change. `pulumi up` actually applies it. `pulumi stack output <name>` prints a
value your code marked for export. A "stack" is one deployment instance of the project; we use one
stack named `dev`.

**Component resources.** Following the reference repo, the resources are grouped into "component
resources" — TypeScript classes that extend `pulumi.ComponentResource` and create a cohesive bundle
of cloud resources, exposing a few outputs. This keeps `index.ts` short and the layout legible. The
reference repo's `infra/pulumi/src/components/PostgresServer.ts`,
`infra/pulumi/src/components/BenchmarkEnvironment.ts`, and
`infra/pulumi/src/components/MonitoringStack.ts` are the patterns to copy: a class calls
`super("ns:kind:Name", name, {}, opts)`, creates resources with `{ parent: this }`, assigns public
`pulumi.Output<...>` fields, and ends with `this.registerOutputs({...})`.

**The key cross-plan ordering fact (Integration Point 10).** The Nagare workstation is
`aarch64-darwin` (Apple Silicon) and cannot build the `x86_64-linux` operating-system image locally.
EP-3 (`docs/plans/3-nixos-host-nagare-01-with-k3s.md`) builds that NixOS image on an on-demand Linux
Nix builder in GCP, uploads it to the image-staging bucket this plan creates, registers it as a GCE
image, and writes its self-link into Pulumi config key `nagareImageSelfLink` via
`scripts/upload-images.sh`. **The VM in this plan cannot be created until that has happened.** Hence
the M2/M3 split: you build everything *except* the VM first (M2), then EP-3 produces the image, then
you re-run `pulumi up` to create the VM (M3). This plan handles the gap gracefully by only declaring
the instance when `nagareImageSelfLink` is set.

**The output contract you are defining (Integration Point 1).** This plan is the single source of
truth for cloud identifiers. It must export exactly these nine stack output names, spelled exactly
this way, because EP-3, EP-4, EP-6, and EP-7 read them with `pulumi stack output <name>`:
`publicIp`, `sshCommand`, `baseDomain`, `instanceName`, `serviceAccountEmail`, `dataDiskName`,
`dnsZoneName`, `artifactRegistry`, `backupBucket`. Renaming any of them later requires editing
MasterPlan Integration Point 1 and notifying the consuming plans.


## Plan of Work

The work proceeds in three milestones. Milestone 1 (M1) creates the project skeleton and proves a
`pulumi preview` runs with the VM gracefully omitted. Milestone 2 (M2) creates the entire perimeter
except the VM and verifies the nine outputs and DNS resolution. Milestone 3 (M3) is blocked on EP-3:
once the NixOS image self-link is in config, a second `pulumi up` creates the VM.

The file layout under `infra/pulumi/` is:

```text
infra/
  pulumi/
    Pulumi.yaml          # project name + runtime (nodejs)
    Pulumi.dev.yaml      # the `dev` stack's config (project/region/zone/baseDomain/imageBucket)
    package.json         # @pulumi/pulumi, @pulumi/gcp dependencies
    tsconfig.json        # TypeScript compiler options (copied from the reference repo)
    index.ts             # entry point: reads config, builds NagarePerimeter, re-exports outputs
    src/
      outputs.ts         # defines the StackOutputs interface and the sshCommand helper
      components/
        NagareNetwork.ts      # VPC, subnet, firewall rules
        NagarePerimeter.ts    # top-level component wiring everything together
        NagareInstance.ts     # the Compute Engine VM (conditional)
```

This is the spec's "Suggested Pulumi layout" reorganized into component classes per the reference
repo's convention. The spec's flat `instance.ts`/`firewall.ts`/`dns.ts`/`disks.ts`/
`service-account.ts` files are consolidated into component resources because the reference repo
proves that pattern works and keeps related resources together; the DNS, disk, service account, and
registry resources live inside `NagarePerimeter` since they are simple enough not to warrant their
own classes, while the network (which has the most resources) and the conditional instance each get
their own file.

**Milestone 1 — scaffolding, state backend, config, preview.** Create the eight files above. Run
`pulumi login file://./infra/pulumi/.pulumi-state`, initialize the `dev` stack, set the config keys,
install dependencies, type-check, and run `pulumi preview`. At the end of M1, `pulumi preview` plans
the network, firewall, IP, disk, service account + IAM, DNS, registry, and buckets — but **not** the
VM, because `nagareImageSelfLink` is unset. This proves the conditional-instance logic and the whole
toolchain end to end without needing the image.

**Milestone 2 — create the perimeter.** Run `pulumi up`. Confirm all nine outputs print, that
`publicIp` is a real IPv4 address, and that the wildcard DNS record resolves to it. At the end of
M2, the cloud perimeter exists; EP-3 can now build and upload the NixOS image into the
`imageBucket`, EP-4's cert-manager can use the service account's `roles/dns.admin` against the DNS
zone, and EP-6's `nagarectl` can push images to the Artifact Registry.

**Milestone 3 — create the VM (blocked on EP-3).** After EP-3 runs `scripts/upload-images.sh` and
the `nagareImageSelfLink` config key is populated, re-run `pulumi up`. The instance is now created,
booting from the registered NixOS image, with the data disk and service account attached and the
static IP assigned. Verify with `gcloud compute instances describe nagare-01` and
`pulumi stack output sshCommand`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless a different
working directory is shown. Enter the dev shell first (or ensure the equivalent tools are on PATH):

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
nix develop        # or rely on direnv loading .envrc; provides pulumi, node, tsc, gcloud, gsutil
```

### Step 1 — create `infra/pulumi/Pulumi.yaml`

This file names the project and selects the Node.js runtime. Create
`infra/pulumi/Pulumi.yaml` with:

```yaml
name: nagare
runtime: nodejs
description: Provisions the GCP cloud perimeter for the Nagare personal PaaS.
```

### Step 2 — create `infra/pulumi/package.json`

Mirror the reference repo's dependency pins. Create `infra/pulumi/package.json`:

```json
{
  "name": "nagare-infra",
  "version": "0.1.0",
  "private": true,
  "main": "index.ts",
  "scripts": {
    "build": "tsc --noEmit"
  },
  "dependencies": {
    "@pulumi/pulumi": "^3.140.0",
    "@pulumi/gcp": "^8.10.0"
  },
  "devDependencies": {
    "@types/node": "^20.11.0",
    "typescript": "^5.4.0"
  }
}
```

### Step 3 — create `infra/pulumi/tsconfig.json`

Copy the reference repo's TypeScript settings verbatim. Create `infra/pulumi/tsconfig.json`:

```json
{
  "compilerOptions": {
    "strict": true,
    "outDir": "bin",
    "target": "es2020",
    "module": "commonjs",
    "moduleResolution": "node",
    "esModuleInterop": true,
    "experimentalDecorators": true,
    "forceConsistentCasingInFileNames": true,
    "sourceMap": true
  },
  "include": [
    "index.ts",
    "src/**/*.ts"
  ]
}
```

### Step 4 — create `infra/pulumi/src/outputs.ts`

This file defines the shape of the stack outputs (so the compiler enforces the contract) and a small
helper that builds the `sshCommand` string. The SSH command uses IAP tunneling because port 22 is
firewalled to the IAP range only (see the firewall rule in Step 5). Create
`infra/pulumi/src/outputs.ts`:

```typescript
import * as pulumi from "@pulumi/pulumi";

/**
 * Integration Point 1 (MasterPlan): the exact set of stack outputs EP-2
 * publishes. EP-3, EP-4, EP-6, and EP-7 read these by name with
 * `pulumi stack output <name>`. Renaming any field here is a cross-plan
 * breaking change and must be coordinated via the MasterPlan.
 */
export interface StackOutputs {
    publicIp: pulumi.Output<string>;
    sshCommand: pulumi.Output<string>;
    baseDomain: pulumi.Output<string>;
    instanceName: pulumi.Output<string>;
    serviceAccountEmail: pulumi.Output<string>;
    dataDiskName: pulumi.Output<string>;
    dnsZoneName: pulumi.Output<string>;
    artifactRegistry: pulumi.Output<string>;
    backupBucket: pulumi.Output<string>;
}

/**
 * Build a ready-to-paste SSH command. Port 22 is reachable only through
 * the GCP Identity-Aware Proxy (IAP) tunnel (see the firewall rules), so
 * the command always tunnels through IAP and targets the project/zone we
 * pin everywhere. `instanceName` is e.g. "nagare-01".
 */
export function buildSshCommand(
    instanceName: pulumi.Input<string>,
    zone: string,
    gcpProject: string,
): pulumi.Output<string> {
    return pulumi.output(instanceName).apply(
        (name) =>
            `gcloud compute ssh ${name} ` +
            `--project=${gcpProject} --zone=${zone} --tunnel-through-iap`,
    );
}
```

### Step 5 — create `infra/pulumi/src/components/NagareNetwork.ts`

This component creates the private network and the firewall rules. A "VPC" (Virtual Private Cloud)
is GCP's software-defined private network; a "subnet" is an IP address range within it bound to a
region; a "firewall rule" decides which traffic may reach instances on the network. We create one
custom VPC (no auto subnets), one subnet in `us-west1`, and four firewall rules. Each rule is
explained in a comment because the rationale matters for security. Create
`infra/pulumi/src/components/NagareNetwork.ts`:

```typescript
import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";

export interface NagareNetworkArgs {
    region: string;
}

// The subnet's private IP range. /24 is 256 addresses — far more than a
// single-node PaaS needs, and it leaves room without overlapping common
// home/Tailscale ranges.
const SUBNET_CIDR = "10.10.0.0/24";

// GCP Identity-Aware Proxy (IAP) TCP-forwarding source range. SSH is
// allowed *only* from this range so port 22 is never exposed to the
// public internet; reaching it requires an authenticated
// `gcloud compute ssh --tunnel-through-iap` tunnel. This is the exact
// range the reference repo uses.
const IAP_SOURCE_RANGE = "35.235.240.0/20";

export class NagareNetwork extends pulumi.ComponentResource {
    public readonly network: gcp.compute.Network;
    public readonly subnet: gcp.compute.Subnetwork;

    constructor(name: string, args: NagareNetworkArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:net:NagareNetwork", name, {}, opts);

        // Custom-mode VPC: we declare the single subnet ourselves rather
        // than letting GCP auto-create one per region.
        this.network = new gcp.compute.Network(`${name}-net`, {
            autoCreateSubnetworks: false,
        }, { parent: this });

        this.subnet = new gcp.compute.Subnetwork(`${name}-subnet`, {
            ipCidrRange: SUBNET_CIDR,
            region: args.region,
            network: this.network.id,
        }, { parent: this });

        // Public HTTPS/HTTP ingress for Kourier (the Knative ingress
        // gateway, backed by Envoy, installed by EP-4). On a single k3s
        // node, k3s's ServiceLB binds host ports 80 and 443 to Kourier's
        // LoadBalancer Service, so the world must be able to reach 80/443.
        new gcp.compute.Firewall(`${name}-fw-web`, {
            network: this.network.id,
            direction: "INGRESS",
            sourceRanges: ["0.0.0.0/0"],
            allows: [{ protocol: "tcp", ports: ["80", "443"] }],
        }, { parent: this });

        // SSH only from the IAP range. See IAP_SOURCE_RANGE comment.
        new gcp.compute.Firewall(`${name}-fw-iap-ssh`, {
            network: this.network.id,
            direction: "INGRESS",
            sourceRanges: [IAP_SOURCE_RANGE],
            allows: [{ protocol: "tcp", ports: ["22"] }],
        }, { parent: this });

        // Tailscale's direct-connection port. Tailscale (configured by
        // EP-3) is a mesh VPN; udp/41641 is the port its WireGuard data
        // plane prefers for direct peer connections. Allowing it from
        // anywhere lets Tailscale establish direct (non-relayed) links;
        // if blocked, Tailscale still works via its relays (DERP), so
        // this is an optimization, not a hard requirement.
        new gcp.compute.Firewall(`${name}-fw-tailscale`, {
            network: this.network.id,
            direction: "INGRESS",
            sourceRanges: ["0.0.0.0/0"],
            allows: [{ protocol: "udp", ports: ["41641"] }],
        }, { parent: this });

        this.registerOutputs({});
    }
}
```

### Step 6 — create `infra/pulumi/src/components/NagareInstance.ts`

This component creates the single Compute Engine VM. It is constructed only when the boot image
self-link is known (the caller decides; see Step 7). It boots from the NixOS image, attaches the
data disk and static IP, runs as the dedicated service account with the broad `cloud-platform`
scope (the actual permissions are constrained by the IAM roles granted in `NagarePerimeter`, not by
the legacy scope), and lives on the subnet. Create
`infra/pulumi/src/components/NagareInstance.ts`:

```typescript
import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";

export interface NagareInstanceArgs {
    zone: string;
    machineType: string;
    /** Self-link of the registered NixOS GCE image (Pulumi config key
     *  `nagareImageSelfLink`, written by EP-3's scripts/upload-images.sh). */
    imageSelfLink: string;
    subnetId: pulumi.Input<string>;
    /** The reserved static external IP address (string form). */
    publicIp: pulumi.Input<string>;
    /** The persistent data disk to attach (its self-link/id). */
    dataDiskId: pulumi.Input<string>;
    serviceAccountEmail: pulumi.Input<string>;
}

export class NagareInstance extends pulumi.ComponentResource {
    public readonly instance: gcp.compute.Instance;

    constructor(name: string, args: NagareInstanceArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:compute:NagareInstance", name, {}, opts);

        this.instance = new gcp.compute.Instance(name, {
            name,                       // GCE instance name == resource name == "nagare-01"
            zone: args.zone,
            machineType: args.machineType,
            bootDisk: { initializeParams: { image: args.imageSelfLink } },
            attachedDisks: [{
                source: args.dataDiskId,
                deviceName: "nagare-data",   // stable device name EP-3 mounts at /var/lib/nagare
                mode: "READ_WRITE",
            }],
            networkInterfaces: [{
                subnetwork: args.subnetId,
                // Assign the reserved static external IP so the VM is
                // reachable at a fixed, DNS-able address.
                accessConfigs: [{ natIp: args.publicIp }],
            }],
            serviceAccount: {
                email: args.serviceAccountEmail,
                // cloud-platform is the modern catch-all scope; real
                // authorization comes from the IAM roles granted to this
                // service account in NagarePerimeter, not from scopes.
                scopes: ["cloud-platform"],
            },
            // OS Login lets IAM control SSH access via the IAP tunnel.
            metadata: { "enable-oslogin": "TRUE" },
            // The data disk must survive the VM. Leave it out of the
            // instance lifecycle: it is its own gcp.compute.Disk resource.
        }, { parent: this });

        this.registerOutputs({});
    }
}
```

### Step 7 — create `infra/pulumi/src/components/NagarePerimeter.ts`

This is the top-level component. It creates the network (via `NagareNetwork`), the static IP, the
data disk, the service account and its IAM members, the DNS zone and wildcard record, the Artifact
Registry, and the two buckets — then, **only if** `imageSelfLink` is provided, the VM. It exposes
all the values needed for the stack outputs. Create
`infra/pulumi/src/components/NagarePerimeter.ts`:

```typescript
import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";
import { NagareNetwork } from "./NagareNetwork";
import { NagareInstance } from "./NagareInstance";

export interface NagarePerimeterArgs {
    gcpProject: string;
    region: string;
    zone: string;
    instanceName: string;       // "nagare-01"
    machineType: string;        // "e2-standard-2"
    dataDiskSizeGb: number;     // 100
    baseDomain: string;         // "apps.example.com"
    artifactRegistryId: string; // "nagare"
    backupBucketName: string;
    imageBucketName: string;
    /** Present only after EP-3 sets Pulumi config `nagareImageSelfLink`.
     *  When undefined, the VM is not declared. */
    imageSelfLink?: string;
}

export class NagarePerimeter extends pulumi.ComponentResource {
    public readonly publicIp: pulumi.Output<string>;
    public readonly serviceAccountEmail: pulumi.Output<string>;
    public readonly dataDiskName: pulumi.Output<string>;
    public readonly dnsZoneName: pulumi.Output<string>;
    public readonly artifactRegistry: pulumi.Output<string>;
    public readonly backupBucket: pulumi.Output<string>;
    public readonly instanceName: pulumi.Output<string>;

    constructor(name: string, args: NagarePerimeterArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:env:NagarePerimeter", name, {}, opts);

        const net = new NagareNetwork(`${name}-network`, { region: args.region }, { parent: this });

        // Static external IPv4 address, regional. Reserving it means the
        // VM keeps the same public IP across rebuilds, so the wildcard DNS
        // record stays valid.
        const address = new gcp.compute.Address(`${name}-ip`, {
            region: args.region,
        }, { parent: this });

        // Persistent data disk (IP-3). pd-balanced is the cost/perf
        // sweet spot; 100 GB default. EP-3 attaches and mounts it at
        // /var/lib/nagare.
        const dataDisk = new gcp.compute.Disk(`${name}-data`, {
            zone: args.zone,
            type: "pd-balanced",
            size: args.dataDiskSizeGb,
        }, { parent: this });

        // Dedicated service account (IP-2). Lowercase `serviceaccount`
        // module per the spec correction.
        const sa = new gcp.serviceaccount.Account(`${name}-sa`, {
            accountId: "nagare-node",
            displayName: "Nagare node/workload service account",
        }, { parent: this });

        // Non-authoritative IAM members (spec correction: never use the
        // authoritative *IAMBinding/*IAMPolicy variants on the shared
        // project). roles/dns.admin lets cert-manager (EP-4) solve the
        // Let's Encrypt DNS-01 challenge against the Cloud DNS zone using
        // the VM's ambient credentials. roles/artifactregistry.writer lets
        // nagarectl (EP-6) push images.
        const saMember = pulumi.interpolate`serviceAccount:${sa.email}`;
        new gcp.projects.IAMMember(`${name}-iam-dns`, {
            project: args.gcpProject,
            role: "roles/dns.admin",
            member: saMember,
        }, { parent: this });
        new gcp.projects.IAMMember(`${name}-iam-ar`, {
            project: args.gcpProject,
            role: "roles/artifactregistry.writer",
            member: saMember,
        }, { parent: this });

        // GCS bucket for backups (IP for EP-7). Uniform bucket-level
        // access means IAM alone controls access (no per-object ACLs).
        const backupBucket = new gcp.storage.Bucket(`${name}-backups`, {
            name: args.backupBucketName,
            location: args.region.toUpperCase(), // GCS uses upper-case region names
            uniformBucketLevelAccess: true,
            forceDestroy: false,
        }, { parent: this });

        // Grant the service account object-admin on the backup bucket only
        // (scoped, non-authoritative). EP-7's backup jobs write here.
        new gcp.storage.BucketIAMMember(`${name}-backups-iam`, {
            bucket: backupBucket.name,
            role: "roles/storage.objectAdmin",
            member: saMember,
        }, { parent: this });

        // GCS bucket for image staging (IP-10). EP-3's
        // scripts/upload-images.sh uploads the NixOS *.raw.tar.gz here
        // before registering it as a GCE image.
        new gcp.storage.Bucket(`${name}-images`, {
            name: args.imageBucketName,
            location: args.region.toUpperCase(),
            uniformBucketLevelAccess: true,
            forceDestroy: false,
        }, { parent: this });

        // Cloud DNS managed zone for the apps domain (IP-4). dnsName must
        // be a fully-qualified domain with a trailing dot.
        const dnsName = `${args.baseDomain}.`;
        const dnsZone = new gcp.dns.ManagedZone(`${name}-zone`, {
            dnsName,
            description: "Nagare apps wildcard zone",
        }, { parent: this });

        // Wildcard A record: *.apps.example.com -> publicIp. ttl in
        // seconds; rrdatas is the list of answer IPs.
        new gcp.dns.RecordSet(`${name}-wildcard`, {
            managedZone: dnsZone.name,
            name: pulumi.interpolate`*.${dnsName}`,
            type: "A",
            ttl: 300,
            rrdatas: [address.address],
        }, { parent: this });

        // Artifact Registry Docker repository (IP for EP-6). Location is
        // the region; repositoryId is the short name "nagare".
        const registry = new gcp.artifactregistry.Repository(`${name}-registry`, {
            location: args.region,
            repositoryId: args.artifactRegistryId,
            format: "DOCKER",
        }, { parent: this });

        // The VM exists only once EP-3 has produced the boot image.
        let instance: NagareInstance | undefined;
        if (args.imageSelfLink) {
            instance = new NagareInstance(args.instanceName, {
                zone: args.zone,
                machineType: args.machineType,
                imageSelfLink: args.imageSelfLink,
                subnetId: net.subnet.id,
                publicIp: address.address,
                dataDiskId: dataDisk.id,
                serviceAccountEmail: sa.email,
            }, { parent: this });
        }

        this.publicIp = address.address;
        this.serviceAccountEmail = sa.email;
        this.dataDiskName = dataDisk.name;
        this.dnsZoneName = dnsZone.name;
        // Stable Docker registry hostname/path EP-6 pushes to.
        this.artifactRegistry = pulumi.interpolate`${args.region}-docker.pkg.dev/${args.gcpProject}/${args.artifactRegistryId}`;
        this.backupBucket = backupBucket.name;
        // instanceName is known even before the VM resource exists, so
        // EP-3 can read it from config-time inputs; if the VM exists we
        // use its real name for fidelity.
        this.instanceName = instance ? instance.instance.name : pulumi.output(args.instanceName);

        this.registerOutputs({
            publicIp: this.publicIp,
            serviceAccountEmail: this.serviceAccountEmail,
            dataDiskName: this.dataDiskName,
            dnsZoneName: this.dnsZoneName,
            artifactRegistry: this.artifactRegistry,
            backupBucket: this.backupBucket,
            instanceName: this.instanceName,
        });
    }
}
```

### Step 8 — create `infra/pulumi/index.ts`

This is the entry point. It reads configuration, gracefully reads the optional
`nagareImageSelfLink`, constructs `NagarePerimeter`, and re-exports the nine outputs by their exact
Integration-Point-1 names. Create `infra/pulumi/index.ts`:

```typescript
import * as pulumi from "@pulumi/pulumi";
import { NagarePerimeter } from "./src/components/NagarePerimeter";
import { buildSshCommand } from "./src/outputs";

const cfg = new pulumi.Config();
const gcpCfg = new pulumi.Config("gcp");

const gcpProject = gcpCfg.require("project");   // "tan-nb-exp"
const region = gcpCfg.require("region");        // "us-west1"
const zone = gcpCfg.require("zone");            // "us-west1-a"

// Project-specific config with defaults so a fresh checkout previews
// without extra setup. Local variable names are suffixed `Cfg` so they
// never collide with the exported stack-output names below (a Pulumi
// stack output is named after its exported binding, so the exports must
// literally be `baseDomain`, `instanceName`, etc.).
const instanceNameCfg = cfg.get("instanceName") ?? "nagare-01";
const machineTypeCfg = cfg.get("machineType") ?? "e2-standard-2";
const dataDiskSizeGbCfg = cfg.getNumber("dataDiskSizeGb") ?? 100;
const baseDomainCfg = cfg.get("baseDomain") ?? "apps.example.com";
const artifactRegistryIdCfg = cfg.get("artifactRegistryId") ?? "nagare";
const backupBucketNameCfg = cfg.get("backupBucket") ?? `${gcpProject}-nagare-backups`;
const imageBucketNameCfg = cfg.require("imageBucket"); // set in Pulumi.dev.yaml

// IP-10: EP-3 writes this after building+registering the NixOS image.
// `get` (not `require`) so the VM is simply omitted until it is set.
const imageSelfLink = cfg.get("nagareImageSelfLink");

const perimeter = new NagarePerimeter("nagare", {
    gcpProject,
    region,
    zone,
    instanceName: instanceNameCfg,
    machineType: machineTypeCfg,
    dataDiskSizeGb: dataDiskSizeGbCfg,
    baseDomain: baseDomainCfg,
    artifactRegistryId: artifactRegistryIdCfg,
    backupBucketName: backupBucketNameCfg,
    imageBucketName: imageBucketNameCfg,
    imageSelfLink,
});

// Integration Point 1 — the nine exact stack-output names. The exported
// binding name *is* the stack-output name, so do not rename any of these
// without updating the MasterPlan and the consuming plans (EP-3/4/6/7).
export const publicIp = perimeter.publicIp;
export const baseDomain = baseDomainCfg;
export const instanceName = perimeter.instanceName;
export const serviceAccountEmail = perimeter.serviceAccountEmail;
export const dataDiskName = perimeter.dataDiskName;
export const dnsZoneName = perimeter.dnsZoneName;
export const artifactRegistry = perimeter.artifactRegistry;
export const backupBucket = perimeter.backupBucket;
export const sshCommand = buildSshCommand(perimeter.instanceName, zone, gcpProject);
```

This yields stack outputs named exactly `publicIp`, `baseDomain`, `instanceName`,
`serviceAccountEmail`, `dataDiskName`, `dnsZoneName`, `artifactRegistry`, `backupBucket`, and
`sshCommand` — the nine names Integration Point 1 requires. Verify the final names in Step 13.

### Step 9 — initialize the in-repo Pulumi state backend and the `dev` stack

Run from the repo root. The `pulumi login` points Pulumi at a file backend inside the repo. Then
create the stack. The empty `PULUMI_CONFIG_PASSPHRASE` (from `.envrc`) prevents a passphrase prompt.

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
export PULUMI_CONFIG_PASSPHRASE=""        # if .envrc/direnv has not exported it
pulumi login file://./infra/pulumi/.pulumi-state
pulumi --cwd infra/pulumi stack init dev
```

Expected (abbreviated):

```text
Logged in to ... as ... (file://./infra/pulumi/.pulumi-state)
Created stack 'dev'
```

### Step 10 — set the config keys

These populate `infra/pulumi/Pulumi.dev.yaml`. The `gcp:`-prefixed keys configure the provider; the
unprefixed keys are this project's own config.

```bash
pulumi --cwd infra/pulumi config set gcp:project tan-nb-exp
pulumi --cwd infra/pulumi config set gcp:region us-west1
pulumi --cwd infra/pulumi config set gcp:zone us-west1-a
pulumi --cwd infra/pulumi config set baseDomain apps.example.com
pulumi --cwd infra/pulumi config set imageBucket tan-nb-exp-nagare-images
```

After running these, `infra/pulumi/Pulumi.dev.yaml` should look like:

```yaml
config:
  gcp:project: tan-nb-exp
  gcp:region: us-west1
  gcp:zone: us-west1-a
  nagare:baseDomain: apps.example.com
  nagare:imageBucket: tan-nb-exp-nagare-images
```

When the owner has a real domain, run `pulumi --cwd infra/pulumi config set baseDomain <real-domain>`
(for example `apps.mydomain.dev`) before `pulumi up`, and the wildcard record and `baseDomain` output
follow automatically.

### Step 11 — install dependencies and type-check

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/infra/pulumi
npm install
npm run build      # runs `tsc --noEmit`; must exit 0 with no errors
```

Expected: `npm install` populates `node_modules/`; `npm run build` prints nothing and exits 0.

### Step 12 — preview (M1 acceptance)

```bash
pulumi --cwd /Users/shinzui/Keikaku/bokuno/nagare/infra/pulumi preview
```

Expected (abbreviated): a plan that creates the network, subnet, three firewall rules, the address,
the disk, the service account, two project IAM members, the bucket IAM member, two buckets, the DNS
zone, the wildcard record set, and the Artifact Registry — but **no** `gcp:compute:Instance`,
because `nagareImageSelfLink` is unset. Roughly:

```text
     Type                                   Name              Plan
 +   pulumi:pulumi:Stack                    nagare-dev        create
 +   └─ nagare:env:NagarePerimeter          nagare            create
 +      ├─ nagare:net:NagareNetwork         nagare-network    create
 +      │  ├─ gcp:compute:Network           nagare-network-net      create
 +      │  ├─ gcp:compute:Subnetwork        nagare-network-subnet   create
 +      │  ├─ gcp:compute:Firewall          nagare-network-fw-web        create
 +      │  ├─ gcp:compute:Firewall          nagare-network-fw-iap-ssh    create
 +      │  └─ gcp:compute:Firewall          nagare-network-fw-tailscale  create
 +      ├─ gcp:compute:Address              nagare-ip         create
 +      ├─ gcp:compute:Disk                 nagare-data       create
 +      ├─ gcp:serviceaccount:Account       nagare-sa         create
 +      ├─ gcp:projects:IAMMember           nagare-iam-dns    create
 +      ├─ gcp:projects:IAMMember           nagare-iam-ar     create
 +      ├─ gcp:storage:Bucket               nagare-backups    create
 +      ├─ gcp:storage:BucketIAMMember      nagare-backups-iam   create
 +      ├─ gcp:storage:Bucket               nagare-images     create
 +      ├─ gcp:dns:ManagedZone              nagare-zone       create
 +      ├─ gcp:dns:RecordSet                nagare-wildcard   create
 +      └─ gcp:artifactregistry:Repository  nagare-registry   create

Resources:
    + 18 to create
```

The exact count may differ slightly by provider version; the load-bearing observation is that **no
Instance** appears. This completes M1.

### Step 13 — apply the perimeter (M2)

```bash
pulumi --cwd /Users/shinzui/Keikaku/bokuno/nagare/infra/pulumi up
```

Confirm the prompt, type `yes`. Expected tail:

```text
Resources:
    + 18 created

Outputs:
    artifactRegistry   : "us-west1-docker.pkg.dev/tan-nb-exp/nagare"
    backupBucket       : "tan-nb-exp-nagare-backups"
    baseDomain         : "apps.example.com"
    dataDiskName       : "nagare-data-<suffix>"
    dnsZoneName        : "nagare-zone-<suffix>"
    instanceName       : "nagare-01"
    publicIp           : "34.x.y.z"
    serviceAccountEmail: "nagare-node@tan-nb-exp.iam.gserviceaccount.com"
    sshCommand         : "gcloud compute ssh nagare-01 --project=tan-nb-exp --zone=us-west1-a --tunnel-through-iap"
```

Then list outputs to confirm the nine names exist:

```bash
pulumi --cwd /Users/shinzui/Keikaku/bokuno/nagare/infra/pulumi stack output
```

### Step 14 — verify DNS (M2)

Find the zone's name servers and confirm the wildcard answers with `publicIp`:

```bash
gcloud dns record-sets list --zone="$(pulumi --cwd /Users/shinzui/Keikaku/bokuno/nagare/infra/pulumi stack output dnsZoneName)" --project=tan-nb-exp
```

Expected: an `A` record for `*.apps.example.com.` whose `DATA` equals the `publicIp` output. To
query directly against one of the zone's name servers (replace `<ns>` with one printed by the zone's
`NS` record):

```bash
dig +short '*.apps.example.com' A @<ns>
```

Expected: the `publicIp` value. Note this resolves only against the zone's own name servers until the
real domain's registrar is pointed at them; that delegation step is the owner's responsibility once a
real domain replaces the placeholder.

### Step 15 — create the VM after EP-3 sets the image (M3, blocked on EP-3)

This step cannot run until EP-3 (`docs/plans/3-nixos-host-nagare-01-with-k3s.md`) has built the NixOS
GCE image on the remote x86_64-linux Nix builder and run `scripts/upload-images.sh`, which uploads the
tarball to the `imageBucket`, registers a GCE image, and sets the Pulumi config key:

```bash
# (Run by EP-3, shown here so the dependency is explicit.)
pulumi --cwd infra/pulumi config set nagareImageSelfLink \
  https://www.googleapis.com/compute/v1/projects/tan-nb-exp/global/images/nagare-image-<suffix>
```

Once that key is set, re-run `pulumi up` from this plan:

```bash
pulumi --cwd /Users/shinzui/Keikaku/bokuno/nagare/infra/pulumi up
```

Expected: exactly one new resource, the instance:

```text
     Type                     Name        Plan
 +   nagare:compute:NagareInstance  nagare-01   create
 +   └─ gcp:compute:Instance        nagare-01   create

Resources:
    + 1 created
    19 unchanged
```

Verify the VM:

```bash
gcloud compute instances describe nagare-01 --zone=us-west1-a --project=tan-nb-exp \
  --format='value(status, serviceAccounts[0].email, disks[].deviceName)'
```

Expected: `RUNNING`, the `nagare-node@tan-nb-exp...` service account email, and device names
including `nagare-data`. Then:

```bash
pulumi --cwd /Users/shinzui/Keikaku/bokuno/nagare/infra/pulumi stack output sshCommand
```

prints a usable `gcloud compute ssh ... --tunnel-through-iap` command. This completes M3.


## Validation and Acceptance

Acceptance is behavioral, observed with commands and their outputs.

**M1 acceptance.** From `infra/pulumi/`, `npm run build` exits 0 (TypeScript type-checks). From the
repo root, `pulumi --cwd infra/pulumi preview` succeeds and the plan contains the network, subnet,
three firewall rules, address, disk, service account, two `gcp:projects:IAMMember`, one
`gcp:storage:BucketIAMMember`, two buckets, the DNS managed zone, the wildcard record set, and the
Artifact Registry — and **does not** contain a `gcp:compute:Instance`. That absence is the proof the
conditional-instance logic works while `nagareImageSelfLink` is unset.

**M2 acceptance.** `pulumi --cwd infra/pulumi up` reports the resources created with no errors.
`pulumi --cwd infra/pulumi stack output` prints all nine names — `publicIp`, `sshCommand`,
`baseDomain`, `instanceName`, `serviceAccountEmail`, `dataDiskName`, `dnsZoneName`,
`artifactRegistry`, `backupBucket` — and `publicIp` is a valid IPv4 address. `gcloud dns record-sets
list --zone=<dnsZoneName> --project=tan-nb-exp` shows an `A` record for `*.apps.example.com.` equal
to `publicIp`. `gcloud artifacts repositories describe nagare --location=us-west1
--project=tan-nb-exp` shows a DOCKER repository. `gsutil ls -p tan-nb-exp` lists both the backups and
images buckets.

**M3 acceptance (after EP-3).** `gcloud compute instances describe nagare-01 --zone=us-west1-a
--project=tan-nb-exp` shows `status: RUNNING`, the data disk attached with device name `nagare-data`,
the static IP as the external NAT IP, and the `nagare-node` service account attached. `pulumi
--cwd infra/pulumi stack output sshCommand` prints a command that, when run, opens an IAP-tunneled
SSH session to the VM.

If any output name is missing or misspelled, M2 is **not** accepted — the output contract is the
single most important deliverable, because three downstream plans break silently otherwise.


## Idempotence and Recovery

Pulumi is declarative: re-running `pulumi up` with unchanged code is a no-op that reports
`unchanged` for every resource, so all steps in this plan are safe to repeat. If `pulumi up` is
interrupted, simply run it again; Pulumi reconciles partial state against your code. Running
`pulumi --cwd infra/pulumi preview` at any time is read-only and side-effect free.

If the recorded state ever drifts from reality (for example, someone deleted a resource by hand in
the GCP console), run `pulumi --cwd infra/pulumi refresh` to re-read actual cloud state into Pulumi,
then `pulumi up` to reconcile. `refresh` is safe; it only updates the state file to match the cloud.

The config keys are stored in `infra/pulumi/Pulumi.dev.yaml`; re-running the `config set` commands is
idempotent (it overwrites the value). Re-running `pulumi login file://./infra/pulumi/.pulumi-state`
is safe. If `pulumi stack init dev` reports the stack already exists, that is fine — select it with
`pulumi --cwd infra/pulumi stack select dev`.

The buckets are created with `forceDestroy: false`, so `pulumi destroy` will refuse to delete a
non-empty bucket; this is intentional to protect backups and uploaded images. To tear the whole
perimeter down deliberately, run `pulumi --cwd infra/pulumi destroy` (it removes the VM, IP, network,
DNS, registry, service account, and empty buckets). Empty the buckets first with `gsutil -m rm -r
gs://<bucket>/**` if you truly want them gone, or set `forceDestroy: true` temporarily. Because the
static IP is reserved, destroying and recreating the perimeter yields a *new* IP unless you reserve
and import the same address; for routine rebuilds prefer leaving the perimeter up and only rebuilding
the VM (delete just the instance, then `pulumi up`).


## Interfaces and Dependencies

**Pulumi providers and resource classes used (from `@pulumi/gcp`, version `^8.10.0`, and
`@pulumi/pulumi` `^3.140.0`):** `gcp.compute.Network`, `gcp.compute.Subnetwork`,
`gcp.compute.Firewall`, `gcp.compute.Address`, `gcp.compute.Disk`, `gcp.compute.Instance`,
`gcp.serviceaccount.Account` (lowercase module, per the spec correction), `gcp.projects.IAMMember`,
`gcp.storage.Bucket`, `gcp.storage.BucketIAMMember`, `gcp.dns.ManagedZone`, `gcp.dns.RecordSet`, and
`gcp.artifactregistry.Repository`. The `pulumi.ComponentResource` base class groups these into
`NagareNetwork`, `NagareInstance`, and `NagarePerimeter`.

**Config keys this plan reads:** `gcp:project` (= `tan-nb-exp`), `gcp:region` (= `us-west1`),
`gcp:zone` (= `us-west1-a`), `baseDomain` (default `apps.example.com`), `imageBucket` (required,
e.g. `tan-nb-exp-nagare-images`), and the optional `instanceName`, `machineType`, `dataDiskSizeGb`,
`artifactRegistryId`, `backupBucket`. The one cross-plan input key is **`nagareImageSelfLink`**,
which EP-3 (`docs/plans/3-nixos-host-nagare-01-with-k3s.md`) sets via `scripts/upload-images.sh`;
this plan reads it with `cfg.get` so the VM is omitted until it is present (mirroring the reference
repo's `postgresImageSelfLink` pattern in
`/Users/shinzui/Keikaku/bokuno/load-testing-infra/infra/pulumi/index.ts`).

**Stack outputs this plan defines (Integration Point 1) and who consumes them:** `publicIp`
(consumed by EP-3 for host networking checks, by EP-4 for ingress), `sshCommand` (operator
convenience), `baseDomain` (EP-4 sets Knative's `config-domain` to it; EP-6 computes app URLs from
it), `instanceName` (EP-3 targets it for `nixos-rebuild`), `serviceAccountEmail` (EP-4 uses its
`roles/dns.admin` for the cert-manager DNS-01 solver; EP-6 uses `roles/artifactregistry.writer`;
EP-7 uses `roles/storage.objectAdmin` on the backup bucket), `dataDiskName` (EP-3 attaches/mounts it
at `/var/lib/nagare`; EP-5 and EP-7 consume the mounted layout), `dnsZoneName` (EP-4's cert-manager
DNS-01 solver targets this zone), `artifactRegistry` (= `us-west1-docker.pkg.dev/tan-nb-exp/nagare`;
EP-6 pushes images here), and `backupBucket` (EP-7 writes backups here).

**Cross-plan dependency direction.** This plan has no hard dependency. It soft-depends on EP-1
(`docs/plans/1-repository-scaffolding-and-nix-flake-dev-environment.md`) for the dev shell
(`pulumi`, `node`, `gcloud`). M3 of this plan is blocked on EP-3 producing and registering the NixOS
image and setting `nagareImageSelfLink`. The image-staging bucket created here (Integration Point 10)
is what EP-3's `scripts/upload-images.sh` uploads into; that script must include the IP-9 preflight
assertion (refuse to run unless the active project is `tan-nb-exp`) and pass `--project=tan-nb-exp`
to every `gcloud`/`gsutil` call, exactly as the reference repo's
`/Users/shinzui/Keikaku/bokuno/load-testing-infra/scripts/upload-images.sh` does.
