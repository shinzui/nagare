# nagare — operating rules

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

**Local mode (`NAGARE_MODE=local`) is a supported testing path that bypasses the
GCP guardrail by design** — and this does **not** weaken the rule above. Local
mode (MasterPlan 16; see [`docs/user/local-development.md`](docs/user/local-development.md))
points every primitive at loopback substitutes — a k3d cluster, a local registry,
MinIO instead of GCS — so there is **no GCP project to protect**. When
`NAGARE_MODE=local`, `_require_target_project` steps aside (after asserting the
local target is genuinely loopback, never a real `*.pkg.dev` registry or a
non-loopback domain, so a misconfigured profile cannot silently disarm protection
while pointing at GCP). When `NAGARE_MODE` is unset or `cloud`, the guardrail stays
fail-closed exactly as before. The local smoke test `just local-smoke` relies on
this short-circuit; the cloud branch must never become anything but fail-closed.

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

## Git conventions

- **Conventional Commits.** Every commit message follows the Conventional
  Commits specification: a type prefix such as `feat:`, `fix:`, `docs:`,
  `refactor:`, `test:`, or `chore:`, optionally with a scope
  (e.g. `feat(infra): ...`), and a `!` or `BREAKING CHANGE:` footer for
  breaking changes.

- **No feature branches by default.** Commit directly to the current
  branch unless explicitly asked to create a new branch.
