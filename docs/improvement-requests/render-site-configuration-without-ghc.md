---
type: Improvement Request
title: Render site configuration without GHC
description: Decide on a way to render an untrusted site's configuration in a credential-free build without shipping a Haskell compiler, either a precompiled evaluator or a data format for simple sites.
timestamp: "2026-11-20T18:36:00Z"
generated:
  by: process:claude-code
  at: "2026-11-20T18:36:00Z"
requestId: IR-49
status: proposed
targetPlan: mori://shinzui/nagare/plans/275-compile-typed-static-site-configurations-and-package-their-rendered-documents-without-ghc
origin: mori://shinzui/kotei/masterplans/26-let-any-engineer-onboard-a-repository-and-deploy-on-push-through-a-kotei-hosted-on-nagare
originPlan: mori://shinzui/kotei/masterplans/26-let-any-engineer-onboard-a-repository-and-deploy-on-push-through-a-kotei-hosted-on-nagare
acceptanceCriteria:
  - id: AC-1
    statement: An ADR records the chosen design for rendering a site's configuration without a full GHC toolchain, or records the decision to keep the compiler, with the trade-offs below.
    verification: The ADR is accepted and amends ADR 3 if it changes the typed-config contract.
  - id: AC-2
    statement: If a design is chosen, a credential-free build of a static site renders the same deployable document without GHC in its closure.
    verification: A closure check of the chosen render output finds no GHC, and its rendered document equals the typed Config.hs render for an equivalent site.
---

# Render site configuration without GHC

Raised alongside IR-48 from
`mori://shinzui/kotei/masterplans/26-let-any-engineer-onboard-a-repository-and-deploy-on-push-through-a-kotei-hosted-on-nagare`.
IR-48 proposes a smaller render package that still carries GHC and `nagare-dsl`, because `site render`
compiles the repository's typed `nagare/Config.hs`. Removing the compiler is a design change,
not packaging.

## Candidate directions

1. **A precompiled evaluator.** Ship `nagare-dsl` as an already-compiled program that loads a
   config without the compiler toolchain, through a small embedded interpreter or a restricted,
   evaluable subset of the DSL for site configs.
2. **A data format for simple sites.** A static site declares validated JSON or Dhall instead of
   `Config.hs`, so its build needs no GHC. Typed `Config.hs` remains for applications.

## Trade-offs to decide

- ADR 3 makes the compiler part of nagarectl's contract, because typed config is executable
  Haskell. Either direction amends it.
- Direction 1 replaces the full language with a smaller one that Nagare must keep sound and
  equivalent to the typed render.
- Direction 2 splits the configuration model: a site written in data loses the typed helpers and
  compile-time validation, and the data format gains its own validation and versioning.
- Security: ADR 35 keeps evaluation of untrusted config in the credential-free build either way.
  A data format shrinks what that build must contain and what an untrusted config can execute.

The proposed pilot in [ExecPlan 275](../plans/275-compile-typed-static-site-configurations-and-package-their-rendered-documents-without-ghc.md) starts with an amendment to ADR 3. The design decision and compiler-free equivalence checks remain open.
