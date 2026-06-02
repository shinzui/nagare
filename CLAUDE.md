# nagare — operating rules

## GCP project isolation

All GCP resources created, modified, or read by anything in this
repository live in **`tan-nb-exp`**, region **`us-west1`**, default
zone **`us-west1-a`**.

No script, command, or instruction in this repository may target any
other GCP project. This includes read operations: listing, describing,
or querying state must be done against `tan-nb-exp`.

### How the policy is enforced

1. **`.envrc`** at the repo root exports `CLOUDSDK_CORE_PROJECT`,
   `CLOUDSDK_COMPUTE_REGION`, and `CLOUDSDK_COMPUTE_ZONE` so any shell
   entered here makes `tan-nb-exp` the default for unqualified `gcloud`
   invocations. Run `direnv allow` once to enable it.

2. **Scripts under `scripts/`** must include the preflight assertion that
   verifies the active project equals `tan-nb-exp` before they make any
   gcloud call. The pattern is:

   ```bash
   PROJECT=tan-nb-exp
   ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
   if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
     echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
     exit 1
   fi
   ```

3. **Every gcloud invocation** in scripts passes `--project="$PROJECT"`
   explicitly. The env-var fallback and the preflight check are defenses
   in depth, not substitutes for the explicit flag.

4. **Pulumi state is isolated in-repo** via
   `pulumi login file://./infra/pulumi/.pulumi-state` with the passphrase
   secrets provider (EP-2 configures this). `PULUMI_HOME` and
   `PULUMI_CONFIG_PASSPHRASE` are set by `.envrc`.

### When the policy might be revised

Only when the work in this repository is intentionally extended to operate
against a different or additional GCP project. That is a deliberate
architectural change and must be recorded in the MasterPlan Decision Log
(`docs/masterplans/1-bootstrap-nagare-personal-paas.md`) before any code
targeting another project is written.

## Git conventions

- **Conventional Commits.** Every commit message follows the Conventional
  Commits specification: a type prefix such as `feat:`, `fix:`, `docs:`,
  `refactor:`, `test:`, or `chore:`, optionally with a scope
  (e.g. `feat(infra): ...`), and a `!` or `BREAKING CHANGE:` footer for
  breaking changes.

- **No feature branches by default.** Commit directly to the current
  branch unless explicitly asked to create a new branch.
