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
- [ ] M3: Parameterize the in-cluster manifest in `scripts/restore-volume.sh`: source the
      helper and interpolate `${TARGET_PROJECT}` into the Job's `CLOUDSDK_CORE_PROJECT` env
      value; fix the two `tan-nb-exp` comments.
- [ ] M3: Parameterize the cdn-spike example scripts
      `cluster/examples/cdn-spike/gcp-cdn-up.sh` and `gcp-cdn-down.sh` (path-adjusted source
      of the helper; replace `ZONE=us-west1-a` with `TARGET_ZONE`) — see Decision Log for the
      in-scope ruling.
- [ ] Validation: with the default profile, dry-run each script and observe the preflight
      passing for `tan-nb-exp` and failing closed when `CLOUDSDK_CORE_PROJECT` is wrong; show
      a rendered restore-volume manifest containing the configured project, not a literal.


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

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**Where things live.** The repository root is `/Users/shinzui/Keikaku/bokuno/nagare`. All
operational shell scripts live under `scripts/`. Two example/spike scripts live deeper, under
`cluster/examples/cdn-spike/`. The repo-root `.envrc` exports the GCP target environment
variables for every interactive shell. The dependency plan EP-60 adds `scripts/lib/target.sh`,
a shared bash library this plan sources from each script.

**What "the preflight" is.** Several scripts currently contain an identical six-line block,
for example in `scripts/backup-postgres.sh` lines 8–14:

```bash
# --- Integration Point 9 preflight: refuse to run outside tan-nb-exp ---
PROJECT=tan-nb-exp
ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
  exit 1
fi
```

A **preflight** here means a guard that runs before the script does any real work. It reads
the active GCP project (from the `CLOUDSDK_CORE_PROJECT` environment variable, or, if unset,
from `gcloud config get-value project`), compares it to the project the script is allowed to
touch, and **exits non-zero (refuses to run)** if they differ. "Fail closed" means: if the
guard cannot positively confirm the right project, it refuses rather than proceeding. This is
the repository's single-project isolation policy (recorded in the root `CLAUDE.md`). This plan
does **not** weaken that guard — it relocates it into one shared file and makes the *compared
project value* configurable instead of the literal `tan-nb-exp`.

**What a "heredoc" is.** A heredoc (here-document) is bash syntax that feeds a block of text
to a command's standard input, written as `command <<MARKER ... MARKER`. `scripts/restore-volume.sh`
uses heredocs to pipe Kubernetes YAML manifests into `kubectl apply -f -`. Shell variables
inside an *unquoted-marker* heredoc are expanded, so `${TARGET_PROJECT}` placed inside one is
substituted with the variable's value at render time. (A *quoted-marker* heredoc, written
`<<'MARKER'`, does not expand variables — `scripts/nix-builder-startup.sh.tpl` uses quoted
markers for its systemd units precisely so their `$`-containing bodies are emitted literally.)

**What "template substitution" is.** `scripts/setup-nix-builder.sh` reads the file
`scripts/nix-builder-startup.sh.tpl`, replaces the placeholder `@BUILDER_PUBKEY@` with the
host's builder public key using `sed`, and writes the result to a temp file used as the VM's
startup script (line 93: `sed "s|@BUILDER_PUBKEY@|$PUBKEY|" "$TEMPLATE" >"$STARTUP"`). The
`@...@` tokens are the substitution markers. This plan leaves that mechanism unchanged because
the template carries no project literal.

**What `scripts/lib/target.sh` provides (delivered by EP-60).** It is a bash file meant to be
*sourced* (run inside the current shell with `source`/`.`, not executed as a subprocess), so
the variables it sets are visible to the rest of the calling script. On source it:

1. Loads the git-ignored profile `nagare.target.env` (a sequence of `export VAR=value` lines)
   if present, applying `tan-nb-exp`/`us-west1`/`us-west1-a` as fallback defaults so an
   operator who does nothing keeps today's behavior. Precedence: a value already in the
   environment wins, then the profile value, then the fallback default.
2. Exports `TARGET_PROJECT`, `TARGET_REGION`, and `TARGET_ZONE` (the resolved GCP project,
   region, and zone), plus the other profile fields (`NAGARE_REGISTRY_HOST`,
   `NAGARE_IMAGE_BUCKET`, `NAGARE_BACKUP_BUCKET`, `NAGARE_BASE_DOMAIN`, `NAGARE_INSTANCE_NAME`,
   `NAGARE_ARTIFACT_REGISTRY_ID`).
3. Runs the fail-closed preflight (`_require_target_project`) that refuses to run — `exit 1`
   with the familiar "refusing to run..." message — unless the active project equals
   `$TARGET_PROJECT`.

