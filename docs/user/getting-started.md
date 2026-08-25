# Getting started

> **Status:** ✅ Working

This page gets your workstation ready to operate Nagare: the toolchain, the
project-pinned dev shell, `direnv`, target contexts, and the GCP
project-isolation guardrails.
Everything else in this guide assumes you have done this once.

---

## What you're operating

In cloud mode, Nagare is a single GCP Compute Engine VM (`nagare-01`) running
NixOS, k3s, Knative, and the Victoria observability stack. In local mode, the
same app platform runs on k3d with a local registry and MinIO object store. You
operate both targets entirely from this repository: Pulumi owns the cloud, a Nix
flake owns the host image, and a `justfile` wraps the common steps.

## Prerequisites

You need, on your workstation:

- **Nix** with flakes enabled. The dev shell (below) provides *everything else*
  — `pulumi`, `node`/`tsc`, `gcloud`, `kubectl`, `helm`, `ghc`/`cabal`, `sops`,
  `age`, etc. — so you should **not** install those globally.
- **`direnv`** (recommended) to auto-load the dev shell on `cd`.
- A **Google Cloud identity** with access to *your* GCP project (the default
  example is `tan-nb-exp`); see [GCP prerequisites](gcp-prerequisites.md) for the
  auth, IAM roles, project, and API setup, and
  [Bring-your-own-project onboarding](onboarding-bring-your-own-project.md) for the
  from-zero runbook. This is required for cloud mode, not for local mode.
- **Docker** if you want local mode (`just local-up` uses k3d).
- An **SSH key** (`~/.ssh/id_ed25519`). Supply its public `.pub` file when generating the selected
  context's host flake; Nagare contains no default operator identity. See
  [Host image and first boot](host-image-and-boot.md).

> This workstation is `aarch64-darwin` (Apple Silicon). GCE images are
> `x86_64-linux`, so the host image is **not** built locally — it's built on an
> on-demand Linux builder in GCP. You don't need a Linux machine; see
> [Host image and first boot](host-image-and-boot.md).

## Enter the dev shell

The repo pins its entire toolchain in `flake.nix`. Load it with either:

```bash
# One-off:
nix develop

# Or, persistently, via direnv (run once per fresh checkout):
direnv allow
```

`direnv allow` runs `.envrc`, which does two things: exports the project
isolation variables (below) and runs `use flake` so the pinned tools land on
your `PATH`. After this, simply `cd`-ing into the repo gives you a ready shell.

Verify:

```bash
pulumi version
gcloud --version
kubectl version --client
just --list      # the available operator recipes
```

## Project isolation (read this once, internalize it)

Nagare acts on **one** cloud project per command, but **which** project is
*configurable*. The target is the active [context](contexts.md): a named bundle
selected by `nagarectl --context NAME`, `NAGARE_CONTEXT=NAME`, or
`nagarectl context use NAME`. `.envrc` resolves that context, then exports the
Cloud SDK variables and Nagare contract variables for the shell.

The old git-ignored target profile still works as a fallback. With no selected
context, `.envrc` checks `nagare.target.env` and then exports the
`tan-nb-exp` / `us-west1` / `us-west1-a` values as **fallback defaults**:

```bash
[ -f "$PWD/nagare.target.env" ] && source_env "$PWD/nagare.target.env"
export CLOUDSDK_CORE_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"
export CLOUDSDK_COMPUTE_REGION="${CLOUDSDK_COMPUTE_REGION:-us-west1}"
export CLOUDSDK_COMPUTE_ZONE="${CLOUDSDK_COMPUTE_ZONE:-us-west1-a}"
```

Selection precedence: **`--context` / `NAGARE_CONTEXT` > current context >
in-repo profile > built-in default**. Per-field values still follow
**environment > context/profile > default**, but a cloud-project override that
disagrees with the selected context is rejected by guarded scripts. So any bare `gcloud …` you type
inside the repo defaults to the active project, region, and zone — and an
operator who does nothing keeps the original `tan-nb-exp` behavior. This is
**defense in depth, not a license to omit flags**:

