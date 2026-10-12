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

Full plan before trimming: [64-bring-your-own-project-onboarding-documentation.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/64-bring-your-own-project-onboarding-documentation.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] Revised `docs/user/README.md` (replaced "The one rule that overrides everything" with the configurable target-profile model; corrected the EP-4/EP-5/EP-7 status rows and "Read in this order" badges to match MasterPlan-1; added the two new docs as a "Before you begin" pair). (2026-06-10)
- [x] Revised `docs/user/getting-started.md` (target profile, `nagare.target.env` / `.example`, the configurable-but-fail-closed `scripts/lib/target.sh` guardrail, `tan-nb-exp` as substitutable default; prerequisites bullet + new-docs links). (2026-06-10)
- [x] Revised `docs/user/provisioning-with-pulumi.md` (Pulumi config = derived projection of the profile; registry/bucket/SA names derive from project/region; dropped "Never change"; shared-project language generalized). (2026-06-10)
- [x] Revised `docs/user/host-image-and-boot.md` (image bucket = `$NAGARE_IMAGE_BUCKET`; self-link embeds the project / regenerated per target; cross-linked the age-key/SSH/Tailscale prereqs to onboarding Steps 3–4). (2026-06-10)
- [x] Revised `docs/user/reference.md` (re-framed "Fixed identifiers" → "Default-example identifiers, derived from the target profile"; added the "Target profile variables" table; dropped "Never change"; added `enable-apis.sh` / `lib/target.sh` / `nagarectl init`). (2026-06-10)
- [x] Revised `docs/user/config-reference.md` (EP-62 image-ref authoring: `Config.hs` supplies only the image *name*; the prefix derives from the profile at deploy time; before/after snippet). (2026-06-10)

Milestone 3 — cross-linking, consistency, and the end-to-end walkthrough check:

- [x] Cross-linked the two new docs from `README.md` and `getting-started.md`; both new docs and the revised pages link `CLAUDE.md` and MasterPlan 12 where the "why" belongs. (2026-06-10)
- [x] Ran the consistency grep gates: no mandate phrasing remains (`must use/target tan-nb-exp` / `never change` / `overrides everything` — the sole "never change**s**" hit is about the deploy command shape, not project isolation); the onboarding doc uses the exact EP-63 flags and explicitly notes there is no `--yes`/`--non-interactive`. (2026-06-10)
- [x] Forward-reference walkthrough of `onboarding-bring-your-own-project.md`: all 13 ordered steps present; the SSH-key (Step 3), age/Tailscale (Step 4), and configure-docker (Step 7) steps each precede the step that needs them; DNS delegation (Step 6) sits after the zone exists (Step 5) and before HTTPS (Step 10). No forward reference found. (2026-06-10)

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

EP-64 brought the docs in line with the configurable target-profile model the four sibling plans
shipped. Two new pages were created — `docs/user/gcp-prerequisites.md` (auth + ADC, the six operator
IAM roles, project/billing, the six service APIs with the manual fallback, DNS delegation) and
`docs/user/onboarding-bring-your-own-project.md` (the single ordered zero-to-running runbook centered
on `nagarectl init`, with the four manual prerequisites `init` does NOT handle made explicit and in
execution order). Six existing pages (README, getting-started, provisioning-with-pulumi,
host-image-and-boot, reference, config-reference) were revised to present `tan-nb-exp` as the
substitutable default example rather than a mandate, to document the nine target-profile variables
and their derivations, to frame Pulumi config as a derived projection seeded by `init`, and to
document EP-62's name-only image-ref authoring story.

Acceptance: the grep gates pass — no `must use/target tan-nb-exp` / `never change` / `overrides
everything` mandate remains (the lone "never changes" match is the deploy-command-shape sentence in
deploying-apps.md, untouched); the onboarding doc uses exactly the EP-63 flags and explicitly states
there is no `--yes`; both new files exist, are linked from the index and getting-started, and
cross-link `CLAUDE.md` and MasterPlan 12; and the forward-reference walkthrough finds every required
step in order with each prerequisite before its dependent step. The honesty correction landed too:
the README status table and the runbook mark EP-4/EP-5 as verified-live (per MasterPlan-1) instead of
the stale "🔭 Planned" page badges, and EP-7 as working with the DR drill deferred.

Result vs. purpose: a newcomer with an empty GCP project and a domain can now read
`onboarding-bring-your-own-project.md` top to bottom and reach a running nagare without editing any
tracked source file to replace `tan-nb-exp`. Per the plan's scope, the stale per-page badges on
`cluster-bootstrap.md`/`observability.md` themselves were left for a later reconciliation; the
runbook surfaces the authoritative status inline so onboarding never over-promises.

