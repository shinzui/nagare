---
title: "Typed application deployment"
type: Capability
description: "Load checked Haskell deployment data and deploy an accepted image publication through a reviewed Knative Service change."
generated:
  by: process:openai-codex
  at: "2026-10-10T05:03:04Z"
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-08-25T20:51:44Z"
    document_timestamp: "2026-08-25T20:51:44Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: codex/gpt-5
    effort: unspecified
    context: >-
      Reviewed the capability, compatibility promise, and repository evidence for inclusion in
      the version 0.1.0 Nix release.
capabilityId: CAP-6
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - nagare-dsl
  - nagarectl
interface:
  - "nagare/Config.hs"
  - "Nagare.Dsl"
  - "nagarectl app image-plan"
  - "nagarectl deploy"
requires:
  - CAP-4
evidence:
  - kind: test
    resource: cli/nagare-dsl/test/Spec.hs
    proves: Smart constructors, typed loading, presets, build modes, volume rendering, and golden Knative manifests are exercised together.
  - kind: test
    resource: cli/nagarectl/test/InventoryApplicationSpec.hs
    proves: Accepted image inputs, independent environment channels, and typed workload resource membership are tested offline.
  - kind: test
    resource: scripts/local-smoke.sh
    proves: The live smoke driver uses reviewed image publication and deployment, verifies HTTP reachability, and preserves accepted resources for separate lifecycle reviews.
  - kind: guide
    resource: docs/user/deploying-apps.md
    proves: The consumer path from Config.hs through readiness and URL output is documented.
---

# Typed application deployment

A project exports checked deployment data from `nagare/Config.hs`. Haskell checks types, smart
constructors validate names, scaling ranges, quantities, and paths, and the loader checks the whole
configuration before provider mutation.

In 0.4.0, build the image separately and publish its Docker archive with `nagarectl app image-plan`.
`nagarectl deploy` loads the program and requires an accepted `--image-resource` and explicit tag.
It prepares a reviewed Service scope, renders native inputs, applies the change, and waits for
readiness. `--save-plan DIR` saves the review for separate inspection and apply. Deployment does
not rebuild the source tree; the Dockerfile or Nixpacks build happens before publication.

This capability consumes the [Knative serving, ingress, and TLS bootstrap](knative-serving-ingress-and-tls.md)
(CAP-4), or an equivalent compatible Knative target.
The current review and recovery protocol is cataloged as
[reviewed operation ledger](reviewed-operation-ledger.md) (CAP-22).

## Limits

- Configuration is executed with `runghc`; it is code, not a sandboxed data file. The loader applies
  time and output bounds, but consumers should still treat project configuration as trusted code.
- Live deploy and deployment dry-run require the selected context's inventory and accepted image
  publication. Dry-run prints the public scope rather than executing a build.
- Fresh local and cloud acceptance is recorded in the [0.4.0 evidence](../releases/v0.4.0.md#ir-24-acceptance-evidence);
  this does not establish every configuration on every target.
- The `nagare-dsl` and `nagarectl` interfaces remain experimental. General in-place platform
  payload upgrades after inventory admission are outside the 0.4.0 contract.
