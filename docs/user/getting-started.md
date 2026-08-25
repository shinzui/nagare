# Getting started

> **Status:** ✅ Working

This page gets your workstation ready to operate a pinned Nagare release: the
operator tools, release package, target contexts, and the GCP
project-isolation guardrails.
Everything else in this guide assumes you have done this once.

---

## What you're operating

In cloud mode, Nagare is a single GCP Compute Engine VM (`nagare-01`) running
NixOS, k3s, Knative, and the Victoria observability stack. In local mode, the
same app platform runs on k3d with a local registry and MinIO object store. You
operate both targets from an immutable release payload: Pulumi owns the cloud, a Nix
flake owns the host image, and the `nagare` launcher runs the common recipes.

## Prerequisites

You need, on your workstation:

- **Nix** with flakes enabled. It installs the pinned CLI and platform payload.
- Operator clients used by the selected recipes: `pulumi`, `node`, `gcloud`, `kubectl`, `helm`,
  `sops`, `age`, and `tailscale`. Install them through Nix or your platform package manager.
- A **Google Cloud identity** with access to *your* GCP project (the default
  example is `tan-nb-exp`); see [GCP prerequisites](gcp-prerequisites.md) for the
  auth, IAM roles, project, and API setup, and
  [Bring-your-own-project onboarding](onboarding-bring-your-own-project.md) for the
  from-zero runbook. This is required for cloud mode, not for local mode.
- **Docker** and `k3d` if you want local mode (`nagare local-up` uses them).
- An **SSH key** (`~/.ssh/id_ed25519`). Supply its public `.pub` file when generating the selected
  context's host flake; Nagare contains no default operator identity. See
  [Host image and first boot](host-image-and-boot.md).

> This workstation is `aarch64-darwin` (Apple Silicon). GCE images are
> `x86_64-linux`, so the host image is **not** built locally — it's built on an
> on-demand Linux builder in GCP. You don't need a Linux machine; see
> [Host image and first boot](host-image-and-boot.md).

## Install the operator release

Choose a reviewed version from the [release page](https://github.com/shinzui/nagare/releases), then
install its full operator output. No checkout or `direnv` session is required:

```bash
export NAGARE_VERSION=0.1.0
nix profile install "github:shinzui/nagare/v${NAGARE_VERSION}#nagare"
nagarectl version --json
nagare --list
```

For one-off use, run
`nix run "github:shinzui/nagare/v${NAGARE_VERSION}#nagarectl" -- …`. See
[Installing Nagare](installation.md) for app-developer and contributor workflows.

Verify:

```bash
pulumi version
gcloud --version
kubectl version --client
nagare --list    # the release's available operator recipes
```

## Project isolation (read this once, internalize it)

Nagare acts on **one** cloud project per command, but **which** project is
*configurable*. The target is the active [context](contexts.md): a named bundle
selected by `nagarectl --context NAME`, `NAGARE_CONTEXT=NAME`, or
`nagarectl context use NAME`. Named contexts live below the user's XDG configuration root.

The old checkout-local target profile still works as a contributor fallback. With no selected
context, the legacy source environment checks `nagare.target.env` and exports the
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
declares the target. Start a fresh shell after changing exported overrides.

For local mode, use a `mode=local` context. In that mode the guardrail steps
aside intentionally after loopback checks, `nagarectl` uses the local registry
and loopback base domain, and backup Jobs use local MinIO instead of GCS. See
[Local development](local-development.md).

To point the same installed release at another target, switch contexts with
`nagarectl context use NAME` or select one command with `--context NAME`; no
checkout is needed. The full configurable-isolation policy is in
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

## The `nagare` launcher is your control surface

Most operations are one release-owned recipe. The launcher resolves the immutable payload to a
writable per-context workspace before invoking its `justfile`.

```bash
nagare --list          # list release-owned recipes
nagare infra-preview   # preview cloud changes
nagare infra-up        # apply cloud changes
nagare host-image      # build + register the NixOS GCE image
nagare host-switch     # apply day-2 host config over Tailscale
nagare local-up        # create local k3d cluster + registry
nagare local-bootstrap # install Knative/Kourier locally
nagare local-minio     # install local MinIO backup store
nagare status          # kubectl: pods + Knative services across namespaces
```

Recipes honor the active context. For a one-off target selection:

```bash
NAGARE_CONTEXT=labs nagare smoke
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
Start the local cluster with `nagare local-up && nagare local-bootstrap`, then follow
**[Local development →](local-development.md)**. A single `nagare local-smoke`
exercises deploy → snapshot/restore → HTTP 200 → teardown end to end, zero-cloud.

## Contributor checkout

Only contributors enter the repository dev shell. Clone the source, run `nix develop`, and use
`just` or `nix run .#nagare` against the working tree. Those commands are development inputs and
must not replace version tags in operator automation.
