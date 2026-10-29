---
id: 222
slug: package-and-publish-static-site-updates-through-a-fast-repeatable-workflow
title: "Package and publish static site updates through a fast repeatable workflow"
kind: exec-plan
created_at: 2026-10-29T14:02:33Z
intention: "intention_01m63zddyhed6sqdete30scs28"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-29T14:02:33Z
---

# Package and publish static site updates through a fast repeatable workflow

This ExecPlan is a living document. Maintain Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective during implementation. Record implementation friction using agents/skills/exec-plan/FRICTION.md and distill durable decisions into ADRs before completion.


## Purpose / Big Picture

An operator can publish a directory of static files, edit it, and publish again with one repeatable command. Nagare generates its own Nginx configuration and image, preserves Docker's build cache, chooses the context's architecture, and carries the accepted image identity into deployment. The operator does not copy Dockerfiles, discover the packaged compiler, invent publication keys, or parse human output.

Implement all four acceptance criteria in [IR-36](../improvement-requests/package-a-static-site-image-for-reviewed-publication.md), plus the user's requested fast repeat-release experience. Deliver both `site package` for an independently usable local artifact and `site publish` for the common complete release. A successful publish prints the deployed URL, release tag, accepted image resource, and recovery material location. Editing the example's HTML and running publish again must change the served bytes; rolling back must restore the earlier bytes.


## Progress

- [ ] M1: Local context packaging works from an external operator checkout and exactly matches Nagare's renderers without provider calls.
- [ ] M2: Cached, architecture-correct archive packaging feeds the existing reviewed image publication unchanged, with safe failure and retry behavior.
- [ ] M3: One-command initial publication and subsequent updates compose the existing reviewed operations, with typed handoff and recoverable partial success.
- [ ] M4: The guide and protected-site drill prove publish, edit, republish, and rollback; cold and warm timing evidence demonstrates the repeat-release cost.


## Surprises & Discoveries


## Decision Log

2026-10-29: Include `site publish` as a small composition of existing publication and site services, alongside standalone packaging. Packaging alone closes the missing artifact step but leaves the user's frequent update workflow dependent on manual key allocation and resource-ID handoff. Preserve the two existing transactions rather than pretending publication and deployment are atomic.

2026-10-29: Package existing output by default, with explicit `--build` for the configured frontend build command. This honors IR-36's local read-and-package contract and avoids rerunning dependency installation on every artifact update. Publish uses the same default; documentation must distinguish editing source from editing prepared output.

2026-10-29: Reuse the existing Docker archive builder and ordinary layer cache. The context's target platform is the default for archives, with explicit `--platform linux/amd64` or `linux/arm64` supported by package. The production AMD64 acceptance and the existing ARM64 drill must both work. No new image builder, dependency upgrade, remote builder, or custom persistent build cache is needed.

2026-10-29: Keep archive and review paths immutable. Every changed release gets a distinct tag and publication key; old images remain accepted for rollback. A retry uses retained inputs and existing inventory recovery, never silently repackages a pending review.


## Outcomes & Retrospective


## Context and Orientation

A StaticSite is a typed Haskell configuration that declares the output directory and HTTP behavior. A build context is a directory containing `Dockerfile`, `nginx.conf`, and `site/`. A Docker archive is the saved container image consumed by `app image-plan`. An inventory review records exact proposed effects and input hashes; apply journals and verifies those effects. A publication key identifies an immutable accepted image publication, not a mutable site's name.

`cli/nagarectl/src/Nagare/Static/Build.hs` provides `prepareStaticOutput`; passing True skips the frontend command but validates the configured directory. `cli/nagarectl/src/Nagare/Static/Image.hs` provides `staticDockerfile` and `withStaticImageContext`. The latter copies output contents, renders `renderNginxConfig`, and deletes its temporary context afterward. Expose one shared durable-context writer beneath this wrapper rather than duplicating rendering.

`cli/nagarectl/app/Nagare/Cli/Options.hs`, `cli/nagarectl/app/Nagare/Cli/Parser/Site.hs`, and `cli/nagarectl/app/Nagare/Cli/Dispatch.hs` own CLI options, parsing, and dispatch. `cli/nagarectl/app/Nagare/Cli/Commands/Site.hs` loads typed configs through `provisionGhcEnv` and `Load.loadSite`, qualifies images with `qualifyImage`, and builds reviewed site scopes. Deployment requires `--skip-build`, an explicit tag, and an accepted image resource. Without `--save-plan`, normal production deployment already saves and applies a review in one invocation.

