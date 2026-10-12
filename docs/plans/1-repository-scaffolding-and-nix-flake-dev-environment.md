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

Full plan before trimming: [1-repository-scaffolding-and-nix-flake-dev-environment.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/1-repository-scaffolding-and-nix-flake-dev-environment.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] M1: Author `flake.nix` at the repo root with the pinned Pulumi overlay and the combined dev
      shell, then verify every tool prints its version under `nix develop`. (2026-06-02 — `pulumi
      v3.239.0`, `kubectl v1.36.1`, `helm v3.20.2`, `ghc 9.10.3`, `cabal 3.16.1.0`, `sops 3.13.1`,
      `just 1.51.0`; `gcloud/gsutil/tailscale/age/jq/socat/node 22.22.3/tsc 5.9.3` all resolve to Nix
      store paths.)
- [x] M1: Obtain the correct release-specific `vendorHash` values for `pulumi` and `pulumi-nodejs`.
      (2026-06-02 — reused the reference repo's known-good 3.239.0 hashes verbatim; build succeeded with
      no hash mismatch, so no refresh was needed.)
- [x] M2: Create the repository directory skeleton with `.gitkeep` placeholder files. (2026-06-02 —
      seven `.gitkeep` files under `infra/pulumi`, `nixos/hosts/nagare-01`, `cluster/{bootstrap,
      observability,examples}`, `cli/nagarectl`, `scripts`.)
- [x] M2: Author the root `justfile` with thin wrapper recipes and verify `just --list`. (2026-06-02 —
      all eight recipes + `default` shown.)
- [x] M2: Update `README.md` so it reflects the corrected decisions (Haskell CLI, cert-manager TLS,
      `tan-nb-exp` project) and verify a `.gitignore` exists covering Nix/Pulumi/direnv artifacts.
      (2026-06-02 — TLS row, registry path, ServiceLB note, and MasterPlan pointer corrected; gitignore
      extended with `result`, `.direnv/`, `.pulumi-home/`, `.pulumi-state/`, `node_modules/`.)
- [x] M3: Author `.envrc` with the GCP isolation env vars and `use flake`; run `direnv allow` and
      confirm `$CLOUDSDK_CORE_PROJECT` is `tan-nb-exp`. (2026-06-02 — `direnv exec` prints `tan-nb-exp`,
      `us-west1`, `us-west1-a`, and `pulumi` resolves through the flake.)
- [x] M3: Author the root `CLAUDE.md` restating GCP project isolation, the preflight assertion, and
      the Git conventions. (2026-06-02)
- [x] Final: Run the full acceptance checklist in "Validation and Acceptance" and record outcomes.
      (2026-06-02 — all M1/M2/M3 checks pass; `nix flake check` succeeds.)

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during implementation.
Provide concise evidence.

- Discovery: `pkgs.nodejs_20` (which the plan and the reference repo pinned) is now marked **insecure**
  in the current `nixos-unstable` channel and refuses to evaluate. Evidence — `nix develop` failed with:
  `error: Refusing to evaluate package 'nodejs-20.20.2' ... because it is marked as insecure ... This
  NodeJS release has reached its end of life.` Resolution: bumped the dev shell to `pkgs.nodejs_22`
  (current active LTS); the build then proceeded. This only affects the Node.js runtime Pulumi's
  TypeScript program uses (EP-2), not the pinned Pulumi CLI version (still 3.239.0). The reference repo
  (`load-testing-infra`) will hit the same wall whenever it re-resolves its flake against a newer
  nixpkgs and should make the same bump. See the Decision Log.

- Discovery: Nix flakes only see files tracked by Git. The first `nix develop` failed with
  `error: Path 'flake.nix' in the repository ... is not tracked by Git` because the new files had not
  been staged. Resolution: `git add` the new files before `nix develop`. (Re-stage after every edit to
  a flake-referenced file, since the flake reads the committed/staged tree, not the dirty working copy
  for path-visibility purposes.)

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

- Decision: Pin the dev shell's Node.js to `pkgs.nodejs_22` instead of the plan's original
  `pkgs.nodejs_20`.
  Rationale: The `nixos-unstable` channel resolved during implementation marks `nodejs_20` insecure
  (end-of-life), which makes `nix develop` refuse to evaluate. `nodejs_22` is the current active LTS and
  is the supported, secure choice for Pulumi's Node.js language host. The Pulumi CLI itself remains
  pinned at 3.239.0; only the Node runtime moved. See Surprises & Discoveries for the error evidence.
  Date: 2026-06-02

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare the result
against the original purpose.

EP-1 delivered the full repository foundation exactly as scoped, and every observable behavior in the
Purpose section holds. A fresh `nix develop` produces a shell where `pulumi` (v3.239.0, pinned via the
reference repo's override), `kubectl`, `helm`, `ghc`, `cabal`, `sops`, and `just` all print versions,
and `gcloud`, `gsutil`, `tailscale`, `age`, `jq`, `socat`, `node`, and `tsc` all resolve to Nix store
paths. `direnv allow` loads the GCP isolation variables (`tan-nb-exp` / `us-west1` / `us-west1-a`), the
in-repo Pulumi home/passphrase, and the dev shell, so entering the directory makes the whole toolchain
and the correct cloud defaults simply present — the contract EP-2 through EP-7 rely on. `just --list`
shows the eight thin-wrapper recipes, and the directory skeleton gives each later plan a home. No cloud
resources, VM, or cluster were created, as intended.

The one deviation from the written plan: `nodejs_20` is now flagged insecure (EOL) in the resolved
`nixos-unstable`, so the dev shell pins `nodejs_22` (current LTS) instead. This did not affect the
pinned Pulumi CLI version and is recorded in the Decision Log and Surprises & Discoveries. No other
gaps; the plan was otherwise accurate, and the reference repo's 3.239.0 `vendorHash` values applied
cleanly with no refresh needed.

Lesson for downstream plans: Nix flakes only see Git-tracked files, so any new file a flake references
must be `git add`-ed before `nix develop`/`nixos-rebuild` will see it — relevant to EP-3's NixOS image
flake in particular.

