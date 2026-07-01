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

- [ ] M1: The DNS-01 `ClusterIssuer` project is rendered from the active context at apply time (`just cluster-bootstrap` applies a templated `letsencrypt-dns.yaml`); rendering with a `tan-nb-exp` context reproduces today's file byte-for-byte, and rendering with a `labs` context yields `project: tan-labs`.
- [ ] M1: Decide and record whether the ACME contact `email:` is parameterized (default preserved either way).
- [ ] M2: The four auth-plane / `nagared` `Service` image references render from the active context's registry prefix at apply/build time; the cloud install path and the local installer (`cluster/bootstrap/local-auth/install.sh`) both produce non-`tan-nb-exp` images under a `labs` context, and `tan-nb-exp`/local render identically to today.
- [ ] M3: `nixos/hosts/nagare-01/registries.nix` reads its `registryHost` from a context-derived source (within the single-host boundary), defaulting to `us-west1-docker.pkg.dev` when absent so the flake still evaluates and reproduces today.
- [ ] M4 (verification): Under a `labs` context, the rendered output of M1+M2+M3 contains no `tan-nb-exp` and no `us-west1-docker.pkg.dev`; under a `tan-nb-exp` context (and in local mode) the rendered output is byte-identical to today.


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

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of the repository. Read every file named here
before editing.

**What nagare is, for this plan's purposes.** nagare deploys applications to a
Knative-on-k3s cluster running on a single Google Compute Engine VM named
`nagare-01` (or, in *local mode*, to a k3d "k3s-in-Docker" cluster on a laptop).
"Knative Service" means a Kubernetes custom resource of kind
`serving.knative.dev/v1 Service` (abbreviated `ksvc`) that runs a container and
gets an auto-managed URL. "cert-manager" is the cluster add-on that obtains TLS
certificates; a "ClusterIssuer" is its cluster-scoped certificate-issuer object;
"DNS-01" is the ACME challenge type where the issuer proves domain control by
writing a TXT record into a DNS zone (here, a Google Cloud DNS zone). "containerd"
is the container runtime k3s uses to pull and run images; it reads per-registry
credentials from `/etc/rancher/k3s/registries.yaml`.

**The active-context contract (defined by the sibling plans, consumed here).**
This plan does not resolve the context itself. It relies on:
`docs/plans/87-target-context-model-store-and-resolver-for-nagarectl.md` (the context
model — what fields a context has) and
`docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md`
(the bash layer `scripts/lib/target.sh` + `.envrc` that resolves the active context
and exports the contract environment variables). The relevant exported variables are:
`CLOUDSDK_CORE_PROJECT` (the GCP project, e.g. `tan-nb-exp`), `NAGARE_REGISTRY_HOST`
(the Artifact Registry host, e.g. `us-west1-docker.pkg.dev`),
`NAGARE_ARTIFACT_REGISTRY_ID` (the AR repository id, default `nagare`),
`NAGARE_BASE_DOMAIN` (the apps domain), and `NAGARE_MODE` (`cloud` or `local`).
This plan introduces one further exported variable, `NAGARE_REGISTRY_PREFIX`
(see Interfaces and Dependencies), and computes it inline as a fallback so the plan
is verifiable even before EP-89 lands.

**The existing dynamic-render pattern (the model to mirror).** Open `justfile` and
read the `cluster-bootstrap` recipe (the `[group('cluster')]` target near line 91).
Two of its steps already render from the active environment instead of from committed
literals:

```bash
BASE_DOMAIN="$(pulumi -C infra/pulumi stack output baseDomain)"; \
  kubectl -n knative-serving patch configmap config-domain --type merge \
    --patch "{\"data\":{\"$BASE_DOMAIN\":\"\"}}"; \
  kubectl -n knative-serving patch configmap config-domain --type=json \
    -p '[{"op":"remove","path":"/data/svc.cluster.local"}]' || true
…
REGISTRY_HOST="${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}"; \
  kubectl -n knative-serving patch configmap config-deployment --type merge \
    --patch "{\"data\":{\"registriesSkippingTagResolving\":\"kind.local,ko.local,dev.local,${REGISTRY_HOST}\"}}"
```

