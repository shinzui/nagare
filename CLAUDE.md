# nagare — operating rules

## GCP project isolation

This repository targets **one** GCP project at a time — but **which** project is
**configurable**, not hard-coded. The target (project, region, zone, and the
derived resource names) is the **active target context**: a named flat
`export VAR=value` bundle in
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`, selected by
`nagarectl --context NAME`, `NAGARE_CONTEXT=NAME`, or
`nagarectl context use NAME`. The tracked `nagare.target.env.example` and
`nagare.local.env.example` document the same schema. `tan-nb-exp` is the
**default example, not a hard constraint**: with no context and no in-repo
profile present the defaults reproduce it, so the original setup is unchanged.

The single-project isolation guardrail is **preserved and still fail-closed** —
it now asserts against the **active cloud context's** project rather than the
literal `tan-nb-exp`. No script, command, or instruction may act on a project
other than the active context; that applies to reads (listing, describing,
querying) too. Switching targets means selecting a different context, not
editing a tracked file. The old in-repo `nagare.target.env` and
`nagare.local.env` files remain valid lower-precedence fallbacks for
back compatibility.

**A local context (`mode=local`) is a supported testing path where the GCP
guardrail steps aside by design** — and this does **not** weaken the rule above.
Local mode (MasterPlan 16; see [`docs/user/local-development.md`](docs/user/local-development.md))
points every primitive at loopback substitutes — a k3d cluster, a local registry,
MinIO instead of GCS — so there is **no GCP project to protect**. When
the active context has `mode=local`, `_require_target_project` steps aside
(after asserting the local target is genuinely loopback, never a real
`*.pkg.dev` registry or a non-loopback domain, so a misconfigured context cannot
silently disarm protection while pointing at GCP). When the active context has
`mode=cloud`, the guardrail stays fail-closed exactly as before. The local smoke
test `just local-smoke` relies on this branch; the cloud branch must never
become anything but fail-closed.

### How the policy is enforced

1. **The active context is canonical.** The canonical variables — read verbatim
   by every consumer — are `CLOUDSDK_CORE_PROJECT`,
   `CLOUDSDK_COMPUTE_REGION`, `CLOUDSDK_COMPUTE_ZONE` (the standard Cloud SDK
   names, so interactive `gcloud` and the Pulumi GCP provider honor them), plus
   `NAGARE_REGISTRY_HOST`, `NAGARE_ARTIFACT_REGISTRY_ID`,
   `NAGARE_IMAGE_BUCKET`, `NAGARE_BACKUP_BUCKET`, `NAGARE_BASE_DOMAIN`,
   `NAGARE_INSTANCE_NAME`, `NAGARE_TARGET_PLATFORM`, `NAGARE_MODE`, and
   `NAGARE_LOCAL_OBJECT_STORE`. Selection precedence: `--context` /
   `NAGARE_CONTEXT` > current-context pointer > in-repo profile > built-in
   default. Per-field precedence: environment > context/profile > default.

2. **`.envrc`** at the repo root resolves the active context and exports the
   `CLOUDSDK_*` / `NAGARE_*` contract, so any shell entered here makes the active
   project the default for unqualified `gcloud`. Run `direnv allow` once.

3. **The guardrail lives in one place:** `scripts/lib/target.sh`. Scripts
   `source` it and call `_require_target_project`, which refuses to run unless
   gcloud's active project equals the active cloud context's `TARGET_PROJECT`.
   This replaces the six-line preflight that used to be copy-pasted into every
   script. No code may weaken the fail-closed behavior; only the compared value
   is context-driven.

4. **Pulumi config is a derived projection** of the context (written at
   onboarding/context selection, not hand-edited). `.envrc` and the scripts
   never shell out to Pulumi to learn the target; they read the active context,
   which is instant and works before any stack exists.

5. **Pulumi state is isolated per context** via
   `PULUMI_BACKEND_URL=file://${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/state`,
   with matching per-context `PULUMI_HOME`. The stack name is the context name,
   and generated `infra/pulumi/Pulumi.<context>.yaml` files are ignored.

### Decision Log basis

The earlier policy made `tan-nb-exp` an immutable binding and required a
MasterPlan Decision Log entry before any code targeted another project. That
decision exists:
`docs/masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md`
("Bring-your-own GCP project onboarding for nagare") is the architectural
decision that authorized the configurable profile model and superseded the
single-project constraint. `docs/masterplans/17-first-class-target-contexts-for-nagare.md`
is the later architectural decision that supersedes the single-profile framing
with first-class target contexts. Any further change to the target model is
recorded in that MasterPlan's Decision Log.

## Git conventions

- **Conventional Commits.** Every commit message follows the Conventional
  Commits specification: a type prefix such as `feat:`, `fix:`, `docs:`,
  `refactor:`, `test:`, or `chore:`, optionally with a scope
  (e.g. `feat(infra): ...`), and a `!` or `BREAKING CHANGE:` footer for
  breaking changes.

- **No feature branches by default.** Commit directly to the current
  branch unless explicitly asked to create a new branch.
