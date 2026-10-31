---
id: 237
slug: publish-release-images-for-the-auth-plane-and-admin-api
title: "Publish release images for the auth plane and admin API"
kind: exec-plan
created_at: 2026-10-31T18:23:43Z
intention: "intention_01m69k6ss1e5797qfn2w8ytnyc"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-31T18:23:43Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-31T18:42:17Z
      verdict: "changes-requested"
      note: "Manifest-as-Nix-output makes the Darwin payload depend on x86_64-linux Haskell builds; existing controller-image route, candidate ordering, local mode and the per-commit gates are not oriented"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-31T18:44:53Z
      mode: "update"
      note: "Manifest becomes a committed release.json source input; oriented on the controller-image route, candidate ordering, local mode, cache push and per-commit gates"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-31T19:58:41Z
      mode: "implement"
      note: "M3 and M4 implemented with tests; M2 harness and candidate step implemented with fake-transport tests; M1 Nix images written, Linux build in progress"
---

# Publish release images for the auth plane and admin API

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Record implementation friction using `agents/skills/exec-plan/FRICTION.md`, and promote durable decisions into the relevant ADRs before completion.


## Purpose / Big Picture

Implement [IR-39](../improvement-requests/publish-release-images-for-the-auth-plane-and-admin-api.md): a Nagare release supplies immutable Linux images for En (authorization), Shōmei (authentication), nagare-access (the request authorization gateway), and nagare-admin-api (the read-only administration service). Operators should bootstrap and upgrade enabled workloads without compiling or supplying image references. `platform status` must show which images actually run and refuse to call a context exact when they differ from the release.

An image digest is the SHA-256 identity of a container manifest, used in a reference such as `ghcr.io/shinzui/nagare-en@sha256:…`. It is not the hash of a compressed archive or a Nix output. This plan delivers four linux/amd64 images, their release metadata, automatic selection in reviewed inventory transactions, observable overrides and drift, and release/runbook verification. It does not enable the optional admin API on contexts that have not requested it.


## Progress

