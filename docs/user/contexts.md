# Target contexts

> **Status:** ✅ Working

A target context is a named Nagare target bundle, like a `kubectl` context. It
contains the project, region, zone, registry, buckets, base domain, VM name,
build platform, mode, and local object-store settings that used to live in one
per-checkout profile. You can keep many contexts in one user-level store and
select one per command without changing checkouts.

Cloud contexts replace the old `nagare.target.env` workflow. Local contexts
replace the old `nagare.local.env` plus `NAGARE_MODE=local` workflow. The old
in-repo files still work as a lower-precedence fallback.

## Context store

Contexts live outside the repo, under your XDG config directory:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/nagare/
  contexts/
    prod.env      # mode=cloud, project=tan-nb-exp, baseDomain=apps.example.com
    labs.env      # mode=cloud, project=<your-labs-project>, baseDomain=labs.topagentnetwork.net
    local.env     # mode=local, registryHost=k3d-registry.localhost:5000
  current-context # one line, e.g. "prod"
```

Each `<name>.env` is a flat `export VAR=value` file. The schema is the same one
documented by [`nagare.target.env.example`](../../nagare.target.env.example) and
[`nagare.local.env.example`](../../nagare.local.env.example), so bash can source
it directly.

The core fields are:

| Field | Environment variable |
| --- | --- |
| GCP project | `CLOUDSDK_CORE_PROJECT` |
| Region / zone | `CLOUDSDK_COMPUTE_REGION`, `CLOUDSDK_COMPUTE_ZONE` |
| Registry | `NAGARE_REGISTRY_HOST`, `NAGARE_ARTIFACT_REGISTRY_ID` |
| Buckets | `NAGARE_IMAGE_BUCKET`, `NAGARE_BACKUP_BUCKET` |
| Apps domain | `NAGARE_BASE_DOMAIN` |
| VM name | `NAGARE_INSTANCE_NAME` |
| Build platform | `NAGARE_TARGET_PLATFORM` |
| Mode | `NAGARE_MODE` (`cloud` or `local`) |
| Local object store | `NAGARE_LOCAL_OBJECT_STORE` |

## Commands

| Command | Effect |
| --- | --- |
| `nagarectl context list` | List stored contexts and mark the current one. |
| `nagarectl context current` | Print the current context name. |
| `nagarectl context use NAME` | Set `NAME` as current, select its Pulumi stack, and regenerate its Pulumi config projection. |
| `nagarectl context show [NAME]` | Print a context bundle as `export VAR=value`; without `NAME`, show the active context. |
| `nagarectl context create NAME [flags]` | Write a context. Add `--use` to make it current. |
| `nagarectl context delete NAME --yes` | Delete a context file; deleting the current context clears the pointer. |

`nagarectl init NAME --project ... --base-domain ...` is the full onboarding
path for a new cloud context: it writes the named context, marks it current,
runs preflight/API enablement unless skipped, and seeds that context's Pulumi
projection. `nagarectl init` without `NAME` keeps the legacy behavior and writes
`./nagare.target.env`.

## Selecting a context

Use the selector that fits the operation:

```bash
nagarectl --context labs deploy -f nagare/Config.hs
NAGARE_CONTEXT=labs just smoke
nagarectl context use labs
```

Selection precedence, highest first:

1. `nagarectl --context NAME`, or `NAGARE_CONTEXT=NAME` for shell/justfile work.
2. `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/current-context`.
3. In-repo `nagare.target.env` / `nagare.local.env` for back compatibility.
4. The built-in `tan-nb-exp` worked-example defaults.

Per-field environment variables still override the selected bundle, except that
the cloud-project guard rejects an effective `CLOUDSDK_CORE_PROJECT` that
differs from the project declared by the context. For example,
`NAGARE_BASE_DOMAIN=preview.example.com nagarectl --context labs domains list`
uses the `labs` bundle, then overrides only the base domain.

If you explicitly select a missing context, Nagare fails instead of falling back
to `tan-nb-exp`.

## Cloud and local modes

A cloud context is a normal target with `NAGARE_MODE=cloud` or no mode line. The
project guardrail in `scripts/lib/target.sh` fail-closes: an ambient effective
project must match the project declared by the context. If no context/profile
declares one, the effective target must match gcloud's stored configuration.

A local context is the same file format with `NAGARE_MODE=local`. It points at
k3d, the local registry, loopback domains, and MinIO. In that mode the guardrail
steps aside after checking the local target is genuinely loopback. See
[Local development](local-development.md) for the local cluster runbook.

## Worked example: labs plus local

Create a second cloud context for a labs project, plus a laptop-only local
context:

```bash
nagarectl context create labs --project your-labs-project \
  --region us-west1 --zone us-west1-a \
  --base-domain labs.topagentnetwork.net --use

