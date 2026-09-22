---
title: "Adopt haskell-jitsurei for production Haskell"
status: accepted
date: 2026-09-13
authors: [shinzui]
related:
  - docs/plans/119-adopt-haskell-jitsurei-across-nagare-s-haskell-packages.md
  - mori://shinzui/haskell-jitsurei/docs/core-standards
  - mori://shinzui/haskell-jitsurei/docs/core-record-patterns
  - mori://shinzui/haskell-jitsurei/docs/core-custom-prelude
---

# ADR 16 — Adopt haskell-jitsurei for production Haskell

## Status

Accepted, 2026-09-13. Implemented by
[ExecPlan 119](../plans/119-adopt-haskell-jitsurei-across-nagare-s-haskell-packages.md).

## Context

Nagare's maintained Haskell packages had converged only partially on a shared source style.
They used GHC2024, but mixed type-prefixed record fields, selector functions, record updates,
prepositive qualified imports, repeated common imports, and package-wide `PackageImports`.
That made structurally similar code differ between `nagare-dsl`, `nagarectl`, and
`nagare-access`, and left no automated guard against further drift.

The project is still at version 0.1.0, so this is the appropriate point to make a coordinated
source-level cleanup. The serialized deployment, platform, and authentication formats and all
command-line and HTTP behavior are already user-facing contracts and must remain stable.

## Decision

Production Haskell under `cli/nagare-dsl/`, `cli/nagarectl/`, and `cli/nagare-access/` follows
the current `haskell-jitsurei` core standards at
`mori://shinzui/haskell-jitsurei/docs/core-standards`,
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`, and
`mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`.

Project-owned records use strict fields, explicit deriving strategies, `Generic`, unprefixed
semantic field names, and generic-lens labels for access and updates. Constructor-based record
construction and patterns remain valid. The rule does not apply to records owned by dependencies,
which may continue to use their native selectors and update syntax.

Opaque invariant-bearing types are the narrow exception: they expose neither `Generic` nor
writable optics. This includes `Nagare.Resource` identity newtypes, scope/snapshot constructors,
validated inventories, composition candidates, and credential carriers. `GHC.Generics.to` can
otherwise reconstruct a hidden constructor. Capability references use a nominal index and an
explicit GADT witness, so `coerce` cannot change an output's capability. Public records whose
invariants are entirely in their field types retain the normal house style. EP-144's compiled
positive control and expected-diagnostic negative fixtures enforce this boundary.

Every field of a project-owned `data` record carries an explicit strictness bang to prevent
accidental thunk retention and space leaks. A `newtype` record field is the sole syntactic
exception: its constructor is representation-erased, and GHC rejects a strictness annotation on
it.

`Nagare.Dsl.Prelude` is shared by `nagare-dsl` and `nagarectl` because the CLI already depends on
the DSL. The independently packaged access service uses `Nagare.Access.Prelude`. `PackageImports`
is enabled only in those Prelude modules. Neither Prelude imports `Data.Generics.Labels`; modules
that manipulate generic records opt into its orphan `IsLabel` instance with a plain, local import.

Field renames may break Haskell source compatibility before 1.0, but explicit Aeson mappings keep
JSON keys byte-identical. Deployment YAML, platform transaction data, command names and help,
access-service cookies, headers, statuses, bodies, and error text remain unchanged.

The repository expresses syntax-aware parts of this contract as ast-grep rules. This lets the
strict-field rule distinguish `data` from `newtype` structurally and keeps comments from triggering
import or label checks. A thin shell entry point limits the scan to maintained components and
checks Cabal-level policy; the root flake additionally runs Fourmolu and Cabal Gild in check mode.

## Consequences

The three packages share one predictable record and import style, with less repeated boilerplate
and without forcing the generic-lens orphan instance into every module. Contributors must use the
package Prelude and explicit label imports, and automated formatting and style checks enforce the
convention in CI.

Existing Haskell consumers must update source field names. Persisted data, rendered manifests,
CLI automation, and HTTP clients require no migration because their external representations do
not change. Historical spikes and completed-plan prose remain historical and are not reformatted.
