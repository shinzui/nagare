---
title: "Publish immutable Nix releases from validated tags"
status: accepted
date: 2026-08-25
authors: [shinzui]
related:
  - docs/plans/109-publish-versioned-releases-and-clone-free-onboarding.md
  - docs/plans/128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md
  - docs/plans/140-make-clone-free-platform-upgrades-carry-release-pinned-operator-tools.md
  - docs/plans/150-integrate-resource-inventories-into-upgrades-and-release-verification.md
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

## Amendment — 2026-09-14

The installable operator package `#nagare` carries the Pulumi CLI and the Node.js language plugin
from the same locked nixpkgs revision used by its release checks. Their binaries are appended to the
operator wrapper and launcher `PATH`, so an intentional operator override or a test double earlier on
`PATH` still wins. `nagarectl version --tools` makes the resolved binaries visible.

This packaging rule applies only to the operator distribution. The smaller app-developer
`#nagarectl` output remains unchanged, and Node.js with npm plus the Google Cloud SDK remain explicit
external prerequisites. [ExecPlan 128](../plans/128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md)
introduced and validated the rule in signed release `v0.2.2`.

## Amendment — 2026-09-14: intentional operator profile surface

Public `#nagarectl` and `#nagare` outputs expose only their intentional `bin`, `share`, and
`nix-support` trees. Build-time Haskell `lib/links` farms are not part of the distribution contract
and must not enter an operator's Nix profile. The full `#nagare` operator environment additionally
carries `socat`, because its packaged IAP SSH transport requires it; the smaller app-developer
package does not.

Release checks exercise the installed commands, reject either public output when `lib/links` is
present, require `socat` on the operator PATH, and prove the package can share a Darwin profile with
another output that owns the former collision path. [ExecPlan 134](../plans/134-install-a-clean-operator-package-and-fetch-a-context-safe-kubeconfig.md)
introduced and validated this boundary.

## Amendment — 2026-09-15: clone-free platform commands enter the operator shell

An operator invoking an immutable target release without installing it runs platform commands as
`nix shell "${TARGET_NAGARE}#nagare" -c nagarectl ...`. Selecting the complete `#nagare` package is
part of the platform-operation contract: its wrapped CLI receives the release-pinned Pulumi CLI,
Pulumi Node.js language host, and other operator tools. `nix run ...#nagarectl -- ...` remains a
supported application-developer interface, but it is not a clone-free platform-operation command
because its intentionally smaller wrapper does not carry Pulumi.

The native release rehearsal enters that exact shell from an isolated host PATH containing Nix but
no Pulumi. It verifies the wrapper resolves both release-pinned Pulumi executables before prepending
recording doubles, then requires an upgrade transaction to finish its Nix evaluation, one saved
Pulumi preview, and Kubernetes diff with every apply phase still pending. The resulting native
release artifact records the Pulumi version, planned state, and preview count so publication retains
evidence of the full documentation-to-package boundary.

## Amendment — 2026-09-25: publication recovers from provider state

The tag-only publication job uses a checked operator command instead of an
unconditional release action. Its review binds the repository, annotated tag
object and commit, payload identity, exact notes, and the complete named asset
set with byte digests. The first provider write creates a draft with this
unchanging intent in its body. A retry finds that same draft or published
release by its tag and intent, verifies each asset by physical ID and downloaded
bytes, and uploads only missing reviewed assets. Query errors are unknown
outcomes, not evidence of absence.

Before publication, a digest-addressed receipt records the verified product
asset IDs. The command then rechecks the complete asset set and publishes the
same draft ID. A retry after publication reconstructs a local completion
observation from the immutable provider record; it does not append to the
published release. A failed upload placeholder requires a separate review of
its exact draft release and asset IDs before deletion. Changed notes, tag
identity, assets, or foreign provider state cause refusal. A private probe
repository exercised lost-acknowledgement recovery and same-byte published
retry; it did not publish a Nagare release.

The release identity is global to the repository and tag. A deployment context
may reference it but does not own or mutate its publication record. Complete
inventory evidence in the release archive and native tagged release gates
remain [ExecPlan 150](../plans/150-integrate-resource-inventories-into-upgrades-and-release-verification.md) acceptance work.