nagarectl context create local --mode local \
  --registry-host k3d-registry.localhost:5000 \
  --base-domain 127-0-0-1.sslip.io \
  --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups

nagarectl context list
# CURRENT  NAME   PROJECT             BASE DOMAIN
# *        labs   your-labs-project   labs.topagentnetwork.net
#          local  tan-nb-exp          127-0-0-1.sslip.io

nagarectl --context labs deploy -f nagare/Config.hs
NAGARE_CONTEXT=local just local-smoke
```

For a brand-new cloud project, prefer `nagarectl init labs --project
your-labs-project --base-domain labs.topagentnetwork.net`; it performs the
onboarding checks and API/config seeding described in
[Bring-your-own-project onboarding](onboarding-bring-your-own-project.md).

## Pulumi per context

Each context has its own Pulumi stack and file backend:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/
  state/
  home/
  passphrase
```

The Pulumi stack name is the context name, and the generated stack config is
`infra/pulumi/Pulumi.<context>.yaml`. Those files are git-ignored projections
derived from the context; the tracked `Pulumi.dev.yaml` has been removed.

`nagarectl init NAME`, `nagarectl context use NAME`, and `nagarectl context
create NAME --use` select the context's backend/stack and regenerate its config.
See [Provisioning with Pulumi](provisioning-with-pulumi.md) for the cloud
resource details.

### Remote GCS Pulumi state (opt-in, cloud contexts only)

The local file backend above is the default and works offline. A **cloud**
context can instead store its Pulumi state in Google Cloud Storage, so the same
context works from more than one machine and survives a lost laptop. Two context
fields select it:

```bash
export NAGARE_PULUMI_BACKEND=gcs
# optional; defaults to gs://<project>-nagare-pulumi-state/nagare/<context>
export NAGARE_PULUMI_BACKEND_URL=gs://my-bucket/nagare/prod
```

Set them when creating a context (they persist to the context file):

```bash
nagarectl context create prod --project acme-prod --pulumi-backend gcs --use \
  --pulumi-backend-member serviceAccount:ci@acme-prod.iam.gserviceaccount.com
```

- **The state bucket is bootstrapped for you.** `nagarectl init`/`context
  create --use` (and the migration script) create the bucket if missing, enable
  object versioning, and set uniform bucket-level access + public-access
  prevention. The bucket defaults to `<project>-nagare-pulumi-state` and is kept
  separate from the `<project>-nagare-backups` application bucket. Preview the
  exact `gcloud storage` commands with `nagarectl init --dry-run --pulumi-backend gcs`.
- **IAM.** The bootstrapping operator needs `roles/storage.admin` on the project
  (already in the `nagarectl init` operator role set). `--pulumi-backend-member`
  optionally grants a CI/second-operator principal bucket-scoped
  `roles/storage.objectAdmin`.
- **`PULUMI_HOME` stays local.** Only the backend URL points at GCS; Pulumi's
  workspace and credentials cache remain under the per-context local `home/`.
