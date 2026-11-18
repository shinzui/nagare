---
type: Friction Entry
title: "Artifact transport exits 0 without publishing under bash 3.2"
description: "A resume run from a shell whose first bash was macOS 3.2 reported 'transport returned success but the publication is absent' three times without copying, which hid the real cause."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-18T19:38:31Z"
frictionId: FRIC-17
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare"
plan: "docs/plans/263-print-versioned-preview-and-saved-review-documents-from-site-deploy.md"
workaround: "put bash 5 first on PATH; the resume then converged"
resolution: "The audit's findings record it for the operator; the transport already needs bash 5, and adding a check is against the house rules."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-18T19:38:56Z"
    change: "Accepted: a known environment requirement, reported in docs/audits/ep263-local-confirmation-2026-11-18.md."
---
# Artifact transport exits 0 without publishing under bash 3.2

## Attempted

inventory resume of an ambiguous image publication on a local context (scripts/inventory-artifact-transport.sh)

## Encountered

an immediate ambiguous result with no registry copy and no stderr

```text
artifact transport returned success but the publication is absent
```

## Workaround

put bash 5 first on PATH; the resume then converged