`cli/nagarectl/app/Nagare/Cli/Commands/Image.hs` similarly converges a publication when `--save-plan` is absent. It refuses a reused publication key with changed content. Its `--contract 1` result carries `imageResource` (see `docs/api/samples/image-publication-result.json`). `cli/nagarectl/src/Nagare/Inventory/ImageBuild.hs` already exposes `buildDockerArchiveWith`, an injectable Docker runner, platform-explicit build arguments, and save logic. It rejects existing archives, but its direct final-path save needs staging for the new package contract. `cli/nagarectl/src/Nagare/Image.hs` owns image qualification and tag composition. `cli/nagarectl/app/Nagare/Cli/Runtime/Target.hs` separates local profile resolution from platform workspace preparation; packaging needs only the former for archive naming.

`scripts/site-access-drill.sh` step 6 hand-copies the renderer and Dockerfile; its cluster is explicitly linux/arm64. `nix/checks/scripts/nagarectl-external-config.sh` is the packaged external-config check. `cli/nagarectl/test/Nagare/Test/Static.hs` contains existing build and Dockerfile tests. `docs/user/static-hosting.md` describes deployment but does not produce its required archive.

Relevant decisions are [ADR 3](../adr/0003-package-the-typed-config-runtime-with-nagarectl.md), which makes the packaged compiler authoritative; [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md), which requires immutable reviewed effects, identity checks, and recoverable journals; [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), which requires deterministic failure tests before native confirmation; and [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md), which keeps access relationships attached to reviewed hostnames. Packaging must not alter access enforcement. ADRs currently use the filesystem convention; `mori show --full` declares no profiled ADR bundle.

[EP-219](219-profile-the-image-publication-and-site-deployment-path-and-remove-its-measured-waste.md) owns general publication/deployment profiling and optimizations. Reuse its trace facilities when present; do not block packaging on its cloud measurement or duplicate that project. This plan measures the added packaging and composition cost and the whole user loop. Existing untracked benchmark files are unrelated work and must be preserved.


## Plan of Work

### M1 — Expose the canonical build context


Add `SitePackageOpts`, a `SitePackage` command, and a thin `cli/nagarectl/app/Nagare/Cli/Commands/SitePackage.hs` boundary. Put testable orchestration and typed errors in new `cli/nagarectl/src/Nagare/Static/Package.hs`, registered in `cli/nagarectl/nagarectl.cabal`. Require exactly one of `--context-out DIR` and `--archive FILE`; archive requires `--tag TAG`. Support the familiar `--file`, `--project-dir`, and `--ghc-env` flags, optional `--output-dir DIR`, and explicit `--build`. Relative config paths follow existing CLI working-directory semantics; relative output overrides resolve from project-dir, and artifact destinations resolve from the invocation directory. Document and test these distinctions.

Load once with the normal packaged compiler and reject ServerSite with an actionable error before building. With no output override, use `prepareStaticOutput True`; with `--build`, run the configured build once and then resolve the selected output. Context mode must work with no active context and no Docker. Archive mode reads local context metadata only. Neither calls inventory, Kubernetes, gcloud, registry publication, or platform preparation. This is an orchestration property, not a sandbox for arbitrary executable Haskell or an explicitly requested build command.

Extract a shared context writer from `withStaticImageContext`. Stage output beside the destination and publish it only when complete; reject existing destinations. Reject source/destination overlap after resolving paths, including destinations inside the source tree. Preserve dotfiles, directory structure and bytes; reject dangling or escaping symlinks and unsupported special files before copying. Internal links may be materialized with a cycle check so the delivered context is self-contained. Tests compare Dockerfile and nginx.conf byte-for-byte to their generators and the copied example tree to public/. Include spaces, nested paths, dotfiles, invalid config, missing output, existing destinations, links and interrupted copy. Verify a sentinel BuildCommand never runs by default and runs exactly once with `--build`.

Extend the external-config check with the protected-site example in an unrelated temporary directory, both GHC environment overrides unset, and failing/logging provider shims. Require successful context packaging and zero calls to Docker, kubectl, gcloud, registry tools or inventory. This closes AC-1 and the context half of AC-3.

### M2 — Produce a reusable archive


Use `qualifyImage` and `taggedImageRef` to derive the exact destination from the loaded config and local target profile. Validate the tag and platform before Docker. Default to the profile platform, never the host architecture or ambient DOCKER_DEFAULT_PLATFORM. Reject unsupported platforms, malformed tags and qualified images outside the selected publication registry before expensive work. Context export needs neither tag nor profile.

Build through `buildDockerArchiveWith` using empty build-argument and secret maps. Preserve cached base/config layers: do not add timestamps, cache-busting labels, `--no-cache`, or unconditional pulls. Retain the existing staticDockerfile bytes. Use a unique sibling staging archive, then publish with no-clobber semantics; clean owned staging files on failure and interruption without deleting a preexisting final file. Ensure failure cleanup is exception-safe, not only a False return. Keep concurrent package attempts from overwriting each other's archive. Docker may fetch the base image on a cold build; “no registry contact” means no target-registry authentication, inspection, or publication by packaging, not a claim that a cold Docker build is network-free.

