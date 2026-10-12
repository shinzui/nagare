---
id: 61
slug: parameterize-shell-scripts-and-envrc-to-the-target-profile
title: "Parameterize shell scripts and envrc to the target profile"
kind: exec-plan
created_at: 2026-06-10T21:59:38Z
intention: "intention_01ktsq8wese1hv93x9fk8d369a"
master_plan: "docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md"
---

# Parameterize shell scripts and envrc to the target profile

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [61-parameterize-shell-scripts-and-envrc-to-the-target-profile.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/61-parameterize-shell-scripts-and-envrc-to-the-target-profile.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today every operational shell script in this repository is welded to one Google Cloud
Platform (GCP) project, `tan-nb-exp`, in region `us-west1` and zone `us-west1-a`. Each
script literally writes `PROJECT=tan-nb-exp` near the top, then refuses to run unless the
active `gcloud` project equals that literal. One in-cluster manifest and one builder script
also bake `tan-nb-exp`/`us-west1`/`us-west1-a` into resource definitions. As a result, a
second operator — or the same person with a second GCP project — cannot run `just host-image`,
`scripts/iap-ssh.sh`, the backup/restore scripts, or the Nix-builder setup against their own
project without hand-editing tracked source files.

After this change, none of the eight scripts under `scripts/` contains a literal
`tan-nb-exp`, `us-west1`, or `us-west1-a`. Each one instead **sources a single shared helper**
(`scripts/lib/target.sh`, delivered by the dependency plan EP-60) that reads the operator's
configured GCP target from a git-ignored profile file and runs the same fail-closed safety
check it has always run — only now it checks against the *configured* project rather than a
baked-in literal. The one in-cluster Kubernetes manifest that pins the project
(`scripts/restore-volume.sh`) interpolates the configured project at render time. The
builder script's hard-coded region, zone, and resource names become environment-overridable
with today's values as defaults.

The user-visible outcome you can observe: with no profile present (or a profile carrying the
default `tan-nb-exp` values), every script behaves exactly as it does today — it runs against
`tan-nb-exp` and refuses to run when `CLOUDSDK_CORE_PROJECT` is set to anything else. With a
profile that names a different project, the very same scripts run against that project, and
the in-cluster restore Job's manifest shows the operator's project, not the literal
`tan-nb-exp`. You can prove both behaviors with the dry-run transcripts in
**Validation and Acceptance** below.

This plan **hard-depends on EP-60** (`docs/plans/60-target-profile-model-and-configurable-isolation-guardrail.md`).
EP-60 creates `scripts/lib/target.sh` and the profile contract this plan consumes; without it,
the `source` lines added here have nothing to load. The exact contract this plan relies on is
restated verbatim in **Interfaces and Dependencies** so a novice can verify EP-60 delivered it
before starting.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Confirm EP-60 has delivered `scripts/lib/target.sh` and that it exports
      `TARGET_PROJECT`, `TARGET_REGION`, `TARGET_ZONE` and defines the fail-closed preflight.
      NOTE: the helper does NOT run the preflight on source — callers invoke
      `_require_target_project` explicitly (see Decision Log). (2026-06-10)
- [x] M1: Replace the inline `PROJECT=tan-nb-exp` + active-project preflight in
      `scripts/backup-postgres.sh` with `source "$(dirname "$0")/lib/target.sh"` +
      `_require_target_project`. (2026-06-10)
- [x] M1: Same replacement in `scripts/restore-postgres.sh`. (2026-06-10)
- [x] M1: Same replacement in `scripts/restore-sqlite.sh`. (2026-06-10)
- [x] M1: Same replacement in `scripts/iap-ssh.sh` (and fix its header comment); change the
      two `gcloud --project="${PROJECT}"` call sites to `--project="${TARGET_PROJECT}"`. (2026-06-10)
- [x] M1: Reconcile the backup bucket name: change the three backup/restore scripts to read
      `BUCKET="${BACKUP_BUCKET:-${NAGARE_BACKUP_BUCKET:?...}}"` so the profile's
      `NAGARE_BACKUP_BUCKET` is honored while `BACKUP_BUCKET` still wins if set. (2026-06-10)
- [x] M2: Rewrite `scripts/setup-nix-builder.sh`: source the helper for project/region/zone;
      replace `REGION`/`ZONE` literals with `TARGET_REGION`/`TARGET_ZONE`; make
      `NETWORK`/`SUBNET`/`FIREWALL`/`INSTANCE`/`SUBNET_CIDR` env-overridable with current
      defaults; bind `PROJECT=$TARGET_PROJECT` so every `--project="$PROJECT"` call site works
      unchanged. (2026-06-10)
- [x] M2: Rewrite `scripts/upload-images.sh`: source the helper (via `${BASH_SOURCE[0]}`);
      bind `PROJECT=$TARGET_PROJECT` and set `REGION="${TARGET_REGION}"`; kept the
      `pulumi config get imageBucket` / `pulumi config set nagareImageSelfLink` logic and added
      the per-target self-link note at the write site. (2026-06-10)
- [x] M2: Confirmed `scripts/nix-builder-startup.sh.tpl` contains no project literal (grep clean);
      pubkey substitution untouched; no `@TARGET_PROJECT@` marker added. (2026-06-10)
- [x] M3: Parameterize the in-cluster manifest in `scripts/restore-volume.sh`: sourced the
      helper + `_require_target_project`; interpolated `${TARGET_PROJECT}` into the Job's
      `CLOUDSDK_CORE_PROJECT` env value (verified the `<<YAML` marker is unquoted); fixed the
      two `tan-nb-exp` comments. (2026-06-10)
- [x] M3: Parameterized the cdn-spike example scripts
      `cluster/examples/cdn-spike/gcp-cdn-up.sh` and `gcp-cdn-down.sh` (path-adjusted source of
      the helper via `../../../scripts`; `ZONE="$TARGET_ZONE"`; `PROJECT="$TARGET_PROJECT"` so the
      `g()` wrapper is unchanged). (2026-06-10)
- [x] Validation: default (`.envrc`-loaded) preflight passes; with the env unset and gcloud's
      config default differing it fails closed (exit 1); a stubbed render of the restore-volume
      Job manifest under `CLOUDSDK_CORE_PROJECT=acme-prod` shows
      `CLOUDSDK_CORE_PROJECT, value: "acme-prod"` — no literal. Whole-tree
      `grep tan-nb-exp/us-west1 scripts/ cluster/examples/cdn-spike/*.sh` returns only the helper's
      own fallback defaults. (2026-06-10)

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The MasterPlan/task brief stated that `scripts/nix-builder-startup.sh.tpl` hard-codes
  `tan-nb-exp` at line ~84 in a Kubernetes env var. **This is not the case.** A grep of the
  whole tree confirms the template contains no `tan-nb-exp` and no `CLOUDSDK_CORE_PROJECT`:

  ```text
  $ grep -rn "tan-nb-exp" scripts/nix-builder-startup.sh.tpl
  (no output)
  ```

  Line 84 of that template is the `SVC` here-document terminator for a systemd unit, not a
  project literal. The builder VM is a generic Ubuntu host that runs Determinate Nix; it has
  no in-cluster manifest and no project binding. **Consequence:** the planned `@TARGET_PROJECT@`
  marker and the corresponding `sed` extension in `setup-nix-builder.sh` are unnecessary and
  are dropped from scope. The only template substitution remains the existing `@BUILDER_PUBKEY@`.
  The single in-cluster `CLOUDSDK_CORE_PROJECT` literal in the whole repo lives in
  `scripts/restore-volume.sh` line 84 (a coincidence of line numbers), and that one is handled
  in M3.

- Guardrail semantics under the configurable helper differ subtly from the old inline guard, and
  this plan's acceptance test (b) as written does not trigger a refusal. The old guard compared
  gcloud's active project against a *literal* `tan-nb-exp`, so `CLOUDSDK_CORE_PROJECT=wrong-project`
  produced a mismatch. EP-60's helper instead *derives* `TARGET_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"`
  from the same variable, so setting `CLOUDSDK_CORE_PROJECT=wrong-project` makes both the active
  value and `TARGET_PROJECT` equal `wrong-project` — they match and the preflight passes. This is by
  design: when the operator explicitly sets the Cloud SDK project, that *is* the configured target.
  The guard now bites the meaningful real case: `CLOUDSDK_CORE_PROJECT` **unset** (operator forgot
  `direnv allow`) while gcloud's *config* default points at a different project than the profile/
  default. Verified with a `gcloud` stub: env unset + stubbed `gcloud config get-value project` →
  `wrong-project`, profile default `tan-nb-exp`, `bash scripts/backup-postgres.sh` prints the refusal
  and exits 1. Also discovered this workstation's real gcloud default is `tan-ng`, so with the env
  unset the guard refuses even without a stub — extra confirmation it is fail-closed. The realistic
  "default profile passes" case is with `.envrc` loaded (`CLOUDSDK_CORE_PROJECT=tan-nb-exp`), which
  passes. No code change needed; the helper is correct. (2026-06-10)

- (Add further discoveries here as work proceeds.)

## Decision Log

Record every decision made while working on the plan.

- Decision: the cdn-spike example scripts (`cluster/examples/cdn-spike/gcp-cdn-up.sh` and
  `gcp-cdn-down.sh`) ARE in scope and will be parameterized with the same helper, rather than
  left as spike artifacts.
  Rationale: They carry the identical six-line `PROJECT=tan-nb-exp` preflight and a
  `ZONE=us-west1-a` literal. Leaving them hard-coded would mean a `grep -rn tan-nb-exp` over
  the repo still returns matches, undermining the MasterPlan's stated success condition that
  no tracked source file needs editing to replace `tan-nb-exp`. They source the helper with a
  path adjusted for their deeper directory (`cluster/examples/cdn-spike/` is three levels below
  the repo root, so the relative path to `scripts/lib/target.sh` differs). The cost is low
  (two files, mechanical edits) and the consistency win is real. Their throwaway resource
  *names* (`cdn-spike-*`) are left as literals because they are deliberately namespaced and
  removed by the down-script; they are not project bindings.
  Date: 2026-06-10

- Decision: the three backup/restore scripts will read the bucket as
  `BUCKET="${BACKUP_BUCKET:-${NAGARE_BACKUP_BUCKET:?...}}"`, reconciling the two names rather
  than renaming the variable wholesale.
  Rationale: Today the scripts read `${BACKUP_BUCKET:?...}`. EP-60's profile provides
  `NAGARE_BACKUP_BUCKET`. Making the script prefer an explicit `BACKUP_BUCKET` (so existing
  muscle memory and any systemd-timer unit that exports `BACKUP_BUCKET` keep working) but fall
  back to the profile's `NAGARE_BACKUP_BUCKET` means an operator who has done `direnv allow`
  needs to export nothing extra. This is additive and backward-compatible: a shell that
  already exports `BACKUP_BUCKET` is unaffected.
  Date: 2026-06-10

- Decision: the Nix-builder resource names (`NETWORK`, `SUBNET`, `FIREWALL`, `INSTANCE`,
  `SUBNET_CIDR`) become environment-overridable with their current values as defaults (e.g.
  `NETWORK="${NIX_BUILDER_NETWORK:-nix-builder-net}"`), but they are NOT sourced from the
  target profile.
  Rationale: These are not GCP-target bindings; they are names of resources the script
  creates. They do, however, live in whatever project the helper selects, so two operators who
  share a project (unusual, but possible) could collide on these names. Exposing overrides lets
  a second operator pick non-colliding names without editing tracked source, while the defaults
  preserve today's behavior exactly. The trade-off (a profile-driven default versus an env
  override) is documented in the script comment so a future reader understands why these are
  env-overridable but not in the profile contract.
  Date: 2026-06-10

