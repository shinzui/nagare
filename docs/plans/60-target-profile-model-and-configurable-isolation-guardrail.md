---
id: 60
slug: target-profile-model-and-configurable-isolation-guardrail
title: "Target profile model and configurable isolation guardrail"
kind: exec-plan
created_at: 2026-06-10T21:59:38Z
intention: "intention_01ktsq8wese1hv93x9fk8d369a"
master_plan: "docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md"
---

# Target profile model and configurable isolation guardrail

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today **nagare** — a single-node personal Platform-as-a-Service running on one Google Cloud
virtual machine — is welded to exactly one Google Cloud Platform (GCP) project, `tan-nb-exp`,
in region `us-west1`, zone `us-west1-a`. That binding is not one configuration value; it is a
hard-coded literal copy-pasted into the repo-root `.envrc`, into a six-line "refuse to run unless
the active project is `tan-nb-exp`" guard at the top of every shell script under `scripts/`, and
the project's `CLAUDE.md` declares the single-project binding an immutable policy. There is no
supported way for a second person — or the same person with a second GCP project — to point
nagare at their own account without editing tracked source files.

This ExecPlan lays the **foundation** that makes the GCP target configurable. It does exactly two
user-visible things and nothing more (the larger consumer rewrites belong to later plans, see
"Context and Orientation"):

1. It defines the **target profile**: a single, git-ignored file `nagare.target.env` at the
   repository root that holds the operator's GCP target — project, region, zone, and the derived
   names (Artifact Registry host and id, image bucket, backup bucket, base domain, instance name)
   — as plain `export VAR=value` shell lines. A tracked `nagare.target.env.example` documents the
   schema and ships the current `tan-nb-exp` values as the worked example, so an operator who does
   nothing keeps today's behavior, and a new operator copies the example and edits one project id.

2. It makes the **isolation guardrail configurable while keeping it fail-closed**. A single new
   sourced helper, `scripts/lib/target.sh`, loads the profile (if present), sets
   `TARGET_PROJECT`/`TARGET_REGION`/`TARGET_ZONE` (falling back to the `tan-nb-exp`/`us-west1`/
   `us-west1-a` defaults), and exposes one function `_require_target_project` that refuses to run
   unless gcloud's active project equals the configured `TARGET_PROJECT`. This replaces the
   six-line preflight currently duplicated in every script. The guardrail is **not weakened** — it
   still aborts on a mismatch — it now asserts against the *configured* project rather than the
   literal `tan-nb-exp`.

After this change an operator can do the following, and *see* it working without any cloud call:

- Run `direnv allow` in a fresh checkout with no profile file present, then
  `echo $CLOUDSDK_CORE_PROJECT` prints `tan-nb-exp` — today's behavior is preserved by the
  fallback defaults.
- Copy `nagare.target.env.example` to `nagare.target.env`, change `CLOUDSDK_CORE_PROJECT` to (say)
  `acme-prod`, re-enter the directory, and `echo $CLOUDSDK_CORE_PROJECT` now prints `acme-prod`;
  a script that sources `scripts/lib/target.sh` reports `TARGET_PROJECT=acme-prod`.
- With the profile pointing at `acme-prod` but gcloud's active project left at something else,
  any script sourcing the helper **fails closed** with a clear message and a fix hint, exactly as
  before — proving the guardrail still bites, now against the configured project.

This plan is deliberately small and sharply specified because every later plan in MasterPlan 12
(`docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md`) consumes the variable
names and the helper contract it fixes here. It writes no Haskell, touches no Pulumi program, and
makes no cloud call.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1.1 — Create the tracked schema file `nagare.target.env.example` at the repo root with the
      nine canonical `export VAR=value` lines (carrying the `tan-nb-exp` worked example) and
      explanatory comments. (2026-06-10)
- [x] M1.2 — Add `nagare.target.env` (the real, per-operator profile) to `.gitignore`. (2026-06-10)
- [x] M1.3 — Create `scripts/lib/target.sh`: a sourced helper that computes the repo root from its
      own path, loads `nagare.target.env` if present, sets `TARGET_PROJECT`/`TARGET_REGION`/
      `TARGET_ZONE` with `tan-nb-exp`/`us-west1`/`us-west1-a` fallbacks, and defines the
      fail-closed `_require_target_project` preflight. (2026-06-10)
- [x] M1.4 — Verify M1 with `bash`: sourcing the helper with no profile yields the defaults;
      copying the example and editing the project changes `TARGET_PROJECT`; a forced active-project
      mismatch makes `_require_target_project` exit non-zero with the fix message. All three
      transcripts matched. (2026-06-10)
- [ ] M2.1 — Rewrite `.envrc` to `source_env`/source the profile then export
      `CLOUDSDK_CORE_PROJECT`/`REGION`/`ZONE` with `${VAR:-default}` fallbacks, preserving the
      Pulumi exports and `use flake`.
- [ ] M2.2 — Rewrite the "GCP project isolation" section of `CLAUDE.md` to the configurable model
      and cite MasterPlan 12 as the Decision-Log entry the old policy required.