Because the helper runs the preflight on source, each consuming script replaces its six-line
inline block with a single `source` line. The exact contract (variable names, exit behavior)
is restated in **Interfaces and Dependencies**; verify it against EP-60 before starting.

**The eight scripts in scope and their current bindings** (line numbers verified against the
working tree at the time of writing; re-read before editing in case they have shifted):

- `scripts/backup-postgres.sh` — inline preflight at lines 8–14; reads `BACKUP_BUCKET` at 16.
- `scripts/restore-postgres.sh` — inline preflight at lines 5–10; reads `BACKUP_BUCKET` at 11.
- `scripts/restore-sqlite.sh` — inline preflight at lines 5–10; reads `BACKUP_BUCKET` at 11.
- `scripts/restore-volume.sh` — inline preflight at lines 20–26; in-cluster manifest pins
  `CLOUDSDK_CORE_PROJECT` to `"tan-nb-exp"` at line 84; comments at 20 and 56 mention the
  literal.
- `scripts/iap-ssh.sh` — header comment at 37; inline preflight at lines 40–45; uses
  `--project="${PROJECT}"` at lines 112 and 363.
- `scripts/setup-nix-builder.sh` — `PROJECT`/`REGION`/`ZONE` literals at 26–28; inline
  preflight at 32–37; resource names at 38–42; many `--project="$PROJECT"`, `--region="$REGION"`,
  `--zone="$ZONE"` call sites throughout.
- `scripts/upload-images.sh` — `PROJECT=tan-nb-exp` at 12; inline preflight at 13–19;
  `REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"` at 25; `BUILDER_INSTANCE` already overridable
  at 26; reads `imageBucket` via `pulumi config get` at 32; writes `nagareImageSelfLink` at 134.
- `scripts/nix-builder-startup.sh.tpl` — template with `@BUILDER_PUBKEY@` only; **no project
  literal** (see Surprises & Discoveries).

Plus the two cdn-spike example scripts:

- `cluster/examples/cdn-spike/gcp-cdn-up.sh` — comment at 32; inline preflight at 33–38;
  `ZONE=us-west1-a` at 43; `g()` wrapper appends `--project="$PROJECT"` at 52.
- `cluster/examples/cdn-spike/gcp-cdn-down.sh` — comment at 11; inline preflight at 12–17;
  `ZONE=us-west1-a` at 19; `g()` wrapper at 28.

**What already needs no change.** The backup/restore scripts already read their bucket from an
environment variable (`BACKUP_BUCKET`), not a literal — this plan only reconciles that name
with the profile's `NAGARE_BACKUP_BUCKET` (see Decision Log). `upload-images.sh` already reads
the image bucket from Pulumi config (`pulumi config get imageBucket`) and already makes
`BUILDER_INSTANCE` overridable — those stay. The `.envrc` itself is **owned and rewritten by
EP-60** (it sources the profile with fallback defaults); this plan does not edit `.envrc`. The
"finalize `.envrc` consumption" framing means: once EP-60's `.envrc` exports the profile values
into the shell, the scripts in this plan consume them (directly via the environment, and via
the helper). If, when starting this plan, EP-60 has not yet rewritten `.envrc`, confirm with
EP-60's owner; do not duplicate that rewrite here.


## Plan of Work

The work is mechanical and low-risk: each edit removes a hard-coded value and replaces it with
a sourced helper or an environment variable, preserving the fail-closed safety guarantee. It
is grouped into three milestones by the *kind* of change, so each can be verified independently.

Throughout, the canonical way a script in `scripts/` loads the helper is:

```bash
source "$(dirname "$0")/lib/target.sh"
```

`$(dirname "$0")` is the directory the script lives in (`scripts/`), so this resolves to
`scripts/lib/target.sh` regardless of the caller's working directory. For the two cdn-spike
scripts, which live in `cluster/examples/cdn-spike/`, the path to the helper is three levels up
plus `scripts/`:

```bash
source "$(cd "$(dirname "$0")/../../../scripts" && pwd)/lib/target.sh"
```

The `cd ... && pwd` normalizes the path so the `source` works no matter where the operator
invokes the script from.

### Milestone M1 — The simple-preflight scripts

Scope: the four scripts whose only project binding is the inline preflight — `backup-postgres.sh`,
`restore-postgres.sh`, `restore-sqlite.sh`, and `iap-ssh.sh` — plus the bucket-name
reconciliation in the three backup/restore scripts. At the end of M1, none of these four
contains `tan-nb-exp`, each loads the helper, and `iap-ssh.sh`'s two `gcloud` call sites use
`${TARGET_PROJECT}`.