The `local-bootstrap` recipe (near line 166) does the same with
`NAGARE_BASE_DOMAIN` and a local registry host. This plan adds one more such
render step (the issuer) to `cluster-bootstrap`, and renders the image references
on the auth-plane install path.

**The three hard-code sites, verified by reading.**

1. `cluster/bootstrap/cert-manager/letsencrypt-dns.yaml` — a `ClusterIssuer` named
   `letsencrypt-dns`. Line 12 is `email: nadeem@gmail.com` (the ACME account
   contact). Line 19 is `project: tan-nb-exp` under
   `spec.acme.solvers[0].dns01.cloudDNS` — the GCP project that owns the Cloud DNS
   managed zone the issuer writes TXT records into. The `cluster-bootstrap` recipe
   applies this file verbatim with `kubectl apply -f cluster/bootstrap/cert-manager/letsencrypt-dns.yaml`
   (justfile line ~97). The `local-bootstrap` recipe intentionally **skips** this
   file (local mode has no GCP project and uses a different TLS issuer), so M1
   touches only the cloud `cluster-bootstrap` path.

2. The four Knative `Service` manifests, each with one `image:` line:
   - `cluster/bootstrap/nagare-access/service.yaml` line 17 —
     `image: us-west1-docker.pkg.dev/tan-nb-exp/nagare/nagare-access:latest`
     (note: the Knative container is *unnamed*).
   - `cluster/bootstrap/en/service.yaml` line 27 —
     `.../tan-nb-exp/nagare/en:latest`.
   - `cluster/bootstrap/shomei/service.yaml` line 27 —
     `.../tan-nb-exp/nagare/shomei:latest`.
   - `cluster/bootstrap/nagared/service.yaml` line 32 —
     `.../tan-nb-exp/nagare/nagared:latest`.
   Each reference is exactly `<registryHost>/<project>/<artifactRegistryId>/<svc>:<tag>`
   — i.e. the **registry prefix** `<registryHost>/<project>/<artifactRegistryId>`
   followed by `/<svc>:<tag>`. The cloud install path is the manual `kubectl apply`
   sequence in `docs/user/access.md` ("Install the optional auth plane", lines ~45-61),
   which today instructs the operator to hand-edit these image references. The local
   install path is `cluster/bootstrap/local-auth/install.sh`, which applies the base
   manifests then overrides the image with `kubectl set image` / `kubectl patch` using
   `${NAGARE_REGISTRY_HOST}/<svc>:${tag}` (local mode uses a *flat* registry with no
   project segment). The image-building scripts are
   `cluster/bootstrap/nagare-access/build-image.sh` (builds nagare-access; computes its
   own image ref as `${REGISTRY_HOST}/${PROJECT}/${ARTIFACT_REPOSITORY}/nagare-access:${TAG}`)
   and `cluster/bootstrap/auth-images/build-local-image.sh` (builds any of the three from
   local source, computing `${registry_host}/${project}/${artifact_repository}/${service}:${tag}`
   in cloud mode and `${NAGARE_REGISTRY_HOST}/${service}:${tag}` in local mode). The build
   scripts already derive the registry prefix from the environment — the gap is purely
   the *applied manifests* on the cloud path.

3. `nixos/hosts/nagare-01/registries.nix` line 10 — `registryHost = "us-west1-docker.pkg.dev"`.
   The file's own comment says: "The NixOS flake has no access to nagare.target.env at
   build time, so the documented default is hard-coded here … a later cross-project change
   can parameterize it." That later change is this plan. `registryHost` feeds the
   `refreshScript` (line 17) that writes `/etc/rancher/k3s/registries.yaml` so containerd
   authenticates pulls from that exact host. `registries.nix` is imported by
   `nixos/hosts/nagare-01/configuration.nix` (line 11), which is included by the static,
   pure flake `nixos/flake.nix` (the `nagare01Modules` list, line 35-40). There is no
   per-operator input to the flake, which is why M3 uses a generated, git-ignored nix file.