- [ ] M1: Four deterministic Nix images and one image manifest build from release-pinned sources; the packaged payload consumes the manifest without a dependency cycle. (2026-10-31: `.#packages.x86_64-linux.release-images-manifest` builds on the builder: en `sha256:ebbfec3d…`, shomei `sha256:b614336b…`, nagare-access `sha256:5e3d78d2…`, admin API `sha256:26cdaa49…`. `release images prepare` wrote them into `release.json` and `release-images-check` passed on the rebuilt tree, so writing the member moves no digest; both systems' payloads then carried a `releaseImages` member identical to the root file, and the aarch64-darwin payload built with no x86_64-linux build. In an amd64 Apple container all four images load; `en-migrate up` and `shomei-migrate up` migrate a disposable Postgres 18; Shōmei's pinned entrypoint migrates, creates and activates a signing key and serves `/health/ready` and its JWKS as uid 10001; En serves `/health/ready` with the packaged schema. The layout conversion produced the same admin digest on the builder and on the workstation. Remaining: an independent rebuild of the four images (a remote `--rebuild` is refused, FRIC-4), which M5's clean-cache rebuild covers. nagare-access starts and listens; the admin API starts and refuses an uninitialised store.)
- [ ] M2: Candidate and publication orchestration publish and independently verify the images and binary-cache closures, with safe retry and complete release evidence. (2026-10-31, `6c4bfe0b`: `release images prepare|verify|publish`, the candidate's image step and `release-publish.sh`'s check are in; the `release images` harness group, 10 cases, covers a missing image, a lost acknowledgement, an upload that never landed, an unknown registry answer, a changed candidate, wrong platform, mismatched remote digest, private package, missing cache token, identical repeat receipt and tags that never move. Remaining: the recorded candidate registry roundtrip, which needs the M1 images and maintainer GHCR and Cachix credentials.)
- [ ] M3: Bootstrap and transitions select release images by default, preserve explicit digest overrides in reviewed state, and roll matching migration Jobs and services together. (2026-10-31, `6c4bfe0b`: `release image selection` group, 8 cases, passes locally: two payloads move every auth workload and its migration Job with no image input; an override moves only its workload and is recorded; removing it restores the release bytes; each server orders after its own image's migration proof; admin API release/override. Existing auth, admin, transition and platform groups pass. Remaining: a resume-after-partial-apply case for an image change; the selection is ordinary saved-review bytes, but no test yet drives an interrupted auth stage.)
- [x] M4: Platform status observes workload and running-container digests, reports release/override/drift/unknown states, and cannot report exact for non-release images. (2026-10-31, `6c4bfe0b`: `release image status` group, 10 cases, passes locally: a previous release's live digest is `other-release` and `image-skew` with matching markers; mixed replicas, absent, unreadable and unparseable observations are `unknown`; restoration is exact only after ready replicas agree; a disabled admin API is `not-enabled`; version skew stays stronger.)
- [ ] M5: Native candidate, bootstrap, upgrade, override, skew, and no-build acceptance pass; runbooks and ADRs describe the shipped procedure.


## Surprises & Discoveries


## Decision Log

2026-10-31: Use public GHCR repositories `ghcr.io/shinzui/nagare-en`, `nagare-shomei`, `nagare-access`, and `nagare-admin-api` (the latter three share the same prefix), with digest references as authority. Release tags are conveniences, never the selection input. Verify anonymous pulls before accepting publication.

2026-10-31: Derive the image manifest as a Nix output and include it in the packaged payload, rather than writing registry results back into the commit being released. This avoids changing a candidate after validation. Split executable/package construction from operator wrappers as needed to keep images independent of the final payload. The candidate must upload images before any rehearsal or intranet transition that needs to pull them.

2026-10-31: Retain explicit immutable overrides, but do not infer override intent from a differing live image or the environment of a later status command. Save intent in reviewed inventory state. An override whose digest differs from the release is visible and non-exact. Image skew must not prevent the reviewed transition that repairs it.

2026-10-31: Complete the release-image route directly. Additional Cloud Build caching and parallelism are not prerequisites: the request's interim workaround applies only while operators must use that route. Keep it documented for unreleased candidates; do not introduce a separate cache project here.

2026-10-31 (review): The image manifest is a source input, not a Nix output; this supersedes the second entry above. The `chore(release): prepare vX.Y.Z` commit writes it into root `release.json` as the `releaseImages` member, from one run of the x86_64-linux image derivations on the release builder. `nix/platform-package.nix` already copies `release.json` into every system's payload, so both payloads carry identical image metadata without the aarch64-darwin payload depending on four x86_64-linux Haskell builds. The x86_64-linux image derivations assert that their computed distribution digests equal the committed ones, the way the payload build already asserts the controller's committed `cluster/bootstrap/net-certmanager/image-reference`; the candidate asserts the same digests against the registry. The superseded design made every Mac build of `nagare-platform` (the Darwin half of `scripts/release-native.sh`, a disposable drill's `nix build git+file://…#nagarectl`, a clone-free install at a tag) depend on a Linux builder or a complete binary cache, and a cold cache would have made a Darwin install fail instead of build. Because `nagare-api-server` depends on the `nagarectl` library, the admin API digest changes with almost every Haskell commit, so a `source-development` payload's `releaseImages` is stale or absent by design and keeps the explicit-image path.

2026-10-31 (review): The cluster pulls the four images from GHCR directly. They are not embedded in the payload and not published into the context registry through the reviewed route `cli/nagarectl/src/Nagare/Inventory/Components/ControllerImage.hs` uses for the patched net-certmanager controller: that route suits one small Go image that `pkgs.pkgsCross.gnu64` cross-builds on either system, while four Haskell closures cannot be cross-built on Darwin and would multiply the payload's size, and IR-39 asks that a context need not mirror them. Local mode keeps its route: `cluster/bootstrap/auth-images/build-local-image.sh` builds the auth images into the k3d registry and the operator exports the image variables before `cluster/bootstrap/local-auth/install.sh`; under the new precedence those are overrides, so `just local-smoke` needs no GHCR access.


2026-10-31 (implementation): The auth package set pins every Hackage package whose pinned-nixpkgs version differs from the cabal solve of `cli/nagare-access/cabal.project` (`nix/release-images/hackage-pins.json`, 99 entries) and builds every Haskell package in that set jailbroken, without its own tests or Haddock. The cabal solve read Hackage's latest revisions; nixpkgs carries older revisions, whose bounds refuse the solve's versions (`singleton-bool` against `some 1.1`). Pinning only what bounds force would give a closure no cabal build ever tested.

2026-10-31 (implementation): Each image becomes an OCI layout whose layers are compressed in the derivation with `gzip -n`, and `skopeo copy --preserve-digests` uploads those bytes, so the manifest digest the derivation writes is the registry digest. `skopeo` compressing a docker-archive on push would make the digest depend on its compressor.

2026-10-31 (implementation): The test-fixture copy of `release.json` in `nix/haskell-packages.nix` drops `releaseImages`. The admin API links the `nagarectl` library, whose tested derivation embeds that copy, so writing the admin digest into `release.json` would otherwise change the admin digest.

2026-10-31 (implementation): The reviewed selection is recorded on each workload object's own metadata (`nagare.dev/image-source`, `nagare.dev/release-image`), not its Pod template, so recording intent never rolls a workload, and status reads intent from the reviewed object instead of loading the inventory store. Only `platform status` observes images; the mutation guards, which call the same status gathering on every apply, do not pay three more kubectl reads. Image skew is its own compatibility level, `image-skew`, weaker than every version diagnosis and never a mutation refusal. A payload without `releaseImages` reports images but leaves the aggregate unchanged, since it names nothing to be exact against.

2026-10-31 (implementation): The test-fixture `release.json` is computed at evaluation (`builtins.removeAttrs` of the parsed file), not filtered in a derivation: a derivation that reads the file takes it as an input, so any change to `releaseImages` still produced a new `nagarectl` and a new admin digest. The first `prepare` run caught exactly that.

2026-10-31 (implementation): The transition table's auth row stays `Unchanged` for the recorded 0.4.0 fixture, whose two releases ran the same exported images; its text now states the release-image behavior, and the new two-payload tests carry the changed case.

## Outcomes & Retrospective


## Context and Orientation

The source request is IR-39, originating at `mori://tan/tan-ng-labs`. This is a standalone plan, associated with intention `intention_01m69k6ss1e5797qfn2w8ytnyc`. Root `release.json` currently declares platform version 0.14.1 and the supported Nix systems x86_64-linux and aarch64-darwin. Both operator packages must select the same Linux service images.

`nix/haskell-packages.nix` defines a GHC 9.12.4 package set and already builds `nagare-api-server`. That package depends on the nagarectl library. The same Nix file also constructs operator wrappers that refer to `platformPackage`; blindly using those wrappers in an image would make the payload depend on itself. `nix/nagare-packages.nix` wires the packages and `nix/platform-package.nix` constructs the immutable payload, including its generated `release.json`. Root metadata is a source input, not a file to rewrite after a candidate run.

Nagare already ships one image it builds itself, and that route is the precedent for this plan. `nix/net-certmanager-controller.nix` builds the patched Knative net-certmanager controller as a linux/amd64 image with `pkgs.dockerTools.buildImage`, cross-compiling the Go binary through `pkgs.pkgsCross.gnu64` on Darwin. `nix/platform-package.nix` copies the archive into the payload and fails unless the committed `cluster/bootstrap/net-certmanager/image-reference` matches the build. `cli/nagarectl/src/Nagare/Inventory/Components/ControllerImage.hs` reads the archive's digest and manifest digest with `shasum` and `skopeo` before any registry mutation and binds them to a reviewed publication into the context registry. This plan reuses the deterministic image construction, `skopeo` (already a direct output of the `nagare` package) and the committed-metadata pattern, but publishes to a public registry instead of embedding the images (Decision Log, 2026-10-31 review entries). In local mode the operator builds the three auth images with `cluster/bootstrap/auth-images/build-local-image.sh` into the k3d registry and exports the image variables before `cluster/bootstrap/local-auth/install.sh` runs the reviewed bootstrap (`cluster/bootstrap/local-auth/README.md`); `Platform.hs` requires the same variables in both modes.

`cli/nagare-access/cabal.project` is a separate dependency workspace. It pins Shōmei to `6179d5678747aeb8ee3c45423c2bf59385dbda88` and En to `c3ee100a0b2cc63a50a9473ef590de7086dca4d0`, plus reviewed WebAuthn, Biscuit and instrumentation forks. These are observed baseline pins, not a request to upgrade them. `cluster/bootstrap/auth-images/build-local-image.sh` archives those sources, creates Cabal projects, and builds four variants through `cluster/bootstrap/auth-images/Dockerfile.local-haskell`. Preserve its runtime behavior, including Shōmei's pinned entrypoint, signing-key initialization, Dhall tooling, migration tools, certificates and non-root execution. Do not copy an arbitrary current upstream checkout into a release.

`cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs` currently requires `NAGARE_AUTH_EN_IMAGE`, `NAGARE_AUTH_SHOMEI_IMAGE`, and `NAGARE_AUTH_ACCESS_IMAGE`; enabled admin API bootstrap also requires `NAGARE_ADMIN_API_IMAGE`. It compiles desired inventory scopes using `cli/nagarectl/src/Nagare/Inventory/Components/Auth.hs`, `PackagedAuth.hs`, and `AdminApi.hs`. An inventory review records intended operations before application. `cli/nagarectl/app/Nagare/Cli/Commands/Transition.hs` uses bootstrap stages to move an admitted context between releases, then commits the context pin. Inspect `cli/nagarectl/src/Nagare/Platform/Transition.hs` as well: its scope table currently describes auth as unchanged and must agree with the new behavior.

`cli/nagarectl/src/Nagare/Platform/Workspace.hs` decodes `PayloadManifest`. `cli/nagarectl/src/Nagare/Platform/Status.hs` compares CLI, payload, context, host and cluster release identities. `cli/nagarectl/app/Nagare/Cli/Runtime/PlatformStatus.hs` observes a cluster version ConfigMap, not running workload images. Consequently a correct marker can conceal stale workloads. Existing version collection lives under `cli/nagarectl/src/Nagare/Platform/Versions/`; reuse its observation infrastructure where applicable, without making IR-39 depend on a separate general version-reporting project.

`cli/nagare-harness/src/Nagare/Harness/Release/Candidate.hs` coordinates candidate gates, rehearsals, native packages, assembly and an intranet transition. `scripts/release-candidate.sh` is a wrapper; `scripts/assemble-release.sh`, `scripts/release-native.sh`, and `scripts/release-publish.sh` remain integration points. Release evidence is bound to the candidate, with later evidence commits separate from released source.

The candidate run is described in `docs/runbooks/releases.md` under "The candidate run". It builds the x86_64-linux outputs from the Mac with `nix build --max-jobs 0`, so only the configured x86_64-linux remote builder or a substituter may produce them, copies them into a file cache under `~/.local/state/nagare/releases/x86-work`, and runs `scripts/release-native.sh` for that system inside an amd64 Apple container under Rosetta that substitutes from that cache. The upgrade rehearsal (`scripts/release-rehearse.sh`) starts in the background before that step and moves a disposable local context on the Colima profile `nagare-mp23`; once bootstrap defaults to release images, that rehearsal pulls the four images, so they must be published before it starts. No step of today's candidate or publication pushes to the public Cachix cache `shinzui.cachix.org` that `flake.nix` names as a substituter; a cache push is new machinery. The release version is prepared by one `chore(release): prepare vX.Y.Z` commit that edits `release.json` and the release notes; `release.json` is the only place the version is written.

Native and cloud steps follow the repository's operating rules. Defects are found by the effect interpreters and fake adapters first, and native runs only confirm ([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)). Before any cloud mutation, complete [`docs/runbooks/before-a-native-run.md`](../runbooks/before-a-native-run.md). Cloud-mutating commands need the operator's go-ahead, asked once for a bounded sequence after a rehearsal; the candidate's intranet step runs under the operator's standing go-ahead. When a guard or check refuses, stop and report rather than work around it. Per Haskell commit run `just haskell-style-check`, then `just gate-fast`; land with `just land`, which starts the full gate on the landed commit. `just gate-release REV` is for the release candidate only, and the candidate run invokes it itself.

Consulted [ADR 1](../adr/0001-auth-plane-images-mirror-upstream-dependency-plans.md): service images and the gateway must share reviewed upstream pins and dependency constraints. [ADR 2](../adr/0002-auth-service-images-own-and-apply-their-database-schemas.md) requires each auth server and its migration executable in the same image and migration success before rollout. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable tags, candidate-bound evidence and retry without replacement; its later amendments describe the pre-tag intranet run. [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md) requires new release logic in tested Haskell, with shell limited to process glue. Amend these records when implementation changes their durable contracts; preserve their existing filesystem metadata convention.


## Plan of Work

### M1 — Build images and prove the payload boundary

Add `nix/release-images.nix` and extend the package wiring with x86_64-linux outputs `release-image-en`, `release-image-shomei`, `release-image-access`, `release-image-admin-api`, a `release-images-manifest` output that writes the four distribution digests as the `releaseImages` JSON described under Interfaces and Dependencies, and a `release-images-check` output that fails unless that JSON equals the `releaseImages` member of root `release.json`. These outputs exist only for x86_64-linux. The aarch64-darwin payload reads the committed `release.json`, which `nix/platform-package.nix` already copies into every payload, so neither payload depends on the other system's builds. Build the outputs on the x86_64-linux remote builder the way the candidate does, with `--max-jobs 0` from the Mac. Follow the existing package set and pinned sources. Introduce explicit fixed-output source hashes for Shōmei and En and a parity check against `cli/nagare-access/cabal.project`, including the fork pins and compatibility constraints. Any new dependency bound or workaround requires Mori source discovery followed by authoritative registry and upstream-tag verification, not a guess from the local corpus.

Build the images from the unwrapped Haskell packages in `nix/haskell-packages.nix`, never from the operator wrappers that embed `platformPackage`; split executable construction from wrapper construction where necessary. Ensure tests and version embedding consume source metadata, never the final payload. Use `pkgs.dockerTools` with deterministic timestamps, ordering and compression, as `nix/net-certmanager-controller.nix` does, and compute each image's distribution digest with the `skopeo` the flake already pins, from the exact archive that will be uploaded. Include all runtime dependencies and migration executables; test command overrides used by Kubernetes Jobs as well as the normal entrypoint. Add image source revision and Nagare release-version labels without pretending an upstream package's version equals Nagare's.

First prove a representative admin API path: build its image on the builder, calculate the distribution digest, write it into a scratch `release.json`, build a payload from it, decode it through `PayloadManifest`, and compile an admin scope using it. This exposes the library/payload boundary before expanding to the auth closure. Then require all four images to start in linux/amd64, with En and Shōmei migration and signing-key initialization smoke checks against disposable databases. Acceptance is a second construction of the four images reproducing the same distribution digests, `release-images-check` passing against a committed `release.json`, and both systems' payload `release.json` files carrying an identical `releaseImages` member.

### M2 — Publish once and bind release evidence

Add `cli/nagare-harness/src/Nagare/Harness/Release/Images.hs` and shared image-manifest types in `cli/nagare-contract/src/Nagare/Contract/ReleaseImages.hs`, beside the existing `Release.hs` and under the same rule: the contract package never links nagarectl. Give the harness two subcommands under `release`: `images prepare`, which builds the four images on the builder and writes `releaseImages` into root `release.json` for the prepare commit, and `images verify`, which checks a manifest against the registry. In `Candidate.hs`, add an image step after preflight and before the upgrade rehearsal starts: build or substitute the four images from the builder, verify their digests equal the candidate's `release.json`, copy each to GHCR by digest, and verify an anonymous pull; the rehearsal and the intranet transition pull these images, so they cannot start earlier. Use the harness's existing process transport for builds, cache upload, registry inspection and copies; never put credentials into evidence. Registry access is `skopeo login ghcr.io` with a GitHub token carrying `write:packages`; the first push creates each package private, and the maintainer sets it public once in the package settings. Push the image closures to `shinzui.cachix.org` with `cachix push` and a `CACHIX_AUTH_TOKEN` from the maintainer environment, then verify a fresh consumer can substitute them; no release step pushes to that cache today.

The candidate uploads content by digest and verifies remote bytes. Final publication verifies these same objects and adds release-version aliases only when absent or already identical. Persist receipts binding candidate revision, image names, platform, manifest digests and source pins. An interrupted upload queries registry state and retries missing identical content; unknown network outcomes are not absence, and mismatched tags or manifests refuse rather than overwrite. Never remove an existing published image to repair a run.

Carry the manifest and receipts through native evidence, assembly and the checked publisher. Port any frozen shell evidence-shaping logic that must change to Haskell under ADR 24, retaining thin wrappers. Tests must include lost acknowledgements, one missing image, wrong platform, mismatched remote digest, changed candidate and unauthenticated pull failure. No GitHub release may publish until all four images and cache evidence validate. M2 passes with a recorded candidate registry roundtrip and repeat invocation producing identical evidence without rebuilding or replacing images.

### M3 — Default bootstrap and transitions to the release

Extend `PayloadManifest` in `cli/nagarectl/src/Nagare/Platform/Workspace.hs` with an optional versioned `releaseImages` member, decoded from the payload's `release.json`, which `nix/platform-package.nix` already copies from the committed root file. Define one pure image resolver used by auth and admin bootstrap. Its precedence is an explicit validated override, then the target payload's reference. For older payloads without metadata, preserve the legacy explicit-image requirement with an actionable error; never silently select `latest`. A new release missing one of the four manifest entries fails its release check.

Record selected image, expected release image and override intent in the reviewed scope and accepted inventory state. Apply executes the saved selection even if environment variables change after review. Remove a previous override by planning again without that override input; document this behavior. Changes to image digests must change desired resource identity and produce migration/rollout operations. The target payload, rather than the installed source payload or an accepted historical scope, supplies defaults during transition. Keep admin enablement unchanged and make both migration Jobs use exactly their server's selected digest.

Exercise existing `InventoryAuthSpec`, `InventoryAdminApiSpec`, `PlatformTransitionSpec` and `PlatformTransitionTableSpec` with a pair of payloads containing distinct digests. Prove all enabled workloads update with the four variables absent, an override changes only its selected workload, mutable tags are rejected, removing the override restores the release image, and failed migration prevents server advancement. Include resume after a partially applied transition. Acceptance is an actual reviewed change to the workloads, not only a changed metadata record.

### M4 — Observe and classify running images

Add a pure image assessment module under `cli/nagarectl/src/Nagare/Platform/` and bounded Kubernetes observation in the runtime status path. Compare the payload expectation, accepted override intent, Deployment container image and ready Pod container `imageID`. Use exact container names and ownership; ignore sidecars. During a rollout, mixed old/new ready replicas remain non-exact. Failed reads, missing workloads and unparseable image identities are unknown, never success. Account for the runtime's digest prefix format and compare the single-platform manifest identity consistently.

Emit per-workload JSON and human status including expected, selected and observed references, selection source, classification and reason. Classifications are `release`, `override`, `other-release`, `drift`, `unknown`, and `not-enabled`. Identify `other-release` only when retained release metadata proves the mapping; an arbitrary mismatch is `drift`, not a fabricated version. An explicit override equal to the expected digest retains its intent but may classify as release. Disabled admin API is `not-enabled` and does not force skew; an enabled-but-absent service is unknown.

Aggregate non-release enabled images into non-exact platform status while preserving stronger existing incompatibility diagnoses. Audit callers of `platformProbe`, mutation guards and transition finalization so skew remains repairable through reviewed reconciliation, and candidate acceptance cannot bypass the new check. Add tests to `cli/nagarectl/test/PlatformSpec.hs` and runtime transport tests proving status needs no image environment variables or registry writes. M4 passes when a previous-release live digest is named as skew despite matching version markers, and restoration returns exact only after ready replicas agree.

### M5 — Verify native behavior and document adoption

Extend the existing release rehearsal and `cli/nagare-harness/test/ReleaseTransitionSpec.hs` to cover the four-image contract. Every native step here only confirms what the interpreter tests of M1 to M4 already proved (ADR 25); complete `docs/runbooks/before-a-native-run.md` before the first cloud step and ask the operator once for the bounded cloud sequence. On disposable local and cloud contexts, bootstrap an enabled admin API with no image variables, then transition between two immutable payloads with different image digests. Capture the saved review, migration completion, ready workload image identities, admin version response, auth health/smoke results and final status. Demonstrate a one-workload override and a deliberately stale workload, then restore defaults. Do not alter a consumer's production environment as part of writing this plan.

Measure the cloud transition and record that no Cabal, GHC, Docker build or Cloud Build image compilation ran in the operator context. Nix substitution and registry pulls are expected. Run a clean-cache rebuild of the four image outputs from the immutable candidate/tag on the maintainer builder separately from the substitution test; compare distribution digests with the payload and registry. Publish the actual release through the existing release workflow when performing release acceptance; never invent a future release version in this plan.

Update `docs/runbooks/releases.md`, `docs/user/cluster-bootstrap.md`, `docs/user/upgrades.md`, and `docs/runbooks/admin-api-reader.md`, plus references to the image helper. Explain default release images, digest overrides, override removal, status classifications, optional mirroring and the candidate-only Cloud Build path. Retain old explicit pins in legacy instructions where required. Distill the packaging/publication changes into ADRs 1, 2, 7 and 24 as applicable. Complete only after all five IR acceptance criteria have recorded evidence.


## Concrete Steps

Run commands at the repository root. The new output names and harness commands below are interfaces to implement, not claims that they exist today. Use the existing dev environment and trusted Linux builder. No dependency sources should be discovered by traversing the Nix store.

```bash
mori registry show shinzui/en --full
mori registry docs shinzui/en
mori registry show shinzui/shomei --full
mori registry docs shinzui/shomei
nix build --no-link --max-jobs 0 .#packages.x86_64-linux.release-image-en .#packages.x86_64-linux.release-image-shomei .#packages.x86_64-linux.release-image-access .#packages.x86_64-linux.release-image-admin-api .#packages.x86_64-linux.release-images-manifest .#packages.x86_64-linux.release-images-check
nix build --no-link .#packages.x86_64-linux.nagare-platform .#packages.aarch64-darwin.nagare-platform
cabal test nagare-harness-test --project-dir=cli/nagare-harness --test-show-details=direct
just haskell-style-check
python3 scripts/check-haskell-architecture.py
```

`--max-jobs 0` makes Nix refuse to build locally, so the image derivations come from the x86_64-linux remote builder or a substituter, exactly as the candidate obtains its x86_64-linux outputs. Builds must finish successfully; harness tests must cover image publication and resume. Per Haskell commit run `just haskell-style-check`, then `just gate-fast`; land with `just land`, which starts the full gate on the landed commit. The focused CLI tests can also run on the remote builder at a committed revision:

```bash
just haskell-style-check
just gate-fast
just test-remote HEAD '/platform/'
```

`just gate-release REV` runs only on the release candidate, and the candidate run invokes it itself. Update the test filter to the actual registered image-test group if it differs, and record the number of executed cases so an empty selection cannot count as passing. Implement the harness entrypoints that write and verify the manifest; the prepare command runs once per release, before the `chore(release): prepare vX.Y.Z` commit that carries its output:

```bash
scripts/harness.sh release images prepare
git diff -- release.json
scripts/harness.sh release images verify --manifest release.json --anonymous
just release-candidate "$RELEASE_VERSION" --revision "$CANDIDATE_REVISION"
```

`RELEASE_VERSION` is the candidate's root metadata version; `CANDIDATE_REVISION` is its immutable commit. These commands require maintainer registry and cache credentials and the existing release environments. Verification must name four successful linux/amd64 digest checks. The candidate command also operates the configured intranet under the release workflow; use its `--rehearsal` mode first when validating orchestration.

For operator acceptance select the disposable context and matching kubeconfig using `docs/user/upgrades.md`, enter the candidate's operator shell with `nix shell "git+file://$PWD?rev=$CANDIDATE_REVISION#nagare"` (a published release uses `github:shinzui/nagare/vX.Y.Z#nagare`), and clear overrides before the normal reviewed transition:

```bash
unset NAGARE_AUTH_EN_IMAGE NAGARE_AUTH_SHOMEI_IMAGE NAGARE_AUTH_ACCESS_IMAGE NAGARE_ADMIN_API_IMAGE
nagarectl platform transition plan --out /tmp/release-images-review
nagarectl platform status --json
```

Apply each review and finalize through the existing transition procedure in `docs/user/upgrades.md`; the plan command returns the next stage, not an all-at-once apply. Retain the review and transaction IDs in acceptance evidence. Status after completion must report the four enabled images as release and aggregate exact. Repeat with one immutable admin override and with one observed stale auth deployment, using disposable fixtures.


## Validation and Acceptance

IR-39 AC-1 passes only when all four public images exist at the payload digests, the sources match the release pins, an independent rebuild reproduces those distribution digests, and binary-cache substitution succeeds. The M1 producer-to-payload-to-scope proof is the early integration gate.

AC-2 passes when bootstrap and a subsequent reviewed transition change all enabled workloads to the target digests without image overrides or operator builds; migration Jobs and servers agree and health/version evidence identifies the corresponding builds. Do not infer service version from a platform ConfigMap alone. Upstream version and Nagare release association are separate facts.

AC-3 passes when status names an intentionally stale workload and is non-exact, including mixed replicas and failed observations, then returns exact after restoration. AC-4 passes when a reviewed immutable admin override runs and remains identified as an override on a fresh status invocation with no environment inputs; the other three remain release images. AC-5 passes with measured cloud transition evidence showing no image compilation and reviewed runbooks that make release consumption the default.

Pure tests cover precedence, invalid/missing metadata, legacy payloads, provenance persistence and classification. Recording transports cover publication/retry and observation failures. Native verification proves anonymous registry access, executable runtime dependencies, migrations, real rollout and cache behavior. Compilation or invented fixtures alone cannot satisfy the acceptance criteria.


## Idempotence and Recovery

Builds and manifest generation are deterministic and repeatable. Uploads use content identity; retries verify before accepting already-present objects. If publication fails halfway, retain receipts and query the registry, then upload only missing content. A changed version tag or digest refuses. Never rewrite a published tag, release attachment or image alias to repair a release.

A failed transition resumes its existing inventory transaction. Keep the source release pin until every required stage verifies. Migration failure does not authorize deleting a database or editing migration history; follow the owning service's supported recovery. Restore default images by a new reviewed plan without override inputs. Rolling back a server image does not promise database downgrade compatibility. When evidence cannot be gathered because a registry, cache or disposable cloud environment is unavailable, record the unfinished criterion explicitly rather than calling the plan complete.


## Interfaces and Dependencies

The new `Nagare.Contract.ReleaseImages` module owns versioned JSON shared by release tooling and the CLI. The `releaseImages` member of root `release.json` contains `schemaVersion` and exactly four entries keyed `en`, `shomei`, `nagare-access`, `nagare-admin-api`. Each entry carries `platform` (`linux/amd64`), repository, digest, full immutable reference and the upstream source revisions it was built from; the Nagare source of nagare-access and the admin API is the release commit itself, which the payload's existing `sourceRevision` names, since a commit cannot record its own hash. `nix/platform-package.nix` copies `release.json` into every payload unchanged apart from the version, revision and payload id it already rewrites, so packaging yields identical image metadata on both supported operator systems; release evidence duplicates it only for verification, not as a second authority.

The resolver returns expected release reference, selected reference and selection source (`release` or `override`) or a typed validation error. Accepted inventory state persists that selection. Observation remains separate from intent and stores per-container digest evidence with errors. Add fields through the existing serialization/versioning contracts and test old records, rather than invalidating historical payloads or inventing an override for them.

Dependencies remain the flake-locked Nix package set, existing Haskell packages, public GHCR and the existing release binary cache. Source discovery uses `mori://shinzui/en` and `mori://shinzui/shomei`; any newly required dependency is located through Mori before API work. This plan chooses no new dependency versions and makes no claim that the local corpus has the latest release. It requires no upstream source change unless runtime/package verification proves one necessary; document any such change using canonical Mori references and refresh this plan's prerequisites.
