---
type: Improvement Request
title: Stop nagarectl init from inheriting derived fields from the active context
description: A new context created while another is current silently takes that context's bucket names and other derived values, pointing a fresh project at another cluster's live buckets.
timestamp: "2026-09-14T01:56:48Z"
generated:
  by: process:claude-code
  at: "2026-09-13T23:42:08Z"
requestId: IR-7
status: completed
completedAt: "2026-09-14T01:56:48Z"
resolution: "Commit 73a2f4a made named init resolve only from flags, built-in defaults, and the named context's own stored values under --force; it also prints derived names and refuses foreign derived buckets before any side effect. The unit suite and nagare-clone-free-platform check cover a foreign current context, fresh and forced init, stored Pulumi backend preservation, and ownership refusal. Full local and native release gates passed, and the behavior is published in the signed v0.2.2 tag at commit 248e5f9."
targetPlan: docs/plans/128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md
origin: mori://shinzui/nagare
---

# Improvement Request: stop `nagarectl init` from inheriting the active context

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout on `v0.2.1`
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** completed by [ExecPlan 128](../plans/128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md) and published in signed tag `v0.2.2` at `248e5f9`.
**Created:** 2026-09-13.


## Why

This is a cross-project blast-radius defect of the kind IR-2 set out to close. On 2026-09-13 the
operator's current context was `tan-nb-exp`, a live cluster. Creating a context for a brand-new
project with every decision passed explicitly:

```bash
nagarectl init labs --project tan-ng-labs --base-domain labs.topagentnetwork.net \
  --machine-type n2-standard-4 --boot-disk-type pd-balanced --boot-disk-size-gb 200 \
  --data-disk-size-gb 100 --acme-email … --acme-directory staging --pulumi-backend gcs --dry-run
```

printed a context containing:

```text
export CLOUDSDK_CORE_PROJECT=tan-ng-labs
export NAGARE_IMAGE_BUCKET=tan-nb-exp-nagare-images
export NAGARE_BACKUP_BUCKET=tan-nb-exp-nagare-backups
```

Those are `tan-nb-exp`'s live buckets. No `--force` was involved. Had it been written, the new
context would have been seeded into its Pulumi stack with another project's bucket names; `host-image`
uploads and backups resolve the bucket from the context. The bucket ownership guard from IR-2 would
likely refuse some writes, but the context file itself would be wrong from birth, and nothing in the
`init` output draws attention to it.


## What is missing

At `v0.2.1`, `profileFromOpts` (`cli/nagarectl/src/Nagare/Init.hs:107-131`) sets the flag values in
the process environment, unsets `NAGARE_REGISTRY_HOST`, `NAGARE_IMAGE_BUCKET`, `NAGARE_BACKUP_BUCKET`,
`NAGARE_ARTIFACT_REGISTRY_ID` and `NAGARE_INSTANCE_NAME` so "the derivation, not a stale env value,
wins", and then calls `resolveTargetProfile`. That resolves the **active** context
(`NAGARE_CONTEXT`, then `current-context`; `cli/nagarectl/src/Nagare/Target.hs:855-866`) and reads it
through `ctxOr` (`Target.hs:714-721`), which falls from environment to the context map before the
default. So any derived field the active context stores explicitly beats `<project>-nagare-images`.
Unflagged fields (`NAGARE_TARGET_PLATFORM`, `NAGARE_MODE`, `NAGARE_LOCAL_OBJECT_STORE`,
`NAGARE_PULUMI_BACKEND_URL`) are inherited the same way. A foreign `NAGARE_PULUMI_BACKEND_URL` would
put the new stack's state in another project's bucket.

`runInit` also takes its prompt defaults from `activeProfile` (`cli/nagarectl/app/Main.hs:2953`),
which is reasonable for re-running `init` on the same context but not for creating a different one.

Workarounds tried: `NAGARE_CONTEXT=labs` aborts with `context "labs" not found`, because the
context does not exist yet. Removing `current-context` works: a dry run with no active context derived
`tan-ng-labs-nagare-images` and `tan-ng-labs-nagare-backups`.


## Requested change

- When `init NAME` creates a context that does not exist, derive every unflagged field from the
  flags and built-in defaults only, never from another context.
- When `NAME` already exists (`--force`), use `NAME`'s own stored values as the base, never the
  active context's.
- Print the derived fields (buckets, registry, backend URL) in `init`'s output, and refuse if any
  derived resource name embeds a project id other than `--project`.


## Required verification

- A hermetic test: with a current context whose file sets `NAGARE_IMAGE_BUCKET=other-nagare-images`,
  `nagarectl init new --project p … --dry-run` renders `NAGARE_IMAGE_BUCKET=p-nagare-images` and the
  same for every derived and unflagged field.
- A test that `init existing --force` bases omitted fields on `existing`, not on the current context.


## Acceptance

Creating a context never copies a value from a different context, whatever is current.


## Non-goals

Changing the context file format or the derivation rules themselves.