Work: in each of the three backup/restore scripts, delete the inline preflight block and
insert `source "$(dirname "$0")/lib/target.sh"` immediately after the `set -euo pipefail` line.
Then change the bucket line to fall back to the profile value. In `iap-ssh.sh`, do the same
preflight replacement, update the header comment that names `tan-nb-exp`, and replace the two
`gcloud --project="${PROJECT}"` occurrences with `gcloud --project="${TARGET_PROJECT}"`.

Commands to run (from the repo root): for each script, `bash -n scripts/<name>.sh` (syntax
check) and a dry-run that exercises the preflight (see Concrete Steps). Acceptance: with the
active project `tan-nb-exp`, the preflight passes and the script proceeds to its first real
action; with `CLOUDSDK_CORE_PROJECT=wrong-project`, the script prints "refusing to run..." and
exits 1.

### Milestone M2 — The image/builder pipeline

Scope: `scripts/setup-nix-builder.sh` and `scripts/upload-images.sh`. At the end of M2, both
source the helper, neither contains a region/zone/project literal, the builder resource names
are env-overridable with today's defaults, and `upload-images.sh` derives its region from
`TARGET_REGION` while still reading the image bucket from Pulumi config and writing the
per-target image self-link back.

Work for `setup-nix-builder.sh`: delete lines 26–37 (`PROJECT`/`REGION`/`ZONE` literals and the
inline preflight) and replace with the helper source; then mechanically replace `$PROJECT` →
`$TARGET_PROJECT`, `$REGION` → `$TARGET_REGION`, `$ZONE` → `$TARGET_ZONE` at every call site
(the `services enable`, VPC, subnet, firewall, instance, disk, tunnel, and stop calls). Make the
resource-name assignments env-overridable: `NETWORK="${NIX_BUILDER_NETWORK:-nix-builder-net}"`
and the analogous lines for `SUBNET`, `SUBNET_CIDR`, `FIREWALL`, `INSTANCE`. Add a one-line
comment above them explaining they are not profile fields but are overridable to avoid
cross-operator name collisions in a shared project. Leave the `@BUILDER_PUBKEY@` template
substitution (line 93) untouched.

Work for `upload-images.sh`: delete lines 12–19 (the `PROJECT` literal and inline preflight)
and replace with the helper source; change line 25 from
`REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"` to `REGION="${TARGET_REGION}"` for consistency
(the helper already resolves `CLOUDSDK_COMPUTE_REGION` into `TARGET_REGION`); replace the three
remaining `${PROJECT}` references (the `gsutil mb -p`, the `compute images describe`, and the
`compute images create`/final `describe`) with `${TARGET_PROJECT}`. **Keep** the
`pulumi config get imageBucket` read (line 32) and the `pulumi config set nagareImageSelfLink`
write (line 134) exactly as they are, and add a comment at the write site noting that the
self-link embeds the project and must therefore be regenerated per target and never committed
for a foreign project (this is MasterPlan Integration Point 3).

Commands: `bash -n` on both; for `upload-images.sh`, a dry-run of the preflight; for
`setup-nix-builder.sh`, a dry-run that reaches the first `gcloud` call under a wrong project and
refuses. Acceptance: `grep -n 'tan-nb-exp\|us-west1' scripts/setup-nix-builder.sh scripts/upload-images.sh`
returns nothing; the preflight passes under `tan-nb-exp` and fails closed otherwise.

### Milestone M3 — In-cluster manifest, comments, and the cdn-spike scripts

Scope: `scripts/restore-volume.sh` (the in-cluster manifest project binding) and the two
cdn-spike example scripts. At the end of M3, the restore-volume Job manifest interpolates the
configured project, and the cdn-spike scripts source the helper and use `TARGET_ZONE`.

Work for `restore-volume.sh`: delete the inline preflight (lines 20–26) and source the helper.
In the second heredoc (the Job manifest), change line 84 from
`{ name: CLOUDSDK_CORE_PROJECT, value: "tan-nb-exp" }` to
`{ name: CLOUDSDK_CORE_PROJECT, value: "${TARGET_PROJECT}" }`. The heredoc marker is the
unquoted `YAML`, so `${TARGET_PROJECT}` is expanded at render time — verify the marker is
`<<YAML` (unquoted), not `<<'YAML'`; it is unquoted today because other `${...}` substitutions
(`${SCRATCH_PVC}`, `${NS}`, `${OBJECT}`) already expand in it. Update the two comments (lines 20
and 56) that say "tan-nb-exp" to say "the configured target project".

