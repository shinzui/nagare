---
id: 64
slug: bring-your-own-project-onboarding-documentation
title: "Bring-your-own-project onboarding documentation"
kind: exec-plan
created_at: 2026-06-10T21:59:38Z
intention: "intention_01ktsq8wese1hv93x9fk8d369a"
master_plan: "docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md"
---

# Bring-your-own-project onboarding documentation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today nagare's documentation tells the reader that every cloud command **must** target one
specific Google Cloud Platform (GCP) project, `tan-nb-exp`, in region `us-west1`, zone
`us-west1-a`. The operator guide under `docs/user/` is written as if that binding is a hard
law ("The one rule that overrides everything"), and the GCP-side prerequisites a brand-new
operator actually needs — signing in to gcloud, holding the right Identity and Access
Management (IAM) roles, creating or selecting a project, turning on the GCP service APIs, and
delegating a DNS domain — are scattered, partial, or entirely absent. A second person, or the
same person with a second GCP project, cannot follow today's docs from zero to a running
nagare.

This ExecPlan is the **documentation layer** of MasterPlan 12 ("Bring-your-own GCP project
onboarding for nagare", `docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md`).
The four sibling plans (EP-60 through EP-63, all checked in under `docs/plans/`) change the
*code* so the GCP target is configurable rather than hard-coded: EP-60 defines a git-ignored
"target profile" file, EP-61 parameterizes the shell scripts, EP-62 parameterizes the Haskell
CLI `nagarectl` and the deployment DSL's image references, and EP-63 adds a guided
`nagarectl init` command plus codified API enablement. This plan, EP-64, makes the *docs*
match that new reality.

After this change, a newcomer with nothing but an empty GCP project and a domain name can open
`docs/user/onboarding-bring-your-own-project.md`, read it top to bottom, and reach a running
nagare without ever editing a tracked source file to swap out `tan-nb-exp`. You can see it
working by following two observable acceptance gates described in detail later: (1) a reader
can walk `onboarding-bring-your-own-project.md` start to finish and meet every required step in
order, with no step referencing something defined only later; and (2) `grep -rn "tan-nb-exp"
docs/user` returns only clearly-labeled *example* usages — never a sentence that says you must
use that exact project. The work is prose only: no code, no scripts, no manifests. Two new
documents are created and six existing documents are revised to drop the "you must use
`tan-nb-exp`" framing in favor of the configurable target-profile model, while still using
`tan-nb-exp` / `us-west1` / `apps.example.com` as the worked **default example**.

A second, honesty-driven purpose: some existing pages are out of date about what is *built*.
Verification against the MasterPlan-1 progress log (see Context and Orientation) shows that
`docs/user/cluster-bootstrap.md` and `docs/user/observability.md` are marked "🔭 Planned — not
built yet," but MasterPlan-1's Progress section records EP-4 (cluster bootstrap) and EP-5
(observability) as **Complete and verified live**. The onboarding runbook this plan writes must
state each step's *real* status and must not over-promise; where this plan touches those pages
it corrects the status badge to reflect the MasterPlan, which is the authoritative source of
truth for build state.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — the two new documents:

- [x] Create `docs/user/gcp-prerequisites.md` (gcloud auth + Application Default Credentials, operator IAM roles, project creation/selection, billing, service-API enablement, DNS delegation to Cloud DNS). (2026-06-10)
- [x] Create `docs/user/onboarding-bring-your-own-project.md` (single ordered zero-to-running runbook centered on `nagarectl init`, consolidating the scattered steps and filling the previously-missing ones: age key placement before first boot, the Tailscale pre-auth key in the sops secrets file, `gcloud auth configure-docker <registry-host>` before the first deploy, and editing the operator SSH key in `nixos/hosts/nagare-01/users.nix`). (2026-06-10)

Milestone 2 — revise existing docs project-agnostic + the image-ref authoring story:

- [ ] Revise `docs/user/README.md` (replace "The one rule that overrides everything" and the `tan-nb-exp` framing with the configurable target-profile model; correct the EP-4/EP-5/EP-7 status rows to match MasterPlan-1; link the two new docs).
- [ ] Revise `docs/user/getting-started.md` (target profile, `nagare.target.env` / `nagare.target.env.example`, the configurable-but-fail-closed guardrail, `tan-nb-exp` as substitutable default).
- [ ] Revise `docs/user/provisioning-with-pulumi.md` (Pulumi config is a derived projection of the profile; bucket/registry/SA names derive from the project; drop "Never change").
- [ ] Revise `docs/user/host-image-and-boot.md` (image bucket name derives from the project; cross-link the age-key/secrets prerequisite to the onboarding runbook).
- [ ] Revise `docs/user/reference.md` (re-frame the "Fixed identifiers" table as "default-example identifiers, derived from the target profile"; document the nine target-profile variables).
- [ ] Revise `docs/user/config-reference.md` (the new image-ref authoring story from EP-62: an app's `nagare/Config.hs` supplies only the image *name*; the registry prefix derives from the profile at deploy time).

Milestone 3 — cross-linking, consistency, and the end-to-end walkthrough check:

- [ ] Cross-link the two new docs from `README.md` and from `getting-started.md`; cross-link to `CLAUDE.md`'s revised isolation policy and to MasterPlan 12 as the architectural decision.
- [ ] Run the consistency grep checks (see Validation and Acceptance) and fix every residual `tan-nb-exp` mandate.
- [ ] Do the top-to-bottom forward-reference walkthrough of `onboarding-bring-your-own-project.md`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (build-state drift): the user-facing pages disagree with MasterPlan-1 about what is
  built. `docs/user/cluster-bootstrap.md` opens with "🔭 Planned (EP-4) — **not built yet.** …
  The manifests under `cluster/bootstrap/` do not exist on disk yet," and
  `docs/user/observability.md` is badged the same way. But MasterPlan-1
  (`docs/masterplans/1-bootstrap-nagare-personal-paas.md`) Progress records:
  `- [x] EP-4: cert-manager + letsencrypt-dns issuer (Ready), Knative Serving + Kourier …` and
  `- [x] EP-5: VictoriaMetrics/Logs/Traces + OTel Collector + Grafana installed and verified
  live`. The onboarding runbook must reflect the MasterPlan's "Complete/verified live" status,
  not the stale page badges, and Milestone 2 corrects the README status table accordingly. The
  MasterPlan also records `- [x] EP-7` complete with the full disaster-recovery drill deferred,
  and the runbooks under `docs/runbooks/` (`disaster-recovery.md`, `cluster-access.md`,
  `server-operations.md`) already exist and are written against live behavior — so the
  onboarding doc should link them rather than re-describe recovery.

- Discovery (init does not do everything): EP-63's `nagarectl init` writes the profile, runs
  preflight, enables APIs, and seeds Pulumi config — but it does **not** place the host age key,
  inject the Tailscale pre-auth key, run `gcloud auth configure-docker`, or edit the operator
  SSH key in `nixos/hosts/nagare-01/users.nix`. EP-63's printed "Next steps" stop at
  `just infra-up` / `just host-image` / `just infra-up` / `just cluster-bootstrap`. Those four
  manual prerequisites are exactly the "previously-missing/scattered steps" the onboarding doc
  must make explicit; the runbook cannot assume `init` handled them.

(Add further entries here as drafting reveals doc inconsistencies.)


## Decision Log

Record every decision made while working on the plan.

- Decision: this plan does **not** edit `CLAUDE.md`. The repo-root `CLAUDE.md` "GCP project
  isolation" section is rewritten by EP-60 (MasterPlan 12 Integration Point 5). EP-64 only
  *references* and *aligns to* that revised policy from the user docs.
  Rationale: MasterPlan 12 assigns `CLAUDE.md` ownership to EP-60 explicitly ("No other plan
  edits `CLAUDE.md`; they rely on EP-60's revision"). Two plans editing the same section would
  conflict.
  Date: 2026-06-10

- Decision: keep `tan-nb-exp` / `us-west1` / `us-west1-a` / `apps.example.com` in the docs as
  the worked **default example**, never delete them, but always frame them as substitutable.
  Rationale: MasterPlan 12 Decomposition Strategy: "A tracked `nagare.target.env.example`
  documents the schema and ships the `tan-nb-exp` values as the worked example so the existing
  operator's workflow is unchanged." An operator who does nothing keeps today's behavior;
  removing the example would make the docs harder to follow, not easier.
  Date: 2026-06-10

- Decision: correct the EP-4/EP-5/EP-7 status badges in the README status table to match
  MasterPlan-1, and have the onboarding runbook mark each step's real status inline.
  Rationale: the prompt requires honesty about build state and the MasterPlan is the
  authoritative source. See Surprises & Discoveries for the evidence.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about nagare. Read it before touching any file.

**What nagare is.** Nagare (流れ, "flow") is a single-node personal Platform-as-a-Service: one
GCP Compute Engine virtual machine named `nagare-01` running NixOS (a Linux distribution whose
whole system is declared in code), the lightweight Kubernetes distribution k3s, the Knative
serverless app runtime, and the Victoria observability stack. An operator stands the platform
up and runs it entirely from this one git repository: Pulumi (an infrastructure-as-code tool)
owns the cloud resources, a Nix flake owns the host image, the Haskell command-line tool
`nagarectl` deploys apps, and a `justfile` (a task runner, like a friendlier Makefile) wraps
the common steps as `just <recipe>`.

**The terms you must understand to write these docs.** Define each in the docs themselves the
first time it appears on a page.

- **Target profile.** A single git-ignored file at the repo root, `nagare.target.env`, holding
  the operator's GCP target as `export VAR=value` shell lines. It is the *single source of
  truth* for which project/region/zone/registry/buckets/domain nagare acts on. A tracked
  companion `nagare.target.env.example` documents the schema and ships the `tan-nb-exp` values
  as the worked example. EP-60 defines this contract; everything reads from it.

- **ADC — Application Default Credentials.** A separate gcloud credential that *programs and
  libraries* (as opposed to the interactive `gcloud` CLI) use to authenticate to GCP. You get
  it with `gcloud auth application-default login`. It is distinct from `gcloud auth login`,
  which authenticates the *CLI itself*. The Pulumi GCP provider and other tooling read ADC, so
  an operator needs **both** logins. The onboarding doc must spell this out, because forgetting
  ADC is a classic "Pulumi can't authenticate" failure.

- **DNS delegation.** Telling your domain registrar (where you bought, e.g.,
  `apps.example.com`) to hand authority for that zone to Google Cloud DNS's nameservers, by
  setting NS (nameserver) records at the registrar to the four nameservers Cloud DNS assigns
  the managed zone. Until delegation is done, the world's DNS resolvers do not consult Cloud
  DNS for your domain, so Let's Encrypt cannot validate your domain and real traffic does not
  reach nagare.

- **sops / age.** `sops` is a tool that encrypts secrets *in place* inside a YAML file so the
  file is safe to commit to Git; `age` is the encryption scheme it uses here. The encrypted
  secrets file is committed; the matching **age private key** lives only on the host (and in
  your offline backup), never in Git. At NixOS activation, `sops-nix` decrypts the file using
  that key. The one host secret at bootstrap time is a **Tailscale pre-auth key** (a token that
  lets `nagare-01` join your Tailscale private network — "tailnet" — unattended at first boot).

**The files this plan creates.** Two new files under `docs/user/`:

- `docs/user/gcp-prerequisites.md` — the complete GCP-side prerequisites.
- `docs/user/onboarding-bring-your-own-project.md` — the single ordered zero-to-running runbook.

**The files this plan revises.** Six existing files under `docs/user/`:

- `docs/user/README.md` — the operator-guide landing page and "read in this order" index.
- `docs/user/getting-started.md` — workstation setup, the dev shell, project isolation.
- `docs/user/provisioning-with-pulumi.md` — creating the cloud perimeter.
- `docs/user/host-image-and-boot.md` — building the NixOS image and first boot.
- `docs/user/reference.md` — the fixed-identifiers / config-keys / recipes lookup.
- `docs/user/config-reference.md` — the typed-config (`nagare/Config.hs`) catalogue.

**The files this plan reads but does not edit** (cross-link targets and sources of truth):

- `CLAUDE.md` (repo root) — the project-isolation policy, rewritten by EP-60 to the configurable
  model; EP-64 links to it, does not edit it.
- `docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md` — the architectural
  decision and the Integration Points; link as the "why."
- `docs/masterplans/1-bootstrap-nagare-personal-paas.md` — the authoritative build-state log;
  consult its Progress section before asserting any "✅ Working / 🔭 Planned" badge.
- `docs/plans/60-*.md` … `63-*.md` — the sibling plans that define the behaviors documented
  here (see Interfaces and Dependencies for the exact mapping).
- `docs/runbooks/disaster-recovery.md`, `docs/runbooks/cluster-access.md`,
  `docs/runbooks/server-operations.md` — existing, live-accurate runbooks to link from the
  onboarding doc rather than duplicate.
- Existing pages that the onboarding doc consolidates and links: `docs/user/accessing-the-host.md`,
  `docs/user/secrets.md`, `docs/user/cluster-bootstrap.md`, `docs/user/observability.md`,
  `docs/user/deploying-apps.md`, `docs/user/backups-and-disaster-recovery.md`.

**The contract this plan documents (from EP-60, by reference).** The target profile
`nagare.target.env` holds nine canonical variables. These names and example values are fixed by
EP-60 (MasterPlan 12 Integration Point 1) and the docs must use them verbatim:

```bash
# Core GCP target (standard Cloud SDK names; honored by gcloud and Pulumi too)
export CLOUDSDK_CORE_PROJECT=tan-nb-exp
export CLOUDSDK_COMPUTE_REGION=us-west1
export CLOUDSDK_COMPUTE_ZONE=us-west1-a
# Derived names (defaults follow the conventions in the comments)
export NAGARE_REGISTRY_HOST=us-west1-docker.pkg.dev      # derived as <region>-docker.pkg.dev
export NAGARE_ARTIFACT_REGISTRY_ID=nagare
export NAGARE_IMAGE_BUCKET=tan-nb-exp-nagare-images       # derived as <project>-nagare-images
export NAGARE_BACKUP_BUCKET=tan-nb-exp-nagare-backups     # derived as <project>-nagare-backups
export NAGARE_BASE_DOMAIN=apps.example.com
export NAGARE_INSTANCE_NAME=nagare-01
```

Precedence everywhere is: **a value already in your environment > this file > the built-in
default** (the `tan-nb-exp` value). So an operator who does nothing keeps today's behavior. The
first three reuse the standard Cloud SDK variable names, so interactive `gcloud` and the Pulumi
GCP provider honor them too. The guardrail is the shell helper `scripts/lib/target.sh`, sourced
by every script, exposing `TARGET_PROJECT` / `TARGET_REGION` / `TARGET_ZONE` and a
`_require_target_project` preflight that refuses to run unless gcloud's active project equals
`$TARGET_PROJECT` — fail-closed, but against the *configured* project, not the literal
`tan-nb-exp`.


## Plan of Work

The work is three milestones. Milestone 1 creates the two new documents (the highest-value
deliverable: the from-zero runbook). Milestone 2 revises the six existing documents to drop the
hard `tan-nb-exp` mandate and document the new image-ref authoring story. Milestone 3 does the
cross-linking, the consistency grep pass, and the top-to-bottom forward-reference walkthrough.
Each milestone is independently verifiable: M1 by reading the two new files for completeness and
order; M2 by the `grep` checks plus a per-file diff review; M3 by the walkthrough and the final
grep gate. Because this is prose, the "commands to run" are the grep gates and a careful human
read; there is no compile step. The author should preserve every page's existing status-badge
convention (✅ Working / 🟡 In progress / 🔭 Planned), correcting only badges that contradict
MasterPlan-1.


### Milestone 1 — the two new documents

Scope: write `docs/user/gcp-prerequisites.md` and `docs/user/onboarding-bring-your-own-project.md`
from scratch. At the end of this milestone both files exist, each is internally complete and
ordered, and the onboarding doc references the prerequisites doc for the GCP-account setup
rather than repeating it. Acceptance: a reader who knows GCP but not nagare can follow
`gcp-prerequisites.md` to a project that is authenticated, has the right roles, has the APIs on,
and has its domain delegated; and can then follow `onboarding-bring-your-own-project.md` to a
running nagare. The Concrete Steps section below gives the exact section outline and key content
for each file.


### Milestone 2 — revise the existing docs project-agnostic + the image-ref story

Scope: edit the six existing pages so they present `tan-nb-exp` as the default example, not a
mandate, and so `config-reference.md` documents EP-62's new image-ref authoring. At the end of
this milestone, none of the six pages tells the reader they *must* use `tan-nb-exp`; each
explains the target-profile model and links to the two new docs; and the `config-reference.md`
`ImageRef` section shows that an app's `Config.hs` supplies only the image name. Acceptance: the
grep gate (Validation and Acceptance) passes for these six files, and a diff review confirms no
factual claim contradicts the sibling plans. The Concrete Steps section gives before/after
snippets for the most important framing changes.


### Milestone 3 — cross-linking, consistency, and the end-to-end walkthrough

Scope: ensure the two new docs are linked from `README.md` and `getting-started.md`, that both
new docs and the revised pages link `CLAUDE.md` and MasterPlan 12 where the "why" belongs, and
that the whole `docs/user` tree passes the consistency greps. Then do the forward-reference
walkthrough: read `onboarding-bring-your-own-project.md` top to bottom and confirm that every
required step appears in order and that no step depends on something the reader has not yet been
told to do. At the end of this milestone the onboarding is coherent, ordered, and gap-free.
Acceptance: the two grep gates pass, and the walkthrough finds no forward reference. The
Validation and Acceptance section enumerates the exact checks.


## Concrete Steps

This section gives the exact outline and key content for each new document, and the specific
edits with before/after snippets for the existing documents. All paths are repo-root-relative.
The working directory for every grep command is the repo root,
`/Users/shinzui/Keikaku/bokuno/nagare`.


### Step 1 — create `docs/user/gcp-prerequisites.md`

Status badge: `> **Status:** ✅ Working` (prerequisites are GCP-account actions that work
today; the codified `nagarectl init` preflight that *checks* them is EP-63). Section outline and
key content, in order:

1. **Title + one-paragraph purpose.** "What you need on the GCP side before nagare can touch
   your project: an authenticated gcloud, the right IAM roles, a project with billing, the
   service APIs turned on, and your domain delegated to Cloud DNS. `nagarectl init` (next page)
   checks most of these for you, but you must put them in place first." Note that `tan-nb-exp`
   is the worked default example and is fully substitutable for your own project id.

2. **Install + authenticate gcloud (with ADC).** The dev shell provides `gcloud`. Two distinct
   logins, both required:

   ```bash
   gcloud auth login                          # authenticates the gcloud CLI (interactive you)
   gcloud auth application-default login       # writes Application Default Credentials (ADC) for Pulumi/tools
   ```

   Define ADC inline (see Context and Orientation). Call out that forgetting the second command
   is the most common "Pulumi can't authenticate" failure. Show how to confirm:

   ```bash
   gcloud auth list                            # shows the ACTIVE account
   gcloud config get-value account
   ```

3. **Create or select a project, and confirm billing.** Either create a fresh project or pick an
   existing empty one. Frame `tan-nb-exp` as the example id:

   ```bash
   gcloud projects create YOUR_PROJECT_ID       # or skip if it exists
   gcloud config set project YOUR_PROJECT_ID    # tan-nb-exp is the default example
   ```

   Note that a billing account must be linked or API enablement and resource creation fail;
   point to the Cloud Console billing page (described in prose, not a memorized URL) and the
   `gcloud billing projects link` command at a high level.

4. **The operator IAM roles you need to provision.** State that `nagarectl init` preflights for
   these and refuses to proceed without them (unless `--skip-preflight`). List the exact roles
   EP-63 checks (`operatorRoles`), and explain in one line what each unlocks:

   ```text
   roles/compute.admin                    — VPC, firewall, static IP, disks, the VM
   roles/dns.admin                        — the Cloud DNS managed zone + records
   roles/artifactregistry.admin           — the Docker image repository
   roles/storage.admin                    — the image-staging and backup GCS buckets
   roles/iam.securityAdmin                — the node service account and its bindings
   roles/serviceusage.serviceUsageAdmin   — enabling the service APIs (next section)
   ```

   Note that a `roles/owner` binding satisfies all of them (EP-63's preflight short-circuits on
   `roles/owner`). Show the grant pattern as an example, framed as substitutable:

   ```bash
   gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
     --member="user:you@example.com" --role="roles/compute.admin"
   # …repeat per role, or grant roles/owner to yourself on your own project
   ```

5. **Enable the service APIs.** Explain that a fresh project has most APIs off, and that this
   was a real bootstrap failure (MasterPlan-1 records `artifactregistry` and `iam` being off and
   blocking `pulumi up`). Two equivalent paths, both codified by EP-63:

   - `scripts/enable-apis.sh` — the tracked script `nagarectl init` runs for you (it sources the
     guardrail, asserts the active project equals the target, then enables the six APIs with an
     explicit `--project`).
   - `gcp.projects.Service` resources in `infra/pulumi/index.ts` — so later `pulumi up` runs keep
     the APIs on.

   List the six exact API names (EP-63's `requiredApis`):

   ```text
   compute.googleapis.com
   dns.googleapis.com
   storage.googleapis.com
   artifactregistry.googleapis.com
   iam.googleapis.com
   servicenetworking.googleapis.com
   ```

   Show the manual fallback for readers not yet running `nagarectl init`:

   ```bash
   gcloud services enable compute.googleapis.com dns.googleapis.com storage.googleapis.com \
     artifactregistry.googleapis.com iam.googleapis.com servicenetworking.googleapis.com \
     --project=YOUR_PROJECT_ID
   ```

6. **Register and delegate a domain to Cloud DNS.** Explain DNS delegation (see Context and
   Orientation). You bring a domain you own (e.g. `apps.example.com` is the example base domain);
   Pulumi creates the Cloud DNS managed zone and the wildcard `*.<baseDomain>` A record; you then
   copy the four nameservers Cloud DNS assigns into NS records at your registrar. Note that until
   delegation propagates, Let's Encrypt (DNS-01 challenge) cannot issue the wildcard certificate
   and real traffic will not resolve — so this is a prerequisite for working HTTPS, even though
   the VM boots without it. Point forward: the managed zone is created during provisioning, so
   the exact nameservers are read with `pulumi -C infra/pulumi stack output dnsZoneName` and the
   Cloud Console / `gcloud dns managed-zones describe` after `just infra-up`.

7. **Where to next.** Link to `onboarding-bring-your-own-project.md`. Cross-link `CLAUDE.md`
   (the configurable isolation policy) and MasterPlan 12 (the architectural decision).


### Step 2 — create `docs/user/onboarding-bring-your-own-project.md`

Status badge: a header note that this is the consolidated zero-to-running runbook, and that each
numbered step carries its own real status badge inline (so the reader is never misled about what
is built). Section outline and key content, strictly in execution order so there are no forward
references:

1. **Title + purpose.** "From an empty GCP project and a domain you own to a running nagare,
   using only this page and the pages it links. The default worked example targets project
   `tan-nb-exp`, region `us-west1`, zone `us-west1-a`, base domain `apps.example.com` — every one
   of those is substitutable for your own values via the target profile." State the two
   prerequisites up front: (a) the GCP-side setup from `gcp-prerequisites.md` is done; (b) you
   have cloned this repo and can open a terminal in it.

2. **Step 0 — workstation + dev shell.** Link `getting-started.md`. The one action: install Nix,
   then `direnv allow` (or `nix develop`) to enter the pinned dev shell that provides `pulumi`,
   `gcloud`, `kubectl`, `helm`, `ghc`/`cabal`, `sops`, `age`, `just`. State that everything below
   runs inside that shell.

3. **Step 1 — GCP prerequisites.** Link `gcp-prerequisites.md` and summarize its checklist in
   one short list (authenticated gcloud + ADC; operator IAM roles or owner; a project with
   billing; APIs enabled — or let `nagarectl init` enable them; a domain ready to delegate). Do
   not repeat the detail; the reader follows the linked page once.

4. **Step 2 — `nagarectl init` (write the target profile, enable APIs, seed Pulumi).** This is
   the centerpiece. Show the command and what it does, by reference to EP-63's behavior:

   ```bash
   nagarectl init --project YOUR_PROJECT_ID --base-domain apps.yourdomain.com
   # interactive on a TTY: prompts for project / region / zone / base domain with sensible defaults
   ```

   Explain the flags exactly as EP-63 ships them: `--project`, `--region`, `--zone`,
   `--base-domain`, `--force` (overwrite an existing `nagare.target.env`), `--skip-preflight`
   (skip the gcloud-auth + operator-IAM checks), `--skip-enable` (skip `scripts/enable-apis.sh`),
   `--skip-seed` (skip seeding Pulumi config), `--dry-run` (show what would happen). Note there is
   no `--yes`/`--non-interactive` flag: supplying `--project` is what makes it non-interactive.
   Describe the ordered effect: resolve defaults → preflight (gcloud active account + the six
   operator IAM roles) → write `nagare.target.env` (nine `export` lines) → enable the six APIs →
   seed eight Pulumi stack-config keys (`gcp:project`, `gcp:region`, `gcp:zone`,
   `nagare:baseDomain`, `nagare:imageBucket`, `nagare:backupBucket`, `nagare:artifactRegistryId`,
   `nagare:instanceName`) → print next steps. Show the generated `nagare.target.env` (the nine
   variables from Context and Orientation) so the reader sees the single source of truth.
   Emphasize: this is the only command that writes the profile and drives Pulumi config; you do
   not hand-edit either for onboarding.

5. **Step 3 — place the operator SSH key in the host config (manual; before image build).**
   `init` does not do this. The image bakes in the `deploy` user's authorized SSH key from
   `nixos/hosts/nagare-01/users.nix`. Edit that file to your own public key before building the
   image, or you cannot log in. Cross-link `accessing-the-host.md`.

6. **Step 4 — place the host age key and the Tailscale pre-auth key (manual; before first
   boot).** `init` does not do this either. Two parts, both required before the host boots
   cleanly: (a) generate the host's age keypair, record the **public** key in `nixos/.sops.yaml`,
   and place the **private** key on the VM at `/var/lib/sops-nix/age-key.txt` (mode `0400`, root)
   before first boot; (b) put a Tailscale pre-auth key into the sops secrets file
   `nixos/hosts/nagare-01/secrets/nagare-01.yaml` under `tailscale/authkey`, encrypted to the
   host's age public key. Link `secrets.md` for the exact `sops` and `.sops.yaml` mechanics; this
   page only states *that* and *when*, with the cross-link for *how*.

7. **Step 5 — provision the cloud perimeter (first `pulumi up`, VM gated).** Run
   `just infra-up`. On a clean checkout the first apply creates everything *except* the VM,
   because `nagareImageSelfLink` isn't set yet. Link `provisioning-with-pulumi.md`. Note the
   observable check: `pulumi -C infra/pulumi stack output publicIp` returns the reserved static
   IP. Status: 🟡 (EP-2, in progress per the page badges, but the perimeter previews/applies).

8. **Step 6 — delegate DNS now that the zone exists.** Read the assigned nameservers
   (`pulumi -C infra/pulumi stack output dnsZoneName`, then `gcloud dns managed-zones describe`)
   and set NS records at your registrar. This must happen after Step 5 (the zone has to exist)
   and before HTTPS can be issued (Step 9). Placing it here keeps the ordering unambiguous.

9. **Step 7 — authenticate Docker to your registry (manual; before the first deploy).** `init`
   does not do this. Before `nagarectl deploy` can push an app image, run:

   ```bash
   gcloud auth configure-docker us-west1-docker.pkg.dev   # use YOUR NAGARE_REGISTRY_HOST
   ```

   Explain the registry host is `<region>-docker.pkg.dev` — i.e. `$NAGARE_REGISTRY_HOST` from the
   profile — so for `us-west1` it is `us-west1-docker.pkg.dev`. (On the deploy path,
   `nagarectl` configures this for you via EP-62's `configureDockerAuth`, but doing it once by
   hand removes a first-deploy surprise.)

10. **Step 8 — build and register the NixOS image, then boot the VM.** Run `just host-image`
    (builds on the on-demand x86_64-linux Nix builder, uploads to `$NAGARE_IMAGE_BUCKET`,
    registers the GCE image, writes `nagare:nagareImageSelfLink` into Pulumi config). Then
    `just infra-up` again — now the VM is created. Link `host-image-and-boot.md`. Note that
    `nagareImageSelfLink` embeds the project, so it is target-specific and is regenerated per
    target (never carried from another project). Status: 🟡 (EP-3).

11. **Step 9 — get on the host and confirm the node is Ready.** Link `accessing-the-host.md`
    (Tailscale SSH primary; `scripts/iap-ssh.sh` break-glass for macOS). Observable check:
    `kubectl get nodes` shows `nagare-01 Ready`. Status: 🟡 (EP-3) but verified live in
    MasterPlan-1.

12. **Step 10 — bootstrap the cluster + observability.** Run `just cluster-bootstrap` then
    `just observability`. Link `cluster-bootstrap.md` and `observability.md`. **Status note
    (honesty):** MasterPlan-1 records EP-4 and EP-5 as Complete and verified live, even though
    those two pages still carry "🔭 Planned" badges; state the MasterPlan status here and note the
    page badges are being reconciled. The HTTPS smoke test (a hello service answering over a
    valid Let's Encrypt cert under your wildcard) depends on Step 6's DNS delegation having
    propagated.

13. **Step 11 — deploy your first app.** Link `deploying-apps.md` and `config-reference.md`.
    Note that an app's `nagare/Config.hs` now supplies only the image *name* (EP-62; see the
    config-reference revision in Step 8 of this plan), and the registry prefix comes from the
    profile. Status: 🟡 (built; live deploy pending per MasterPlan-1 EP-6).

14. **Step 12 — backups and recovery.** Link `backups-and-disaster-recovery.md` and the
    `docs/runbooks/` runbooks. Restate the two things only the operator can keep off-machine: the
    host age private key and a copy of this repo (including Pulumi state).

15. **Switching projects later.** One short closing section: to point the same checkout at a
    different GCP project, re-run `nagarectl init --force` (rewrites `nagare.target.env` and
    re-seeds Pulumi config) — you do not run two targets at once; the guardrail enforces one
    active target per checkout (MasterPlan 12 "out of scope: simultaneous multi-project").

16. **Cross-links footer.** `CLAUDE.md` (the configurable isolation policy), MasterPlan 12 (the
    architectural decision), `gcp-prerequisites.md`.


### Step 3 — revise `docs/user/README.md`

Replace the closing "## The one rule that overrides everything" section. Before:

```markdown
## The one rule that overrides everything

**Every cloud resource and every read targets the `tan-nb-exp` GCP project,
region `us-west1`, zone `us-west1-a`.** No command in this repo may touch
another project — not even a `list` or `describe`. …
```

After (configurable framing, keep `tan-nb-exp` as the default example):

```markdown
## One target at a time — and it's yours to choose

Nagare acts on **one** GCP project at a time, but **which** project is
configurable, not hard-coded. The target lives in a git-ignored **target
profile**, `nagare.target.env` (schema in the tracked `nagare.target.env.example`,
which ships `tan-nb-exp` / `us-west1` / `us-west1-a` / `apps.example.com` as the
worked default example). `.envrc` sources it; every script's preflight and
`nagarectl` read it; the guardrail still **fail-closes** — it refuses to run
unless gcloud's active project equals your *configured* target. To bring your own
project from scratch, start at **[GCP prerequisites](gcp-prerequisites.md)** and
**[Bring-your-own-project onboarding](onboarding-bring-your-own-project.md)**. See
[`CLAUDE.md`](../../CLAUDE.md) for the full configurable-isolation policy and
[MasterPlan 12](../masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md)
for the decision.
```

Also: in the "Read in this order" list, change item 1's tail from "the hard rule that every
cloud call targets `tan-nb-exp`" to "the configurable target profile and the fail-closed
guardrail," and add the two new docs as a "Before you begin" pair ahead of Provisioning.
Correct the status table rows so they match MasterPlan-1: change EP-4 (Cluster bootstrap) and
EP-5 (Observability) from "🔭 Planned" to "✅ Working (verified live)" and update the matching
"Read in this order" badges (items 6 and 7) from 🔭 to ✅; note EP-7 backups/DR as "✅ Working
(full DR drill deferred)." Keep the "MasterPlan wins if this table disagrees" caveat.


### Step 4 — revise `docs/user/getting-started.md`

Rewrite the "## Project isolation" section to describe the target profile. Before:

```markdown
`.envrc` exports:

```bash
export CLOUDSDK_CORE_PROJECT=tan-nb-exp
export CLOUDSDK_COMPUTE_REGION=us-west1
export CLOUDSDK_COMPUTE_ZONE=us-west1-a
```
…
**Never** point any command in this repo at another GCP project …
```

After (key points to convey):

- `.envrc` sources the git-ignored `nagare.target.env` if present, then exports
  `CLOUDSDK_CORE_PROJECT` / `CLOUDSDK_COMPUTE_REGION` / `CLOUDSDK_COMPUTE_ZONE` with the
  `tan-nb-exp` / `us-west1` / `us-west1-a` values as *fallback defaults*. Show the precedence:
  environment > `nagare.target.env` > built-in default.
- The schema is documented in the tracked `nagare.target.env.example`; copy it to
  `nagare.target.env` and edit, or let `nagarectl init` write it.
- The guardrail is configurable but still fail-closed: `scripts/lib/target.sh` exposes
  `TARGET_PROJECT`/`TARGET_REGION`/`TARGET_ZONE` and `_require_target_project` refuses to run
  unless the active project equals `$TARGET_PROJECT`. Quote the real refusal message shape:
  `refusing to run: gcloud active project is '…', expected '<your target>'.`
- Replace "Never point any command at another project" with: "One target per checkout — to
  target a different project, change the profile (or `nagarectl init --force`), don't run two at
  once." Cross-link `CLAUDE.md` and MasterPlan 12.

Also update the "Prerequisites" bullet "A Google Cloud identity with access to the `tan-nb-exp`
project" to "A Google Cloud identity with access to *your* GCP project (the default example is
`tan-nb-exp`); see [GCP prerequisites](gcp-prerequisites.md)." Add a "Where to go next" pointer
to the onboarding runbook for a from-zero bring-up.


### Step 5 — revise `docs/user/provisioning-with-pulumi.md`

Three framing changes:

- **"Configuration" table.** Change `gcp:project` Notes from "Never change." to "Your target
  project; the default example is `tan-nb-exp`. Seeded from the target profile by
  `nagarectl init`." Add a sentence above the table: "These keys are a **derived projection of
  the target profile** — `nagarectl init` writes them from `nagare.target.env` with
  `pulumi config set`; you normally don't hand-edit `Pulumi.dev.yaml` for a new project."
- **Derived names.** Where the "What gets created" table hard-codes
  `us-west1-docker.pkg.dev/tan-nb-exp/nagare`, `tan-nb-exp-nagare-backups`,
  `tan-nb-exp-nagare-images`, and the SA `nagare-node@tan-nb-exp…`, add a note that these names
  **derive from your project/region**: registry host `<region>-docker.pkg.dev`, buckets
  `<project>-nagare-images` / `<project>-nagare-backups`, SA `nagare-node@<project>…`. Keep the
  `tan-nb-exp` values as the worked example in the table.
- **"shared `tan-nb-exp` project" language.** The two notes that say IAM uses non-authoritative
  members "so it never clobbers existing bindings on the shared `tan-nb-exp` project" should read
  "on the target project (it may be a shared project)."

Add a one-line pointer near the top: "New to nagare? Start at
[Bring-your-own-project onboarding](onboarding-bring-your-own-project.md); this page is the
provisioning detail it links."


### Step 6 — revise `docs/user/host-image-and-boot.md`

- In "The model" ASCII diagram and the "Build and register the image" numbered list, change the
  hard `tan-nb-exp-nagare-images` to `$NAGARE_IMAGE_BUCKET` (= `<project>-nagare-images`; the
  default example is `tan-nb-exp-nagare-images`).
- In "Prerequisite: the host age key and secrets," add a forward link to
  `onboarding-bring-your-own-project.md` Steps 3–4 so a reader on the onboarding path lands here
  for detail but knows the ordering (operator SSH key + age key + Tailscale key all before first
  boot). Keep `secrets.md` as the "how" link.
- Note that `nagareImageSelfLink` embeds the project and is regenerated per target (never carried
  across projects).


### Step 7 — revise `docs/user/reference.md`

- Re-title "## Fixed identifiers" to "## Default-example identifiers (derived from the target
  profile)" and add a lead sentence: "These are the values for the default example target
  (`tan-nb-exp` / `us-west1`). For your own project they derive from `nagare.target.env`:
  registry host `<region>-docker.pkg.dev`, buckets `<project>-nagare-*`, SA `nagare-node@<project>…`."
- Add a new subsection "## Target profile variables" listing the nine `nagare.target.env`
  variables (from Context and Orientation) with their derivation rule and default, and stating
  precedence (env > profile > default). Cross-link `getting-started.md` and `CLAUDE.md`.
- In "## Pulumi config keys," drop "Never change." from `gcp:project` (mirror Step 5) and note
  the keys are a derived projection of the profile.
- In "## Scripts," add `scripts/enable-apis.sh` (enables the six service APIs against the target
  project; run by `nagarectl init`) and `scripts/lib/target.sh` (the sourced guardrail/profile
  loader). Add a "## `nagarectl init`" row/line documenting its flags by reference to EP-63.


### Step 8 — revise `docs/user/config-reference.md` (the image-ref authoring story)

The single substantive change is the `### `ImageRef`` subsection. Before:

```markdown
Non-empty and **must not contain a colon** — the tag is appended separately at
deploy time (`nagarectl` computes a UTC timestamp tag, or you pass `--tag`). For
a real Nagare app the path is
`us-west1-docker.pkg.dev/tan-nb-exp/nagare/<app>`.
```

After:

```markdown
Non-empty and **must not contain a colon** — the tag is appended separately at
deploy time (`nagarectl` computes a UTC timestamp tag, or you pass `--tag`).

You now supply only the app's **image name**, not the full registry path. Write
`mkImageRef "notes"` (or pass the bare name as `webService`'s second argument).
At deploy time `nagarectl` derives the registry prefix from your target profile —
`<NAGARE_REGISTRY_HOST>/<CLOUDSDK_CORE_PROJECT>/<NAGARE_ARTIFACT_REGISTRY_ID>` —
and prefixes the bare name, so the pushed/pulled image is e.g.
`us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes` for the default-example target.
A name that already contains a `/` (e.g. a public image like
`gcr.io/knative-samples/helloworld-go`) is treated as fully qualified and left
untouched.
```

Show the before/after `Config.hs` snippet so the change is unmistakable:

```haskell
-- before (project + region baked into application source):
mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes"
-- after (just the name; the prefix comes from the target profile at deploy time):
mkImageRef "notes"
```

Also update the two example snippets later in the page that pass full registry paths to
`webService` (the `attachVolume`/preset examples use `"gcr.io/myproject/notes"`, which is a
public-style fully-qualified ref and is fine — leave those, but add a one-line note that a bare
name like `"notes"` is prefixed from the profile while a `/`-bearing ref is used as-is). Add a
cross-link to MasterPlan 12 Integration Point 4 (the registry-host derivation) and to EP-62.


### Step 9 — cross-linking and consistency (Milestone 3)

Add the two new docs to `README.md`'s index (done in Step 3) and to `getting-started.md`'s
"Where to go next" (done in Step 4). Confirm every page touched links `CLAUDE.md` and
MasterPlan 12 where the "why" belongs. Then run the grep gates in Validation and Acceptance and
fix any residual mandate phrasing.


## Validation and Acceptance

Because this is documentation, acceptance is a coherent, ordered, gap-free onboarding a newcomer
can follow, plus mechanical grep checks. Run all greps from the repo root.

**Acceptance 1 — the from-zero walkthrough (the primary gate).** Read
`docs/user/onboarding-bring-your-own-project.md` top to bottom as if you were a newcomer with an
empty project and a domain. Confirm every required step is present and in execution order, with
**no forward reference** — i.e. no step depends on something the reader is told to do only later.
The required ordered steps, each of which must appear and in this relative order:

1. workstation + dev shell; 2. GCP prerequisites (auth+ADC, IAM/owner, project+billing, APIs,
domain ready); 3. `nagarectl init`; 4. operator SSH key in `nixos/hosts/nagare-01/users.nix`
(before image build); 5. host age key at `/var/lib/sops-nix/age-key.txt` + Tailscale pre-auth
key in `nixos/hosts/nagare-01/secrets/nagare-01.yaml` (before first boot); 6. first `just
infra-up` (VM gated); 7. DNS delegation (after the zone exists); 8. `gcloud auth
configure-docker <registry-host>` (before first deploy); 9. `just host-image` + second `just
infra-up` (VM boots); 10. get on the host, `kubectl get nodes` = Ready; 11. `just
cluster-bootstrap` + `just observability`; 12. deploy first app; 13. backups/recovery. The
walkthrough passes when each of these is found exactly once, in order, and the age-key/Tailscale
and configure-docker and SSH-key steps each appear *before* the step that needs them.

**Acceptance 2 — `tan-nb-exp` is example-not-mandate.** Run:

```bash
grep -rn "tan-nb-exp" docs/user
```

Every hit must be a clearly-labeled example, a default value, or a derived-name illustration —
never a sentence asserting the reader must use that exact project. In particular, the phrases
"must … `tan-nb-exp`", "Never change", and "the one rule that overrides everything" must be
gone. Spot-check with:

```bash
grep -rniE "must (use|target).*tan-nb-exp|never change|overrides everything" docs/user
# expected: no output
```

**Acceptance 3 — documented commands match shipped behavior.** Each referenced command/flag must
match what the sibling plans ship. Verify by cross-reading the plan files (no code to run):

- The `nagarectl init` flags in the onboarding doc are exactly `--project`, `--region`,
  `--zone`, `--base-domain`, `--force`, `--skip-preflight`, `--skip-enable`, `--skip-seed`,
  `--dry-run` (EP-63), and the doc does **not** invent `--yes`/`--non-interactive`.

  ```bash
  grep -nE "non-interactive|--yes" docs/user/onboarding-bring-your-own-project.md
  # expected: at most an explanatory "no --yes flag" note, never a usage example
  ```

- The operator IAM role list is exactly the six EP-63 `operatorRoles`
  (`roles/compute.admin`, `roles/dns.admin`, `roles/artifactregistry.admin`,
  `roles/storage.admin`, `roles/iam.securityAdmin`, `roles/serviceusage.serviceUsageAdmin`).
- The service-API list is exactly the six EP-63 `requiredApis`
  (`compute`, `dns`, `storage`, `artifactregistry`, `iam`, `servicenetworking` `.googleapis.com`).
- The nine target-profile variable names are spelled exactly as EP-60 fixes them.
- The registry host is `<region>-docker.pkg.dev` and the image-ref story says `Config.hs` supplies
  only the name (EP-62).
- The four manual prerequisites the onboarding doc marks as *not* done by `init` (SSH key, age
  key, Tailscale key, `configure-docker`) match EP-63's stated scope (init's "Next steps" stop at
  the four `just` recipes).

**Acceptance 4 — build-state honesty.** The onboarding runbook and the README status table state
EP-4/EP-5 as Complete (matching MasterPlan-1 Progress), not "Planned." Cross-check:

```bash
grep -n "\[x\] EP-4\|\[x\] EP-5\|\[x\] EP-7" docs/masterplans/1-bootstrap-nagare-personal-paas.md
```

confirms the MasterPlan marks them done; the docs must not contradict it. Where a page badge
(e.g. `cluster-bootstrap.md`) still reads "Planned," the onboarding doc explicitly notes the
reconciliation rather than silently trusting the stale badge.

**Acceptance 5 — the two new files exist and link correctly.**

```bash
test -f docs/user/gcp-prerequisites.md && test -f docs/user/onboarding-bring-your-own-project.md
grep -l "onboarding-bring-your-own-project.md" docs/user/README.md docs/user/getting-started.md
grep -n "CLAUDE.md\|masterplans/12" docs/user/gcp-prerequisites.md docs/user/onboarding-bring-your-own-project.md
```

All three must succeed (files present, linked from the index and getting-started, and both new
docs cross-link the policy and the MasterPlan).


## Idempotence and Recovery

Documentation edits are inherently safe to iterate: re-running a section's edits, re-reading a
file, or re-writing a new doc causes no drift in the running system, and nothing here touches
GCP, Pulumi state, or the cluster. If an edit is wrong, fix the prose and re-run the grep gates;
there is no destructive operation and no migration. The two new files can be regenerated from
the Concrete Steps outline at any time.

The one ongoing hazard is **truth decay**: a doc claim can silently fall out of step with shipped
behavior as the sibling plans evolve. So treat every command, flag, variable name, role, and API
name in these docs as a claim to be re-verified against EP-60/61/62/63 (and MasterPlan-1 for
build state) whenever those plans change. The Acceptance 3 grep cross-checks above are the
re-verification procedure; run them again after any sibling plan revises a flag or name. If the
sibling plans add a target-profile variable (EP-60 owns that list), add it to `reference.md`'s
"Target profile variables" subsection and to the generated `nagare.target.env` shown in the
onboarding doc.


## Interfaces and Dependencies

This plan produces prose, not code, so it defines no types or function signatures. Its
"interfaces" are the behaviors it documents, each owned by a sibling plan (all checked into
`docs/plans/`). The docs reference these behaviors **by name** so they stay accurate as the
plans are the source of truth:

- **EP-60** (`docs/plans/60-target-profile-model-and-configurable-isolation-guardrail.md`) —
  defines the target profile contract: the git-ignored `nagare.target.env`, the tracked
  `nagare.target.env.example`, the nine canonical variables
  (`CLOUDSDK_CORE_PROJECT`, `CLOUDSDK_COMPUTE_REGION`, `CLOUDSDK_COMPUTE_ZONE`,
  `NAGARE_REGISTRY_HOST`, `NAGARE_ARTIFACT_REGISTRY_ID`, `NAGARE_IMAGE_BUCKET`,
  `NAGARE_BACKUP_BUCKET`, `NAGARE_BASE_DOMAIN`, `NAGARE_INSTANCE_NAME`), the precedence rule
  (env > profile > default), the `.envrc` sourcing, the guardrail helper `scripts/lib/target.sh`
  (`TARGET_PROJECT`/`TARGET_REGION`/`TARGET_ZONE`, `_require_target_project`), and the `CLAUDE.md`
  rewrite. The docs document these names verbatim; EP-60 owns them. This plan does not edit
  `CLAUDE.md` (EP-60 does); it links it.

- **EP-61** (`docs/plans/61-parameterize-shell-scripts-and-envrc-to-the-target-profile.md`) —
  parameterizes the shell scripts to source `scripts/lib/target.sh`. The docs reference
  `scripts/upload-images.sh` (writes the per-target `nagareImageSelfLink`),
  `scripts/iap-ssh.sh`, `scripts/setup-nix-builder.sh`, and the backup/restore scripts as
  reading the profile. (Note: EP-61 leaves `nix-builder-startup.sh.tpl` unchanged — it has no
  project literal — so the docs must not claim the builder template is parameterized.)

- **EP-62** (`docs/plans/62-parameterize-nagarectl-and-the-dsl-image-refs-to-the-target-profile.md`)
  — defines the resolved `TargetProfile` record (module `Nagare.Target`,
  `cli/nagarectl/src/Nagare/Target.hs`), `resolveTargetProfile`, and `registryPrefix`. It owns
  the image-ref authoring story documented in `config-reference.md`: an app's `nagare/Config.hs`
  supplies only the image **name**; `nagarectl` prefixes it with
  `<NAGARE_REGISTRY_HOST>/<CLOUDSDK_CORE_PROJECT>/<NAGARE_ARTIFACT_REGISTRY_ID>` at deploy time
  (`qualifyImage`), leaving a `/`-bearing ref untouched. It also owns
  `configureDockerAuth :: Text -> IO ()` (the deploy-path `gcloud auth configure-docker`).

- **EP-63** (`docs/plans/63-gcp-bootstrap-automation-and-nagarectl-init-onboarding-command.md`)
  — defines `nagarectl init` (module `Nagare.Init`) with the exact flags `--project`,
  `--region`, `--zone`, `--base-domain`, `--force`, `--skip-preflight`, `--skip-enable`,
  `--skip-seed`, `--dry-run`; the preflight (gcloud active account + the six `operatorRoles`);
  the six `requiredApis`; `scripts/enable-apis.sh`; the profile write; and the eight seeded
  Pulumi config keys. The `gcp-prerequisites.md` and `onboarding-bring-your-own-project.md` docs
  document these exactly. EP-63 also fixes the scope boundary the onboarding doc relies on: init
  does **not** place the age key, inject the Tailscale key, run `configure-docker`, or edit
  `users.nix` — those are the manual steps the onboarding doc makes explicit.

- **MasterPlan 12**
  (`docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md`) — the architectural
  decision and the five Integration Points; linked from the new docs as the "why."

- **MasterPlan 1** (`docs/masterplans/1-bootstrap-nagare-personal-paas.md`) — the authoritative
  build-state log; consulted (Progress section) before asserting any status badge. Records EP-4,
  EP-5, EP-7 Complete (EP-7 with the full DR drill deferred), which the README status table and
  onboarding runbook must reflect.

- **Existing docs and runbooks** linked rather than duplicated:
  `docs/user/getting-started.md`, `provisioning-with-pulumi.md`, `host-image-and-boot.md`,
  `accessing-the-host.md`, `secrets.md`, `cluster-bootstrap.md`, `observability.md`,
  `deploying-apps.md`, `config-reference.md`, `backups-and-disaster-recovery.md`, and
  `docs/runbooks/disaster-recovery.md` / `cluster-access.md` / `server-operations.md`.


## Revision Note

2026-06-10 — Initial authored draft. Fleshed out the skeleton into a complete documentation
ExecPlan: Purpose/Big Picture (zero-to-running from these docs alone), an unchecked Progress
checklist (each new and revised doc), Context and Orientation (full paths; definitions of target
profile, ADC, DNS delegation, sops/age), a three-milestone Plan of Work, Concrete Steps with the
exact section outlines for the two new docs and before/after snippets for the key framing changes
in the six revised docs, grep-based Validation and Acceptance, Idempotence and Recovery, and the
Interfaces and Dependencies mapping each documented behavior to its owning sibling plan by
reference. Reason: EP-64 is the documentation layer of MasterPlan 12 and must be self-contained
and finalized last so the runbook matches shipped behavior; the draft also records the build-state
drift discovered (EP-4/EP-5 are Complete per MasterPlan-1 despite stale "Planned" page badges) so
the onboarding does not over-promise.
