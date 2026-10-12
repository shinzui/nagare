---
id: 91
slug: de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context
title: "De-hardcode cluster manifests and NixOS registry from the active context"
kind: exec-plan
created_at: 2026-06-30T23:48:03Z
intention: "intention_01kwdepj5gey18qqy0pjjx3mep"
master_plan: "docs/masterplans/17-first-class-target-contexts-for-nagare.md"
---

# De-hardcode cluster manifests and NixOS registry from the active context

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today, three kinds of value baked into nagare's tracked files still hard-code the
original worked-example GCP target — the project name `tan-nb-exp` and the
Artifact Registry host `us-west1-docker.pkg.dev` — into things that are
**applied to a real cluster**. An operator who wants to run a *second* nagare
instance against a different GCP project (for example
`labs.topagentnetwork.net` on a project that is not `tan-nb-exp`) must today
hand-edit those tracked files before bootstrapping, which is error-prone and
defeats the whole point of having a selectable target. After this change, every
such value is **rendered from the active target context at apply time** —
nothing in the tracked tree needs editing to point a second instance at a second
project.

Concretely, three sites change behavior:

1. The cert-manager DNS-01 `ClusterIssuer`
   (`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml`) currently names
   `project: tan-nb-exp` as the Google Cloud DNS project that answers the
   ACME DNS-01 challenge. After this change the `just cluster-bootstrap` recipe
   renders that project from the active context's project before applying.

2. The four auth-plane / `nagared` Knative `Service` manifests
   (`cluster/bootstrap/{nagare-access,en,shomei,nagared}/service.yaml`) currently
   pin image references of the form
   `us-west1-docker.pkg.dev/tan-nb-exp/nagare/<svc>:latest`. After this change the
   install path renders each image from the active context's **registry prefix**
   (`<registryHost>/<project>/<artifactRegistryId>`).

3. The NixOS host module `nixos/hosts/nagare-01/registries.nix` currently hard-codes
   `registryHost = "us-west1-docker.pkg.dev"`, which configures the VM's containerd
   to authenticate pulls against that exact Artifact Registry host. After this
   change the host's registry host follows the active context's registry host
   (within the single-host boundary — see Scope below).

**A term used throughout, defined once.** A **target context** (or just
"context") is the fully-resolved target bundle that the sibling plan
`docs/plans/87-target-context-model-store-and-resolver-for-nagarectl.md` defines:
a named set of values including the GCP project (`tpProject`), the region/zone, the
Artifact Registry host (`tpRegistryHost`), the Artifact Registry repository id
(`tpArtifactRegistryId`), the apps base domain (`tpBaseDomain`), and a `mode`
that is either `cloud` or `local`. The shell scripts and the `justfile` learn the
active context through the bash resolution layer that the sibling plan
`docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md`
provides: it sources the active context and exports the contract environment
variables `CLOUDSDK_CORE_PROJECT`, `NAGARE_REGISTRY_HOST`,
`NAGARE_ARTIFACT_REGISTRY_ID`, `NAGARE_BASE_DOMAIN`, and (newly, see Interfaces)
`NAGARE_REGISTRY_PREFIX`. This plan consumes those variables; it does not redefine
how they are resolved.

**The pattern already exists; we are extending it.** The `just cluster-bootstrap`
recipe (in `justfile`) already renders two ConfigMaps from the active environment
rather than from committed literals: it patches the `config-domain` ConfigMap from
`$(pulumi -C infra/pulumi stack output baseDomain)` and patches the
`config-deployment` ConfigMap's `registriesSkippingTagResolving` key from
`${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}`. This plan mirrors that exact
technique — substitute-from-the-active-environment-at-apply-time — for the three
remaining applied hard-codes.

**How you see it working.** With a context whose project is `tan-nb-exp` (or with
no context configured at all, the documented back-compat default), the rendered
output is **byte-identical to today**. With a different context (the verification
uses a fictitious `labs` context whose project is `tan-labs`), the rendered
`ClusterIssuer`, the four `Service` image references, and the NixOS registry host
all carry `tan-labs` / the labs registry, and a `grep -R 'tan-nb-exp'` /
`us-west1-docker.pkg.dev` over the **rendered** output finds nothing.