Work for the cdn-spike scripts: in both `gcp-cdn-up.sh` and `gcp-cdn-down.sh`, delete the inline
preflight, source the helper with the path-adjusted form shown above, replace `ZONE=us-west1-a`
with `ZONE="${TARGET_ZONE}"`, and change the `g()` wrapper's `--project="$PROJECT"` to
`--project="$TARGET_PROJECT"` (and any other `--project=${PROJECT}` references in their help
text / final echoes). Update the comment that names `tan-nb-exp`. The `cdn-spike-*` resource
names stay as literals (Decision Log).

Commands: `bash -n` on all three; render the restore-volume manifest without applying it (a
dry-run that echoes the heredoc body — see Concrete Steps) and confirm it contains the
configured project; preflight dry-runs on the cdn-spike scripts. Acceptance: a repo-wide
`grep -rn 'tan-nb-exp' scripts/ cluster/examples/cdn-spike/` returns nothing, and a rendered
restore-volume manifest shows `CLOUDSDK_CORE_PROJECT` set to the configured project value.


## Concrete Steps

All commands below are run from the repository root
`/Users/shinzui/Keikaku/bokuno/nagare` inside the dev shell (`direnv allow` once, or
`nix develop`). The before/after diffs are the authoritative edits.

### M1 — backup-postgres.sh

```diff
--- a/scripts/backup-postgres.sh
+++ b/scripts/backup-postgres.sh
@@
 set -euo pipefail

-# --- Integration Point 9 preflight: refuse to run outside tan-nb-exp ---
-PROJECT=tan-nb-exp
-ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
-if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
-  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
-  exit 1
-fi
+# Load the target profile and run the configurable, fail-closed project-isolation
+# preflight (EP-60). Refuses to run unless gcloud's active project equals the
+# configured TARGET_PROJECT.
+source "$(dirname "$0")/lib/target.sh"

-BUCKET="${BACKUP_BUCKET:?set BACKUP_BUCKET to the backupBucket stack output}"
+BUCKET="${BACKUP_BUCKET:-${NAGARE_BACKUP_BUCKET:?set BACKUP_BUCKET or NAGARE_BACKUP_BUCKET to the backup bucket name}}"
```

### M1 — restore-postgres.sh

```diff
--- a/scripts/restore-postgres.sh
+++ b/scripts/restore-postgres.sh
@@
 set -euo pipefail
-PROJECT=tan-nb-exp
-ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
-if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
-  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
-  exit 1
-fi
-BUCKET="${BACKUP_BUCKET:?set BACKUP_BUCKET}"
+source "$(dirname "$0")/lib/target.sh"
+BUCKET="${BACKUP_BUCKET:-${NAGARE_BACKUP_BUCKET:?set BACKUP_BUCKET or NAGARE_BACKUP_BUCKET}}"
```

### M1 — restore-sqlite.sh

```diff
--- a/scripts/restore-sqlite.sh
+++ b/scripts/restore-sqlite.sh
@@
 set -euo pipefail
-PROJECT=tan-nb-exp
-ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
-if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
-  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
-  exit 1
-fi
-BUCKET="${BACKUP_BUCKET:?set BACKUP_BUCKET}"
+source "$(dirname "$0")/lib/target.sh"
+BUCKET="${BACKUP_BUCKET:-${NAGARE_BACKUP_BUCKET:?set BACKUP_BUCKET or NAGARE_BACKUP_BUCKET}}"
```

### M1 — iap-ssh.sh

Replace the header comment and the inline preflight, and update the two `gcloud` call sites.

```diff
--- a/scripts/iap-ssh.sh
+++ b/scripts/iap-ssh.sh
@@
-# Project isolation: gcloud's active project must be tan-nb-exp (see CLAUDE.md).
+# Project isolation: gcloud's active project must equal the configured target
+# project (TARGET_PROJECT from the profile; see CLAUDE.md and EP-60).
 set -euo pipefail

-PROJECT=tan-nb-exp
-ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
-if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
-  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
-  exit 1
-fi
+source "$(dirname "$0")/lib/target.sh"
```

The two tunnel call sites (lines 112 and 363 in the current file) change from `${PROJECT}` to
`${TARGET_PROJECT}`:

```diff
-  gcloud --project="${PROJECT}" compute start-iap-tunnel "${instance}" "${remote_port}" \
+  gcloud --project="${TARGET_PROJECT}" compute start-iap-tunnel "${instance}" "${remote_port}" \
```

```diff
-  gcloud --project="${PROJECT}" compute start-iap-tunnel "${instance}" "${remote_port}" \
+  gcloud --project="${TARGET_PROJECT}" compute start-iap-tunnel "${instance}" "${remote_port}" \
```