- **Local mode can never use GCS.** A `mode=local` context with
  `NAGARE_PULUMI_BACKEND=gcs` is downgraded to the local file backend with a
  warning — local mode has no GCP project to protect.
- **Offline shells stay fast.** Entering a gcs context does not eagerly contact
  GCS; the stack is selected/initialised by `nagarectl` operations when needed.

**Migrating an existing context between backends** uses Pulumi's supported
export/import (never file copying):

```bash
# local -> gcs (exports a timestamped rollback artifact, verifies outputs, then
# flips the context file to gcs only if baseDomain/backupBucket still match):
scripts/migrate-pulumi-backend.sh --context prod

# gcs -> local (re-imports the latest artifact; never deletes the GCS bucket):
scripts/migrate-pulumi-backend.sh --rollback --context prod
```

The local backend under `…/nagare/<context>/state` is kept as a rollback source;
remove it only after a successful `pulumi preview` on GCS.

## Cluster and host rendering

The active context also feeds bootstrap rendering:

- `just cluster-bootstrap` renders the cert-manager DNS-01 issuer project from
  the active context.
- `cluster/bootstrap/auth-install.sh` renders shomei, en, nagare-access, and
  nagared images from `NAGARE_REGISTRY_PREFIX`.
- `nagarectl host init` writes the registry and host identity into a context-owned flake under the
  XDG configuration root. `just host-image` and `just host-switch` resolve that flake without
  writing into Nagare's source or another context.

## Migrating from profile files

Migration is additive. Nothing breaks if you do nothing: an in-repo
`nagare.target.env` or `nagare.local.env` is still honored, and a checkout with
neither a context nor a profile still resolves to the historic `tan-nb-exp`
defaults.

1. Confirm the old profile still resolves.

   ```bash
   direnv allow
   nagarectl context show
   ```

2. Pick a context name such as `prod`, `labs`, or `local`.

3. Either create the context from flags:

   ```bash
   nagarectl context create prod --project YOUR_PROJECT_ID \
     --region us-west1 --zone us-west1-a \
     --base-domain apps.yourdomain.com
   ```

   Or copy the old file into the context store:

   ```bash
   mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts"
   cp nagare.target.env "${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/prod.env"
   cp nagare.local.env "${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/local.env"
   ```

   A copied local context must contain `export NAGARE_MODE=local`; the tracked
   `nagare.local.env.example` includes it.

4. Make the context current and verify it:

   ```bash
   nagarectl context use prod
   nagarectl context current
   nagarectl context show prod
   ```

5. Optionally remove the old in-repo profile once you are satisfied. Keeping it
   is also valid; it remains a lower-precedence fallback when no context is
   selected.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `no current context set` | Run `nagarectl context use NAME`, or select one command with `--context NAME` / `NAGARE_CONTEXT=NAME`. |
| `no such context: NAME` | Check `nagarectl context list`; explicit missing contexts fail closed. |
| A cloud script refuses because gcloud is on the wrong project | Re-enter the dev shell and run `gcloud config get-value project`; it must match the active cloud context's `CLOUDSDK_CORE_PROJECT`. |
| You edited `nagare.target.env` but nothing changed | A selected context outranks in-repo profiles. Run `nagarectl context current`, unset `NAGARE_CONTEXT`, or update the context file instead. |
| Pulumi is using the wrong stack | Run `nagarectl context use NAME` again to reselect the backend/stack and regenerate `Pulumi.<context>.yaml`. |

The policy details live in [`CLAUDE.md`](../../CLAUDE.md). The implementation
coordination lives in
[MasterPlan 17](../masterplans/17-first-class-target-contexts-for-nagare.md);
the command catalogue is in [Reference](reference.md), and workstation setup is
in [Getting started](getting-started.md). For the end-to-end topology and
operator workflow, see
[Running multiple Nagare clusters](../guides/running-multiple-clusters.md).