**Out-of-scope sites, for completeness (do NOT change them):**
`cluster/bootstrap/knative-serving/config-deployment.yaml` and
`cluster/bootstrap/knative-serving/config-domain.yaml` (overwritten at apply time — see
Surprises); `cluster/examples/sqlite-litestream/litestream.yml` and
`cluster/examples/sqlite-pvc-litestream/litestream.yml`
(`gcs://tan-nb-exp-nagare-backups/…` — example files a user copies and edits, never
applied by nagare automation — see Decision Log); and any test/golden fixture pinning
`tan-nb-exp`.


## Plan of Work

The work is three independent rendering changes plus a verification milestone. Each of
M1, M2, M3 is independently verifiable by *rendering* (no live cluster required); M4 ties
them together with a single grep over the combined rendered output.

### M1 — DNS-01 issuer project rendered from the active context

Scope: make `just cluster-bootstrap` apply a `letsencrypt-dns` `ClusterIssuer` whose
`cloudDNS.project` is the active context's project (`CLOUDSDK_CORE_PROJECT`) instead of
the literal `tan-nb-exp`, and (per the Decision Log) whose ACME `email` is
`${NAGARE_ACME_EMAIL:-nadeem@gmail.com}`. At the end, rendering under a `tan-nb-exp`
context reproduces the current file byte-for-byte, and rendering under a `labs` context
yields `project: tan-labs`.

Edits:

1. Rename `cluster/bootstrap/cert-manager/letsencrypt-dns.yaml` to
   `cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl` and replace the two literal
   lines with placeholders:
   - `email: nadeem@gmail.com` → `email: ${NAGARE_ACME_EMAIL}`
   - `project: tan-nb-exp` → `project: ${CLOUDSDK_CORE_PROJECT}`
   Keep every other line (including the ACME server URL and all comments) unchanged. The
   `${…}` are the only `$`-bearing tokens in the file, so an `envsubst` restricted to those
   two names is safe.
2. In `justfile`, change the `cluster-bootstrap` recipe's apply step from
   `kubectl apply -f cluster/bootstrap/cert-manager/letsencrypt-dns.yaml` to a render-then-apply:

   ```bash
   NAGARE_ACME_EMAIL="${NAGARE_ACME_EMAIL:-nadeem@gmail.com}" \
   CLOUDSDK_CORE_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}" \
     envsubst '${NAGARE_ACME_EMAIL} ${CLOUDSDK_CORE_PROJECT}' \
       < cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl \
     | kubectl apply -f -
   ```

   The defaults `${…:-tan-nb-exp}` / `${…:-nadeem@gmail.com}` preserve today's behavior
   when nothing is configured. (Dependency-free fallback if `envsubst` is unavailable:
   `sed -e "s|\${CLOUDSDK_CORE_PROJECT}|${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}|" -e "s|\${NAGARE_ACME_EMAIL}|${NAGARE_ACME_EMAIL:-nadeem@gmail.com}|"`.)
3. Update `docs/user/access.md` / `cluster/bootstrap/cert-manager/README.md` only if they
   reference the file by its old name (verify and adjust the path to `.yaml.tmpl`).

Renaming to `.yaml.tmpl` (rather than keeping a `.yaml` with `${…}` placeholders) is
deliberate: a `.yaml` containing `${CLOUDSDK_CORE_PROJECT}` is not a valid ClusterIssuer
if applied directly, so the `.tmpl` suffix signals "render before apply" and prevents a
stray `kubectl apply -f letsencrypt-dns.yaml` from shipping a broken project name.

### M2 — Auth-plane / nagared image references rendered from the registry prefix

