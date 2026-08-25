---
title: "Publish immutable Nix releases from validated tags"
status: accepted
date: 2026-08-25
authors: [shinzui]
related:
  - docs/plans/109-publish-versioned-releases-and-clone-free-onboarding.md
  - docs/adr/0003-package-the-typed-config-runtime-with-nagarectl.md
  - docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md
  - docs/adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md
---

# ADR 7 — Publish immutable Nix releases from validated tags

## Status

Accepted, 2026-08-25. Implemented by
[ExecPlan 109](../plans/109-publish-versioned-releases-and-clone-free-onboarding.md).

## Context

Nagare now packages an installed CLI and a separate immutable platform payload, but operators need
one public identity that selects both. Package versions, payload metadata, generated host inputs, and
the context upgrade contract become misleading if publication can assign different versions to the
same source or silently replace release evidence.

Native Nix outputs also differ by system. Treating one runner's success as proof for every declared
system would make the supported-system claim unverifiable, while publishing portable archives would
introduce a separate runtime-dependency contract that Nagare has not designed.

## Decision

Nagare's first distribution channel is Nix selected by an immutable Git tag named
`v<major>.<minor>.<patch>`. Root `release.json` is the source of truth for the platform version,
release schemas, and supported Nix systems. The release gate requires that version to equal every
Cabal package version, the built CLI version, the packaged payload version, release notes, and
compatibility fixtures. Nix injects the exact clean Git revision into built artifacts.

Tag creation remains a deliberate maintainer action. CI validates an existing tag; it never changes
source, chooses a version, creates a tag, or operates a cluster. Each supported system runs the normal
flake checks and builds its outputs on a native trusted runner. Manual workflow dispatch exercises the
same validation and artifact upload path but cannot publish.

The GitHub release contains reviewed/generated notes, a machine-readable release manifest, native
Nix output identities, and checksums. These attachments describe Nix-by-tag artifacts; they are not
portable binary distributions. The workflow is read-only until a tag-only publication job, where it
receives the minimum `contents: write` permission. A retry accepts an existing release only when all
attachments are byte-identical and otherwise fails. Published tags and attachments are never moved or
replaced.

## Consequences

Operators can pin the same version in `nix run`, profiles, contexts, payloads, and upgrade plans, and
can verify exactly which source revision and native output identities were released. Publication has
no authority to mutate clusters, so selecting or upgrading a context stays an explicit operator
transaction under [ADR 6](0006-version-platform-state-across-cli-payload-context-host-and-cluster.md).

Maintainers must update all version sources and release notes before tagging. Every newly supported
system needs a native or trusted remote runner and release-gate coverage. A broken release is marked
deprecated and superseded by a new semantic version; reproducibility requires retaining its tag and
attachments.
