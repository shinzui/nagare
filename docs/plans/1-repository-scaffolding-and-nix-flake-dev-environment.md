---
id: 1
slug: repository-scaffolding-and-nix-flake-dev-environment
title: "Repository scaffolding and Nix flake dev environment"
kind: exec-plan
created_at: 2026-06-02T15:39:48Z
intention: "intention_01kt4f3svnekz80g94f2k4tthq"
master_plan: "docs/masterplans/1-bootstrap-nagare-personal-paas.md"
---

# Repository scaffolding and Nix flake dev environment

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This is the foundation plan for **Nagare** (流れ, "flow"), a small personal Platform-as-a-Service
(PaaS) — a system that lets one person deploy many small web projects to their own cloud server with
a single command. Nagare runs on a single Google Cloud Platform (GCP) virtual machine. It is built
from six other plans (numbered 2 through 7 under `docs/plans/`) that each install a different layer:
the cloud resources (Pulumi), the operating system (NixOS), the container cluster (k3s), the
app-serving platform (Knative), the monitoring stack (the VictoriaMetrics/Logs/Traces family plus
Grafana), and a command-line tool (`nagarectl`) written in Haskell. Every one of those plans assumes
a working set of command-line tools — `pulumi`, `kubectl`, `helm`, `gcloud`, the Haskell compiler,
and so on — and a couple of repository-wide conventions about which GCP project to use and how to
write Git commits.

This plan builds exactly that foundation and nothing else. After this plan is complete, a developer
who clones the repository can run one command, `nix develop`, and be dropped into a shell where every
tool the other six plans need is on the `PATH` at a pinned, reproducible version. They can run a
second command, `direnv allow`, so those tools and a fixed set of environment variables (which GCP
project, region, and zone to target) load automatically every time they enter the directory. They can
run `just --list` to see the high-level commands that wire the whole system together. And they will
find a directory skeleton already laid out so each later plan has an obvious home for its files.

Concretely, "done" for this plan means all of the following observable behaviors are true. Running
`nix develop -c pulumi version` prints a Pulumi version string (`v3.239.0` or whatever release we
pinned). Running `nix develop -c kubectl version --client`, `nix develop -c helm version`,
`nix develop -c ghc --version`, `nix develop -c cabal --version`, `nix develop -c sops --version`,
and `nix develop -c just --version` each print that tool's version. Running `direnv allow` once and
then `echo $CLOUDSDK_CORE_PROJECT` prints `tan-nb-exp`. Running `just --list` prints a list of recipe
names (`infra-up`, `infra-preview`, `host-image`, `host-switch`, `cluster-bootstrap`, `observability`,
`deploy-hello`, `status`). And the directory tree contains empty-but-tracked placeholder folders for
every later plan's output. No cloud resources are created, no virtual machine is provisioned, and no
cluster is started by this plan — that is all deliberately deferred to later plans.

The terms used above, defined in plain language so this file stands alone:

- **Nix** is a package manager and build system. A **flake** is a single file, `flake.nix`, that
  declares exactly which versions of which tools a project uses, so two machines produce the same
  environment. **`nix develop`** reads that file and opens a shell with those tools on the `PATH`.
- **direnv** is a small utility that, when you `cd` into a directory containing a file named `.envrc`,
  automatically applies the environment described there (environment variables, and via `use flake`,
  the Nix dev shell). You authorize it once per directory with `direnv allow`.
- **Pulumi** is an infrastructure-as-code tool: you write TypeScript that describes cloud resources
  and `pulumi up` creates them. We pin a specific Pulumi release through Nix.
- **kubectl** is the command-line client for Kubernetes (a container cluster). **helm** installs
  packaged Kubernetes applications ("charts"). **k3s** is a lightweight Kubernetes distribution.
- **Knative** turns a single container image into an auto-scaling ("scale-to-zero") web service.
- **gcloud** / **gsutil** are the Google Cloud command-line tools, shipped together in the
  **Google Cloud SDK**.
- **sops** and **age** are tools for encrypting secrets so they can be safely committed to Git.
- **GHC** is the Glasgow Haskell Compiler; **cabal** is Haskell's build tool. `nagarectl` (plan 6) is
  written in Haskell, so the dev shell must provide both.
- **just** is a command runner that reads a file named `justfile` containing named "recipes" (short
  shell snippets). It is like `make` but simpler.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here, even if it
requires splitting a partially completed task into two ("done" vs. "remaining"). This section must
always reflect the actual current state of the work.

- [ ] M1: Author `flake.nix` at the repo root with the pinned Pulumi overlay and the combined dev
      shell, then verify every tool prints its version under `nix develop`.
