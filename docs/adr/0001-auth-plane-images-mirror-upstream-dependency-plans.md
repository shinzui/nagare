---
title: "Auth-plane images mirror upstream dependency plans"
status: accepted
date: 2026-08-25
authors: [shinzui]
related:
  - docs/plans/104-upgrade-nagare-to-the-latest-shomei-and-en.md
  - "mori://shinzui/en — docs/adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md"
---

# ADR 1 — Auth-plane images mirror upstream dependency plans

## Status

Accepted, 2026-08-25. Implemented by
[ExecPlan 104](../plans/104-upgrade-nagare-to-the-latest-shomei-and-en.md).

## Context

Nagare consumes `mori://shinzui/shomei` and `mori://shinzui/en` both as Haskell
libraries linked into nagare-access and as standalone service images. The image helper
builds from sibling source checkouts and writes a temporary `cabal.project`; this is a
second dependency-plan surface alongside `cli/nagare-access/cabal.project`.

That duplication is security-relevant. En's Biscuit support requires the reviewed
`mori://shinzui/biscuit-haskell` fork, and pg-migrate moves the shared closure to
crypton 1.1. A generated project that omits the fork or admits an older crypton can
solve differently from upstream, fail late during an image build, or silently miss an
upstream compatibility constraint.

## Decision

Nagare Git-pins exact, remote-reachable Shomei and En commits for nagare-access. Its
local-source image builder consumes the corresponding sibling checkouts and generates a
Cabal project that mirrors the relevant pins and constraints from both upstream projects.

In particular:

- OpenAPI, JOSE, pg-migrate, and health packages resolve from their current Hackage
  releases unless upstream explicitly requires a fork.
- The Shomei WebAuthn fork and En Biscuit fork remain pinned to reviewed commits.
- The combined Shomei/nagare-access plans retain
  `crypton-x509-validation >= 1.9.1` and `crypton >= 1.1`; En retains the crypton 1.1
  floor required by its Biscuit and pg-migrate closure.
- Updating either upstream pin requires comparing its current `cabal.project` with both
  Nagare project files and building all affected images.

## Consequences

Auth images are reproducible from explicit sources, and dependency policy cannot drift
merely because an executable is built through a different Docker path. The cost is a
deliberate maintenance obligation: every Shomei or En upgrade must review two Nagare Cabal
plans and validate the service images, not only compile the Haskell library.

The local-source builder still requires sibling checkouts. Removing that operational
requirement belongs to the versioned-distribution work, not to dependency compatibility.


## Amendment — 2026-10-12: service images use the same source pins as the gateway

The user requested latest upstream En and Shomei while validating
[MasterPlan 27](../masterplans/27-protect-every-nagare-site-with-explicit-user-and-team-access.md).
All three image variants now archive the exact commits in `cli/nagare-access/cabal.project`,
including Shomei's entrypoint. A dirty or newer Mori source checkout cannot change a server
image independently of the gateway's client API. The upstream-owned migration executable
continues to ship in the same image as its server.

The selected En commit still bounds its migration packages to the pg-migrate 1.1 cohort,
while selected Shomei requires 1.2. The published 1.2 core, CLI, and embed changelogs report no
API or behavior change; the breaking change is confined to test support. Nagare admits 1.2
only for En's three affected migration dependencies and constrains the cohort to 1.2.0.0 in
both build plans. This is a narrow compatibility exception, removable when upstream bounds
admit 1.2; it does not relax unrelated package bounds. Source and release evidence belongs to
mori://shinzui/pg-migrate and its project-relative `pg-migrate/CHANGELOG.md`,
`pg-migrate-cli/CHANGELOG.md`, and `pg-migrate-embed/CHANGELOG.md` (artifact URIs pending).
