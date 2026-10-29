---
id: 215
slug: let-one-access-review-carry-several-memberships-or-grants
title: "Let one access review carry several memberships or grants"
kind: exec-plan
created_at: 2026-10-22T20:22:26Z
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-22T20:22:26Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-28T19:15:39Z
      verdict: "approved"
      note: "The optional multi-relationship review has a coherent scope, satisfied prerequisite, duplicate checks, and partial-failure/resume acceptance."
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-29T16:43:23Z
      mode: "update"
      note: "Detached from MasterPlan 29 as a standalone plan"
---

# Let one access review carry several memberships or grants

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). It is a standalone, optional plan, split out of
[MasterPlan 29](../masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md)
on 2026-10-29 when that MasterPlan closed; it never gated it.


## Purpose / Big Picture

Onboarding five people to a team today is five `access team add-member --save-plan` reviews and
five `inventory apply` runs, because each command compiles exactly one relationship. After this
plan one command carries several: `access team add-member --team engineering --user a@x --user b@x
--save-plan DIR` writes one review whose plan lists two memberships, and one `inventory apply DIR
--yes` lands both in one transaction. `remove-member` accepts repeated `--user` the same way;
`grant` and `revoke` accept repeated `--user` or repeated `--team` on one host. Every relationship
is still its own reviewed scope ([ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md)
§5); the review simply replaces several scopes at once, which the composer already supports.

Observable outcome: the saved review's plan shows one `create` operation per relationship, each
named as today (`grant user_… (a@x) viewer on HOST`, `member user_… (a@x) of team engineering`);
`access team list-members --team engineering` lists both after the apply; and a second
`add-member` with the same two users plans no operations.


## Progress

- [ ] M1: `planRelationship` compiles a non-empty list of scopes into one candidate. Pass:
  planning two memberships against an accepted snapshot yields one `ReviewBundle` with two scope
  members, two operations and two accepted-base revisions unchanged (`InventoryAccessSpec`).
- [ ] M2: CLI options. `add-member` and `remove-member` accept `--user` one or more times;
  `grant` and `revoke` accept `--user` one or more times or `--team` one or more times, never
  both; duplicates refuse with the duplicate named; `--host` stays single. Pass: option-parsing
  tests for the accepted and refused shapes; `nagarectl access team add-member --help` documents
  the repetition.
- [ ] M3: Apply semantics are the existing ones and are documented. Pass: an apply whose second
  write fails leaves the first relationship landed and the transaction stopped with a
  per-operation exit (ADR 26), proved with a fake `AccessOps` whose second write is
  `AdapterEffectFailed`; `docs/user/access.md` "Teams" shows the multi-user form and says what a
  partial failure looks like and how `inventory resume` finishes it.


## Surprises & Discoveries

(Not used; operator decision 2026-10-10.)


## Decision Log

2026-10-22: One review, several scopes, unchanged model. A relationship stays one scope so that
retirement, observation and ADR 29's identity rules do not change; the review composes several
`ReplaceScope` changes, which `composeInventory` already accepts as a `NonEmpty`.

2026-10-22: One host per `grant` and `revoke`. Repeating `--host` would make a review span sites
and read less clearly; the per-host review is the unit the access runbook explains.

2026-10-29: Detached from MasterPlan 29 as a standalone optional plan (operator); MasterPlan 29 closed without it.


## Outcomes & Retrospective

(Not used; operator decision 2026-10-10.)


## Context and Orientation

`cli/nagarectl/src/Nagare/Access/Reviewed.hs` is the planner for reviewed access commands.
`planAccess`, `planTeamAccess` and `planTeamMember` each pass one compile function
(`compileAccessScope`, `compileTeamAccessScope`, `compileTeamMemberScope` from
`Nagare.Inventory.Access`) to `planRelationship`, which loads the accepted snapshot, compiles one
`ScopeDeclaration`, builds a `CompositionCandidate` with
`composeInventory snapshot (ReplaceScope scope :| [])` and hands it to
`Command.planInventoryCandidateWith` with `accessPlanRegistry`. After EP-212 lands,
`planRelationship` takes the opened store and pinned history instead of loading them; this plan
builds on that signature, which is why it waits for EP-212.