- The guardrail lives in one place, `scripts/lib/target.sh`. Scripts source it and
  call `_require_target_project`. When a context/profile declares a project, the
  final effective project must equal that declaration; an ambient
  `CLOUDSDK_CORE_PROJECT` cannot silently retarget the script. Without a declared
  project, the effective/default project must match gcloud's configured project,
  read with the environment override removed. The check is **fail-closed** and
  avoids comparing two values derived from the same environment variable.
- Scripts also pass `--project="$TARGET_PROJECT"` explicitly on every call.

If a script reports that the effective project differs from the context's
declared project, unset the ambient `CLOUDSDK_CORE_PROJECT` override or select
the intended context. If it reports that gcloud's configured project differs,
run `gcloud config set project <expected>` or create/select a context that
declares the target. Re-enter the shell (`direnv allow` / `nix develop`) after
changing context files.

For local mode, use a `mode=local` context. In that mode the guardrail steps
aside intentionally after loopback checks, `nagarectl` uses the local registry
and loopback base domain, and backup Jobs use local MinIO instead of GCS. See
[Local development](local-development.md).

To point the same checkout at another target, switch contexts with
`nagarectl context use NAME` or select one command with `--context NAME`; no
second checkout is needed. The full configurable-isolation policy is in
[`CLAUDE.md`](../../CLAUDE.md); the architectural decision is
[MasterPlan 17](../masterplans/17-first-class-target-contexts-for-nagare.md).

## Pulumi state is per context

`.envrc` also derives a Pulumi file backend and workspace from the active
context:

```bash
export PULUMI_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/home"
export PULUMI_BACKEND_URL="file://${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/state"
```

Each context has its own stack and backend, so `labs` and `prod` cannot collide
on local state. Generated `infra/pulumi/Pulumi.<context>.yaml` files are
git-ignored projections from the context. A cloud context can opt into a remote
GCS state backend instead (`NAGARE_PULUMI_BACKEND=gcs`), in which case
`PULUMI_BACKEND_URL` is a `gs://…` URL and `PULUMI_HOME` stays local — see
[Target contexts](contexts.md#remote-gcs-pulumi-state-opt-in-cloud-contexts-only). See
[Provisioning with Pulumi](provisioning-with-pulumi.md).

## The `justfile` is your control surface

Most operations are one `just` recipe. They are deliberately **thin wrappers** —
the real logic lives in scripts and the plans they reference.

```bash
just                 # list all recipes (same as just --list)
just infra-preview   # preview cloud changes
just infra-up        # apply cloud changes
just host-image      # build + register the NixOS GCE image
just host-switch     # apply day-2 host config over Tailscale
just local-up        # create local k3d cluster + registry
just local-bootstrap # install Knative/Kourier locally
just local-minio     # install local MinIO backup store
just status          # kubectl: pods + Knative services across namespaces
```

Recipes honor the active context. For a one-off target selection:

```bash
NAGARE_CONTEXT=labs just smoke
```

The full recipe list with what each does is in the [Reference](reference.md).

## Where to go next

You're set up. Stand up the cloud perimeter:
**[Provisioning with Pulumi →](provisioning-with-pulumi.md)**

Running more than one target? Define and switch them in
**[Target contexts →](contexts.md)**.

### Running nagare locally

Don't want a GCP account yet? **Local mode** runs the whole platform on a k3d
cluster on your laptop — same `nagarectl` commands, a local registry, a loopback
apps domain, and MinIO instead of GCS — so you can test the real use cases
(deploy, managed databases, snapshot/restore, require-login) with no cloud bill.
Start the local cluster with `just local-up && just local-bootstrap`, then follow
**[Local development →](local-development.md)**. A single `just local-smoke`
exercises deploy → snapshot/restore → HTTP 200 → teardown end to end, zero-cloud.
