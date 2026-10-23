---
type: Improvement Request
title: Profile the complete image publication and site deployment path
description: Extend existing inventory tracing to explain image publication and site deployment latency, then optimize the measured remaining costs without weakening reviewed execution.
timestamp: "2026-10-23T02:09:00Z"
generated:
  by: process:codex-cli
  at: "2026-10-23T02:09:00Z"
requestId: IR-37
status: proposed
origin: mori://tan/tan-ng-labs
acceptanceCriteria:
  - id: AC-1
    statement: A representative prebuilt-image publication and protected StaticSite deployment has a reproducible timing report for image-plan, publication apply, site deployment planning, deployment apply, and readiness, identifying CLI version, source commit, cache state and time outside Nagare commands.
    verification: Exercise the ordinary reviewed release sequence on the local harness and confirm it on an authorized intranet release; record cold and warm observations separately and compare the latest candidate with the captured v0.9.0 baseline.
  - id: AC-2
    statement: Existing opt-in tracing attributes time to store work and the remaining release phases, including configuration loading, archive inspection, provider preflight and observation, registry transfer, journal execution, and workload readiness, with completion or failure recorded for started phases.
    verification: Use injected clocks and delayed or failing fake transports to prove attribution and failure reporting, then capture one release trace; keep nested or concurrent timing distinguishable from total wall time.
  - id: AC-3
    statement: Tracing emits safe progress and a final timing summary on stderr without changing stdout contracts, review digests, command exit behavior, authorization, transaction ordering, locking, recovery, or secret handling.
    verification: Compare traced and untraced fake-command results, review bytes and normalized execution journals; assert tokens, credentials, private native payloads and complete environment dumps are absent from diagnostics.
  - id: AC-4
    statement: The report identifies which remaining costs warrant optimization, records before-and-after evidence for any selected changes, and documents how an operator profiles a slow release using supported commands.
    verification: Review the report and operator documentation against repeatable warm measurements; reuse existing performance work and explicitly explain any residual time instead of promising an unsupported deployment-time target.
reviews:
  - kind: model
    reviewer: process:codex-cli
    reviewed_at: "2026-10-23T02:09:00Z"
    document_timestamp: "2026-10-23T02:09:00Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    context: >-
      Author review against the v0.9.0 intranet release evidence, Image and Site
      command boundaries, current Store.Counters, and completed EP-212, EP-217
      and EP-218 at 5b92987f. No independent verification is claimed.
---

# Profile the complete image publication and site deployment path

## Observed operator cost

The protected TAN Connect release in `mori://tan/tan-ng-labs` reached a locally tested Docker
archive at 2026-10-23 01:33:09 UTC. Its new Knative revision became Ready at 01:38:04 UTC,
an interval of approximately 295 seconds. The successful local build, source checks, two browser
passes and image packaging took approximately 33 seconds. These observations motivate measuring
the publication and deployment path, rather than concentrating only on image building.

The 295 seconds are end-to-end elapsed time, including operator orchestration and review
inspection. They are not a measurement of Nagare CPU time, network time, or a single command.
No phase trace was enabled, so this evidence does not establish a particular root cause.

The operator used Nagare v0.9.0. The source was
`d0ef19793c93cc81579cf70aac618ba3ff1906e2` and packaging commit was
`617f6704d71b8df919009e90f42f71e99a3cd158` in `mori://tan/tan-ng-labs`. Release
`git-d0ef19793c93` used image digest
`sha256:04976c81ec99d52ce98a790ec8b085808231742145844728e6225f963ac65444` and revision
`tan-connect-lp-00002`. The image review file was saved at 01:33:59 UTC and the deployment
review at 01:36:32 UTC. These are file-save observations, not command-duration boundaries.
Both applies converged; the final inventory had no active transaction or executor claim.

The operator procedure and accepted release evidence are in `mori://tan/tan-ng-labs`,
project-relative `docs/runbooks/operations.md`, section “The TAN Connect preview”
(artifact-level URI pending). On the operator workstation, immutable reviews are under
`$HOME/.local/state/nagare/intranet/reviews/image-tan-connect-lp-git-d0ef19793c93/` and
`deploy-tan-connect-lp-git-d0ef19793c93/`. Those private files are supporting local evidence,
not prerequisites for understanding or implementing this request.

## Existing work to reuse

This request extends existing instrumentation and performance work. It does not assert that
current Nagare has no timing support or that the v0.9.0 behavior persists in the next release.

[EP-212](../plans/212-open-the-inventory-store-once-per-command-and-load-its-history-once.md)
added `NAGARE_TRACE=1` store counts and elapsed times.
[EP-217](../plans/217-serve-the-committed-journal-from-a-verified-local-copy-and-fetch-only-its-new-tail.md)
records a warm apply improvement from 67.2 seconds to 12.5 seconds for a reviewed access
change. [EP-218](../plans/218-read-inventory-status-native-evidence-concurrently.md)
records faster cold inventory status. All belong to
[MasterPlan 29](../masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md).
Their measurements concern access changes or status, rather than the complete image/site path.

At `5b92987f34f18bdfb84aeb26858bc12b7548011a`, `Nagare.Inventory.Store.Counters`
prints per-store totals and command wall time through `dispatchTraced` in
`cli/nagarectl/app/Nagare/Cli/Dispatch.hs`. Begin with that facility and the completed
optimizations. Measure the current candidate before deciding what additional work remains.
The authoritative latest GitHub release was still v0.9.0 when checked on 2026-10-23; the
working tree was preparing v0.10.0.

## Requested improvement

Profile this supported sequence using an already built archive:

```text
nagarectl app image-plan ... --save-plan IMAGE_REVIEW
nagarectl inventory apply IMAGE_REVIEW --yes
nagarectl site deploy ... --skip-build --image-resource PUBLICATION --save-plan SITE_REVIEW
nagarectl inventory apply SITE_REVIEW --yes
```

Use one outer timer per command and the existing trace for store work. Add phase reporting
where it is needed to distinguish typed-configuration compilation, archive hashing and manifest
inspection, credential acquisition and guards, provider observation, registry upload, journal
replay and writes, and readiness waits. Report safe stage labels when work starts and finishes,
including a final summary on failure. Keep diagnostics on stderr and preserve machine-readable
stdout. Durations should use a monotonic clock. Explain overlapping counters so their sum
is not mistaken for total elapsed time.

Relevant entry points are `cli/nagarectl/app/Nagare/Cli/Commands/Image.hs`
(`runAppImagePlan`), `cli/nagarectl/app/Nagare/Cli/Commands/Site.hs`
(`runReviewedSiteDeployPlan`), `cli/nagarectl/src/Nagare/Inventory/Command.hs`,
`cli/nagarectl/src/Nagare/Inventory/Execute/Transaction.hs`,
`cli/nagarectl/src/Nagare/Inventory/Adapters/ArtifactRuntime.hs`, and the existing
`cli/nagarectl/src/Nagare/Inventory/Store/Counters.hs`.

Use deterministic fake-provider and injected-clock checks for attribution and failure behavior,
then confirm with an ordinary authorized protected release. Record the source/version, archive
size, inventory/cache state, per-command wall time and internal timings. Do not repeatedly
mutate the intranet merely to collect benchmarks. Keep operator gaps separate. Optimize the
measured residual work, and publish the before-and-after evidence or explain why no further
optimization is warranted.

The separate static packaging request [IR-36](package-a-static-site-image-for-reviewed-publication.md)
remains useful; producing an archive and explaining the time after that archive exists are
independently implementable improvements. This request requires no image-builder migration,
platform upgrade in an operator repository, reduced validation, or bypass of reviewed execution.