Note `iap-ssh.sh` also has a `ZONE="${ZONE:-$(gcloud config get-value compute/zone ...)}"`
fallback (line 62). The helper already exports `TARGET_ZONE`; leave `iap-ssh.sh`'s `ZONE`
resolution as-is (it honors an explicitly passed `ZONE` and otherwise falls back to gcloud's
active zone, which the profile/`.envrc` set), so it continues to work unchanged.

After all M1 edits, syntax-check and dry-run:

```bash
for s in backup-postgres restore-postgres restore-sqlite iap-ssh; do
  bash -n "scripts/${s}.sh" && echo "OK ${s}"
done
```

Expected:

```text
OK backup-postgres
OK restore-postgres
OK restore-sqlite
OK iap-ssh
```

### M2 — setup-nix-builder.sh

```diff
--- a/scripts/setup-nix-builder.sh
+++ b/scripts/setup-nix-builder.sh
@@
 set -euo pipefail

-PROJECT=tan-nb-exp
-REGION=us-west1
-ZONE=us-west1-a
-
-# Project-isolation guard: fail closed if anything has misconfigured
-# gcloud's active project. See CLAUDE.md for the policy.
-ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
-if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
-  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
-  echo "fix: 'direnv allow' in the repo root, or 'export CLOUDSDK_CORE_PROJECT=$PROJECT'." >&2
-  exit 1
-fi
-NETWORK=nix-builder-net
-SUBNET=nix-builder-subnet
-SUBNET_CIDR=10.10.0.0/24
-FIREWALL=nix-builder-iap-ssh
-INSTANCE=nix-builder-x86
+# Load the target profile and run the configurable, fail-closed project-isolation
+# preflight (EP-60). Exports TARGET_PROJECT / TARGET_REGION / TARGET_ZONE.
+source "$(dirname "$0")/lib/target.sh"
+PROJECT="$TARGET_PROJECT"
+REGION="$TARGET_REGION"
+ZONE="$TARGET_ZONE"
+
+# Builder resource names. These are NOT target-profile fields — they name
+# resources this script creates inside $PROJECT. They are env-overridable so a
+# second operator sharing a project can avoid name collisions without editing
+# this file; the defaults preserve today's behavior.
+NETWORK="${NIX_BUILDER_NETWORK:-nix-builder-net}"
+SUBNET="${NIX_BUILDER_SUBNET:-nix-builder-subnet}"
+SUBNET_CIDR="${NIX_BUILDER_SUBNET_CIDR:-10.10.0.0/24}"
+FIREWALL="${NIX_BUILDER_FIREWALL:-nix-builder-iap-ssh}"
+INSTANCE="${NIX_BUILDER_INSTANCE:-nix-builder-x86}"
```

The rest of the script already references `$PROJECT`, `$REGION`, `$ZONE`, `$NETWORK`,
`$SUBNET`, `$FIREWALL`, `$INSTANCE` by name, so binding them to the profile values above is
sufficient — no further edits are needed in the body. (Assigning `PROJECT=$TARGET_PROJECT`
etc. keeps the diff minimal and leaves every downstream `--project="$PROJECT"` working.)

### M2 — upload-images.sh

```diff
--- a/scripts/upload-images.sh
+++ b/scripts/upload-images.sh
@@
 set -euo pipefail

-PROJECT=tan-nb-exp
-# IP-9 project-isolation guard: fail closed if gcloud's active project is wrong.
-ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
-if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
-  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
-  echo "fix: 'direnv allow' in the repo root, or 'export CLOUDSDK_CORE_PROJECT=$PROJECT'." >&2
-  exit 1
-fi
+# Load the target profile and run the configurable, fail-closed project-isolation
+# preflight (EP-60). Exports TARGET_PROJECT / TARGET_REGION / TARGET_ZONE.
+source "$(dirname "${BASH_SOURCE[0]}")/lib/target.sh"
+PROJECT="$TARGET_PROJECT"

 REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
 NIXOS_DIR="${REPO_ROOT}/nixos"
 PULUMI_DIR="${REPO_ROOT}/infra/pulumi"
 IAP_SSH="${REPO_ROOT}/scripts/iap-ssh.sh"
-REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"
+REGION="${TARGET_REGION}"
 BUILDER_INSTANCE="${BUILDER_INSTANCE:-nix-builder-x86}"
```

Note this script uses `${BASH_SOURCE[0]}` rather than `$0` for path resolution (it does so
already for `REPO_ROOT`), so the helper is sourced via `dirname "${BASH_SOURCE[0]}"` to match.
Binding `PROJECT="$TARGET_PROJECT"` keeps the existing `--project="${PROJECT}"` call sites and
the `gsutil mb -p "${PROJECT}"` working unchanged.