Scope: make the four `Service` image references render from the active context's registry
prefix on the apply path. At the end, the cloud install path (and the local installer)
produce non-`tan-nb-exp` images under a `labs` context, while `tan-nb-exp` and local mode
render exactly as today.

The registry prefix differs by mode: in **cloud** mode it is
`<registryHost>/<project>/<artifactRegistryId>` (three segments, e.g.
`us-west1-docker.pkg.dev/tan-nb-exp/nagare`); in **local** mode it is the *flat* registry
host with no project segment (e.g. `k3d-registry.localhost:5000`). The image reference is
then `<prefix>/<svc>:<tag>`.

Edits:

1. Change the four `image:` lines to a placeholder rendered at apply time:
   - In `cluster/bootstrap/{nagare-access,en,shomei,nagared}/service.yaml`, replace
     `us-west1-docker.pkg.dev/tan-nb-exp/nagare/<svc>:latest` with
     `${NAGARE_REGISTRY_PREFIX}/<svc>:${NAGARE_AUTH_TAG}` where `<svc>` is the literal
     service name (`nagare-access`, `en`, `shomei`, `nagared`).
2. Add a cloud apply path that renders these. Because the cloud install is currently a
   manual `kubectl apply` sequence in `docs/user/access.md`, introduce a small wrapper
   script `cluster/bootstrap/auth-install.sh` (sibling to `local-auth/install.sh`) that, in
   cloud mode, applies each rendered manifest:

   ```bash
   render() {  # $1 = service dir
     NAGARE_REGISTRY_PREFIX="${NAGARE_REGISTRY_PREFIX}" \
     NAGARE_AUTH_TAG="${NAGARE_AUTH_TAG:-latest}" \
       envsubst '${NAGARE_REGISTRY_PREFIX} ${NAGARE_AUTH_TAG}' \
         < "cluster/bootstrap/$1/service.yaml"
   }
   render shomei       | kubectl apply -f -
   render en           | kubectl apply -f -
   render nagare-access | kubectl apply -f -
   ```

   where `NAGARE_REGISTRY_PREFIX` comes from the EP-89 bash layer (or is computed inline as
   `${NAGARE_REGISTRY_HOST}/${CLOUDSDK_CORE_PROJECT}/${NAGARE_ARTIFACT_REGISTRY_ID}` with the
   documented defaults — see Interfaces). Update `docs/user/access.md` to call this script /
   the rendered apply instead of instructing a manual image edit.
3. Update `cluster/bootstrap/local-auth/install.sh` so it does not apply an *unresolved*
   placeholder. Two acceptable approaches; pick the smaller diff:
   (a) render the base through the same `envsubst` (with `NAGARE_REGISTRY_PREFIX="${NAGARE_REGISTRY_HOST}"`,
   the flat local prefix) before applying, after which the existing `kubectl set image` /
   `patch nagare-access` override becomes redundant but harmless and can stay as a belt-and-braces
   step; or (b) keep the apply-then-override flow but first substitute a benign resolvable image
   into the base so the transient Service is never created with a literal `${…}`. Approach (a) is
   preferred because it unifies cloud and local on one render seam.
4. `nagared` (`cluster/bootstrap/nagared/service.yaml`) is applied by whatever installs the
   nagared control surface; verify its apply site and render it the same way (search the repo for
   `nagared/service.yaml`). If nothing in-tree applies it yet, the manifest placeholder change is
   sufficient and the render seam is the same one-liner.

Note: the image-build scripts (`build-image.sh`, `auth-images/build-local-image.sh`) already
compute their push targets from the environment, so they are *not* hard-coded and need no change;
M2 only fixes the *applied manifests*. Confirm the build scripts' computed image equals the rendered
manifest image under the same context (they share the prefix construction).

### M3 — NixOS registry host driven by the active context (single-host boundary)

Scope: make `nixos/hosts/nagare-01/registries.nix` read its `registryHost` from a
context-derived source, defaulting to `us-west1-docker.pkg.dev` so the flake evaluates and
reproduces today when no override is present. At the end, writing a labs override yields a
`registries.yaml` configured for the labs registry; absent the override, the build is identical
to today.

