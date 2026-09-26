---
type: Guide
title: "Target contexts"
description: "Create, select, inspect, migrate, and troubleshoot named Nagare target contexts."
docId: DOC-10
tags: [contexts, targets, configuration, migration]
generated:
  by: human:nadeem
  at: 2026-08-25T20:53:35Z
---

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
| ACME contact | `NAGARE_ACME_EMAIL` (no default — see [ACME identity](#acme-identity)) |
| ACME endpoint | `NAGARE_ACME_DIRECTORY` (`production`, `staging`, or an `https://` URL) |
| VM name | `NAGARE_INSTANCE_NAME` |
| VM shape | `NAGARE_MACHINE_TYPE`, `NAGARE_BOOT_DISK_TYPE`, `NAGARE_BOOT_DISK_SIZE_GB`, `NAGARE_DATA_DISK_SIZE_GB` |
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
| `nagarectl context delete NAME --yes` | Delete a context file only before it has substantive resource inventory history; deleting the current context clears the pointer. |
| `nagarectl context guard [--json]` | Refuse unless ADC, the Pulumi stack, the environment and `gcloud` are safe for the active context's project. |
| `nagarectl context env` | Print the active context's full shell environment as `export` lines, safe to `eval`. |

`nagarectl init NAME --project ... --base-domain ...` is the full onboarding
path for a new cloud context: it writes the named context, marks it current,
runs preflight/API enablement unless skipped, and seeds that context's Pulumi
projection. `nagarectl init` without `NAME` keeps the legacy behavior and writes
`./nagare.target.env`.

### `nagarectl context guard`

The project-confinement preflight. `just infra-up` and `just infra-preview` run it before
Pulumi, so that a disagreement about the target project stops the run rather than reaching
Google Cloud. Unlike `nagarectl platform guard` — which answers the separate
release-compatibility question and can be skipped during an upgrade with
`NAGARE_UPGRADE_APPLY` — this guard has no escape hatch: there is no situation in which
writing to the wrong project is correct.

It checks the Application Default Credentials (ADC) that Google client libraries use before
preparing or inspecting Pulumi, then compares the project the active context declares against the
Pulumi stack, environment, and gcloud configuration. Missing or malformed ADC and a known foreign
`quota_project_id` fail closed. A missing quota project, an unknowable ADC principal, or a principal
that differs from gcloud's active account is a visible warning because it is incomplete evidence,
not proof that resources target a foreign project. When the guard accepts without warnings, it
prints one line:

```text
context guard: labs confined to project acme-prod (stack labs)
```

When it refuses, it exits non-zero and always names the selected stack and resolved backend. The
stack probe has three primary failure classes with different remedies:

```text
pulumi was not found on PATH while reading gcp:project for stack 'labs' at backend 'file://...'
pulumi config --json exited with status 23 while reading gcp:project for stack 'labs' at backend 'gs://...'
Pulumi stack 'labs' at backend 'file://...' declares no gcp:project
```

For a missing executable, use the Nagare operator package and confirm the packaged tool with
`nagarectl version --tools`. For a non-zero exit, keep the selected context and fix the captured
Pulumi error under the environment printed by `nagarectl context env`; a backend authentication or
state-access failure is not evidence that the config key is absent. Only the third message means
the successful config listing proved `gcp:project` is missing; repair that projection with
`nagarectl context use <name>`. A foreign stack project uses the same projection remedy, an ambient
`CLOUDSDK_CORE_PROJECT` mismatch is fixed by unsetting that override, and a configured-project
mismatch is fixed with `gcloud config set project <project>` or by selecting the right context. A
successful Pulumi command whose output is invalid JSON or has the wrong shape also refuses and
identifies that parse failure. Repair ADC with:

```bash
gcloud auth application-default login
gcloud auth application-default set-quota-project acme-prod
```

Selecting another Nagare context or changing `gcloud config set project` does not change the ADC
file or its quota project. ADC selection follows `GOOGLE_APPLICATION_CREDENTIALS`, then
`CLOUDSDK_CONFIG/application_default_credentials.json`, then the normal gcloud ADC file under
`$HOME/.config/gcloud/`. A `mode=local` context has no project to confine, so the guard prints
`context guard: local mode; no GCP project to confine` and exits 0 without calling `gcloud`.

`--json` emits the same verdict with every compared value under `observations`. A refusal is exactly
one JSON object on stderr and no stdout, so the complete stream is accepted by `jq`. The existing
nullable `observations.stackProject` remains for compatibility; `observations.pulumiBackendUrl`
names the resolved backend and `observations.stackProjectProbe.status` is one of `found`, `missing`,
`tool-not-found`, `tool-start-failed`, `command-failed`, `invalid-output`, or `skipped`. Structured
ADC identity metadata is under `observations.adc`, and non-fatal findings are in
`observations.warnings`; credential tokens are never emitted. Applicable Pulumi details appear as
`project`, `exitCode`, `stderr`, or `error` in that probe object.

### `nagarectl context env`

Prints the active context's whole shell environment — the `CLOUDSDK_*` / `NAGARE_*` contract
plus `PULUMI_HOME`, `PULUMI_BACKEND_URL`, the passphrase file and `NAGARE_PULUMI_STACK` — as
single-quoted `export` lines and nothing else. It is safe to `eval`.

You will not normally run it yourself. The packaged `nagare` launcher evaluates it, which is
how an installed operator with no source checkout and no `.envrc` gets the same Pulumi
backend and stack that a `direnv`-loaded checkout has. Run it by hand when you want to see
exactly what a recipe will inherit:

```bash
nagarectl context env
eval "$(nagarectl context env)"   # apply it to the current shell
```

Note that it reflects the resolved profile, and the documented per-field precedence is
environment over context file. So an ambient `CLOUDSDK_CORE_PROJECT` shows up here rather
than being overridden — and `nagarectl context guard` is what refuses when such an override
disagrees with the context.

## Selecting a context

Use the selector that fits the operation:

```bash
nagarectl --context labs deploy -f nagare/Config.hs
NAGARE_CONTEXT=labs nagare smoke
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

## ACME identity

A cloud cluster serves apps over HTTPS using certificates from **Let's
Encrypt**. To obtain them the cluster registers an **ACME account**, which is
identified by a contact email address. Let's Encrypt sends certificate-expiry
and policy notices to that address. The account lives in one cluster object, the
`letsencrypt-dns` `ClusterIssuer`, created during `nagare cluster-bootstrap`.

**The contact belongs to the context, and there is no default.** Every other
context field has a safe generic default — `apps.example.com` is deliberately
non-routable, `nagare-01` is a local name — but an email address cannot have
one, because any value is somebody's real mailbox. So `NAGARE_ACME_EMAIL` is
empty until you set it:

```bash
nagarectl init labs --project your-labs-project --acme-email you@example.com
# or, for the low-level writer:
nagarectl context create labs --project your-labs-project --acme-email you@example.com
```

`nagarectl init` requires it: on a terminal it prompts, and without one it stops
and names the flag. `nagarectl context create` leaves it optional, because it
also writes local contexts, where no ACME account is ever registered.

Confirm what a context carries:

```bash
nagarectl context show labs | grep ACME
# export NAGARE_ACME_EMAIL=you@example.com
# export NAGARE_ACME_DIRECTORY=production
```

With no contact configured, rendering the issuer **refuses** — it writes nothing
to standard output and `nagare cluster-bootstrap` stops before `kubectl apply`
runs, so no `ClusterIssuer` is created under an address you did not choose:

```text
nagare: no ACME contact is configured for context 'labs'.
  Set NAGARE_ACME_EMAIL in the active context:
    nagarectl init <name> --acme-email you@example.com
    nagarectl context create <name> --acme-email you@example.com
```

### Why a wrong address is expensive

Changing `email:` on the issuer afterwards does **not** move the account. The
account is keyed by the private key in the Secret named by
`privateKeySecretRef` — `letsencrypt-dns-account-key` in the `cert-manager`
namespace. Recovering means deleting that Secret so cert-manager registers a
fresh account on its next reconcile:

```bash
kubectl -n cert-manager delete secret letsencrypt-dns-account-key
nagare cluster-bootstrap          # re-apply, now rendered from the right contact
kubectl get clusterissuer letsencrypt-dns -o wide   # READY=True again
```

Certificates already issued stay valid and keep serving; they are re-issued
under the new account at their next renewal.

### Rehearsing against Let's Encrypt staging

Let's Encrypt's staging service issues certificates that browsers do **not**
trust, but its rate limits are far looser. It is the standard way to rehearse
issuance on a new domain without burning the production quota:

```bash
nagarectl context create labs --force --acme-directory staging
```

With `--force`, `context create` changes only the fields you pass and keeps every
other stored value, including the base domain, VM shape, and platform pin. It
prints the lines that changed; confirm that only `NAGARE_ACME_DIRECTORY` moved.
Nagare 0.2.0 and earlier reset every omitted field to its default instead, so on
those versions edit the one line in the context file rather than running this
command. A changed `NAGARE_BASE_DOMAIN` replaces the Cloud DNS zone, which gets
new name servers and breaks the parent domain's delegation; `nagarectl infra guard`
refuses that plan.

This example applies before the context has substantive resource inventory
history. After admission, `context create --force`, `init NAME` on that
existing context, and `context delete --yes` refuse. Changing or removing the
profile could strand the selected history store or break its project binding.
Use `inventory store migrate` for a reviewed store move.

`NAGARE_ACME_DIRECTORY` accepts `production` (the default), `staging`, or an
absolute `https://` ACME directory URL. An unrecognized value is an **error**,
not a silent fallback: choosing production for you would burn a real rate limit,
and choosing staging for you would install untrusted certificates. Switch back
to `production` once issuance works end to end, and delete the account key
Secret as above so the production account is registered fresh.

Local contexts (`--mode local`) never contact Let's Encrypt and need neither
variable.

## Worked example: labs plus local

Create a second cloud context for a labs project, plus a laptop-only local
context:

```bash
nagarectl context create labs --project your-labs-project \
  --region us-west1 --zone us-west1-a \
  --base-domain labs.topagentnetwork.net \
  --acme-email you@example.com --use

nagarectl context create local --mode local \
  --registry-host k3d-registry.localhost:5000 \
  --base-domain 127-0-0-1.sslip.io \
  --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups

nagarectl context list
# CURRENT  NAME   PROJECT             BASE DOMAIN
# *        labs   your-labs-project   labs.topagentnetwork.net
#          local  tan-nb-exp          127-0-0-1.sslip.io

nagarectl --context labs deploy -f nagare/Config.hs
NAGARE_CONTEXT=local nagare local-smoke
```

For a brand-new cloud project, prefer `nagarectl init labs --project
your-labs-project --base-domain labs.topagentnetwork.net --acme-email
you@example.com`; it performs the
onboarding checks and API/config seeding described in
[Bring-your-own-project onboarding](onboarding-bring-your-own-project.md).

## Pulumi per context

Each context has its own Pulumi stack and file backend:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/
  state/          # file backend (absent once the context uses GCS)
  home/           # PULUMI_HOME
    passphrase    # PULUMI_CONFIG_PASSPHRASE_FILE
```

**Stack passphrase.** Pulumi's passphrase secrets provider reads the context's
`home/passphrase` file. An empty file means an empty passphrase, which is how
contexts are initialised. To protect stack secrets, run
`pulumi stack change-secrets-provider passphrase` and write the new passphrase to
that file (mode `0600`), keeping a copy in your password manager. Nagare creates the
file only when it is absent and never truncates it. A non-empty
`PULUMI_CONFIG_PASSPHRASE` in your environment takes precedence over the file; an
empty one is unset, because Pulumi would otherwise prefer the empty variable over
the file.

The Pulumi stack name is the context name. Since 0.2.1 the stack config lives at
one context-owned path,
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/pulumi/Pulumi.<context>.yaml`, next to
the context file. Every directory Nagare runs Pulumi in (each release's payload
workspace, and `infra/pulumi` in a source checkout) holds a symlink named
`Pulumi.<context>.yaml` pointing at it, so `pulumi config set` and
`just host-image` write to that one file and a new release keeps values such as
`nagare:nagareImageSelfLink`. The first Pulumi command creates the link. It adopts
an older workspace copy when no context-owned file exists yet. If two different
copies exist, or the context-owned path is a symlink to a missing file (for
example an operator repository that is not cloned), Nagare refuses and names both
paths rather than guessing. Resolve that by keeping the authoritative content at
the context-owned path.

When the stack config lives in a private operator repository, link it into place
once:

```bash
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/nagare/pulumi"
ln -s /path/to/ops/pulumi/Pulumi.<context>.yaml \
  "${XDG_CONFIG_HOME:-$HOME/.config}/nagare/pulumi/Pulumi.<context>.yaml"
```

A payload workspace also needs the Pulumi program's Node dependencies. The first
Pulumi command in a new workspace runs `npm ci` from the release's lock file, so
Node.js and npm must be on `PATH`.

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

**Reload every shell after migrating.** A shell that resolved the context before the
migration still exports `NAGARE_PULUMI_BACKEND=local` and a `file://`
`PULUMI_BACKEND_URL`. The environment overrides the context file, so that shell keeps
reading and writing the old local state. Run `direnv reload` (or open a new shell) and
confirm `echo "$PULUMI_BACKEND_URL"` prints the `gs://` URL before running Pulumi.

The bucket-ownership check reads the bucket's owning project number with
`gcloud storage buckets describe --raw`; current gcloud releases omit that field from
the formatted output.

### Shared inventory history (cloud contexts)

Resource inventory history defaults to a private local directory under
`${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/inventory`. A cloud
context may use its state bucket instead:

```bash
export NAGARE_INVENTORY_STORE=gcs
# optional: defaults to gs://<project>-nagare-pulumi-state/nagare/<context>/inventory
export NAGARE_INVENTORY_STORE_URL=gs://my-bucket/nagare/prod/inventory
```

Use `nagarectl inventory store status --json` to see the selected store's
binding, head digest, generation, active transaction, and executor claim.
The GCS store uses conditional object generations, and an active transaction
belongs to one client identity. A second workstation must explicitly run
`nagarectl inventory resume TRANSACTION --take-over --yes` after deciding the
previous executor is no longer active. There is no remote heartbeat or liveness
test. A local-mode context always uses the local inventory store.

Move an existing history before selecting another store:

```bash
nagarectl inventory store migrate --to gcs --dry-run
nagarectl inventory store migrate --to gcs --yes
# To return to local history later:
nagarectl inventory store migrate --to local --dry-run
nagarectl inventory store migrate --to local --yes
```

Migration copies and verifies all members before it marks the source head as
migrated, then updates the context file through its symlink. If interrupted
after marking the source, repeat the same command to finish the context update.
Reload every shell after migration; a stale shell is refused by the source
tombstone. No bucket objects are deleted by migration. Any inventory mutation
using GCS needs bucket access. Principals who can read that prefix can also
read private native review bundles, including sensitive provider inputs.

For a local-store context, back up the full private history with
`nagarectl --context NAME inventory export --out DIRECTORY`. On a second
state root with the same context and project configuration, inspect the
backup with `nagarectl --context NAME inventory restore --from DIRECTORY`,
then repeat with `--yes` to restore it into an **empty** local inventory store.
The restore verifies the export's member digests and refuses a different
context/project or any occupied destination. Check `inventory store status`
before planning another mutation. Keep the export private because it contains
native reviews and may contain sensitive provider inputs.

## Cluster and host rendering

The active context also feeds bootstrap rendering:

- `nagare cluster-bootstrap` renders the cert-manager DNS-01 issuer project from
  the active context.
- `cluster/bootstrap/auth-install.sh` renders shomei, en, nagare-access, and
  nagared images from `NAGARE_REGISTRY_PREFIX`.
- `nagarectl host init` writes the registry and host identity into a context-owned flake under the
  XDG configuration root. `nagare host-image` and `nagare host-switch` resolve that flake without
  writing into Nagare's source or another context.

## Keeping contexts in a private repository

Contexts, host flakes, and encrypted cluster secrets are operator material, not part
of Nagare. To version and back them up, keep them in your own **private** git
repository and link it into the paths Nagare already reads:

```bash
OPS=~/src/my-nagare-ops          # your private repository
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/nagare"
mkdir -p "$CFG/contexts" "$CFG/hosts" "$CFG/cluster-secrets"
ln -sfn "$OPS/contexts/prod.env"       "$CFG/contexts/prod.env"
ln -sfn "$OPS/hosts/prod"              "$CFG/hosts/prod"
ln -sfn "$OPS/cluster-secrets/prod"    "$CFG/cluster-secrets/prod"
ln -sfn "$OPS/pulumi/Pulumi.prod.yaml" infra/pulumi/Pulumi.prod.yaml   # from a Nagare checkout
```

Nagare's own writes to these files (backend migration, platform-version updates,
Pulumi config changes) go through the links and keep them intact. Keep Pulumi
**state** out of git by using the [GCS backend](#remote-gcs-pulumi-state-opt-in-cloud-contexts-only);
the context file then records where the state lives. Never commit age private keys
or the Pulumi passphrase file. Because a host flake inside a git repository is
evaluated as a git flake, `git add` new files under `hosts/<context>/` before
running `nagare host-switch`.

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

## Replacement transaction ownership

Replacement transactions belong to one context and record its exact GCP project, zone, host IDs,
reserved address, payload identity, and drift token. Cutover and cleanup require the confirmation
token `<context>/<transaction-suffix>` and re-read actual state before mutation. Copying a
transaction to another context or changing a recorded identity makes it invalid; never edit the JSON
to bypass that guard.
