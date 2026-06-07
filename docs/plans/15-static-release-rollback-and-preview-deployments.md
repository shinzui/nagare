---
id: 15
slug: static-release-rollback-and-preview-deployments
title: "Static release rollback and preview deployments"
kind: exec-plan
created_at: 2026-06-07T19:49:33Z
intention: "intention_01ktht1bdme019jxs38yjsebxq"
master_plan: "docs/masterplans/3-static-hosting-for-nagare.md"
---

# Static release rollback and preview deployments

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan is complete, static site deploys are not one-way mutations. Every production deploy
records a release id, image tag, timestamp, source label, and URL. A developer can list releases,
roll back production to a prior release, and deploy branch or pull-request previews without changing
the production site. This closes the largest lifecycle gap between a basic static deploy command and
a Cloudflare Pages-like workflow.

The observable behavior is CLI-driven: `nagarectl site releases` lists prior deploys, `nagarectl site
rollback <release-id>` points the production Knative Service back to an earlier image, and
`nagarectl site preview deploy --name feature-x` creates a separate preview Knative Service and URL.


## Progress

- [ ] Define release metadata types and JSON encoding in `nagarectl`.
- [ ] Store and update release metadata in a Kubernetes ConfigMap per site.
- [ ] Add release recording to successful `nagarectl site deploy`.
- [ ] Add `nagarectl site releases` and `nagarectl site rollback`.
- [ ] Add preview naming, preview deploy, preview list, and preview delete commands.
- [ ] Add tests for release metadata parsing, preview name validation, and rollback manifest generation.
- [ ] Validate the release and preview flow against the static example.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Store release metadata in a ConfigMap before introducing a database.
  Rationale: Nagare is a single-node personal PaaS. ConfigMaps are available immediately, easy to
  inspect, covered by Kubernetes backup practices, and sufficient for compact release history.
  Date: 2026-06-07

- Decision: Use image tags as immutable release artifacts.
  Rationale: EP-14 packages every static asset set into a tagged container image. Rollback can be a
  Kubernetes patch to an older image tag; no separate asset store or symlink manager is required.
  Date: 2026-06-07

- Decision: Model preview deployments as separate Knative Services, not as traffic splits on the
  production service.
  Rationale: Branch and pull-request previews need independent domains and lifecycle. Separate
  services are easy to list, delete, and isolate, and fit the existing Knative resource model.
  Date: 2026-06-07


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan builds on `docs/plans/14-static-build-packaging-and-deploy-pipeline.md`, which provides
`nagarectl site deploy` for a production static site. That command builds a static site into an
Nginx container image and applies a Knative Service. This plan adds lifecycle state around that
working deploy path.

A "release" is one successful production deploy. It records which image tag was activated and enough
metadata to show it to a human. A "rollback" means changing the live production Knative Service back
to the image tag from an older release. A "preview deployment" means a non-production copy of the
site for a branch or pull request, usually under a URL such as
`feature-x.<site>.preview.<baseDomain>`.

The chosen metadata store is a Kubernetes ConfigMap in the site's namespace. The ConfigMap should be
named predictably, for example `nagare-static-releases-<site>`, and contain a compact JSON document
with recent release records. Keep the schema small to avoid ConfigMap size issues.


## Plan of Work

Milestone 1 defines release metadata. Add a module such as
`cli/nagarectl/src/Nagare/Static/Release.hs` with strict records:

```haskell
data StaticRelease = StaticRelease
  { releaseId :: Text
  , siteName :: Text
  , namespace :: Text
  , image :: Text
  , imageTag :: Text
  , url :: Text
  , source :: Maybe Text
  , createdAt :: UTCTime
  }

data StaticReleaseLog = StaticReleaseLog
  { current :: Maybe Text
  , releases :: [StaticRelease]
  }
```

The release id should default to the image tag computed by the deploy pipeline. Keep the newest
records first and cap history at a reasonable number such as 50 releases.

Milestone 2 implements ConfigMap persistence. Add helpers that call `kubectl get configmap ... -o
json`, decode the release log, and `kubectl apply` an updated ConfigMap. Use the same process style
as `Nagare.Deploy`, through `cradle` if that is still the pattern. A missing ConfigMap should be
treated as an empty release log. Malformed JSON should be a clear CLI error, not silent data loss.

Milestone 3 records successful deploys. Extend the non-dry-run path from EP-14 so release metadata is
written only after the Knative Service is Ready. Dry-run should print the release id it would use but
not write the ConfigMap. If release recording fails after the service is live, print the error and
exit non-zero so the operator knows the deploy succeeded but history is incomplete.

Milestone 4 adds release commands. Add these CLI forms under `nagarectl site`:

```text
nagarectl site releases
nagarectl site rollback RELEASE_ID
```

`site releases` loads the static config to identify the site and namespace, reads the ConfigMap, and
prints a compact table of release id, timestamp, current marker, source, image tag, and URL.
`site rollback` finds the release, renders the production Static Service with that old image tag,
applies it, waits for readiness, sets `current` in the release log, and prints the URL.

Milestone 5 adds previews. Add:

```text
nagarectl site preview deploy --name NAME
nagarectl site preview list
nagarectl site preview delete NAME
```

Preview names must be DNS-safe after normalization. A preview service name should be derived from
the production site name and preview name without exceeding Kubernetes DNS label limits. The preview
domain should be derived from the apps base domain, for example
`<preview>.<site>.preview.<baseDomain>`, unless the static config later adds explicit preview domain
settings. Preview delete should remove the preview Knative Service and DomainMapping manifests that
Nagare created; it should not delete production releases.


## Concrete Steps

Start from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
```

Inspect the static deploy implementation from EP-14:

```bash
sed -n '1,320p' cli/nagarectl/app/Main.hs
rg "site" cli/nagarectl/src cli/nagarectl/app
```

After editing, run:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
cabal build
cabal test
```

With a live cluster, validate against the static example:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cluster/examples/static-site
nagarectl site deploy
nagarectl site releases
nagarectl site preview deploy --name feature-x
nagarectl site preview list
nagarectl site preview delete feature-x
```


## Validation and Acceptance

This plan is accepted when the static deploy flow records a release ConfigMap after successful
deployment, `site releases` prints that release, and `site rollback <release-id>` applies the older
image tag and marks it current. Preview deploy acceptance requires that `site preview deploy --name
feature-x` creates a distinct Knative Service, prints a preview URL, and leaves the production
service unchanged. `site preview delete feature-x` should remove the preview resources and tolerate a
second delete with a clear "not found" or no-op message.

Unit tests should cover JSON round-tripping for release logs, malformed release log handling, history
capping, preview name validation, and production versus preview service naming.


## Idempotence and Recovery

Release listing is read-only. Recording a release should be idempotent for the same release id:
re-running the same deploy with the same tag should update or preserve that record rather than
duplicating it. Rollback is safe to repeat because it reapplies the same desired Knative Service.
Preview deploy with the same name should update that preview to the new image tag; preview delete
should be safe to retry.

If ConfigMap JSON is malformed, do not overwrite it automatically. Print the ConfigMap name and ask
the operator to inspect it. This avoids destroying release history because of a decoder bug.


## Interfaces and Dependencies

This plan consumes the static deploy functions and renderer context from EP-14 and EP-13. It should
add release helpers in `cli/nagarectl/src/Nagare/Static/Release.hs` and preview helpers in
`cli/nagarectl/src/Nagare/Static/Preview.hs` if the implementation grows beyond one module.

No new external service is required. The only external command dependency is `kubectl`, already used
by `Nagare.Deploy`.
