---
title: "Static publication is a local package followed by two reviewed stages"
status: accepted
date: 2026-10-30
authors: [shinzui]
related:
  - docs/plans/222-package-and-publish-static-site-updates-through-a-fast-repeatable-workflow.md
  - docs/improvement-requests/package-a-static-site-image-for-reviewed-publication.md
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
  - docs/adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md
---

# ADR 32 — Static publication is a local package followed by two reviewed stages

## Status

Accepted on 2026-10-30 with [EP-222](../plans/222-package-and-publish-static-site-updates-through-a-fast-repeatable-workflow.md),
which answers [IR-36](../improvement-requests/package-a-static-site-image-for-reviewed-publication.md).

## Context

A static site deploy needed an operator-built Docker archive and a hand-carried image resource, so
the common loop (edit the files, publish again) meant copying Nagare's own Dockerfile and renderer
and running four commands. [ADR 22](0022-compose-independent-resource-scopes-through-a-typed-inventory.md)
makes image publication and site deployment two reviewed transactions on one inventory, each with its
own pinned head; they cannot be one atomic change.

## Decision

- **Packaging is a local operation.** `site package` writes the canonical build context (`Dockerfile`,
  `nginx.conf`, `site/`) or a Docker archive from it, reading local files only: no inventory,
  Kubernetes, gcloud or target-registry call. Existing destinations are never replaced and symlinks in
  the output are refused. The archive path needs a Docker daemon and nothing else.
- **The content digest is the release identity.** The context writer returns a SHA-256 over sorted
  relative paths, regular-versus-executable mode and bytes. An OCI manifest digest is not that
  identity: Docker stamps a creation time into the image config. A hash of the loaded `StaticSite`
  value covers configuration. Publish records `content=…;config=…` as the release's `source`, and a
  later publish whose digests match the serving release reports it and builds nothing.
- **The builder's cache policy is explicit.** `--no-cache` is passed only for a build with Build
  Secrets, where fresh values must reach every secret-mounting instruction. A secret-free static
  build keeps Docker's layer cache, so an edited file rebuilds one layer and uploads the layers the
  registry lacks.
- **`site publish` composes, it does not merge.** Preflight (every accepted prerequisite, with the
  command that provides it), the unchanged check, packaging, the existing reviewed image publication,
  then the existing reviewed site deployment. The image resource is computed from the publication key
  by the constructors the publication uses, never parsed from output. Each release has a unique
  publication key.
- **A receipt records the stage reached; the inventory stays authoritative.** The private versioned
  receipt names the last proved stage and is only a pointer for resume. Resume re-enters the stage
  through the same reviewed operation, refuses when the files or configuration changed since the
  archive was built, never rebuilds, and leaves a pending inventory transaction to
  `inventory resume`.
- **Machine output is one document.** `--contract 1` prints one `site-publish-result`; the nested
  handlers run with the sink off, and a stage failure after the receipt exists is exit 7 with the last
  proved stage and the resume command.

## Consequences

- An operator edits, runs `nagarectl site publish`, and either gets the URL or the exact resume
  command; a repeat with no change costs one config load, a file copy and a hash.
- Publication and deployment can still fail separately; the receipt and journals make that visible
  rather than hiding it.
- The release `source` field now carries machine-read provenance. A release made by any other command
  has no `content=` and is treated as changed.
- The config load (`runghc`) is the largest remaining cost of every command and is outside this
  decision.