Edits:

1. In `nixos/hosts/nagare-01/registries.nix`, replace the literal
   `registryHost = "us-west1-docker.pkg.dev";` with a default-with-override read:

   ```nix
   # The Artifact Registry Docker host the cluster pulls private images from.
   # Default = the worked example; an operator targeting a different context writes
   # ./registry-host.nix (git-ignored) from the active context's NAGARE_REGISTRY_HOST.
   registryHostCfg =
     if builtins.pathExists ./registry-host.nix
     then import ./registry-host.nix
     else { registryHost = "us-west1-docker.pkg.dev"; };
   registryHost = registryHostCfg.registryHost;
   ```

2. Document the generated file's shape. `nixos/hosts/nagare-01/registry-host.nix`, when present,
   is exactly `{ registryHost = "<host>"; }`. It is **git-ignored** (add it to `.gitignore`
   alongside the existing `nagare.target.env` / `nagare.local.env` entries, with a matching
   comment) so a second instance needs zero tracked-file edits.
3. Provide the generator. Add a tiny helper — a `just` recipe `nixos-registry-host` (or a
   `scripts/` script) — that writes the file from the active context:

   ```bash
   printf '{ registryHost = "%s"; }\n' "${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}" \
     > nixos/hosts/nagare-01/registry-host.nix
   ```

   This is the Nix analogue of how `cluster-bootstrap` renders from the environment, adapted to
   the flake's purity constraint (the value is materialized into a file the flake imports).

Boundary statement (record verbatim in the commit/PR): M3 parameterizes the **single**
`nagare-01` host's registry host only. Generating distinct NixOS host configurations for N
concurrent cloud VMs (the `nixos/hosts/<name>/` tree and `nixosConfigurations.<name>`) is out of
scope per MasterPlan 17; running two cloud VMs concurrently still implies per-host config, which
this initiative does not automate.

### M4 — Verification: a non-tan-nb-exp context renders clean

Scope: prove the combined effect. Define a fictitious `labs` context (project `tan-labs`,
registry host `us-west1-docker.pkg.dev` but a different project, base domain
`labs.topagentnetwork.net`) purely as environment variables, render all of M1+M2+M3, and assert no
leak. Then render under the `tan-nb-exp` defaults and assert byte-identical-to-today. See Concrete
Steps for the exact commands and expected transcripts.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless noted.
These steps render to **stdout / temp files only** — none of them touch a live cluster, so they are
safe to run repeatedly.

**M1 render check (labs context).**

```bash
NAGARE_ACME_EMAIL="ops@topagentnetwork.net" \
CLOUDSDK_CORE_PROJECT="tan-labs" \
  envsubst '${NAGARE_ACME_EMAIL} ${CLOUDSDK_CORE_PROJECT}' \
    < cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl
```

Expected (excerpt):

```yaml
    email: ops@topagentnetwork.net
…
            project: tan-labs
```

**M1 byte-identity check (tan-nb-exp default).** Rendering with the historic defaults must equal
the file as it stood before the rename:

```bash
NAGARE_ACME_EMAIL="nadeem@gmail.com" \
CLOUDSDK_CORE_PROJECT="tan-nb-exp" \
  envsubst '${NAGARE_ACME_EMAIL} ${CLOUDSDK_CORE_PROJECT}' \
    < cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl \
  | git diff --no-index -- - <(git show HEAD:cluster/bootstrap/cert-manager/letsencrypt-dns.yaml) || true
```

Expected: no differences (an empty diff), confirming the `tan-nb-exp` render reproduces today's
file.

**M2 render check (labs context, cloud prefix).**

```bash
NAGARE_REGISTRY_PREFIX="us-west1-docker.pkg.dev/tan-labs/nagare" \
NAGARE_AUTH_TAG="latest" \
  envsubst '${NAGARE_REGISTRY_PREFIX} ${NAGARE_AUTH_TAG}' \
    < cluster/bootstrap/nagare-access/service.yaml | grep image:
```