- [ ] M1: Obtain the correct release-specific `vendorHash` values for `pulumi` and `pulumi-nodejs`
      (start from the reference repo's pinned 3.239.0; refresh only if a different version is chosen).
- [ ] M2: Create the repository directory skeleton with `.gitkeep` placeholder files.
- [ ] M2: Author the root `justfile` with thin wrapper recipes and verify `just --list`.
- [ ] M2: Update `README.md` so it reflects the corrected decisions (Haskell CLI, cert-manager TLS,
      `tan-nb-exp` project) and verify a `.gitignore` exists covering Nix/Pulumi/direnv artifacts.
- [ ] M3: Author `.envrc` with the GCP isolation env vars and `use flake`; run `direnv allow` and
      confirm `$CLOUDSDK_CORE_PROJECT` is `tan-nb-exp`.
- [ ] M3: Author the root `CLAUDE.md` restating GCP project isolation, the preflight assertion, and
      the Git conventions.
- [ ] Final: Run the full acceptance checklist in "Validation and Acceptance" and record outcomes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during implementation.
Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Scope EP-1 to the repository foundation only — `flake.nix`, the `nix develop` dev shell,
  `.envrc`, `CLAUDE.md`, `justfile`, `README.md`, `.gitignore`, and empty placeholder directories. No
  cloud resources, no VM, no cluster.
  Rationale: The MasterPlan (`docs/masterplans/1-bootstrap-nagare-personal-paas.md`) makes EP-1 the
  sole Wave-1 "Foundation" plan that every other plan soft-depends on. Keeping it to the toolchain and
  conventions makes it independently verifiable (tools print versions; env vars set) and unblocks all
  six downstream plans without coupling to any cloud state.
  Date: 2026-06-02

- Decision: Provide a single combined `nix develop` dev shell that includes the Haskell toolchain
  (`ghc` + `cabal-install`) alongside everything else, rather than a minimal default shell plus a
  separate Haskell shell.
  Rationale: Simplicity for the reader — one command (`nix develop`) gives the full toolchain for all
  plans. The Haskell compiler is a large download (its "closure" — the compiler plus all its
  dependencies — is multiple gigabytes), so this plan documents an optional `devShells.<system>.haskell`
  split for anyone who wants a lighter default shell, but the default ships everything combined.
  Date: 2026-06-02

- Decision: Pin Pulumi to the same upstream release the reference repo uses, **3.239.0**, via a
  `pkgs.pulumi.overrideAttrs` overlay with a matching `pulumiPackages.pulumi-nodejs.override` overlay,
  copied verbatim in shape from `/Users/shinzui/Keikaku/bokuno/load-testing-infra/flake.nix`.
  Rationale: Integration Point 8 of the MasterPlan requires the same pinned-Pulumi-via-Nix pattern as
  the sibling `load-testing-infra` repo, which is the canonical pattern source. Reusing the proven
  override and its already-known hashes minimizes risk; the reader may bump the version later but must
  refresh the hashes when they do (procedure documented in this plan).
  Date: 2026-06-02

- Decision: The `Pulumi.yaml` `runtime` for Nagare's infra project will be `nodejs` (TypeScript),
  matching the `mori.dhall` package identity (`infra-pulumi`, language TypeScript) and the reference
  repo. The dev shell therefore ships `nodejs_20`, `typescript`, and `pulumi-nodejs`.
  Rationale: The MasterPlan Decision Log distinguishes the CLI (Haskell) from "the provisioning is
  pulumi and nix"; `mori.dhall` declares `infra-pulumi` as TypeScript. EP-1 only provides the
  toolchain; EP-2 authors the actual Pulumi project.
  Date: 2026-06-02

- Decision: Reuse the `tan-nb-exp` / `us-west1` / `us-west1-a` GCP isolation policy and the per-script
  preflight assertion verbatim from the reference repo, encoded in `.envrc` and `CLAUDE.md`.
  Rationale: MasterPlan Integration Point 9 and the MasterPlan Decision Log mandate the identical hard
  isolation policy. EP-1 is the plan that owns this policy file-wise; downstream plans obey it.
  Date: 2026-06-02


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare the result
against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The reader is assumed to know nothing about this repository. The working directory for every command
in this plan is the repository root, which on the author's machine is
`/Users/shinzui/Keikaku/bokuno/nagare`. All file paths below are written relative to that root (for
example, `flake.nix` means `/Users/shinzui/Keikaku/bokuno/nagare/flake.nix`).

At the start of this plan the repository already contains: a `README.md` (an early draft that predates
some design decisions and will be lightly corrected here), a `.gitignore` (covers tool config dirs),
a `mori.dhall` (a machine-readable description of the project's packages — informational only, you do
not edit it), the design specification at `docs/initial-spec.md`, the coordination document at
`docs/masterplans/1-bootstrap-nagare-personal-paas.md`, and this plan under `docs/plans/`. It does
**not** yet contain a `flake.nix`, an `.envrc`, a `justfile`, a root `CLAUDE.md`, or any of the
`infra/`, `nixos/`, `cluster/`, `cli/`, or `scripts/` directories.

Two external documents are the authoritative sources this plan derives from, and you should keep them
in mind:

The **MasterPlan** at `docs/masterplans/1-bootstrap-nagare-personal-paas.md` coordinates all seven
plans. Two of its "Integration Points" bind this plan directly. Integration Point 8 ("Developer shell
toolchain") lists the exact tools the `nix develop` shell must provide. Integration Point 9 ("GCP
project isolation") mandates that every cloud command target the GCP project `tan-nb-exp`, region
`us-west1`, zone `us-west1-a`, enforced through `.envrc` environment variables and a `CLAUDE.md`
policy. Read both before editing; this plan reproduces their substance so you do not strictly need to,
but they are the source of truth.

The **spec corrections appendix** at the very end of `docs/initial-spec.md` (the section titled "Spec
Accuracy Corrections (2026-06-02)") overrides the prose earlier in that file wherever they conflict.
The corrections relevant to this plan: `nagarectl` is **Haskell**, not TypeScript (so the dev shell
needs GHC and cabal, and the `cli/nagarectl/` directory is a Cabal project, not a Node package); the
canonical GCP project is `tan-nb-exp` (not the `my-project` placeholder); and TLS uses cert-manager,
not Caddy. The early `README.md` in the repo still shows the pre-correction choices in a couple of
places; M2 fixes those.

The **reference repository** at `/Users/shinzui/Keikaku/bokuno/load-testing-infra` is the canonical
pattern source. It runs the same toolchain family (NixOS + GCP + Pulumi pinned via Nix) and the
MasterPlan instructs us to copy its patterns closely. The four files you will mirror are
`flake.nix` (the pinned-Pulumi dev shell), `.envrc` (the GCP isolation env vars plus `use flake`),
`CLAUDE.md` (the isolation policy and preflight assertion), and `infra/pulumi/Pulumi.yaml` (confirms
the Pulumi runtime is `nodejs`). You may read those files directly; their relevant contents are also
embedded in the Concrete Steps below so this plan stands alone.

One important fact about the developer workstation: it is an Apple-silicon Mac, whose Nix "system"
identifier is `aarch64-darwin`. The GCP virtual machine will run Linux (`x86_64-linux`). That is why
the flake's `systems` list includes both. It is also why, in later plans, NixOS images are built on a
remote Linux builder rather than locally — but image building is entirely out of scope for EP-1; we
only need the dev shell to evaluate on both systems so the same `flake.nix` works on the Mac today and
on a Linux CI machine or the builder later.


## Plan of Work

The work is three milestones, each independently verifiable. The order is deliberate: the dev shell
(M1) is the thing every other deliverable and plan depends on, so it comes first and is proven before
anything else is built. The skeleton, `justfile`, and docs (M2) give the later plans homes and
high-level entry points. The environment and policy files (M3) wire the GCP isolation and conventions
into every shell session. Throughout, the guiding principle is that the `justfile` recipes and the
directory placeholders are **thin** — they reserve space and name the commands, but the substantive
contents belong to plans 2 through 7, which are referenced by path so the reader knows where to look.

**Milestone M1 — the Nix flake and dev shell.** The scope is a single new file, `flake.nix`, at the
repository root, that defines `devShells.<system>.default` as an `mkShell` containing every tool from
Integration Point 8, with Pulumi pinned via the override pattern copied from the reference repo. At
the end of this milestone, the file exists and `nix develop -c <tool> --version` (or the tool's
equivalent version command) succeeds for `pulumi`, `kubectl`, `helm`, `ghc`, `cabal`, `sops`, and
`just`, and `which gcloud`, `which gsutil`, `which tailscale`, `which age`, `which jq`, `which socat`,
`which tsc`, and `which node` all resolve to Nix store paths inside the shell. The acceptance is the
observed version output shown in Concrete Steps. The one subtlety is the Pulumi `vendorHash` values:
they are specific to the pinned release and cannot be invented. We start from the reference repo's
known-good 3.239.0 hashes (reproduced below); if you choose to bump the version, the plan explains how
to let Nix tell you the new hashes.

**Milestone M2 — repository skeleton, `justfile`, `README.md` correction, and `.gitignore`.** The
scope is creating the placeholder directory tree (so the layout the corrected spec and `mori.dhall`
expect physically exists), writing the root `justfile` with thin wrapper recipes for the
system-wiring commands, lightly correcting the existing `README.md` where it still shows
pre-correction choices, and ensuring `.gitignore` covers Nix, Pulumi, and direnv build artifacts. At
the end, `just --list` prints all eight recipe names and the directory tree (verified with `find` or
`ls -R`) contains the expected folders each holding a `.gitkeep`. Acceptance is the `just --list`
output and the directory listing shown in Concrete Steps.

**Milestone M3 — `.envrc` and root `CLAUDE.md`.** The scope is two files: `.envrc` (the GCP isolation
env vars, the in-repo Pulumi home and passphrase, and `use flake`), and `CLAUDE.md` (the project
isolation policy with the preflight assertion snippet, plus the Conventional Commits and
no-feature-branches conventions). At the end, running `direnv allow` once and then
`echo $CLOUDSDK_CORE_PROJECT` prints `tan-nb-exp`, and `echo $CLOUDSDK_COMPUTE_REGION` prints
`us-west1`. Acceptance is that env-var output shown in Concrete Steps.


## Concrete Steps

Every command below is run from the repository root unless a different directory is shown. Where a
command produces output, an expected transcript follows so you can compare; exact version numbers and
hashes will vary, so match the *shape* of the output, not every character.

A prerequisite for the whole plan: you must have Nix installed with "flakes" enabled, and `direnv`
installed and hooked into your shell. To check Nix and flakes:

```bash
nix --version
nix flake --help >/dev/null && echo "flakes enabled"
```

Expected (version will differ):

```text
nix (Nix) 2.24.10
flakes enabled
```

If `nix flake` errors with "experimental feature", enable flakes by adding the line
`experimental-features = nix-command flakes` to `~/.config/nix/nix.conf` (create the file if needed),
then re-run the check. To check direnv:

```bash
direnv version
```

Expected (version will differ):

```text
2.34.0
```

If direnv is not hooked into your shell, follow your shell's hook line (for `zsh`, add
`eval "$(direnv hook zsh)"` to `~/.zshrc` and restart the shell). direnv is only needed for M3.


### M1: author `flake.nix`

Create the file `flake.nix` at the repository root with the following content. This mirrors the
reference repo's `flake.nix` structure exactly — `inputs.nixpkgs.url` pinned to `nixos-unstable`, a
`systems` list, a `forAllSystems` helper, the `pulumi` / `pulumi-nodejs` override pair, and a
`devShells.<system>.default` `mkShell` — and extends the `packages` list to every tool Integration
Point 8 requires.

```nix
{
  description = "nagare developer shell (project-pinned Pulumi + Haskell + cloud toolchain)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs { inherit system; }));
    in {
      devShells = forAllSystems (pkgs:
        let
          # Pulumi 3.239.0 is upstream's current release at the time this
          # repo was scaffolded; nixpkgs ships an older one. We override
          # version + source + vendor hashes so the dev shell ships a
          # current CLI without waiting for nixpkgs to bump. The shape of
          # this override is copied verbatim from the sibling reference
          # repo /Users/shinzui/Keikaku/bokuno/load-testing-infra/flake.nix.
          #
          # IMPORTANT: the two `vendorHash` values below are SPECIFIC TO
          # THIS RELEASE. If you bump `version`, they will be wrong and the
          # build will fail with a hash mismatch. See the plan section
          # "Refreshing the Pulumi hashes" for how to obtain new ones.
          pulumi = pkgs.pulumi.overrideAttrs (_: rec {
            version = "3.239.0";
            src = pkgs.fetchFromGitHub {
              owner = "pulumi";
              repo = "pulumi";
              tag = "v${version}";
              hash = "sha256-dkBiEKK0qgQOATolv4o49yIUk0W6uf27LWaESoLhOU4=";
              name = "pulumi";
            };
            vendorHash = "sha256-xdTsh3tbosIisvYZPYyIVHi7p/9ex7+MO/8v2OYe32c=";
            # Two log-decryption tests fail in 3.239.0's sandbox build
            # (TestDecryptEncryptedLog, TestDecryptGzipLog). Upstream CI
            # validates the release; we consume the binary and skip tests.
            doCheck = false;
          });
          pulumi-nodejs =
            ((pkgs.pulumiPackages.pulumi-nodejs.override { inherit pulumi; }).overrideAttrs (_: {
              vendorHash = "sha256-1Jxo09ecpeOR7X5Tdn3hI0OZUfqPKuLVxnXA4ElGspY=";
              # The 3.239.0 language tests invoke external version managers
              # (fnm, bun) not present in the build sandbox; we only need
              # the resource binary, so skip the tests.
              doCheck = false;
              # `pulumi-analyzer-policy` was removed from sdk/nodejs/dist/
              # between the nixpkgs-pinned version and 3.239.0; only the
              # resource binary remains. The upstream postInstall hard-codes
              # both, so we redefine it to copy just the one that exists.
              postInstall = ''
                cp -t "$out/bin" ../../dist/pulumi-resource-pulumi-nodejs
              '';
            }));
        in {
          default = pkgs.mkShell {
            name = "nagare";
            packages = [
              # Pulumi (provisioning) — Integration Point 8 / EP-2.
              pulumi
              pulumi-nodejs
              pkgs.nodejs_20
              pkgs.typescript
              # Google Cloud SDK provides both `gcloud` and `gsutil` — EP-2/3/4/7.
              pkgs.google-cloud-sdk
              # socat: ssh ProxyCommand for IAP tunnels, working around the
              # macOS OpenSSH 10.x <-> gcloud --tunnel-through-iap bug noted
              # in the reference repo. — EP-2/EP-3.
              pkgs.socat
              # Kubernetes + Helm clients — EP-4/EP-5/EP-6.
              pkgs.kubectl
              pkgs.kubernetes-helm
              # Secret encryption — EP-3/EP-7.
              pkgs.sops
              pkgs.age
              # Private network access to the host — EP-3.
              pkgs.tailscale
              # JSON wrangling in scripts — used across plans.
              pkgs.jq
              # The command runner that reads ./justfile.
              pkgs.just
              # Haskell toolchain for nagarectl — EP-6. GHC's closure is
              # large (multiple GB); see the plan for an optional split.
              pkgs.ghc
              pkgs.cabal-install
            ];
            shellHook = ''
              export PULUMI_HOME="''${PWD}/infra/pulumi/.pulumi-home"
            '';
          };

          # OPTIONAL lighter shell without the Haskell compiler, for readers
          # who do not need to build nagarectl and want a smaller download.
          # Enter it with `nix develop .#haskell`-style targets reversed:
          # this one is `nix develop` minus GHC. Kept here as documentation
          # of the split option from the Decision Log; safe to delete if
          # unused.
          haskell = pkgs.mkShell {
            name = "nagare-haskell";
            packages = [ pkgs.ghc pkgs.cabal-install ];
          };
        });
    };
}
```

Now verify the shell builds and every tool is present. The first `nix develop` invocation may take a
long time (minutes to tens of minutes) because Nix downloads or builds Pulumi and the GHC closure;
later invocations are near-instant because the results are cached. Run each tool's version command
through `nix develop -c`, which runs a single command inside the shell and exits:

```bash
nix develop -c pulumi version
nix develop -c kubectl version --client
nix develop -c helm version
nix develop -c ghc --version
nix develop -c cabal --version
nix develop -c sops --version
nix develop -c just --version
```

Expected output shapes (exact versions will differ):

```text
v3.239.0
Client Version: v1.31.1
version.BuildInfo{Version:"v3.16.1", GitCommit:"...", GitTreeState:"clean", GoVersion:"go1.22.7"}
The Glorious Glasgow Haskell Compilation System, version 9.8.2
cabal-install version 3.12.1.0
sops 3.9.1 (...)
just 1.36.0
```

Confirm the tools that do not have a tidy `--version` (or that we only need on the `PATH`) resolve to
Nix store paths inside the shell:

```bash
nix develop -c bash -c 'for t in gcloud gsutil tailscale age jq socat node tsc; do echo "$t -> $(command -v "$t")"; done'
```

Expected (the `/nix/store/...` prefixes will differ; the point is each resolves, none says "not
found"):

```text
gcloud -> /nix/store/...-google-cloud-sdk-.../bin/gcloud
gsutil -> /nix/store/...-google-cloud-sdk-.../bin/gsutil
tailscale -> /nix/store/...-tailscale-.../bin/tailscale
age -> /nix/store/...-age-.../bin/age
jq -> /nix/store/...-jq-.../bin/jq
socat -> /nix/store/...-socat-.../bin/socat
node -> /nix/store/...-nodejs-.../bin/node
tsc -> /nix/store/...-typescript-.../bin/tsc
```

#### Refreshing the Pulumi hashes (only if you change `version`)

A **`vendorHash`** is a checksum Nix computes over Pulumi's vendored Go dependency tree; it changes
between Pulumi releases. You cannot guess it. The hashes in the flake above are correct for 3.239.0
(taken from the reference repo). If — and only if — you decide to pin a different Pulumi version, do
this: change `version` to the new value, set the `src` `hash` and both `vendorHash` lines to the
all-zero placeholder `sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`, then run
`nix develop -c pulumi version`. The build will fail and print the *expected* hash it computed; copy
that value back into the file in place of the placeholder. Repeat once for the `src` hash, once for
`pulumi`'s `vendorHash`, and once for `pulumi-nodejs`'s `vendorHash` (the build stops at the first
mismatch, so you iterate). When all three are correct the build succeeds. Do **not** invent hashes and
do **not** change the version unless you have a reason to — the pinned 3.239.0 is known-good.


### M2: repository skeleton, `justfile`, README correction, `.gitignore`

Create the placeholder directory tree. Each leaf directory gets a `.gitkeep` file (an empty,
conventionally-named file whose only purpose is to make Git track an otherwise-empty directory, since
Git does not track empty directories). These directories are where plans 2 through 7 will put their
files; creating them now gives those plans an obvious home and makes the corrected spec's layout real.

```bash
mkdir -p infra/pulumi \
         nixos/hosts/nagare-01 \
         cluster/bootstrap \
         cluster/observability \
         cluster/examples \
         cli/nagarectl \
         scripts \
         docs