- [ ] M2.3 — Update the justfile header comment (line ~5) to describe the configurable target.
- [ ] M2.4 — Verify M2: `direnv allow` then `echo $CLOUDSDK_CORE_PROJECT` is `tan-nb-exp` with no
      profile; a profile with a different project flips the exported env var on re-entry.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The verification commands (Steps 4 and 8) use BSD `sed -i ''`, but this checkout's dev shell
  provides **GNU sed** on `PATH` (via the Nix flake), where `sed -i ''` treats `''` as a filename and
  fails (`sed: can't read s/...`). The behavior under test is unaffected — the override path works
  identically. For verification, use a non-in-place form instead, e.g.
  `sed 's/^export CLOUDSDK_CORE_PROJECT=.*/export CLOUDSDK_CORE_PROJECT=acme-prod/' nagare.target.env.example > nagare.target.env`.
  This is a test-harness detail only; no shipped file uses `sed -i`. (2026-06-10)


## Decision Log

Record every decision made while working on the plan.

- Decision: the canonical contract file is exactly `nagare.target.env` (a sequence of
  `export VAR=value` lines), tracked-example `nagare.target.env.example`; we do not also introduce
  a `.envrc.local` mechanism.
  Rationale: MasterPlan 12 Integration Point 1 fixes `nagare.target.env` as the single source of
  truth and every consumer (`.envrc`, `scripts/lib/target.sh`, `nagarectl`) reads the same file. A
  second optional include path would add a precedence question for no benefit; keep it one file.
  Date: 2026-06-10

- Decision: `.envrc` sources the profile and exports the three `CLOUDSDK_*` variables with
  `${VAR:-default}` fallbacks; it does NOT shell out to `pulumi config`.
  Rationale: MasterPlan 12 Decision Log — the target profile is canonical and Pulumi config is a
  derived projection written later by EP-63. Sourcing a plain env file is instant and works before
  any Pulumi stack exists (avoiding an onboarding chicken-and-egg). `.envrc` must stay fast on
  every `cd` into the repo.
  Date: 2026-06-10

- Decision: the first three variable names are the standard Cloud SDK ones
  (`CLOUDSDK_CORE_PROJECT`, `CLOUDSDK_COMPUTE_REGION`, `CLOUDSDK_COMPUTE_ZONE`).
  Rationale: those env vars are honored by interactive `gcloud` and by the Pulumi GCP provider
  directly, so exporting them makes the target take effect for unqualified `gcloud` calls and for
  Pulumi without extra plumbing (MasterPlan 12 Integration Point 1).
  Date: 2026-06-10

- Decision: the guardrail stays fail-closed; only the compared value becomes configurable.
  `_require_target_project` aborts unless the active project equals `$TARGET_PROJECT`.
  Rationale: MasterPlan 12 Decision Log and Integration Point 2 — "keep the single-project
  isolation guardrail, made configurable," not relaxed to per-command. Centralizing it in one
  sourced helper removes six duplicated lines per script and guarantees one enforcement path.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This plan changes only four kinds of files, all at or near the repository root. It writes no
Haskell, edits no Pulumi program, and makes no GCP call. Everything here is plain text and bash.

**What "target profile" means.** A *target profile* is a single file, `nagare.target.env`, that
lives at the repository root and is **not committed to git** (it is per-operator). It is a plain
shell fragment: a sequence of `export NAME=value` lines, nothing else. It is the single source of
truth for *which* GCP project/region/zone and *which* derived resource names nagare acts on. A
committed sibling, `nagare.target.env.example`, documents the schema and carries the existing
`tan-nb-exp` values as a worked example; an operator copies it to `nagare.target.env` and edits
it. The MasterPlan calls this file the "target profile" throughout
(`docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md`, Integration Point 1).

**What "direnv" means.** `direnv` is a tool that, when you `cd` into a directory containing an
`.envrc` file, runs that file and loads any variables it `export`s into your shell, then unloads
them when you leave. The repo's `.envrc` is what makes `gcloud` default to the right project in
any shell opened inside the repo. You must run `direnv allow` once per machine to authorize the
`.envrc` (a security gate so an untrusted `.envrc` cannot auto-run). `source_env` is a helper
function direnv provides inside `.envrc` to include another env file relative to the current one;
`use flake` is another direnv helper that loads this repo's Nix development shell onto `PATH`.

**What "preflight" means.** A *preflight* is a check a script runs at its very start, before doing
any real work, that aborts immediately if a precondition is not met. Here the precondition is
"gcloud's active project equals the configured target project."

**What "fail-closed" means.** A check is *fail-closed* (as opposed to fail-open) when, on any
doubt or mismatch, it refuses to proceed — it errs toward doing nothing rather than risk acting on
the wrong project. The guardrail in this repo is fail-closed: if the active project does not match,
the script exits non-zero and runs nothing.

**Files this plan creates.**

- `/Users/shinzui/Keikaku/bokuno/nagare/nagare.target.env.example` — NEW, tracked. The schema +
  worked example.
- `/Users/shinzui/Keikaku/bokuno/nagare/scripts/lib/target.sh` — NEW, tracked. The sourced helper.
  (The directory `scripts/lib/` does not exist yet; creating the file creates it.)

**Files this plan edits.**

- `/Users/shinzui/Keikaku/bokuno/nagare/.gitignore` — add `nagare.target.env`.
- `/Users/shinzui/Keikaku/bokuno/nagare/.envrc` — source the profile, export the three `CLOUDSDK_*`
  vars with fallbacks, keep the Pulumi exports and `use flake`.
- `/Users/shinzui/Keikaku/bokuno/nagare/CLAUDE.md` — rewrite the "GCP project isolation" section.
- `/Users/shinzui/Keikaku/bokuno/nagare/justfile` — update the header comment (around line 5).

**Where the existing inline preflight lives (the thing this plan centralizes).** Every script under
`scripts/` currently begins with its own copy of the six-line guard. Two representative copies:

`/Users/shinzui/Keikaku/bokuno/nagare/scripts/backup-postgres.sh` lines 8–14:

```bash
# --- Integration Point 9 preflight: refuse to run outside tan-nb-exp ---
PROJECT=tan-nb-exp
ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
  exit 1
fi
```

`/Users/shinzui/Keikaku/bokuno/nagare/scripts/upload-images.sh` lines 12–19 (labeled "IP-9
project-isolation guard"):

```bash
PROJECT=tan-nb-exp
# IP-9 project-isolation guard: fail closed if gcloud's active project is wrong.
ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
  echo "fix: 'direnv allow' in the repo root, or 'export CLOUDSDK_CORE_PROJECT=$PROJECT'." >&2
  exit 1
fi
```

**Scope boundary — what this plan does NOT do.** This plan does **not** edit the scripts themselves
to source the helper, and it does **not** rewrite `scripts/nix-builder-startup.sh.tpl`. Replacing
every script's inline preflight with `source "$(dirname "$0")/lib/target.sh"` is the job of EP-61
(`docs/plans/61-parameterize-shell-scripts-and-envrc-to-the-target-profile.md`). This plan only
*creates the helper they will source* and *centralizes the pattern* so EP-61 has something to call.
It also does not touch the Haskell CLI `nagarectl` (that is EP-62), the Pulumi program or its config
(EP-62/EP-63), or the user-facing docs (EP-64). Keeping this plan to the contract + helper + `.envrc`
+ `CLAUDE.md` + the justfile comment is deliberate so the parallel consumer plans can start
immediately against a fixed contract (MasterPlan 12, Decomposition Strategy).

**The canonical variable list (every consumer reads these names verbatim).** From MasterPlan 12
Integration Point 1, the schema is exactly these nine variables, with their `tan-nb-exp` defaults
and how derived ones are formed:

- `CLOUDSDK_CORE_PROJECT` — GCP project id. Default `tan-nb-exp`.
- `CLOUDSDK_COMPUTE_REGION` — compute region. Default `us-west1`.
- `CLOUDSDK_COMPUTE_ZONE` — compute zone. Default `us-west1-a`.
- `NAGARE_REGISTRY_HOST` — Artifact Registry Docker host, derived as `<region>-docker.pkg.dev`.
  Default `us-west1-docker.pkg.dev`.
- `NAGARE_ARTIFACT_REGISTRY_ID` — Artifact Registry repository id. Default `nagare`.
- `NAGARE_IMAGE_BUCKET` — GCS bucket for NixOS image tarballs, derived as `<project>-nagare-images`.
  Default `tan-nb-exp-nagare-images`.
- `NAGARE_BACKUP_BUCKET` — GCS bucket for database/volume backups, derived as
  `<project>-nagare-backups`. Default `tan-nb-exp-nagare-backups`.
- `NAGARE_BASE_DOMAIN` — wildcard apps domain. Default `apps.example.com`.
- `NAGARE_INSTANCE_NAME` — the VM instance name. Default `nagare-01`.

The first three reuse the standard Cloud SDK variable names so interactive `gcloud` and the Pulumi
GCP provider also honor them. Precedence across the whole system (fixed by the MasterPlan, and
realized by the `${VAR:-default}` form used here): a value already present in the environment wins;
otherwise the profile value applies; otherwise the fallback default (the `tan-nb-exp` value)
applies — so an operator who does nothing keeps today's behavior.


## Plan of Work

The work is two milestones. M1 creates the contract artifacts and the guardrail helper and is fully
verifiable with `bash` alone — no cloud, no direnv. M2 wires the contract into the shell-entry path
(`.envrc`), the agent policy (`CLAUDE.md`), and the runner banner (`justfile`), and is verifiable
with `direnv allow` and an `echo`. Each milestone ends in observable behavior, not just an added
file.


### Milestone 1 — contract files and the guardrail helper

Scope: at the end of M1 the repository contains a tracked `nagare.target.env.example` documenting
the nine-variable schema with the `tan-nb-exp` worked example; `.gitignore` ignores the real
`nagare.target.env`; and `scripts/lib/target.sh` exists as a sourceable helper that loads the
profile, sets `TARGET_PROJECT`/`TARGET_REGION`/`TARGET_ZONE` with the historic defaults, and
defines the fail-closed `_require_target_project` preflight. Nothing about live behavior changes for
the existing operator because the defaults reproduce `tan-nb-exp`/`us-west1`/`us-west1-a`.

What will exist that did not before: a documented, copyable schema; a git-ignore entry that keeps a
real foreign profile out of commits; and one canonical guardrail function to replace six duplicated
lines per script (EP-61 will do the replacing).

Commands to run: the three `bash` checks in Concrete Steps (source-with-no-profile prints defaults;
source-with-a-custom-profile prints the custom project; a forced active-project mismatch makes the
preflight exit non-zero). Acceptance: those three transcripts match.


### Milestone 2 — `.envrc`, `CLAUDE.md`, and the justfile comment

Scope: at the end of M2 entering the repository directory sources the target profile (if any) and
exports `CLOUDSDK_CORE_PROJECT`/`CLOUDSDK_COMPUTE_REGION`/`CLOUDSDK_COMPUTE_ZONE` from it, falling
back to `tan-nb-exp`/`us-west1`/`us-west1-a`; the `CLAUDE.md` "GCP project isolation" section
describes the configurable model and names MasterPlan 12 as the Decision-Log entry the old policy
demanded; and the justfile header no longer claims cloud commands are hard-pinned to `tan-nb-exp`.

What will exist that did not before: an `.envrc` whose project pin is *derived* from the profile (so
changing the profile changes the shell environment), and repository policy text that authorizes and
explains the configurable model rather than forbidding it.

Commands to run: `direnv allow` then `echo $CLOUDSDK_CORE_PROJECT` (expect `tan-nb-exp` with no
profile); create a `nagare.target.env` with a different project, re-enter, and `echo` again (expect
the new project). Acceptance: those two transcripts match.


## Concrete Steps

All commands run from the repository root,
`/Users/shinzui/Keikaku/bokuno/nagare`, unless stated otherwise.


### Step 1 (M1.1) — create `nagare.target.env.example`

Create the file `nagare.target.env.example` at the repository root with exactly this content. It is
a tracked, copyable schema: comments explain each variable, and the values are the `tan-nb-exp`
worked example so copying it reproduces today's target.

```bash
# nagare target profile — WORKED EXAMPLE / SCHEMA (tracked in git).
#
# Copy this file to `nagare.target.env` (which IS git-ignored) and edit it to
# point nagare at YOUR GCP project. `.envrc` and scripts/lib/target.sh source
# `nagare.target.env`; nagarectl reads these variables from the environment.
# Doing nothing keeps the values below, which are the original tan-nb-exp setup.
#
# Each line is a plain `export NAME=value`. Precedence everywhere is:
#   a value already in your environment  >  this file  >  built-in defaults.
# The built-in defaults equal the tan-nb-exp values shown here, so an operator
# with no profile file behaves exactly as the repo historically did.

# --- Core GCP target (standard Cloud SDK names; honored by gcloud and Pulumi) ---

# GCP project id. THE one value most operators change.
export CLOUDSDK_CORE_PROJECT=tan-nb-exp

# Compute region. All regional resources (subnet, static IP, buckets) live here.
export CLOUDSDK_COMPUTE_REGION=us-west1

# Compute zone. The single VM lives here.
export CLOUDSDK_COMPUTE_ZONE=us-west1-a

# --- Derived names. Defaults follow the conventions in the comments; override
#     only if you have a reason to diverge from the standard layout. ---

# Artifact Registry Docker host. Convention: "<region>-docker.pkg.dev".
export NAGARE_REGISTRY_HOST=us-west1-docker.pkg.dev

# Artifact Registry repository id (the repo within the host above).
export NAGARE_ARTIFACT_REGISTRY_ID=nagare

# GCS bucket holding NixOS image tarballs. Convention: "<project>-nagare-images".
export NAGARE_IMAGE_BUCKET=tan-nb-exp-nagare-images

# GCS bucket holding database/volume backups. Convention: "<project>-nagare-backups".
export NAGARE_BACKUP_BUCKET=tan-nb-exp-nagare-backups

# Wildcard apps domain. Knative serves "<app>.<this>". Delegate it to the Cloud
# DNS zone nagare creates. The placeholder below is intentionally non-routable.
export NAGARE_BASE_DOMAIN=apps.example.com

# The single VM's instance name.
export NAGARE_INSTANCE_NAME=nagare-01
```


### Step 2 (M1.2) — ignore the real profile in `.gitignore`

Add `nagare.target.env` to `/Users/shinzui/Keikaku/bokuno/nagare/.gitignore`. Apply this diff
(insert after the `CLAUDE.local.md` line, near the top with the other root-level ignores):

```diff
 .claude/
 .agents/
 .seihou/manifest.json.tmp
 CLAUDE.local.md
+
+# Per-operator GCP target profile (EP-60). The tracked schema/example is
+# nagare.target.env.example; the real, per-operator file is never committed so
+# the repository stays project-agnostic.
+nagare.target.env
```


### Step 3 (M1.3) — create `scripts/lib/target.sh`

Create the file `scripts/lib/target.sh` with exactly this content. It is meant to be **sourced**,
not executed, by other scripts (`source "$(dirname "$0")/lib/target.sh"`). It computes the repo root
from its own location (so it works regardless of the caller's working directory), loads
`nagare.target.env` if present, sets the three `TARGET_*` variables with the historic fallbacks, and
defines `_require_target_project`.

```bash
#!/usr/bin/env bash
# scripts/lib/target.sh (EP-60) — the SINGLE source of the GCP target and the
# configurable, fail-closed isolation guardrail. SOURCE this file; do not run it:
#
#   source "$(dirname "$0")/lib/target.sh"
#   _require_target_project
#
# It loads the git-ignored target profile `nagare.target.env` from the repo root
# (if present), then sets TARGET_PROJECT / TARGET_REGION / TARGET_ZONE, falling
# back to the historic tan-nb-exp / us-west1 / us-west1-a defaults so a checkout
# with no profile behaves exactly as before. `_require_target_project` refuses to
# proceed unless gcloud's active project equals TARGET_PROJECT — the same
# fail-closed guard every script used to inline, now configurable.

# Resolve the repository root from THIS file's path, independent of the caller's
# cwd. ${BASH_SOURCE[0]} is this file; its parent is scripts/lib, so ../.. is the
# repo root.
_target_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAGARE_REPO_ROOT="$(cd "${_target_lib_dir}/../.." && pwd)"

# Load the per-operator profile if it exists. Lines are `export NAME=value`.
# A value already exported in the environment is NOT overwritten by sourcing,
# because the example uses bare `export NAME=value`; if you want the environment
# to win unconditionally, do not set it in the profile. (.envrc applies the same
# precedence via ${VAR:-default}.)
if [ -f "${NAGARE_REPO_ROOT}/nagare.target.env" ]; then
  # shellcheck disable=SC1091
  . "${NAGARE_REPO_ROOT}/nagare.target.env"
fi

# Derive the guardrail's comparison values, with the historic defaults as the
# fallback so "do nothing" preserves today's behavior.
TARGET_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"
TARGET_REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"
TARGET_ZONE="${CLOUDSDK_COMPUTE_ZONE:-us-west1-a}"

# Fail-closed preflight: abort unless gcloud's active project equals the
# configured target. Returns/exits non-zero on mismatch. Call it once at the top
# of any script that talks to GCP, AFTER sourcing this file.
_require_target_project() {
  local active
  active="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
  if [ "${active}" != "${TARGET_PROJECT}" ]; then
    echo "refusing to run: gcloud active project is '${active:-<unset>}', expected '${TARGET_PROJECT}'." >&2
    echo "fix: run 'direnv allow' in the repo root, set CLOUDSDK_CORE_PROJECT in nagare.target.env," >&2
    echo "     or 'export CLOUDSDK_CORE_PROJECT=${TARGET_PROJECT}'." >&2
    return 1
  fi
}
```

A note on the `return 1` versus `exit 1`. The old inline guard used `exit 1` because it ran in the
script's top-level body. Here the check is a function; `return 1` propagates the failure to the
caller. Because callers run `set -euo pipefail` and invoke it as a bare statement
(`_require_target_project`), a non-zero return aborts the script just as `exit 1` did. (EP-61, when
it wires the scripts, will call it as `_require_target_project` on its own line, so the `errexit`
shell option turns the failed return into an immediate abort.)


### Step 4 (M1.4) — verify Milestone 1 with bash only

These checks need no cloud and no direnv. Run them from the repo root.

First, sourcing the helper with **no** profile present yields the historic defaults:

```bash
test ! -f nagare.target.env && echo "no profile present (good)"
bash -c 'source scripts/lib/target.sh; echo "P=$TARGET_PROJECT R=$TARGET_REGION Z=$TARGET_ZONE"'
```

Expected:

```text
no profile present (good)
P=tan-nb-exp R=us-west1 Z=us-west1-a
```

Second, a profile pointing at a different project flows through to `TARGET_PROJECT`:

```bash
cp nagare.target.env.example /tmp/demo.target.env
sed -i '' 's/^export CLOUDSDK_CORE_PROJECT=.*/export CLOUDSDK_CORE_PROJECT=acme-prod/' /tmp/demo.target.env
cp /tmp/demo.target.env nagare.target.env
bash -c 'source scripts/lib/target.sh; echo "P=$TARGET_PROJECT"'
```

Expected:

```text
P=acme-prod
```

(On Linux, `sed -i 's/.../.../'` without the `''` argument; the `''` form shown is macOS/BSD `sed`,
matching this repo's `darwin` host.)

Third, the guardrail still fails closed. With the `acme-prod` profile still in place, force gcloud's
active project to something else via the environment and confirm `_require_target_project` aborts:

```bash
bash -c 'source scripts/lib/target.sh; CLOUDSDK_CORE_PROJECT=wrong-project _require_target_project; echo "rc=$?"'
```

Wait — note that sourcing the profile re-exports `CLOUDSDK_CORE_PROJECT=acme-prod`, so to simulate a
mismatch we override the *active* value the function reads. The function reads
`CLOUDSDK_CORE_PROJECT` first; to force a mismatch we set `TARGET_PROJECT` from the profile but point
the active project elsewhere. Use this precise form, which sets the active env var after sourcing:

```bash
bash -c '
  source scripts/lib/target.sh           # TARGET_PROJECT=acme-prod from the profile
  export CLOUDSDK_CORE_PROJECT=wrong-project   # pretend gcloud is on the wrong project
  if _require_target_project; then echo "UNEXPECTED: passed"; else echo "rc=$?"; fi
'
```

Expected (the message on stderr, then the non-zero return code):

```text
refusing to run: gcloud active project is 'wrong-project', expected 'acme-prod'.
fix: run 'direnv allow' in the repo root, set CLOUDSDK_CORE_PROJECT in nagare.target.env,
     or 'export CLOUDSDK_CORE_PROJECT=acme-prod'.
rc=1
```

Finally, clean up the demo profile so the repo returns to default behavior for the rest of the work:

```bash
rm -f nagare.target.env /tmp/demo.target.env
```


### Step 5 (M2.1) — rewrite `.envrc`

The current `.envrc` hard-codes the three values. Replace the hard-coded block with a profile
include plus `${VAR:-default}` fallbacks, keeping everything else (the Pulumi exports and
`use flake`) unchanged. Here is the exact before and after of the top of the file.

Before (current lines 1–8):

```bash
# All GCP work for this repository targets the tan-nb-exp project only.
# These env vars override gcloud's `core/project` default for any shell
# entered into this directory, so an interactive `gcloud ...` without an
# explicit `--project` flag still hits the right project. See CLAUDE.md
# for the full policy (MasterPlan Integration Point 9).
export CLOUDSDK_CORE_PROJECT=tan-nb-exp
export CLOUDSDK_COMPUTE_REGION=us-west1
export CLOUDSDK_COMPUTE_ZONE=us-west1-a
```

After (replace those eight lines with this):

```bash
# GCP target for any shell entered into this directory. The target is read from
# the git-ignored profile `nagare.target.env` (copy nagare.target.env.example to
# create one); if absent, the defaults below reproduce the original tan-nb-exp
# setup. Exporting the standard CLOUDSDK_* names makes unqualified `gcloud ...`
# and the Pulumi GCP provider honor the target without a --project flag. See
# CLAUDE.md and docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md.
#
# Precedence: a value already in your environment wins; else the profile; else
# the default. The ${VAR:-default} form below implements that — sourcing the
# profile first sets the vars, and the fallbacks only apply when unset.
[ -f "$PWD/nagare.target.env" ] && source_env "$PWD/nagare.target.env"
export CLOUDSDK_CORE_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"
export CLOUDSDK_COMPUTE_REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"
export CLOUDSDK_COMPUTE_ZONE="${CLOUDSDK_COMPUTE_ZONE:-us-west1-a}"
```

The rest of the file — the `PULUMI_HOME` export, the `PULUMI_CONFIG_PASSPHRASE` export, and the
`use flake` line — is left exactly as it is now. `source_env` is direnv's own include helper; it
loads the profile relative to the repo root and records it as a watched file so re-entering the
directory after editing the profile re-applies it. We do NOT shell out to `pulumi` here: the profile
is canonical and Pulumi config is a later, derived projection (EP-63), and `.envrc` must stay
instant on every directory entry.

For reference, the full intended `.envrc` after the edit is:

```bash
# GCP target for any shell entered into this directory. The target is read from
# the git-ignored profile `nagare.target.env` (copy nagare.target.env.example to
# create one); if absent, the defaults below reproduce the original tan-nb-exp
# setup. Exporting the standard CLOUDSDK_* names makes unqualified `gcloud ...`
# and the Pulumi GCP provider honor the target without a --project flag. See
# CLAUDE.md and docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md.
#
# Precedence: a value already in your environment wins; else the profile; else
# the default. The ${VAR:-default} form below implements that — sourcing the
# profile first sets the vars, and the fallbacks only apply when unset.
[ -f "$PWD/nagare.target.env" ] && source_env "$PWD/nagare.target.env"
export CLOUDSDK_CORE_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"
export CLOUDSDK_COMPUTE_REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"
export CLOUDSDK_COMPUTE_ZONE="${CLOUDSDK_COMPUTE_ZONE:-us-west1-a}"

# Pulumi state isolation: keep credentials, plugins, templates, and stack
# state inside this repository so nothing under ~/.pulumi/ (which other
# projects on this workstation may use) collides with our state. The state
# backend itself is configured per-stack by EP-2 via
# `pulumi login file://./.pulumi-state` (resolves relative to infra/pulumi/).
export PULUMI_HOME="$PWD/infra/pulumi/.pulumi-home"

# Pulumi secrets use the passphrase provider, initialised with an empty
# passphrase. Export it explicitly so `pulumi config set --secret` and
# `pulumi up` don't prompt or error. To tighten later, run
# `pulumi stack change-secrets-provider passphrase` with a real value and
# update this line.
export PULUMI_CONFIG_PASSPHRASE=""

# Project-pinned Pulumi + Haskell + cloud toolchain (see flake.nix).
# `use flake` loads devShells.<system>.default onto PATH so pulumi, node,
# tsc, gcloud, kubectl, helm, ghc, cabal, sops, etc. come from the flake
# rather than any global install.
use flake
```


### Step 6 (M2.2) — rewrite the `CLAUDE.md` "GCP project isolation" section

Replace the entire current "## GCP project isolation" section of
`/Users/shinzui/Keikaku/bokuno/nagare/CLAUDE.md` (the heading and everything down to but not
including "## Git conventions", i.e. current lines 3–48) with the following. The "## Git
conventions" section below it is left unchanged.

```text
## GCP project isolation

This repository targets **one** GCP project at a time — but **which** project is
**configurable**, not hard-coded. The target (project, region, zone, and the
derived resource names) is read from a per-operator **target profile**: a
git-ignored file `nagare.target.env` at the repo root, a sequence of
`export VAR=value` lines. The tracked `nagare.target.env.example` documents the
schema and ships the original **`tan-nb-exp`** / **`us-west1`** / **`us-west1-a`**
values as the worked example. `tan-nb-exp` is the **default example, not a hard
constraint**: with no profile present the defaults reproduce it, so the original
setup is unchanged; with a profile, nagare acts on the operator's own project.

The single-project isolation guardrail is **preserved and still fail-closed** —
it now asserts against the **configured** target project rather than the literal
`tan-nb-exp`. No script, command, or instruction may act on a project other than
the configured target; that applies to reads (listing, describing, querying)
too. Switching projects means editing the profile, never running two at once.

### How the policy is enforced

1. **The target profile is canonical.** `nagare.target.env` is the single source
   of truth for the GCP target. The canonical variables — read verbatim by every
   consumer — are `CLOUDSDK_CORE_PROJECT`, `CLOUDSDK_COMPUTE_REGION`,
   `CLOUDSDK_COMPUTE_ZONE` (the standard Cloud SDK names, so interactive `gcloud`
   and the Pulumi GCP provider honor them), plus `NAGARE_REGISTRY_HOST`,
   `NAGARE_ARTIFACT_REGISTRY_ID`, `NAGARE_IMAGE_BUCKET`, `NAGARE_BACKUP_BUCKET`,
   `NAGARE_BASE_DOMAIN`, and `NAGARE_INSTANCE_NAME`. Precedence: environment >
   profile > built-in default (the `tan-nb-exp` value).

2. **`.envrc`** at the repo root sources `nagare.target.env` (if present) and
   exports the three `CLOUDSDK_*` variables with the `tan-nb-exp`/`us-west1`/
   `us-west1-a` fallback defaults, so any shell entered here makes the configured
   project the default for unqualified `gcloud`. Run `direnv allow` once.

3. **The guardrail lives in one place:** `scripts/lib/target.sh`. Scripts
   `source` it and call `_require_target_project`, which refuses to run unless
   gcloud's active project equals the configured `TARGET_PROJECT`. This replaces
   the six-line preflight that used to be copy-pasted into every script. No code
   may weaken the fail-closed behavior; only the compared value is configurable.

4. **Pulumi config is a derived projection** of the profile (written at
   onboarding, not hand-edited). `.envrc` and the scripts never shell out to
   Pulumi to learn the target; they read the profile, which is instant and works
   before any stack exists.

5. **Pulumi state is isolated in-repo** via
   `pulumi login file://./infra/pulumi/.pulumi-state` with the passphrase secrets
   provider (EP-2 configures this). `PULUMI_HOME` and `PULUMI_CONFIG_PASSPHRASE`
   are set by `.envrc`.

### Decision Log basis

The earlier policy made `tan-nb-exp` an immutable binding and required a
MasterPlan Decision Log entry before any code targeted another project. That
decision exists:
`docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md`
("Bring-your-own GCP project onboarding for nagare") is the architectural
decision that authorizes the configurable model and supersedes the single-project
constraint. Any further change to the target model is recorded in that
MasterPlan's Decision Log.
```


### Step 7 (M2.3) — update the justfile header comment

In `/Users/shinzui/Keikaku/bokuno/nagare/justfile`, update the header comment (currently lines 5–7)
that claims cloud commands are pinned to `tan-nb-exp`. Apply this diff:

```diff
 # Nagare command runner. These recipes are THIN WRAPPERS. The detailed
 # contents of each step are owned by the child plans referenced below,
 # under docs/plans/. Run `just --list` to see all recipes.
 #
-# All cloud commands target the tan-nb-exp GCP project (see .envrc and
-# CLAUDE.md). Enter the dev shell first with `nix develop`, or let direnv
-# load it automatically after `direnv allow`.
+# All cloud commands target the GCP project configured in the target profile
+# `nagare.target.env` (copy nagare.target.env.example to create one); with no
+# profile they default to tan-nb-exp / us-west1 / us-west1-a. See .envrc and
+# CLAUDE.md. Enter the dev shell first with `nix develop`, or let direnv load
+# it automatically after `direnv allow`.
```


### Step 8 (M2.4) — verify Milestone 2 with direnv

From the repo root, with no `nagare.target.env` present, authorize and reload the `.envrc`, then
read the exported project:

```bash
test ! -f nagare.target.env && echo "no profile present (good)"
direnv allow
echo "$CLOUDSDK_CORE_PROJECT"
```

Expected:

```text
no profile present (good)
tan-nb-exp
```

Now create a profile pointing at a different project, reload, and read again. `direnv` reloads on
the next prompt in an interactive shell; in a script, force the reload with `direnv exec`:

```bash
cp nagare.target.env.example nagare.target.env
sed -i '' 's/^export CLOUDSDK_CORE_PROJECT=.*/export CLOUDSDK_CORE_PROJECT=acme-prod/' nagare.target.env
direnv exec . sh -c 'echo "$CLOUDSDK_CORE_PROJECT"'
```

Expected:

```text
acme-prod
```

Clean up so the working tree returns to the default target:

```bash
rm -f nagare.target.env
direnv exec . sh -c 'echo "$CLOUDSDK_CORE_PROJECT"'   # prints tan-nb-exp again
```


## Validation and Acceptance

Acceptance is observable behavior, not the mere presence of files.

**A1 — default behavior is preserved (no profile).** In a clean checkout with no
`nagare.target.env`, after `direnv allow`, `echo "$CLOUDSDK_CORE_PROJECT"` prints `tan-nb-exp`, and
`bash -c 'source scripts/lib/target.sh; echo $TARGET_PROJECT'` prints `tan-nb-exp`. This proves the
fallback defaults reproduce today's target and that an existing operator who does nothing is
unaffected.

**A2 — the profile changes the target end to end.** Copy the example to `nagare.target.env`, set
`CLOUDSDK_CORE_PROJECT=acme-prod`, and observe two independent surfaces change: the shell
environment (`direnv exec . sh -c 'echo $CLOUDSDK_CORE_PROJECT'` prints `acme-prod`) and the
guardrail's view (`bash -c 'source scripts/lib/target.sh; echo $TARGET_PROJECT'` prints
`acme-prod`). This proves the profile is the single source of truth read by both `.envrc` and the
helper.

**A3 — the guardrail still fails closed.** With the `acme-prod` profile in place but gcloud's active
project forced to something else, `_require_target_project` prints the refusal message to stderr and
returns non-zero (the Step 4 transcript). This proves the guardrail was not weakened — it still
aborts on mismatch, now against the *configured* project.

**A4 — no committed literal regression.** `git status` shows `nagare.target.env` is untracked-and-
ignored (it does not appear under "Untracked files" because `.gitignore` covers it; confirm with
`git check-ignore nagare.target.env` printing the path). The tracked new files are
`nagare.target.env.example` and `scripts/lib/target.sh`. This proves a foreign operator's real
profile can never be committed.

A quick combined check:

```bash
git check-ignore nagare.target.env || echo "NOT IGNORED (bad)"
git status --porcelain nagare.target.env.example scripts/lib/target.sh
```

Expected (the example and helper are the new tracked additions; the ignore check echoes the path):

```text
nagare.target.env
?? nagare.target.env.example
?? scripts/lib/target.sh
```


## Idempotence and Recovery

Every step is safe to repeat. Writing `nagare.target.env.example` and `scripts/lib/target.sh` is
idempotent — re-running overwrites with identical content. Editing `.gitignore`, `.envrc`,
`CLAUDE.md`, and the justfile is a one-time textual change; if a diff is already applied, re-applying
it is a no-op (the `old_string` will not be found, signalling the edit is already in place).

`direnv allow` is idempotent; re-running re-authorizes the same `.envrc`. Sourcing
`scripts/lib/target.sh` multiple times is harmless — it only sets variables and defines a function.

The verification steps create a temporary `nagare.target.env` (and a `/tmp/demo.target.env`); each
verification block ends by removing them, returning the working tree to the default target. Because
`nagare.target.env` is git-ignored, even if a verification file is left behind it cannot be
committed; `rm -f nagare.target.env` restores the default behavior at any time.

No step makes a GCP call, so there is nothing to roll back in the cloud. If `.envrc` is left in a
broken intermediate state, `direnv` simply reports the error on directory entry and loads nothing;
fixing the file and re-running `direnv allow` recovers. The original `.envrc` content is reproduced
verbatim in Step 5 for restoration if needed.


## Interfaces and Dependencies

This plan has **no hard dependencies** (MasterPlan 12 registry: EP-60, Hard Deps None). It is
consumed by EP-61, EP-62, EP-63, and EP-64, which read the contract fixed here.

**The contract files.**

- `nagare.target.env` (git-ignored, per-operator) and `nagare.target.env.example` (tracked) — a
  sequence of `export VAR=value` lines over exactly these nine variables, with the
  precedence environment > profile > default, the defaults being the `tan-nb-exp` values:

```text
CLOUDSDK_CORE_PROJECT          (default tan-nb-exp)
CLOUDSDK_COMPUTE_REGION        (default us-west1)
CLOUDSDK_COMPUTE_ZONE          (default us-west1-a)
NAGARE_REGISTRY_HOST           (default us-west1-docker.pkg.dev; = <region>-docker.pkg.dev)
NAGARE_ARTIFACT_REGISTRY_ID    (default nagare)
NAGARE_IMAGE_BUCKET            (default tan-nb-exp-nagare-images; = <project>-nagare-images)
NAGARE_BACKUP_BUCKET           (default tan-nb-exp-nagare-backups; = <project>-nagare-backups)
NAGARE_BASE_DOMAIN             (default apps.example.com)
NAGARE_INSTANCE_NAME           (default nagare-01)
```

EP-60 owns this list. If a later plan needs a new target field, it adds the variable to
`nagare.target.env.example`, to MasterPlan 12 Integration Point 1, and to this section, then
notifies the other consumers (MasterPlan 12, Integration Point 1).

**The guardrail helper `scripts/lib/target.sh`.** A bash file meant to be `source`d. After sourcing,
the following are in scope for the caller:

- `NAGARE_REPO_ROOT` — absolute path to the repository root, computed from the helper's own
  location (independent of the caller's working directory).
- `TARGET_PROJECT` — `${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}` after the profile is loaded.
- `TARGET_REGION` — `${CLOUDSDK_COMPUTE_REGION:-us-west1}`.
- `TARGET_ZONE` — `${CLOUDSDK_COMPUTE_ZONE:-us-west1-a}`.
- `_require_target_project` — a function taking no arguments. It reads the active project as
  `${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}`; if that does
  not equal `TARGET_PROJECT`, it prints a two-or-three-line refusal-and-fix message to stderr and
  returns `1`; otherwise it returns `0` and prints nothing. Callers run under `set -euo pipefail`
  and invoke it as a bare statement, so a non-zero return aborts the script (the fail-closed
  guarantee). This is the exact contract EP-61 relies on when it replaces each script's inline
  preflight with `source "$(dirname "$0")/lib/target.sh"` followed by `_require_target_project`.

**Tools used.** Only `bash`/`sh`, `git`, and `direnv` (for `.envrc`; `source_env` and `use flake`
are direnv built-ins). No GCP credentials, no `gcloud` call, no Pulumi, no Haskell toolchain are
required to implement or verify this plan.

**Downstream coupling (for the next contributor).** EP-61 will edit every script under `scripts/`
(`backup-postgres.sh`, `upload-images.sh`, `restore-postgres.sh`, `restore-sqlite.sh`,
`restore-volume.sh`, `setup-nix-builder.sh`, `iap-ssh.sh`, and the `nix-builder-startup.sh.tpl`
template) to source this helper instead of inlining the six-line guard, and will replace literal
`tan-nb-exp`/`us-west1` references with the `TARGET_*`/`CLOUDSDK_*`/`NAGARE_*` variables. EP-62
reads the same nine variables from the process environment in the Haskell CLI. EP-63 writes
`nagare.target.env` (and projects it into Pulumi config) from its `nagarectl init` command. EP-64
documents the onboarding flow. None of those edits belong to this plan; this plan only fixes the
contract and ships the helper they consume.
