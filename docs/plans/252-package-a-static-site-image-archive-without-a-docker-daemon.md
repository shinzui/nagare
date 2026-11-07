---
id: 252
slug: package-a-static-site-image-archive-without-a-docker-daemon
title: "Package a static site image archive without a Docker daemon"
kind: exec-plan
created_at: 2026-11-07T17:05:29Z
master_plan: "docs/masterplans/33-delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-07T17:05:29Z
---

# Package a static site image archive without a Docker daemon

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current.


## Purpose / Big Picture

`nagarectl site package --archive` can produce a static site's image archive without a Docker daemon: it takes a
pinned Nginx base image and adds one layer holding the generated `nginx.conf` and the site files. Afterwards a build
that runs in a locked-down Pod, with no Docker socket, no root and no privileges, can produce the archive that
`nagarectl app image-plan --archive` publishes. The same inputs give a byte-identical archive, so a rebuilt release has
the same image digest.

This is needed by [UC-4](../use-cases/004-engineers-deploy-sites-by-pushing-through-a-delegated-deployer.md): Kotei
builds engineers' repositories in Nagare's hardened one-shot Jobs
(`mori://shinzui/kotei/plans/136-run-forge-builds-in-credential-free-kubernetes-jobs`), which cannot run a Docker daemon,
and static sites are the commonest thing engineers deploy.


## Progress

Interpreter and unit evidence first; a local-context run only confirms
([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)).

- [ ] D1, a pinned base: the static image's base is named by digest per supported platform (`linux/amd64`,
  `linux/arm64`) instead of the mutable `nginx:1.27-alpine` tag in `staticDockerfile`
  (`cli/nagarectl/src/Nagare/Static/Image.hs`), and both builders use the same pin. Evidence: a test that the
  generated `Dockerfile` names the digest for the requested platform, and that an unknown platform is refused.
- [ ] D2, the layered builder: `site package --archive FILE --builder layered` writes a Docker archive (the format
  `skopeo` reads as `docker-archive:`, which `scripts/inventory-artifact-transport.sh` already uses) from the base image
  plus one layer. The layer is a tar of `etc/nginx/conf.d/default.conf` and `usr/share/nginx/html/...` with sorted
  entries, fixed modification time, owner and group 0, and the modes `writeStaticContext` already normalizes; the image
  config sets `ExposedPorts` 8080 and a fixed `created` time, and keeps the base's entrypoint and command. Evidence: a
  golden test that packages a fixture site twice and gets identical bytes, and a test that `skopeo inspect
  docker-archive:` reads it.
- [ ] D3, getting the base without a daemon: the base is read from `--base-archive FILE` (a Docker archive of exactly
  the pinned digest, refused otherwise) or, when absent, fetched once by digest with `skopeo copy` into a cache under
  the user's cache directory and verified by digest on every use. A build with no network passes `--base-archive`.
  Evidence: tests for a matching archive, a mismatched archive refused before writing, and a cache entry whose bytes no
  longer match its digest refused.
- [ ] D4, the default: without `--builder`, `site package --archive` keeps the Docker builder when a daemon answers and
  uses the layered builder otherwise, printing which one it used; `site publish` behaves the same. The content digest
  that identifies a release (ADR 32) is unchanged, because it hashes the context, not the image. Evidence: tests with a
  fake daemon present and absent.
- [ ] D5, the local confirmation: on a local context, a Pod with no Docker socket, a read-only root filesystem and a
  non-root user packages a fixture site with `--builder layered --base-archive`, the operator publishes the archive with
  `app image-plan`, deploys it with `site deploy --skip-build`, and the site serves its files. Evidence: an audit file
  under `docs/audits/`.
- [ ] D6, docs and decision: `docs/user/static-hosting.md` documents the builder choice and the base pin, and
  [ADR 32](../adr/0032-static-publication-is-a-local-package-then-two-reviewed-stages.md) is amended: packaging may use
  either builder, and "the archive path needs a Docker daemon" no longer holds. Evidence: the linked pages.


## Surprises & Discoveries

- 2026-11-07, while writing this plan. The static image is built `FROM nginx:1.27-alpine`, a mutable tag, so two
  builds of one release on different days can contain different Nginx bytes. D1 pins it by digest for both builders.


## Decision Log

- Decision: Append one layer to a digest-pinned base in Nagare itself, rather than requiring a daemonless builder
  such as BuildKit rootless, Kaniko or Buildah in the build Pod.
  Rationale: a static site image is a base plus files, which needs no build execution at all. Each named builder
  needs extra privileges or user namespaces that Nagare's hardened Job (non-root, read-only root, all capabilities
  dropped) does not grant, and adds a tool to every build image.
  Date: 2026-11-07

- Decision: The release identity stays the context content digest from ADR 32, not the image digest.
  Rationale: the Docker builder stamps creation times, so image digests differ between builders; the unchanged-release
  check must not depend on which builder ran.
  Date: 2026-11-07


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

**Terms.** A Docker archive is the tar file `docker save` writes: a `manifest.json`, an image config JSON and one tar per
layer. A layer is a tar of files that the container runtime overlays on the layers below it. A base image is the image
a new one starts from. Pinning by digest names an image by the hash of its manifest, which cannot change.

**Today.** `cli/nagarectl/src/Nagare/Static/Package.hs` has two outputs chosen by `PackageTarget`: `ContextOut`, which
writes the build context (`Dockerfile`, `nginx.conf`, `site/`) through `writeStaticContext` and needs nothing else, and
`ArchiveOut`, which writes that context to a temporary directory and runs `docker build` then `docker save` through
`buildDockerArchiveWith` with an injectable runner (`runDockerProcess`). `staticDockerfile` in
`cli/nagarectl/src/Nagare/Static/Image.hs` is the generated Dockerfile. `nagarectl site package` and `site publish`
(`cli/nagarectl/app/Nagare/Cli/Commands/SitePublish.hs`) call it. Publication reads the archive with `skopeo` in
`scripts/inventory-artifact-transport.sh`.

**ADRs.** [ADR 32](../adr/0032-static-publication-is-a-local-package-then-two-reviewed-stages.md) makes packaging a
local operation followed by two reviewed transactions, and the context content digest the release identity; this plan
keeps both and amends only the builder.


## Plan of Work

Pin the base first (D1), then write the layer and archive writer as a pure function from the prepared context and the
base archive bytes to the output archive bytes (D2), so its determinism is a unit test. Add base acquisition (D3), then
builder selection (D4). Keep `ArchiveOut` and its result type; add the builder as a field of `ArchiveOut`. Use an
existing tar library already in the package set (check with `mori registry search`) rather than writing tar by hand.


## Validation

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
just haskell-style-check
just gate-fast
cabal test nagarectl-test --test-options='-p /Static/'
```


## Interfaces

`site package --archive FILE [--builder docker|layered] [--base-archive FILE]`; `ArchiveOut` gains
`builder :: ArchiveBuilder`; a new module `cli/nagarectl/src/Nagare/Static/Layered.hs` exporting
`layeredArchive :: BaseImage -> StaticContext -> Platform -> Either PackageError LazyByteString`. No contract document
changes; Kotei's build calls the command.
