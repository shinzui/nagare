---
type: Improvement Request
title: Publish the auth-plane and admin API images with each release
description: Build en, Shōmei, nagare-access and the admin API once per release with Nix and publish them, so a platform transition rolls them to the release's digests instead of every operator compiling and pinning them per context, and platform status reports any image that is not the release's.
timestamp: "2026-10-31T17:49:52Z"
generated:
  by: process:claude-code
  at: "2026-10-31T17:49:52Z"
requestId: IR-39
status: proposed
origin: mori://tan/tan-ng-labs
acceptanceCriteria:
  - id: AC-1
    statement: Each Nagare release publishes linux/amd64 images of en, Shōmei, nagare-access and nagare-admin-api, built with Nix from the sources that release pins, and records each image's digest in the release payload.
    verification: Cut a release candidate and assert the four images exist in the release registry at the digests the payload records; rebuild the four Nix derivations from the tag and assert they produce the recorded images.
  - id: AC-2
    statement: A platform transition or bootstrap to a release rolls the four workloads to that release's digests without the operator building or pinning anything.
    verification: Transition a context from one release to the next with no NAGARE_AUTH_*_IMAGE or NAGARE_ADMIN_API_IMAGE set and assert the plan updates the four workloads to the new payload's digests and each serves its release version afterwards.
  - id: AC-3
    statement: platform status reports, for each of the four images, whether it is the release's image, an operator override, or an image from another release, and a context running a non-release image is not reported as exact.
    verification: Pin one workload to the previous release's image and assert platform status names that workload and reports skew; restore the release image and assert exact.
  - id: AC-4
    statement: An operator can still override any of the four with an immutable digest, for a candidate or a patched build, and the override is reported as such.
    verification: Set NAGARE_ADMIN_API_IMAGE to a non-release digest, plan and apply, and assert the workload runs it and platform status reports an operator override for that workload only.
  - id: AC-5
    statement: Obtaining a release's images no longer compiles anything in the operator's context, and the per-context Cloud Build path is documented as the route for unreleased candidates only.
    verification: Time a transition that takes the release images on a cloud context and record that no image build runs; review the runbooks for the new procedure.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-31T17:49:52Z"
    document_timestamp: "2026-10-31T17:49:52Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against cluster/bootstrap/auth-images/build-local-image.sh and
      nix/haskell-packages.nix at v0.13.0, the ExecPlan 81 decision log of
      2026-06-25, ExecPlan 85's timings, ExecPlan 200 M3, and the tan-ng-labs
      operator history for v0.6.4 to v0.13.0. Shōmei and En were confirmed public
      on GitHub on 2026-10-31. No independent verification is claimed.
---

# Publish the auth-plane and admin API images with each release

**Authored by:** a `claude-code` session operating the `tan-ng-labs` intranet
(`mori://tan/tan-ng-labs`), running Nagare v0.13.0.
**Addressed to:** `shinzui/nagare` agents.
**Created:** 2026-10-31.
**Related:** IR-38 (report installed and running versions), which would make the drift
described here visible; this request removes its cause.


## Why

Nagare does not ship four of its own workloads. The en, Shōmei, nagare-access and admin API
images are operator inputs (`NAGARE_AUTH_EN_IMAGE`, `NAGARE_AUTH_SHOMEI_IMAGE`,
`NAGARE_AUTH_ACCESS_IMAGE`, `NAGARE_ADMIN_API_IMAGE`; `cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs`).
A transition never changes them, and `platform status` does not compare them with the release.
Each operator compiles them from source per context and pins the digests.

On the tan-ng-labs intranet this has gone wrong twice:

- **nagare-access.** From v0.6.4 to 2026-10-28 nobody rebuilt it, so the intranet upgraded to
  v0.10.0 kept running the v0.6.4 enforcer. Its concurrent-refresh race, fixed in v0.10.0, kept
  revoking sessions: 17 early sign-outs in 21 days
  (`mori://tan/tan-ng-labs/plans/12-keep-labs-sign-ins-alive-and-add-a-remember-me-option`).
- **Admin API.** It stayed on the v0.9.0 build through the v0.10.0 to v0.13.0 upgrades. On
  2026-10-31 the platform stamp read 0.13.0 while the portal showed "admin API 0.9.0".
  `platform status` reported exact throughout. An admin API older than the inventory has already
  answered 503 on records it did not know (2026-10-21, a 0.6.5 image).

Building the images is also slow:

- `build-local-image.sh` compiles each image's whole Haskell dependency closure from a clean
  workspace in Docker.
- In Cloud Build mode it has no cache and defaults to `--jobs=1` on an `e2-highcpu-32` machine.
  The incremental BuildKit cache from ExecPlan 200 M3 applies only in local mode.
- Measured costs: about 35 minutes for the admin API and 35 to 60 minutes for each auth-plane
  image. ExecPlan 85 recorded about 47 minutes for en, Shōmei and nagare-access built one after
  another.
- The same compile repeats in every context, for every release.

The reason for building from source no longer holds. The ExecPlan 81 decision of 2026-06-25
chose per-context builds from local source because "Cabal [needed] private GitHub credentials
to fetch `shinzui/shomei` and `shinzui/en`, and shomei/en do not currently publish working
release images". Both repositories are now public. Nagare already builds `nagare-api-server`
as a Nix package (`nix/haskell-packages.nix`), and its flake uses the `shinzui.cachix.org`
binary cache.


## Requested change

- **Build once per release with Nix.**
  - Add Nix packages for en, Shōmei and nagare-access, beside the existing `nagare-api-server`,
    from the source revisions the release pins (today `cli/nagare-access/cabal.project`).
  - Build OCI images from them (for example `dockerTools.streamLayeredImage`).
  - Push the closures to the binary cache, so a rebuild is a cache hit.
- **Publish them.** Push the four images to a public release registry as part of cutting a
  release, and record their digests in the release payload beside the other pinned
  components. Registry and naming are Nagare's call. A context may mirror them into its own
  Artifact Registry, but should not have to.
- **Roll them with the platform.** Bootstrap and transition default to the payload's digests,
  so upgrading Nagare upgrades these workloads in the same reviewed plan.
- **Keep overrides, and make them visible.**
  - The `NAGARE_AUTH_*_IMAGE` and `NAGARE_ADMIN_API_IMAGE` variables stay as explicit
    overrides for candidates and patched builds.
  - `platform status` reports each of the four as release, override, or another release's
    image, and is not exact while one of them runs another release's image.
- **Retire the slow path.** Document per-context Cloud Build as the route for unreleased
  candidates only. Until then, give its Cloud Build mode a cache and more than one job.


## Consumer

The tan-ng-labs intranet would drop the four image pins from `operator/intranet/images.env`
and the rebuild step from its upgrade checklist (`docs/runbooks/operations.md`, step 7), and
take these workloads from the release like every other platform component.