Before adding convenience orchestration, prove the real producer/consumer boundary: package an example archive and pass that file unchanged to the existing image-plan inspection path. Test runner argv and failures without Docker first, then inspect a real AMD64 archive and an ARM64 archive. Verify the selected architecture, embedded tag and expected HTTP content; do not infer platform from the requested argv alone. Archive mode must work without inventory or cluster credentials. Docker-daemon credentials and a cached or fetchable public base image are its only external requirements.

### M3 — Make repeated publication one command


Add `site publish` with the same source/build options plus optional `--tag` and `--release-dir`. Default release directories live under the context's XDG state directory, separate from platform workspaces. Allocate a collision-resistant release identifier once; derive a valid tag and publication key from site identity plus that identifier when omitted. An explicit tag still gets a unique publication key. Never use the existing second-resolution `computeTag` alone for uniqueness. Once chosen, record tag, key, context, config identity, platform, archive path and eventual image resource in a versioned private receipt.

Create a small typed coordinator in new `cli/nagarectl/src/Nagare/Static/Publish.hs` with injectable package, image-publication and site-deployment operations. Refactor command-boundary helpers in `cli/nagarectl/app/Nagare/Cli/Commands/Image.hs` and `cli/nagarectl/app/Nagare/Cli/Commands/Site.hs` to return typed results before rendering output. Load the site and resolve context once for this coordinator. Reuse existing inventory planning, execution, accepted-image validation and site compilation; do not spawn nagarectl subprocesses or parse console output. Register the new managed command in the repository's managed-command audit and contract dispatcher.

The ordered path is package, reviewed image convergence, then reviewed site convergence. Display each review's operations through existing output conventions. A failed or ambiguous publication cannot proceed to deployment. A successful publication followed by a deployment failure retains the archive, receipt, review and transaction identity; print an exact supported recovery command. Provide `site publish --resume DIR` as a mutually exclusive mode which checks the retained receipt and current context, verifies archive identity, delegates ambiguous work to existing inventory recovery, and continues only after accepted publication is proved. It must not rebuild, overwrite a review, replay proved effects, or reuse stale live observations. If configuration changes, refuse resume and explain how to start a new release while retaining the old transaction for recovery.

Support `--contract 1` with a versioned package/publish result through the existing contract machinery: archive/context path, tag, destination, platform, image resource when available, release directory, stage, and transaction outcome. Keep progress and Docker output off machine stdout. Human success prints URL and tag. Manual review remains available through standalone package, image-plan --save-plan, inventory apply, and site deploy --save-plan; do not invent one combined review across two inventory heads.

Deterministic coordinator tests cover initial creation, changed output, same-output new release, repeated explicit tag behavior under existing publication rules, missing image acceptance, publication failure, deployment failure, changed config/archive, lost acknowledgement and resume. Ensure old accepted image resources remain available for rollback. Match existing site deployment's CDN/TLS binding options needed by static sites; access continues to resolve through the existing site service. Server-site packaging is outside scope.

### M4 — Prove the operator loop and its cost


Replace drill step 6's copied renderer and Dockerfile with package; retain its separate publication reviews so AC-2 exercises archive compatibility. Add a focused publish-update scenario using the same disposable context, changing an HTML marker between releases and checking served bytes, protected access and rollback to the original marker. Keep unique archives and keys for each release. Update `docs/user/static-hosting.md` with one-command first publish, editing prepared output, rebuilding source explicitly, repeat publish, retained recovery paths, manual review, architecture selection, and rollback. Remove stale claims that site dry-run produces a Dockerfile.

Measure one cold package and at least three warm unchanged and three warm one-file-update packages in the same builder, recording config-load, copy, build and archive-save durations, total wall time, image size and cache-hit evidence. Separately time complete publish/update commands against the same disposable context, excluding user think time and platform bootstrap. Report medians and ranges; do not promise an arbitrary latency independent of compiler, builder and cluster readiness. Acceptance requires cached unchanged layers, no frontend command by default, no provider calls during package, no duplicate config load within publish, no redundant rebuild after successful publication on resume, and no manual renderer/key/resource-ID steps in the common loop. If instrumentation reveals avoidable repetition in these new paths, remove it and rerun matched samples. General provider latency remains EP-219's ownership, with measured residual explicitly reported.


## Concrete Steps


Run implementation commands from the repository root. New commands below describe the interface to implement, not functionality already available. For contributor checks:

```bash
just haskell-style-check
python3 scripts/check-haskell-architecture.py
bash scripts/test-managed-command-audit.sh
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p /static/' --test-show-details=direct
```

Place new tests under a group matched by `/static/` and verify the runner executes them. Run the packaged external-config flake check declared in `nix/checks/haskell.nix` through the normal gate. After meaningful implementation commits, run `just gate-fast <commit-sha>`. Before native confirmation, use the exact-revision full gate and the prerequisites in `docs/runbooks/before-a-native-run.md`. Do not run the shared or cloud context merely to benchmark.

From an operator project containing `nagare/Config.hs` and its configured output, with a selected initialized context and accepted namespace/access prerequisites:

```bash
nagarectl site package --context-out ./artifacts/context-v1
nagarectl site package --archive ./artifacts/site-v1.tar --tag v1 --platform linux/amd64
nagarectl site publish --release-dir ./artifacts/release-a
# Edit a file in the configured output directory, then:
nagarectl site publish --release-dir ./artifacts/release-b
# For source projects with a configured frontend build:
nagarectl site publish --build --release-dir ./artifacts/release-c
```

Create missing parent artifact directories automatically, but never replace an existing final context/archive. Each new publish directory is owned by exactly one release. First publish and update print distinct release tags and image resources and the same production URL. On a recoverable interruption:

```bash
nagarectl site publish --resume ./artifacts/release-b
```

The guide must also show a complete manual-review transcript using the actual package result destination and image-plan result image resource, then site rollback with the earlier accepted resource. Use contract JSON fields instead of sed. For native confirmation run `bash scripts/site-access-drill.sh` only after satisfying its documented disposable-daemon, CLI, image-pin and GHC-environment prerequisites at the script header. Record the exact candidate revision, environment, timings and observed HTTP markers under `docs/audits/ep222-static-publication.md`.


## Validation and Acceptance


M1 closes AC-1 through byte/tree comparisons and AC-3 through the packaged external-config check. M2 closes archive AC-3 using a fake Docker runner and forbidden-provider shims and proves real archive compatibility before M3. M4 closes AC-2 through the revised complete protected-site drill and AC-4 through a transcript following only the guide. The guide must cover both an existing local context and link its setup prerequisites; do not imply packaging initializes a cluster.

M3's acceptance is an observable three-step user loop: publish, edit, publish again, with distinct served markers and preserved rollback. Test failures at every boundary before native runs, including retry after accepted publication with no second build. The final evidence must distinguish implemented deterministic checks from actual native observations. No milestone is complete because code merely compiles or a saved review exists. Publish speed claims require the recorded cold/warm measurements and cache evidence.


## Idempotence and Recovery


Packaging never overwrites final artifacts. A failed stage cleans only its owned temporary files. A completed archive is immutable input to publication, retained until the operator no longer needs review/resume material; do not add automatic archive or image pruning here. Repeating package with a new destination can reuse Docker layers; existing destinations are an actionable refusal.

A publish receipt is local coordination metadata, not authority to mutate providers. Accepted inventory history and transaction journals remain authoritative. Resume rechecks context, exact input identities and transaction state, and uses existing recovery rules. It must handle a crash between provider success and receipt update by reconciling against those journals, never trusting a receipt's phase alone. Deployment failure does not roll back or erase a successful publication. Rollback remains the existing saved-review operation selecting the earlier accepted image; confirm the site returns the original content afterward.


## Interfaces and Dependencies


`Nagare.Static.Package` owns validated packaging inputs, a closed context/archive output choice, typed errors and a result with artifact path, optional destination/tag and platform. `Nagare.Static.Image` remains the only Dockerfile/context generator. `Nagare.Inventory.ImageBuild` remains the Docker build/save boundary. `Nagare.Static.Publish` sequences typed operation results and receipts, never provider-specific commands. CLI modules own parsing, compiler/profile acquisition, service wiring and presentation.

Use existing dependencies and pinned toolchain. Cradle's process behavior was located through Mori at `mori://garnix-io/cradle/packages/cradle`; its guide confirms argv-based execution without implicit shell parsing. No new dependency bounds or pins are chosen here. Before introducing unfamiliar dependency APIs, use Mori to locate their source; verify upstream registry/releases if dependency selection becomes necessary. Do not inspect or traverse `/nix/store` to find a compiler.

This is a standalone plan, not a new child of the completed static-hosting MasterPlan. Coordinate shared tracing edits with EP-219 and preserve unrelated work. Implementation commits carry this plan's ExecPlan trailer and the frontmatter intention's Intention trailer. Update or create a filesystem-convention ADR for the local-package versus reviewed-publication boundary and two-stage recovery once implementation establishes the final contract.