Expected:

```text
        - image: us-west1-docker.pkg.dev/tan-labs/nagare/nagare-access:latest
```

Repeat for `en`, `shomei`, `nagared`.

**M3 render check.** Write the labs override, build (or evaluate) the host module, and inspect the
rendered `registryHost`. Because a full NixOS build is heavy, the cheap evaluation check is:

```bash
printf '{ registryHost = "%s"; }\n' "us-west1-docker.pkg.dev/labs-not-used-here" \
  > nixos/hosts/nagare-01/registry-host.nix
# Cheapest proof the import path resolves to the override:
nix eval --impure --expr '(import ./nixos/hosts/nagare-01/registry-host.nix).registryHost'
# Expected: "us-west1-docker.pkg.dev/labs-not-used-here"
rm -f nixos/hosts/nagare-01/registry-host.nix   # absent => default restored
```

(For the real host registry host you would write the bare AR host, e.g. `us-west1-docker.pkg.dev`;
the suffix above is only to make the override visually distinct in the eval output.)

**M4 combined no-leak grep (labs context).** Render every applied artifact into a scratch dir and
grep:

```bash
out="$(mktemp -d)"
NAGARE_ACME_EMAIL="ops@topagentnetwork.net" CLOUDSDK_CORE_PROJECT="tan-labs" \
  envsubst '${NAGARE_ACME_EMAIL} ${CLOUDSDK_CORE_PROJECT}' \
    < cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl > "$out/issuer.yaml"
for svc in nagare-access en shomei nagared; do
  NAGARE_REGISTRY_PREFIX="us-west1-docker.pkg.dev/tan-labs/nagare" NAGARE_AUTH_TAG="latest" \
    envsubst '${NAGARE_REGISTRY_PREFIX} ${NAGARE_AUTH_TAG}' \
      < "cluster/bootstrap/$svc/service.yaml" > "$out/$svc.yaml"
done
printf '{ registryHost = "%s"; }\n' "us-west1-docker.pkg.dev" > "$out/registry-host.nix"  # labs would differ
grep -R -n -e 'tan-nb-exp' "$out" && echo "LEAK" || echo "clean: no tan-nb-exp"
```

Expected final line: `clean: no tan-nb-exp` (and, for the issuer + service files, no
`tan-nb-exp` anywhere). The registry *host* `us-west1-docker.pkg.dev` legitimately persists when the
labs context shares that host but a different project — the leak we forbid is the **project**
`tan-nb-exp` (and a stale `us-west1-docker.pkg.dev/tan-nb-exp/...` prefix). If the labs context also
uses a different registry host, the host disappears too; grep for both as appropriate to the chosen
labs values.


## Validation and Acceptance

Acceptance is phrased as observable rendering behavior; a live cluster is not required to validate
the de-hard-coding (the live apply is exercised by `just cluster-bootstrap` separately and is
unchanged except for the new render step).

1. **Back-compat (highest priority).** Under the `tan-nb-exp` defaults (or with no context
   configured at all), the M1 render of `letsencrypt-dns.yaml.tmpl` is byte-identical to the
   pre-change `letsencrypt-dns.yaml` (the `git diff --no-index` in Concrete Steps is empty), the M2
   render of each `service.yaml` reproduces `us-west1-docker.pkg.dev/tan-nb-exp/nagare/<svc>:latest`,
   and with `registry-host.nix` absent the NixOS build's `registryHost` is `us-west1-docker.pkg.dev`.
   This proves "do nothing" reproduces today exactly.
2. **Local mode unchanged.** `cluster/bootstrap/local-auth/install.sh` under a local context still
   results in `Service`s whose images are `${NAGARE_REGISTRY_HOST}/<svc>:<tag>` (the flat local
   registry) — the same images it produced before this plan. `just local-bootstrap` is untouched
   (it already skips the cloud issuer and renders config-domain/config-deployment dynamically).