Add the per-target self-link note at the write site (around line 133–134):

```diff
-log "pulumi config set nagareImageSelfLink ${self_link}"
+# The self-link embeds the project (.../projects/<project>/global/images/...), so it
+# is target-specific: it must be regenerated per target and never committed for a
+# foreign project (MasterPlan-12 Integration Point 3). `pulumi config set` writes it
+# into the local stack config, which is a derived projection of the profile.
+log "pulumi config set nagareImageSelfLink ${self_link}"
 pulumi --cwd "${PULUMI_DIR}" config set nagareImageSelfLink "${self_link}"
```

Verify M2:

```bash
bash -n scripts/setup-nix-builder.sh && echo OK setup
bash -n scripts/upload-images.sh && echo OK upload
grep -n 'tan-nb-exp\|us-west1' scripts/setup-nix-builder.sh scripts/upload-images.sh || echo "no literals"
```

Expected:

```text
OK setup
OK upload
no literals
```

### M3 — restore-volume.sh

```diff
--- a/scripts/restore-volume.sh
+++ b/scripts/restore-volume.sh
@@
 set -euo pipefail

-# --- project-isolation preflight: refuse to run outside tan-nb-exp ---
-PROJECT=tan-nb-exp
-ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
-if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
-  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
-  exit 1
-fi
+# Load the target profile and run the configurable, fail-closed project-isolation
+# preflight (EP-60). Exports TARGET_PROJECT for the in-cluster manifest below.
+source "$(dirname "$0")/lib/target.sh"
```

In the Job manifest heredoc (unquoted `<<YAML`), and the comment above it:

```diff
-#    then print a listing. ADC resolves the node service account via the metadata
-#    IP; the project is pinned to tan-nb-exp (in-cluster analogue of the preflight).
+#    then print a listing. ADC resolves the node service account via the metadata
+#    IP; the project is pinned to the configured target project (in-cluster
+#    analogue of the preflight).
@@
-            - { name: CLOUDSDK_CORE_PROJECT, value: "tan-nb-exp" }
+            - { name: CLOUDSDK_CORE_PROJECT, value: "${TARGET_PROJECT}" }
```

### M3 — cdn-spike/gcp-cdn-up.sh

```diff
--- a/cluster/examples/cdn-spike/gcp-cdn-up.sh
+++ b/cluster/examples/cdn-spike/gcp-cdn-up.sh
@@
 set -euo pipefail

-# --- Project isolation preflight (CLAUDE.md): refuse to run outside tan-nb-exp ---
-PROJECT=tan-nb-exp
-ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
-if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
-  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
-  exit 1
-fi
+# Load the target profile and run the configurable, fail-closed project-isolation
+# preflight (EP-60). Exports TARGET_PROJECT / TARGET_ZONE.
+source "$(cd "$(dirname "$0")/../../../scripts" && pwd)/lib/target.sh"
+PROJECT="$TARGET_PROJECT"

 HC_HOST="${HC_HOST:?set HC_HOST to a known Knative ksvc hostname (e.g. notes.personal.apps.example.com)}"
 HC_PATH="${HC_PATH:-/}"

-ZONE=us-west1-a
+ZONE="$TARGET_ZONE"
```

Binding `PROJECT="$TARGET_PROJECT"` keeps the `g() { gcloud "$@" --project="$PROJECT"; }`
wrapper and the help-text `--project=${PROJECT}` lines working unchanged.

### M3 — cdn-spike/gcp-cdn-down.sh

```diff
--- a/cluster/examples/cdn-spike/gcp-cdn-down.sh
+++ b/cluster/examples/cdn-spike/gcp-cdn-down.sh
@@
 set -euo pipefail

-# --- Project isolation preflight (CLAUDE.md): refuse to run outside tan-nb-exp ---
-PROJECT=tan-nb-exp
-ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
-if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
-  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
-  exit 1
-fi
+# Load the target profile and run the configurable, fail-closed project-isolation
+# preflight (EP-60). Exports TARGET_PROJECT / TARGET_ZONE.
+source "$(cd "$(dirname "$0")/../../../scripts" && pwd)/lib/target.sh"
+PROJECT="$TARGET_PROJECT"

-ZONE=us-west1-a
+ZONE="$TARGET_ZONE"
```

Verify M3:

```bash
bash -n scripts/restore-volume.sh && echo OK restore-volume
bash -n cluster/examples/cdn-spike/gcp-cdn-up.sh && echo OK cdn-up
bash -n cluster/examples/cdn-spike/gcp-cdn-down.sh && echo OK cdn-down
grep -rn 'tan-nb-exp\|us-west1-a' scripts/ cluster/examples/cdn-spike/*.sh || echo "no literals"
```