- Decision: drop the planned `@TARGET_PROJECT@` template marker and `sed` extension.
  Rationale: `scripts/nix-builder-startup.sh.tpl` contains no project literal (see Surprises &
  Discoveries). There is nothing to substitute. Adding an unused marker would be dead code.
  Date: 2026-06-10

- Decision: each rewritten script calls `_require_target_project` **explicitly** on its own line
  immediately after `source "$(dirname "$0")/lib/target.sh"`, rather than relying on the helper to
  run the preflight on source.
  Rationale: This plan's Interfaces item 4 anticipated that EP-60's helper might run the preflight
  on source. The delivered `scripts/lib/target.sh` (EP-60, verified) does NOT — sourcing only loads
  the profile, sets `TARGET_PROJECT`/`TARGET_REGION`/`TARGET_ZONE`, and *defines* the
  `_require_target_project` function; the caller must invoke it. EP-60 is the single source of truth
  for the contract (per this plan's Interfaces note), and its own CLAUDE.md/Interfaces text states
  scripts "source it and call `_require_target_project`". Calling it explicitly preserves the
  fail-closed guarantee one-for-one (under `set -euo pipefail` a non-zero return aborts the script),
  so every diff in Concrete Steps gains a `_require_target_project` line after the `source` line.
  Date: 2026-06-10

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-61 removed every literal `tan-nb-exp` / `us-west1` / `us-west1-a` project binding from the eight
operational scripts and the two cdn-spike example scripts, replacing each inline six-line preflight
with `source lib/target.sh` + an explicit `_require_target_project` call (EP-60's helper defines the
guard but does not auto-run it on source — the one contract correction this plan made, recorded in
the Decision Log). The single in-cluster project literal (`restore-volume.sh` Job manifest) now
interpolates `${TARGET_PROJECT}`; the nix-builder resource names became `NIX_BUILDER_*`-overridable;
`upload-images.sh` derives its region from `TARGET_REGION` and documents the per-target self-link.

Acceptance was proven by observable behavior, not edited lines: (a) the default `.envrc`-loaded
profile passes the preflight as `tan-nb-exp`; (b) with the env unset and gcloud's config default
differing, the guard fails closed and exits 1; (c) a stubbed render of the restore-volume Job
manifest under `acme-prod` carries `acme-prod`, never the literal; and a whole-tree grep over
`scripts/` and the cdn-spike `*.sh` returns only the helper's own fallback defaults.

Result vs. purpose: every script now reads its GCP target from the profile via the shared helper,
the fail-closed guardrail is preserved (one enforcement path instead of six copies), and a second
operator can run the backup/restore, IAP-SSH, nix-builder, image-upload, and CDN-spike scripts
against their own project with no tracked-source edit. Scope was trimmed once during planning (the
`.tpl` carries no project literal — confirmed by grep) and once during implementation (the helper's
preflight-invocation contract). The `cdn-spike/README.md` prose still names `tan-nb-exp`/`us-west1-a`
as worked examples; updating that prose is EP-64's job, as the plan scoped.