`composeInventory` (`Nagare.Resource.Inventory`) takes a `NonEmpty ScopeChange` and already
checks address claims and identities across all of them, so two memberships of the same user in
the same team, or two grants of the same subject on the same host, are refused as duplicate
identities by composition; the CLI refuses them earlier with a clearer message.

`cli/nagarectl/app/Nagare/Cli/Options/Access.hs` defines the option records: the membership
command has `user :: !String` (line 38), the grant command has `user :: !(Maybe String)` and
`team :: !(Maybe String)` with "exactly one of" enforced in
`cli/nagarectl/app/Nagare/Cli/Commands/Access.hs` (line 110). `runAccess` dispatches to the
planner functions.

The access adapter (`Nagare.Inventory.Access.mkAccessAdapter`) observes and operates per tuple;
with EP-214 landed the tuples of one review share one forward. Each tuple is its own operation in
the transaction, run in operation-ID order (`Nagare.Inventory.Execute.Driver`), and a failure
after a landed write stops the transaction with a per-operation exit
([ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md)); `inventory resume`
continues it.

User documentation: `docs/user/access.md`, section "Teams" and "Manage grants".


## Plan of Work

M1 generalizes the planner. `planRelationship` takes `NonEmpty (ScopeSnapshot -> Bool -> Either Text ScopeDeclaration)`
(or a function returning `NonEmpty ScopeDeclaration`), compiles each against the same snapshot,
refuses if two compiled scopes share a `scopeId`, and composes
`ReplaceScope <$> scopes`. `planAccess`, `planTeamAccess` and `planTeamMember` take a `NonEmpty`
of subjects. The registry (`accessPlanRegistry`) is unchanged: it already binds every declared
tuple.

M2 changes the option parsers to `some` for the repeated flags, keeps `--host` single, and moves
the "exactly one of `--user` and `--team`" check to "one kind, at least one value, no duplicates".
Help text names the repetition.

M3 writes the test for a partial failure (fake `AccessOps` whose `accessWrite` fails on the
second tuple) and documents the behaviour and the `inventory resume` path in `access.md`.


## Concrete Steps

```bash
just haskell-style-check
just gate-fast
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "/Access/"' --test-show-details=direct
```

Commit message shape:

```text
feat(access): plan several memberships or grants in one review

ExecPlan: docs/plans/215-let-one-access-review-carry-several-memberships-or-grants.md
```


## Validation and Acceptance

- Planning `add-member --user a --user b` produces one bundle with two scopes and two create
  operations; planning it again against the applied state produces no operations.
- `add-member --user a --user a` refuses naming `a`; `grant --user a --team t` refuses as today.
- Apply with the second write failing leaves one landed membership, a stopped transaction and a
  resumable ID; resume with the fake fixed finishes the second.
- Existing access tests pass; `just gate-fast` is green.
- The documented command in `docs/user/access.md` is the one the tests exercise.


## Idempotence and Recovery

Planning is read-only apart from publishing the review object. Apply is the existing transaction
with the existing per-operation recovery. Reverting the landed commit returns the single-subject
options; saved multi-subject reviews remain valid immutable reviews and still apply.


## Interfaces and Dependencies

```haskell
-- cli/nagarectl/src/Nagare/Access/Reviewed.hs (after EP-212's signature)
planRelationship :: ... -> NonEmpty (ScopeSnapshot -> Bool -> Either Text ScopeDeclaration) -> ...
planTeamMember :: ... -> TeamKey -> NonEmpty ShomeiUser -> ...
planAccess :: ... -> Text -> NonEmpty ShomeiUser -> ...
planTeamAccess :: ... -> Text -> NonEmpty TeamKey -> ...
```

Hard dependency: EP-212 complete (shared `planRelationship`). Soft: EP-214 (one forward for the
several observations).