for d in infra/pulumi nixos/hosts/nagare-01 cluster/bootstrap cluster/observability cluster/examples cli/nagarectl scripts; do
  touch "$d/.gitkeep"
done
```

(`docs/` already exists and contains real files, so it does not need a `.gitkeep`; it is listed in the
`mkdir -p` only so the command is safe to run on a fresh checkout. The `mkdir -p` is harmless if a
directory already exists.)

Verify the tree:

```bash
find infra nixos cluster cli scripts -type f -name .gitkeep | sort
```

Expected:

```text
cli/nagarectl/.gitkeep
cluster/bootstrap/.gitkeep
cluster/examples/.gitkeep
cluster/observability/.gitkeep
infra/pulumi/.gitkeep
nixos/hosts/nagare-01/.gitkeep
scripts/.gitkeep
```

Now create the root `justfile`. Each recipe is a **thin wrapper**: it names the command and points at
where the real work lives, but the substantive contents (the Pulumi program, the NixOS config, the
Helm values, etc.) are owned by the plans referenced in the comments. The recipes incorporate the
spec's "Suggested justfile" but apply the MasterPlan/spec corrections: a new `host-image` recipe for
the build-upload-register image pipeline (owned by EP-3), the `--sudo` flag and `.#nagare-01` flake
target on `host-switch`, an `observability` recipe that includes VictoriaTraces, and the corrected
Knative/cert-manager bootstrap. The leading whitespace inside recipes must be a consistent indentation
(spaces are shown here); `just` accepts spaces or tabs as long as each recipe is internally
consistent.

