# Getting started

> **Status:** ✅ Working

This page gets your workstation ready to operate Nagare: the toolchain, the
project-pinned dev shell, `direnv`, and the GCP project-isolation guardrails.
Everything else in this guide assumes you have done this once.

---

## What you're operating

Nagare is a single GCP Compute Engine VM (`nagare-01`) running NixOS, k3s, and
(eventually) Knative + the Victoria observability stack. You operate it entirely
from this repository: Pulumi owns the cloud, a Nix flake owns the host image,
and a `justfile` wraps the common steps. There is no separate control plane and
no shared state outside this repo plus a handful of encrypted secrets.

## Prerequisites

You need, on your workstation:

- **Nix** with flakes enabled. The dev shell (below) provides *everything else*
  — `pulumi`, `node`/`tsc`, `gcloud`, `kubectl`, `helm`, `ghc`/`cabal`, `sops`,
  `age`, etc. — so you should **not** install those globally.
- **`direnv`** (recommended) to auto-load the dev shell on `cd`.
- A **Google Cloud identity** with access to the `tan-nb-exp` project.
- An **SSH key** (`~/.ssh/id_ed25519`). The operator public key baked into
  `nagare-01` is in `nixos/hosts/nagare-01/users.nix`; if your key differs,
  see [Day-2 host changes](day-2-host-changes.md) to add it.

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

`.envrc` exports:

```bash
export CLOUDSDK_CORE_PROJECT=tan-nb-exp
export CLOUDSDK_COMPUTE_REGION=us-west1
export CLOUDSDK_COMPUTE_ZONE=us-west1-a
```

So any bare `gcloud …` you type inside the repo defaults to the right project,
region, and zone. This is **defense in depth, not a license to omit flags**:

- Scripts under `scripts/` run a preflight assertion that aborts if the active
  project isn't `tan-nb-exp`.
- Scripts also pass `--project=tan-nb-exp` explicitly on every call.

If you ever see a script refuse to run with *"refusing to run: gcloud active
project is …"*, you're outside the dev shell or your `gcloud` config overrides
the env var. Re-enter the shell (`direnv allow` / `nix develop`) and retry.

**Never** point any command in this repo at another GCP project — including
read-only `list`/`describe`. Changing that is an architectural decision that
must be recorded in the MasterPlan Decision Log *first*
([`CLAUDE.md`](../../CLAUDE.md)).

## Pulumi state is in-repo

`.envrc` also sets:

```bash
export PULUMI_HOME="$PWD/infra/pulumi/.pulumi-home"
export PULUMI_CONFIG_PASSPHRASE=""   # empty passphrase for now
```

Pulumi state, credentials, and plugins live **inside the repo** (a `file://`
backend), not under `~/.pulumi/`, so this project can never collide with another
Pulumi project on your machine. The secrets provider is the passphrase provider
with an empty passphrase for now; to harden it later, run
`pulumi stack change-secrets-provider passphrase` with a real value and update
`.envrc`. See [Provisioning with Pulumi](provisioning-with-pulumi.md).

## The `justfile` is your control surface

Most operations are one `just` recipe. They are deliberately **thin wrappers** —
the real logic lives in scripts and the plans they reference.

```bash
just                 # list all recipes (same as just --list)
just infra-preview   # preview cloud changes
just infra-up        # apply cloud changes
just host-image      # build + register the NixOS GCE image
just host-switch     # apply day-2 host config over Tailscale
just status          # kubectl: pods + Knative services across namespaces
```

The full recipe list with what each does is in the [Reference](reference.md).

## Where to go next

You're set up. Stand up the cloud perimeter:
**[Provisioning with Pulumi →](provisioning-with-pulumi.md)**