**Explicitly out of scope (do not touch).** Test fixtures and golden files that
pin `tan-nb-exp` are intentional back-compat assertions — they assert the
"defaults reproduce `tan-nb-exp`" guarantee — and are **not** hard-codes to fix.
Generating N distinct NixOS *hosts* for N concurrent cloud VMs is out of scope:
this plan parameterizes the *single* host's registry host only (see M3 and the
Decision Log).

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: The DNS-01 `ClusterIssuer` project is rendered from the active context at apply time (`just cluster-bootstrap` applies a templated `letsencrypt-dns.yaml`); rendering with a `tan-nb-exp` context reproduces today's file byte-for-byte, and rendering with a `labs` context yields `project: tan-labs`.
- [x] M1: Decide and record whether the ACME contact `email:` is parameterized (default preserved either way).
- [x] M2: The four auth-plane / `nagared` `Service` image references render from the active context's registry prefix at apply/build time; the cloud install path and the local installer (`cluster/bootstrap/local-auth/install.sh`) both produce non-`tan-nb-exp` images under a `labs` context, and `tan-nb-exp`/local render identically to today.
- [x] M3: `nixos/hosts/nagare-01/registries.nix` reads its `registryHost` from a context-derived source (within the single-host boundary), defaulting to `us-west1-docker.pkg.dev` when absent so the flake still evaluates and reproduces today.
- [x] M4 (verification): Under a `labs` context, the rendered output of M1+M2+M3 contains no `tan-nb-exp` and no `us-west1-docker.pkg.dev`; under a `tan-nb-exp` context (and in local mode) the rendered output is byte-identical to today.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (research, 2026-06-30): the **cloud** auth-plane install has no script
  or `just` recipe — it is a manual `kubectl apply -f cluster/bootstrap/<svc>/service.yaml`
  sequence documented in `docs/user/access.md` ("Install the optional auth plane"),
  which explicitly instructs the operator to "edit … image references" by hand. The
  **local** auth-plane install, by contrast, is scripted
  (`cluster/bootstrap/local-auth/install.sh`) and already de-hard-codes the image by
  applying the base then running `kubectl set image` / `kubectl patch` with
  `${NAGARE_REGISTRY_HOST}/<svc>:<tag>`. So M2's real gap is the **cloud** apply path
  (a manual edit today); the local path already renders, and only needs to avoid
  applying an unresolved placeholder.
- Discovery (research, 2026-06-30): `cluster/bootstrap/knative-serving/config-deployment.yaml`
  (line ~30, `registriesSkippingTagResolving: "…,us-west1-docker.pkg.dev"`) and
  `cluster/bootstrap/knative-serving/config-domain.yaml` (`apps.example.com: ""`) DO
  carry literal worked-example values, but both `just cluster-bootstrap` and
  `just local-bootstrap` **overwrite them dynamically** at apply time (the
  `config-domain` patch from `$BASE_DOMAIN`, the `config-deployment` patch from
  `${NAGARE_REGISTRY_HOST}`). The committed literals are therefore harmless apply-time
  placeholders, not applied hard-codes — out of scope (confirmed by reading the recipe;
  see Context and Orientation).
- Discovery (research, 2026-06-30): the NixOS flake (`nixos/flake.nix`) is a static,
  pure flake with no per-operator input; `registries.nix` cannot read
  `nagare.target.env`/the active context at build time without impurity. This forces
  the M3 mechanism to be a *generated, git-ignored* nix file the flake imports with a
  default fallback (mirroring how `nagare.target.env` is git-ignored), rather than an
  environment read. See M3 and the Decision Log.
- Discovery (implementation, 2026-07-01): `envsubst` was not present in the active shell, so the
  implementation uses `cluster/bootstrap/render-context-template.sh`, a repo-local renderer that
  performs exact `sed` substitutions for the four supported placeholders. This keeps the apply path
  dependency-free and makes the render behavior testable on the existing toolchain.

## Decision Log

Record every decision made while working on the plan.

- Decision: render the applied values **at apply time from the active-context
  environment** (the EP-89 bash layer exports them), rather than committing a
  pre-rendered per-context copy of each manifest into the tree.
  Rationale: this mirrors the mechanism `just cluster-bootstrap` already uses for
  `config-domain` and `config-deployment` (substitute-from-environment-at-apply-time),
  so there is one consistent idiom; it keeps exactly one tracked base per manifest
  (no per-context file proliferation); and with the `tan-nb-exp` defaults it renders
  byte-identically to today, satisfying the back-compat guarantee. Committed-per-context
  files were rejected because they multiply tracked YAML per instance, drift from the
  base, and re-introduce the very "edit a tracked file per project" problem this plan
  removes.
  Date: 2026-06-30

- Decision: use `envsubst` (from gettext) as the templating tool for
  `letsencrypt-dns.yaml` and the four `service.yaml` files, restricted to the exact
  variable names being substituted, with a dependency-free `sed` fallback documented.
  Rationale: `envsubst '${VAR}'` substitutes only the named variables and leaves every
  other `$`-free text (the ACME server URL, the security-context block) untouched, so the
  template stays readable and the diff is minimal. `sed 's|<literal>|<value>|'` is the
  fallback when `envsubst` is unavailable, since each literal occurs on a unique line.
  Both render byte-identically to today when the variables hold the `tan-nb-exp` defaults.
  Date: 2026-06-30