3. **De-hard-coding (the point of the plan).** Under the `labs` context, M1 yields
   `project: tan-labs`, M2 yields `.../tan-labs/nagare/<svc>:latest`, and the M3 override yields the
   labs registry host; the M4 combined grep over the rendered output finds no `tan-nb-exp` (and no
   stale `us-west1-docker.pkg.dev/tan-nb-exp/...` prefix).
4. **No fixture regressions.** Run the repository's existing test suite; the golden/fixtures that
   intentionally pin `tan-nb-exp` (out of scope) must still pass unchanged, confirming the change
   did not disturb the back-compat assertions. (Find and run the project's test command; do not edit
   any fixture.)

Each milestone is independently acceptable: M1 by its two renders (labs + byte-identity), M2 by the
four-service render under labs and the byte-identity render under `tan-nb-exp`, M3 by the `nix eval`
override-vs-absent check, and M4 by the single combined grep.


## Idempotence and Recovery

Every step in this plan is idempotent and safe to repeat. The render commands write only to stdout
or to scratch temp files and never mutate cluster state, so they can be run any number of times. The
live apply step (`kubectl apply -f -` of a rendered manifest, and `just cluster-bootstrap` as a
whole) is idempotent by `kubectl apply`'s declarative nature: applying the same rendered manifest
twice converges to the same object. Re-running `just cluster-bootstrap` re-renders from the current
environment and re-applies — applying the *same* context renders the same bytes (so no drift),
applying a *different* context updates the objects to the new target (the intended switch).

The NixOS override file `nixos/hosts/nagare-01/registry-host.nix` is recoverable by deletion:
removing it restores the built-in `us-west1-docker.pkg.dev` default and an identical build. Because
it is git-ignored, it cannot accidentally be committed. Regenerating it from the active context
(`just nixos-registry-host`) is idempotent — it overwrites with the same content for the same
context.

Rollback of the manifest changes is a `git revert` of this plan's commit; because the renders are
byte-identical to today under the `tan-nb-exp` defaults, reverting changes nothing for the original
operator. The `.yaml.tmpl` rename is the only structurally breaking change — if a downstream
reference still uses the old `.yaml` path, the apply fails loudly (file not found) rather than
silently shipping a wrong project, which is the safe failure direction.


## Interfaces and Dependencies

**Tools.** `envsubst` (from gettext) is the templating tool; it substitutes only the variable names
passed in its `SHELL-FORMAT` argument and leaves all other text untouched, which is why it is safe
on YAML containing `$`-free comments and URLs. A `sed`-based fallback (documented in M1) covers
environments without `envsubst`. `kubectl apply -f -` consumes the rendered manifest from stdin.
`nix eval` / `nixos-rebuild` consume the NixOS module. No new Haskell or library dependencies are
introduced — this plan is shell/YAML/Nix only.

**Context fields → file mapping (the templating seam).** This is the authoritative mapping of which
resolved-context value feeds which rendered value:

- `CLOUDSDK_CORE_PROJECT` (context `tpProject`) → `letsencrypt-dns.yaml.tmpl`
  `spec.acme.solvers[0].dns01.cloudDNS.project`.
- `NAGARE_ACME_EMAIL` (operator identity, **not** a context field; default `nadeem@gmail.com`) →
  `letsencrypt-dns.yaml.tmpl` `spec.acme.email`.
- `NAGARE_REGISTRY_PREFIX` (derived: cloud = `<NAGARE_REGISTRY_HOST>/<CLOUDSDK_CORE_PROJECT>/<NAGARE_ARTIFACT_REGISTRY_ID>`;
  local = `<NAGARE_REGISTRY_HOST>`) → the four `service.yaml` `spec.…containers[0].image` (prefix
  portion); `NAGARE_AUTH_TAG` (default `latest`) → the tag portion.