```make
# Nagare command runner. These recipes are THIN WRAPPERS. The detailed
# contents of each step are owned by the child plans referenced below,
# under docs/plans/. Run `just --list` to see all recipes.
#
# All cloud commands target the tan-nb-exp GCP project (see .envrc and
# CLAUDE.md). Enter the dev shell first with `nix develop`, or let direnv
# load it automatically after `direnv allow`.

# Show all recipes.
default:
    @just --list

# EP-2 (docs/plans/2-pulumi-gcp-infrastructure.md): create/update the GCP
# resources (VM, static IP, Cloud DNS, disks, service account, Artifact
# Registry, backup bucket).
infra-up:
    cd infra/pulumi && pulumi up

# EP-2: preview the Pulumi changes without applying them.
infra-preview:
    cd infra/pulumi && pulumi preview

# EP-3 (docs/plans/3-nixos-host-nagare-01-with-k3s.md): build the NixOS
# GCE image on the remote x86_64-linux Nix builder, upload the tarball to
# the image-staging GCS bucket, register it as a GCE image, and write its
# self-link into Pulumi config key `nagareImageSelfLink`. The script owns
# the details.
host-image:
    scripts/upload-images.sh

# EP-3: apply day-2 host configuration changes to the running nagare-01
# over Tailscale. The non-root deploy user needs --sudo.
host-switch:
    nixos-rebuild switch --flake .#nagare-01 --target-host nagare-01 --sudo

# EP-4 (docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md):
# install cert-manager, Knative Serving, Kourier ingress, and the
# config-domain / config-network wiring.
cluster-bootstrap:
    kubectl apply -f cluster/bootstrap/cert-manager
    kubectl apply -f cluster/bootstrap/knative-serving
    kubectl apply -f cluster/bootstrap/kourier
    kubectl apply -f cluster/bootstrap/config-domain

# EP-5 (docs/plans/5-victoria-observability-stack-and-grafana.md): install
# the VictoriaMetrics/Logs/Traces stack + Grafana via Helm.
observability:
    helm repo add vm https://victoriametrics.github.io/helm-charts/
    helm repo update
    helm upgrade --install vmks vm/victoria-metrics-k8s-stack \
      --namespace monitoring --create-namespace \
      -f cluster/observability/victoria-metrics/values.yaml
    helm upgrade --install victoria-logs vm/victoria-logs-single \
      --namespace logging --create-namespace \
      -f cluster/observability/victoria-logs/values.yaml
    helm upgrade --install victoria-logs-collector vm/victoria-logs-collector \
      --namespace logging \
      -f cluster/observability/victoria-logs/collector-values.yaml
    helm upgrade --install victoria-traces vm/victoria-traces-single \
      --namespace tracing --create-namespace \
      -f cluster/observability/victoria-traces/values.yaml

# EP-4 ships the sample app; this applies it as a smoke test.
deploy-hello:
    kubectl apply -f cluster/examples/hello-knative-service

# Quick cluster status across all namespaces (pods and Knative services).
status:
    kubectl get pods -A
    kubectl get ksvc -A
```