Expected:

```text
OK restore-volume
OK cdn-up
OK cdn-down
no literals
```

(The `cluster/examples/cdn-spike/README.md` still contains `tan-nb-exp`/`us-west1-a` as worked
examples in prose; updating that prose belongs to the documentation plan EP-64. The grep above
deliberately scopes to `*.sh`.)


## Validation and Acceptance

Acceptance is observable behavior, not edited lines. Run all commands from the repo root in the
dev shell. The two behaviors to prove are (a) the default profile preserves today's behavior
and (b) the preflight fails closed on a wrong project, and (c) a rendered manifest carries the
configured project rather than a literal.

**Precondition — the helper exists.** Confirm EP-60 delivered the helper before validating:

```bash
test -f scripts/lib/target.sh && echo "helper present" || echo "MISSING: EP-60 not done"
```

Expected: `helper present`.

**(a) Default profile passes the preflight as `tan-nb-exp`.** With `.envrc` loaded (or
`nagare.target.env` absent so the fallback default applies), the active project resolves to
`tan-nb-exp`. Source any rewritten script's helper and observe no refusal. A clean way to prove
the guard without running the whole script is to source the helper directly:

```bash
( unset BACKUP_BUCKET; CLOUDSDK_CORE_PROJECT=tan-nb-exp bash -c '
    source scripts/lib/target.sh
    echo "preflight passed; TARGET_PROJECT=$TARGET_PROJECT TARGET_REGION=$TARGET_REGION TARGET_ZONE=$TARGET_ZONE"' )
```

Expected (default fallbacks):

```text
preflight passed; TARGET_PROJECT=tan-nb-exp TARGET_REGION=us-west1 TARGET_ZONE=us-west1-a
```

**(b) Wrong project fails closed.** Set the active project to something else and confirm the
script refuses before doing any work. Use a script that exits early after the preflight:

```bash
CLOUDSDK_CORE_PROJECT=wrong-project bash scripts/backup-postgres.sh; echo "exit=$?"
```

Expected:

```text
refusing to run: gcloud active project is 'wrong-project', expected 'tan-nb-exp'.
exit=1
```

(The exact wording comes from EP-60's helper; if EP-60 phrased the message differently, match
its wording. The load-bearing observable is the non-zero exit before any `gcloud`/`gsutil`/`pg_dump`
call runs.) Repeat the same `CLOUDSDK_CORE_PROJECT=wrong-project` invocation against
`scripts/restore-postgres.sh`, `scripts/restore-sqlite.sh`, `scripts/upload-images.sh`,
`scripts/setup-nix-builder.sh`, `scripts/restore-volume.sh`, and both cdn-spike scripts; each
must print the refusal and exit 1.

**(c) A different configured project flows through, and the in-cluster manifest carries it.**
Simulate a second operator's profile by exporting a different project (the helper honors an
already-set environment value), then render the restore-volume Job manifest *without applying
it*. The cleanest proof is to extract just the manifest heredoc by running the script up to the
`kubectl apply` and redirecting `kubectl` to a no-op. A simpler, self-contained check is to
confirm the substitution directly:

```bash
CLOUDSDK_CORE_PROJECT=acme-prod bash -c '
  source scripts/lib/target.sh 2>/dev/null
  printf "CLOUDSDK_CORE_PROJECT value in rendered manifest: \"%s\"\n" "${TARGET_PROJECT}"'
```

Expected:

```text
CLOUDSDK_CORE_PROJECT value in rendered manifest: "acme-prod"
```

To prove it end-to-end inside the actual heredoc without touching a cluster, temporarily alias
`kubectl` to `cat` for one invocation (this prints the manifest the script would apply):

```bash
CLOUDSDK_CORE_PROJECT=acme-prod \
  bash -c 'kubectl() { cat; }; export -f kubectl;
           source scripts/lib/target.sh 2>/dev/null;
           bash <(sed "1,/^set -euo pipefail$/d" scripts/restore-volume.sh) \
             gs://acme-bucket/volumes/app/data/x.tar.gz 2>/dev/null' \
  | grep CLOUDSDK_CORE_PROJECT
```

Expected (the literal `tan-nb-exp` must NOT appear):

```text
            - { name: CLOUDSDK_CORE_PROJECT, value: "acme-prod" }
```

If you see `value: "tan-nb-exp"`, the heredoc substitution did not take — check that the
manifest marker is the unquoted `<<YAML` and that `${TARGET_PROJECT}` (not `$TARGET_PROJECT`
inside a single-quoted context) was used.