- `NAGARE_REGISTRY_HOST` (context `tpRegistryHost`) → `nixos/hosts/nagare-01/registry-host.nix`
  `registryHost`, imported by `registries.nix`.

**The `NAGARE_REGISTRY_PREFIX` contract.** This plan **introduces** the exported variable
`NAGARE_REGISTRY_PREFIX`. Its canonical producer is the EP-89 bash layer
(`scripts/lib/target.sh`), which should compute it mode-aware (cloud: three-segment prefix; local:
the flat host) alongside the other contract variables it exports — this plan notes that requirement
for EP-89 (a soft dependency). So this plan is self-contained, the render scripts also compute the
prefix inline with the documented defaults when `NAGARE_REGISTRY_PREFIX` is unset:
`NAGARE_REGISTRY_PREFIX="${NAGARE_REGISTRY_PREFIX:-${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}/${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}/${NAGARE_ARTIFACT_REGISTRY_ID:-nagare}}"`.
This lets M2 be verified standalone (against EP-87's context model) before EP-89 lands, while
preferring EP-89's value once it exists.

**Dependencies on sibling plans.** Hard dependency:
`docs/plans/87-target-context-model-store-and-resolver-for-nagarectl.md` defines the context model
whose fields (`tpProject`, `tpRegistryHost`, `tpArtifactRegistryId`, `tpBaseDomain`) are the values
rendered here. Soft dependency:
`docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md` makes
`just cluster-bootstrap` / the auth-install path resolve the active context through bash and export
the contract variables (including `NAGARE_REGISTRY_PREFIX`); the live `just cluster-bootstrap` path
reads the context via that layer, while this plan's rendering can be unit-verified against EP-87
alone (using the inline-fallback prefix). This plan does **not** touch Pulumi state or config — that
is the disjoint sibling `docs/plans/90-per-context-pulumi-state-and-config-projection.md`.

**Artifacts that must exist at the end of each milestone.** After M1:
`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl` (renamed, two placeholders) and the
updated `cluster-bootstrap` recipe in `justfile`. After M2: the four `service.yaml` with
`${NAGARE_REGISTRY_PREFIX}/<svc>:${NAGARE_AUTH_TAG}` image lines, a cloud render path
(`cluster/bootstrap/auth-install.sh` or equivalent rendered-apply documented in
`docs/user/access.md`), and the local installer rendering rather than applying an unresolved
placeholder. After M3: `registries.nix` reading `./registry-host.nix` with the built-in default, the
`.gitignore` entry for `nixos/hosts/nagare-01/registry-host.nix`, and the generator recipe/script.
After M4: the combined no-leak grep passes under `labs` and the byte-identity checks pass under
`tan-nb-exp`/local.

**Commit trailers.** Every commit that lands work for this plan carries these trailers so the
initiative stays traceable:

```text
MasterPlan: docs/masterplans/17-first-class-target-contexts-for-nagare.md
ExecPlan: docs/plans/91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md
Intention: intention_01kwdepj5gey18qqy0pjjx3mep
```


---

**Revision note (2026-06-30).** Initial authoring of this ExecPlan from the skeleton. Fleshed out
all sections from a reading of `docs/masterplans/17-first-class-target-contexts-for-nagare.md`
(Integration Point 6 and the Scope/Decomposition sections), the sibling contracts EP-87 and EP-89,
the `justfile` `cluster-bootstrap`/`local-bootstrap` recipes, the three hard-code sites
(`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml`, the four
`cluster/bootstrap/{nagare-access,en,shomei,nagared}/service.yaml`, and
`nixos/hosts/nagare-01/registries.nix`), the auth build/install scripts, `docs/user/access.md`, and
the out-of-scope classification of `config-deployment.yaml`/`config-domain.yaml` and the
`cluster/examples/*/litestream.yml` bucket URLs. The rendering mechanism (apply-time `envsubst` from
the active-context environment, mirroring the existing `config-domain`/`config-deployment` patches)
and the NixOS generated-file boundary were chosen and recorded in the Decision Log.