Verify the recipes are visible. `just` looks for a file named `justfile` in the current directory:

```bash
nix develop -c just --list
```

Expected (descriptions come from the comment lines above each recipe):

```text
Available recipes:
    cluster-bootstrap # EP-4 ...: install cert-manager, Knative Serving, ...
    default           # Show all recipes.
    deploy-hello      # EP-4 ships the sample app; this applies it as a smoke test.
    host-image        # EP-3 ...: build the NixOS GCE image ...
    host-switch       # EP-3: apply day-2 host configuration changes ...
    infra-preview     # EP-2: preview the Pulumi changes without applying them.
    infra-up          # EP-2 ...: create/update the GCP resources ...
    observability     # EP-5 ...: install the VictoriaMetrics/Logs/Traces stack ...
    status            # Quick cluster status across all namespaces ...
```

The recipe order in `just --list` is alphabetical, so do not worry that it differs from the file
order. The point of acceptance is that all eight named recipes (`infra-up`, `infra-preview`,
`host-image`, `host-switch`, `cluster-bootstrap`, `observability`, `deploy-hello`, `status`) plus the
`default` helper appear.

Next, lightly correct the existing `README.md`. It already gives a good orientation, but it predates
two corrections and must not mislead a reader who follows it. Make two edits. First, in the stack
table, change the TLS row from mentioning host-level Caddy to cert-manager only, and change the
example image registry path from the `my-project` / `us-docker.pkg.dev` placeholder to the canonical
`us-west1-docker.pkg.dev/tan-nb-exp/nagare`. Second, update the implementation-phases / CLI wording so
it does not imply `nagarectl` is TypeScript (the early draft's repo-layout block is fine, but ensure
no sentence claims a Node/TypeScript CLI). Add one short sentence near the top pointing the reader at
the MasterPlan and at this plan as the foundation. Keep the edits minimal — the README is orientation,
not a plan. Verify the corrections landed:

```bash
grep -n "cert-manager" README.md
grep -n "us-west1-docker.pkg.dev/tan-nb-exp/nagare" README.md
grep -n "masterplans/1-bootstrap-nagare-personal-paas.md" README.md
```

Each `grep` should print at least one matching line.

Finally, confirm `.gitignore` covers the build artifacts this repo will produce so they are never
committed. The existing `.gitignore` already ignores tool config dirs; append entries for Nix, Pulumi,
and direnv outputs if they are not already present. The required entries are: `result` and `result-*`
(the symlinks `nix build` drops), `infra/pulumi/.pulumi-home/` and `infra/pulumi/.pulumi-state/` (the
in-repo Pulumi home and state backend that `.envrc` points at), `infra/pulumi/node_modules/` (Pulumi's
TypeScript dependencies), and `.direnv/` (direnv's cache). Verify:

```bash
grep -nE 'result|\.pulumi-home|\.pulumi-state|node_modules|\.direnv' .gitignore
```

Expected (order may differ):

```text
5:result
6:result-*
7:.direnv/
8:infra/pulumi/.pulumi-home/
9:infra/pulumi/.pulumi-state/
10:infra/pulumi/node_modules/
```


### M3: `.envrc` and root `CLAUDE.md`

Create the file `.envrc` at the repository root. This is copied in pattern from the reference repo's
`.envrc` and encodes Integration Point 9. It exports the three Google Cloud SDK environment variables
that make `tan-nb-exp` / `us-west1` / `us-west1-a` the defaults for any unqualified `gcloud` command,
isolates Pulumi's home and state inside the repo, sets the empty Pulumi passphrase so commands do not
prompt, and finally calls `use flake` so entering the directory loads the M1 dev shell automatically.

```bash
# All GCP work for this repository targets the tan-nb-exp project only.
# These env vars override gcloud's `core/project` default for any shell
# entered into this directory, so an interactive `gcloud ...` without an
# explicit `--project` flag still hits the right project. See CLAUDE.md
# for the full policy (MasterPlan Integration Point 9).
export CLOUDSDK_CORE_PROJECT=tan-nb-exp
export CLOUDSDK_COMPUTE_REGION=us-west1
export CLOUDSDK_COMPUTE_ZONE=us-west1-a

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

Authorize direnv to load it (you run this once; re-run it any time `.envrc` changes):

```bash
direnv allow
```

The first time, direnv evaluates the flake, which may take a moment. Then verify the variables are set
in the current shell:

```bash
echo "$CLOUDSDK_CORE_PROJECT"
echo "$CLOUDSDK_COMPUTE_REGION"
echo "$CLOUDSDK_COMPUTE_ZONE"
```

Expected:

```text
tan-nb-exp
us-west1
us-west1-a
```

If `direnv allow` prints nothing about loading the environment, or the `echo` lines are empty, your
shell is probably missing the direnv hook (see the prerequisite check at the top of Concrete Steps).
After fixing the hook and re-entering the directory, the variables will be set.

Create the root `CLAUDE.md`. This restates the GCP isolation policy (adapted from the reference repo's
`CLAUDE.md`), including the per-script preflight assertion every `scripts/` file must contain, and adds
the two Git conventions that match the user's global rules.

```markdown
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
```

Verify the file exists and contains the policy and the preflight snippet:

```bash
grep -n "tan-nb-exp" CLAUDE.md | head -n 3
grep -n "refusing to run" CLAUDE.md
grep -n "Conventional Commits" CLAUDE.md
```

Each `grep` should print at least one line.


## Validation and Acceptance

This plan is accepted when all three milestones' observable behaviors hold simultaneously. Run the
following from the repository root and compare against the expectations stated inline. None of these
commands creates cloud resources; they only inspect the local toolchain and files.

First, the M1 toolchain. Every tool prints a version under `nix develop`:

```bash
nix develop -c pulumi version        # -> v3.239.0 (or your pinned version)
nix develop -c kubectl version --client   # -> Client Version: v1.x.y
nix develop -c helm version          # -> version.BuildInfo{Version:"v3..."}
nix develop -c ghc --version         # -> The Glorious Glasgow Haskell ... version 9.x.y
nix develop -c cabal --version       # -> cabal-install version 3.x.y
nix develop -c sops --version        # -> sops 3.x.y
nix develop -c just --version        # -> just 1.x.y
```

Success is each command exiting 0 and printing a version line of the shape shown. Failure looks like
`error: ... not found` or a Nix build error; if Pulumi fails with a hash mismatch, you changed the
version and must refresh the `vendorHash` values (see "Refreshing the Pulumi hashes").

Second, the M2 skeleton and recipes. The directory tree exists and `just --list` shows the recipes:

```bash
find infra nixos cluster cli scripts -type f -name .gitkeep | sort
nix develop -c just --list
```

Success is the seven `.gitkeep` paths listed earlier and a recipe list containing `infra-up`,
`infra-preview`, `host-image`, `host-switch`, `cluster-bootstrap`, `observability`, `deploy-hello`,
and `status`.

Third, the M3 environment. After `direnv allow`, the GCP isolation variables are set:

```bash
direnv allow
echo "$CLOUDSDK_CORE_PROJECT"    # -> tan-nb-exp
echo "$CLOUDSDK_COMPUTE_REGION"  # -> us-west1
echo "$CLOUDSDK_COMPUTE_ZONE"    # -> us-west1-a
```

Success is the three exact values printed. As a combined end-to-end check that the dev shell and the
environment co-operate, run a tool that direnv loaded without typing `nix develop`:

```bash
pulumi version
```

If direnv is working, this prints the pinned Pulumi version directly because `use flake` put it on the
`PATH`. This proves the foundation behaves as the later plans expect: a developer enters the directory
and the toolchain plus the GCP defaults are simply there.

A final sanity check that the flake itself is well-formed (catches syntax errors before any later plan
relies on it):

```bash
nix flake check
```

Expected: it completes without error (it may print nothing, or evaluation notes). An error here means
`flake.nix` has a syntax or evaluation problem to fix.


## Idempotence and Recovery

Every step in this plan is safe to run more than once. `nix develop` is idempotent by design: it
evaluates `flake.nix` and reuses cached build results, so re-running it never changes the repository
and only rebuilds if the flake content changed. `direnv allow` can be run any number of times; you
must re-run it after editing `.envrc`, and doing so is harmless. Creating the skeleton with
`mkdir -p` and `touch ... .gitkeep` is idempotent — `mkdir -p` does nothing if the directory exists,
and `touch` on an existing empty file leaves it unchanged. Re-writing `flake.nix`, `justfile`,
`.envrc`, or `CLAUDE.md` from this plan's content simply restores the intended state.

If the first `nix develop` fails partway (for example, a network drop while downloading GHC or
Pulumi), just run it again; Nix resumes from cached partial results. If Pulumi fails to build with a
"hash mismatch" message, you have an incorrect `vendorHash` — follow "Refreshing the Pulumi hashes" to
obtain the value Nix reports and paste it in, then re-run. If `direnv` does not load the environment,
the cause is almost always a missing shell hook rather than a content error in `.envrc`; install the
hook (see the prerequisites) and re-enter the directory.

Because this plan creates no cloud resources and no cluster, there is nothing to tear down or roll
back. To completely undo the plan you would only delete the files it created (`flake.nix`, `justfile`,
`.envrc`, `CLAUDE.md`, the `.gitkeep` placeholders) — but there is no reason to, since none of them
have side effects beyond the local working tree.


## Interfaces and Dependencies

This plan has no hard dependencies and no soft dependencies; per the MasterPlan's Exec-Plan Registry it
is the sole Wave-1 Foundation plan, and every other plan (EP-2 through EP-7) soft-depends on it for the
dev shell and conventions it establishes. It consumes only the host's Nix and direnv installations.

The interfaces this plan must expose at completion — the contract the other six plans rely on — are:

A repository-root **`flake.nix`** providing `devShells.x86_64-linux.default` and
`devShells.aarch64-darwin.default` (a `nix develop` shell) whose `PATH` contains, at minimum: `pulumi`
and `pulumi-language-nodejs` plus `node` and `tsc` (consumed by EP-2's Pulumi/TypeScript program),
`kubectl` and `helm` (EP-4, EP-5, EP-6), `ghc` and `cabal` (EP-6's Haskell `nagarectl`), `sops` and
`age` (EP-3 host secrets, EP-7 backups), `gcloud` and `gsutil` from the Google Cloud SDK (EP-2, EP-3,
EP-4, EP-7), `tailscale` (EP-3 host access), `socat` (the SSH IAP-tunnel `ProxyCommand` workaround),
`jq`, and `just`. Pulumi is pinned via the `pkgs.pulumi.overrideAttrs` + `pulumiPackages.pulumi-nodejs`
override pattern. The optional `devShells.<system>.haskell` is a documented convenience, not part of
the required contract.

A repository-root **`.envrc`** that, after `direnv allow`, exports `CLOUDSDK_CORE_PROJECT=tan-nb-exp`,
`CLOUDSDK_COMPUTE_REGION=us-west1`, `CLOUDSDK_COMPUTE_ZONE=us-west1-a`,
`PULUMI_HOME=$PWD/infra/pulumi/.pulumi-home`, and `PULUMI_CONFIG_PASSPHRASE=""`, and runs `use flake`.
This is the mechanism MasterPlan Integration Point 9 names, and EP-2/EP-3/EP-4/EP-7 assume these
variables are present.

A repository-root **`CLAUDE.md`** stating the GCP project-isolation policy and the exact preflight
assertion every `scripts/` file must embed (EP-3 and EP-7 author scripts under `scripts/` and must copy
that assertion), plus the Conventional Commits and no-feature-branches conventions.

A repository-root **`justfile`** exposing the recipe names `infra-up`, `infra-preview`, `host-image`,
`host-switch`, `cluster-bootstrap`, `observability`, `deploy-hello`, and `status` as thin wrappers; the
bodies are filled in or relied upon by EP-2 through EP-5.

A **directory skeleton** — `infra/pulumi/`, `nixos/hosts/nagare-01/`, `cluster/bootstrap/`,
`cluster/observability/`, `cluster/examples/`, `cli/nagarectl/`, `scripts/`, and `docs/` — each
existing (tracked via `.gitkeep`) so EP-2 (`infra/pulumi/`), EP-3 (`nixos/hosts/nagare-01/`,
`scripts/`), EP-4 (`cluster/bootstrap/`, `cluster/examples/`), EP-5 (`cluster/observability/`), and
EP-6 (`cli/nagarectl/`) have a home for their files. These paths line up with the `path` fields in the
repository's `mori.dhall` package identity.

A corrected **`README.md`** giving orientation consistent with the post-correction decisions
(Haskell CLI, cert-manager TLS, `tan-nb-exp` registry path) and pointing at the MasterPlan.

No new software libraries are introduced by this plan; the only "dependencies" are the upstream Nix
packages named in `flake.nix` (`nixpkgs` at the `nixos-unstable` channel and the overridden Pulumi),
all pinned by the flake so the environment is reproducible.