- Decision: implement the documented `sed` fallback as the primary renderer because `envsubst` is not
  available in the active development shell.
  Rationale: the templates have a fixed, tiny placeholder set
  (`CLOUDSDK_CORE_PROJECT`, `NAGARE_ACME_EMAIL`, `NAGARE_REGISTRY_PREFIX`, `NAGARE_AUTH_TAG`), so an
  exact `sed` renderer is simpler than adding a new tool dependency and still avoids broad
  substitutions. The renderer escapes replacement text for `sed` and preserves byte-identical default
  output.
  Date: 2026-07-01

- Decision: the ACME contact `email:` in `letsencrypt-dns.yaml` (`nadeem@gmail.com`)
  **is** parameterized, via an optional `NAGARE_ACME_EMAIL` variable that defaults to
  the current literal `nadeem@gmail.com`.
  Rationale: the email is a per-operator Let's Encrypt account contact, not a target
  value; a second operator should not have to file expiry/recovery mail under the first
  operator's address. It is not part of the EP-87 context bundle (it is operator
  identity, not target identity), so it is a standalone env var with the historic value
  as its default — "do nothing" is unchanged. Keeping it as an env var (not a context
  field) avoids widening the context contract for a non-target value.
  Date: 2026-06-30

- Decision: parameterize the NixOS host registry via a **generated, git-ignored**
  `nixos/hosts/nagare-01/registry-host.nix` that `registries.nix` imports with a
  built-in default; do NOT generate per-host NixOS trees.
  Rationale: the flake is pure and cannot read the active context at build time, so the
  context value must be materialized into a nix file (mirroring how `nagare.target.env`
  is a git-ignored per-operator file). `registries.nix` imports it only if it exists,
  defaulting to `us-west1-docker.pkg.dev` so the flake still evaluates and reproduces
  today when the file is absent. Standing up N distinct NixOS *hosts* (one per concurrent
  cloud VM) is explicitly out of scope per MasterPlan 17 — this parameterizes the single
  `nagare-01` host's registry host only.
  Date: 2026-06-30

- Decision: the `cluster/examples/*/litestream.yml` GCS backup URLs
  (`gcs://tan-nb-exp-nagare-backups/…`) are **out of scope** for rendering; they remain
  illustrative example literals with a doc note pointing at the operator's own backup
  bucket.
  Rationale: these files are *examples a user copies and edits*, not manifests that
  `just cluster-bootstrap` / the auth-install path applies — they are never rendered or
  applied by nagare's own automation, so they are not "applied hard-codes." The masterplan
  seam (Integration Point 6) enumerates exactly the issuer project, the four image refs,
  and `registries.nix`; the example bucket URLs are not in it. They already carry a
  comment telling the reader to substitute their own bucket; M4 leaves them untouched but
  the plan records them here so a later initiative can template the examples if desired.
  Date: 2026-06-30

- Decision: the `config-deployment.yaml` / `config-domain.yaml` committed literals are
  left as-is (out of scope).
  Rationale: both bootstrap recipes already overwrite them at apply time from the active
  environment, so the committed values never reach a cluster — they are placeholders, not
  applied hard-codes. Editing them would gain nothing and risk drifting the back-compat
  default. (Recorded so a future reader does not mistake them for a missed site.)
  Date: 2026-06-30

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-91 is implemented. `just cluster-bootstrap` renders the DNS-01 issuer template from the active
context, the auth-plane and `nagared` service manifests carry rendered image placeholders, the local
auth installer renders the shared service bases before applying, and the single NixOS host imports a
git-ignored `registry-host.nix` override when generated by `just nixos-registry-host`.

Validation completed:

- Default render identity: rendering `letsencrypt-dns.yaml.tmpl` and all four `service.yaml`
  templates with no context overrides matched the pre-change files exactly.
- Labs render: `CLOUDSDK_CORE_PROJECT=tan-labs` rendered issuer `project: tan-labs`, and
  `NAGARE_REGISTRY_PREFIX=europe-west1-docker.pkg.dev/tan-labs/nagare` rendered all four images with
  the labs project and no `tan-nb-exp` leak.
- Local render: `NAGARE_MODE=local NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000
  NAGARE_AUTH_TAG=dev` rendered `k3d-registry.localhost:5000/shomei:dev`, preserving the flat local
  registry shape.
- Nix override: `just nixos-registry-host` with `NAGARE_REGISTRY_HOST=europe-west1-docker.pkg.dev`
  wrote the ignored override, and `nix eval --impure --expr '(import
  ./nixos/hosts/nagare-01/registry-host.nix).registryHost'` returned
  `"europe-west1-docker.pkg.dev"`. With the override absent, importing `registries.nix` still
  evaluates.
- Mechanical checks: `bash -n cluster/bootstrap/render-context-template.sh`,
  `bash -n cluster/bootstrap/auth-install.sh`, `bash -n cluster/bootstrap/local-auth/install.sh`,
  `just --list`, and `cabal test -v0` all passed; the Haskell suite reported 342 tests passed.

