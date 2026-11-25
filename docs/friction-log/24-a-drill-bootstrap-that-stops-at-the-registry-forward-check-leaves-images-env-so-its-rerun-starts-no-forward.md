---
type: Friction Entry
title: "A drill bootstrap that stops at the registry forward check leaves images.env, so its rerun starts no forward"
description: "scripts/site-access-drill.sh writes images.env before it checks the forward port; when that check fails, the rerun sources images.env, skips seed_images and the registry-forward container, and the next host-side image push in the bootstrap fails with connection refused."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-25T03:54:42Z"
frictionId: FRIC-24
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/nagare"
affects: "mori://shinzui/nagare/scripts/site-access-drill.sh"
plan: "docs/plans/282-resume-inventory-transactions-in-the-configured-local-object-store.md"
workaround: "Started the registry-forward container by hand with the drill's own docker run command and resumed the stopped transaction"
resolution: "Start the registry-forward container with the drill's own docker run command, or rerun in a new root; the drill is a disposable-context tool."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-25T05:11:34Z"
    change: "Accepted: one occurrence after an unusual port refusal; the workaround is recorded here."
---
# A drill bootstrap that stops at the registry forward check leaves images.env, so its rerun starts no forward

## Attempted

Bootstrapping a disposable context ir54 with NAGARE_DRILL_BOOTSTRAP_ONLY=1 after the first run refused 127.0.0.1:15313 (held by another Colima VM's port forward)

## Encountered

Stage 2's apply stopped ambiguous: the artifact transport could not reach the registry forward on 127.0.0.1:15513, which no run had started

```text
pinging container registry 127.0.0.1:15513: Get "http://127.0.0.1:15513/v2/": dial tcp 127.0.0.1:15513: connect: connection refused
```

## Workaround

Started the registry-forward container by hand with the drill's own docker run command and resumed the stopped transaction