**(d) Pulumi preview still works under the default profile.** The Pulumi program is unaffected
by this plan, but `just infra-preview` exercises the end-to-end environment and should be green
under the default profile:

```bash
just infra-preview
```

Expected: a normal Pulumi preview (resource diff or "no changes"), with no refusal and no
literal-project error. (This requires a working local Pulumi state per `.envrc`; if the stack
is not initialized in your checkout, this step is informational — the script-level acceptance
in (a)–(c) is the binding gate for this plan.)

**(e) No literals remain in scripts.** The decisive whole-tree check:

```bash
grep -rn 'tan-nb-exp\|us-west1-a\|us-west1' scripts/ cluster/examples/cdn-spike/*.sh
```

Expected: no output. (Prose in `README.md` files is out of scope here; see EP-64.)


## Idempotence and Recovery

Every edit in this plan is a pure source change to a shell script; nothing here mutates cloud
state, so the edits are trivially safe to repeat and reverse. The scripts themselves remain as
idempotent as they were before — `setup-nix-builder.sh` still only creates missing resources,
`upload-images.sh` still reuses existing GCS objects and registered images, and the restore
scripts still write to scratch databases/PVCs and never touch live data.

If a `source` line is mistyped (wrong relative path), the script fails immediately with a
"No such file or directory" from bash before any cloud call, because `source` of a missing
file under `set -euo pipefail` aborts the script. That is a safe, loud failure: re-check the
path and re-run.

If, mid-migration, EP-60's helper is not yet present, the scripts will fail to source it and
refuse to run — which is the correct fail-closed behavior. Do not work around it by restoring
inline preflights; instead complete or confirm EP-60 first.

To roll back any single script, revert that file with `git checkout -- <path>`; the scripts are
independent, so a partial migration leaves the un-migrated scripts working exactly as before
(they still carry their own inline preflight until edited).


## Interfaces and Dependencies

This plan **consumes** the contract defined by EP-60
(`docs/plans/60-target-profile-model-and-configurable-isolation-guardrail.md`) and **produces**
no new interface of its own. The exact contract it relies on — verify each item against EP-60's
delivered `scripts/lib/target.sh` before starting:

1. **File location.** `scripts/lib/target.sh` exists and is meant to be *sourced* (with
   `source`/`.`), not executed. Sourcing it from a script in `scripts/` is
   `source "$(dirname "$0")/lib/target.sh"`; from `cluster/examples/cdn-spike/` it is
   `source "$(cd "$(dirname "$0")/../../../scripts" && pwd)/lib/target.sh"`.

2. **Exported variables.** After sourcing, these shell variables are set and exported:
   `TARGET_PROJECT` (resolved GCP project id), `TARGET_REGION` (e.g. `us-west1`),
   `TARGET_ZONE` (e.g. `us-west1-a`), and the remaining profile fields
   `NAGARE_REGISTRY_HOST`, `NAGARE_IMAGE_BUCKET`, `NAGARE_BACKUP_BUCKET`, `NAGARE_BASE_DOMAIN`,
   `NAGARE_INSTANCE_NAME`, `NAGARE_ARTIFACT_REGISTRY_ID`. This plan uses `TARGET_PROJECT`,
   `TARGET_REGION`, `TARGET_ZONE`, and `NAGARE_BACKUP_BUCKET`.

3. **Resolution precedence.** A value already present in the environment wins; otherwise the
   `nagare.target.env` profile value applies; otherwise the fallback default (the `tan-nb-exp`
   / `us-west1` / `us-west1-a` value) applies. This is what makes the default profile preserve
   today's behavior and lets an operator who exports `CLOUDSDK_CORE_PROJECT` (or sets a profile)
   redirect every script at once.

4. **Fail-closed preflight on source.** Sourcing the helper runs the equivalent of
   `_require_target_project`: if `gcloud`'s active project (from `CLOUDSDK_CORE_PROJECT`, or
   `gcloud config get-value project`) does not equal `$TARGET_PROJECT`, the helper prints a
   "refusing to run..." message to stderr and `exit 1`s the calling script. This replaces the
   inline six-line preflight one-for-one and must not be weakened.

If EP-60 named any of these differently (variable names, helper path, or message wording),
update the edits in this plan to match EP-60's actual contract and record the discrepancy in
the Decision Log — EP-60 is the single source of truth for the names.

This plan has no other external dependencies. It touches only bash scripts; it adds no
libraries, services, or build steps. The `just` recipes (`just host-image`, etc.) call these
scripts unchanged — their behavior is preserved because the scripts read their target from the
same environment the recipes already run under.
