---
id: 37
slug: make-releases-routine-by-deleting-what-nagare-does-not-need
title: "Make releases routine by deleting what Nagare does not need"
kind: master-plan
created_at: 2026-11-20T14:59:44Z
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-20T14:59:44Z
---

# Make releases routine by deleting what Nagare does not need

The operator asked for this plan on 2026-11-20, after v0.24.1, a 30-line CLI fix, took seven
candidate runs and most of a day. Its deliverables are deletions. A deliverable that adds a
mechanism states what it adds and what it deletes, and the second number is larger.


## Vision & Scope

### Finish line

The plan is done when one real release passes all four:

1. **A CLI-only fix ships without moving the platform.** Its intranet plan has zero operations: no
   host activation, no image publication, no cluster change.
2. **A platform release that stops at the intranet step restarts at that step.** Nothing before it
   runs again.
3. **A release is cut from a clean checkout on a second machine**, with nothing copied from the
   first except credentials.
4. **One engineer's stopped stateless apply does not block another engineer's unrelated apply.**

The operator's aim (2026-11-20) is an architecture several engineers can operate safely. What
protects them from each other is at the review level and is not touched here: admission refuses a
stale review, a second transaction and a deployer outside its delegation
(`Execute/Admission.hs:168-170`), and every review records its actor. What hurts them is that one
unresolved transaction blocks every other apply, so each stop state is a team-wide stop.

And one number: the Haskell under `cli/` is smaller at the end than at v0.24.1 (177,970 source
lines, 104,710 test lines at v0.24.0), by at least the floors in Progress.

### What stays exactly as strict

- Everything that guards data: the reviewed, journalled, fenced path for databases, migrations,
  backups, restores and volumes, and the upgrade rehearsal that reads a seeded row back.
- The GCP guardrail in `scripts/lib/target.sh` and its fail-closed cloud branch.
- Guarded, self-reverting host activation (`just host-switch`, ADR 11).
- Ownership: Nagare still refuses to write a Kubernetes object or Helm release that is not stamped
  as this context's.

### What is wrong, measured

- **Nothing is ever removed.** From v0.4.0 (2026-10-09) to v0.24.0 (2026-11-19), 146,760 lines
  were added under `cli/` and 10,789 deleted. ExecPlans went from 182 to 270, ADRs from 27 to 40.
  Of 969 commits, 231 are fixes.
- **The engine treats a ConfigMap like a database.** The planner computes a recovery class per
  operation (`Plan/Changes.hs:954`), and no executor reads it. A stateless Deployment and a
  PostgreSQL volume take the same journal, the same per-object proof and the same stop states.
- **A slow rollout becomes an ambiguous stop.** When a Deployment update lands and is not Ready in
  180 s, resume re-reads Nagare's own stamp, sees it differs from the reviewed "before" value and
  reports "stamp changed since review" (`Adapters/Kubernetes.hs:404`, `KubernetesProof.hs:376`).
  Only a Knative Service update is exempt. This was v0.24.1's stage-4 stop.
- **Recovering from a stop makes a new state.** `inventory close` keeps the scope's desired
  revision and leaves it unconverged (`Execute/Close.hs:449`). The next plan then emits a
  journalled `VerifyResource` for every unchanged member of that scope (`Plan/Changes.hs:902`),
  each of which fails if its object is not Ready at that moment, and the scope converges only when
  one review operates on every member (`Execute/Claims.hs:203`). The planner already observes
  every member, so the converged revision is a second record of what observation says. This was
  v0.24.1's "artifact runtime only executes…" stop, and `4fe9b48b` answered it with more code.
- **Every release moves the host and the admin API, whatever changed.** The host flake carries the
  source revision (`Host/Config.hs:344`), so a new revision is a host activation. The admin API
  image links the whole `nagarectl` library and depends on `cluster/`, `nixos/` and `release.json`
  (`nix/haskell-packages.nix:36`), so its digest changed in all 20 of the last 20 releases.
  v0.24.1 planned a host update and 14 platform operations for a planner fix.
- **A candidate run cannot resume.** Each run starts a new directory and repeats every step.
  `release-publish` needs a `latest` link and a landed evidence commit that only a complete run
  writes. The intranet step refuses on pin files it is about to overwrite (two of v0.24.1's seven
  runs; six of fifteen failed runs since v0.16.0, per `4a015b84`).
- **Release state lives on one workstation:** gate and sweep records under `~/.local/state`, a
  Colima profile whose socket path is hard-coded (`TransitionDrill.hs:290`), two container images
  that must already be in its store, and an on-demand x86 builder.

### Why the earlier attempts made it worse

Each kept the engine's contract fixed and built around it.

- **MasterPlan 13** (June) fixed "abstractions": it deleted four shell scripts and added a typed
  Job module, doctor checks, a flake check and a live smoke.
- **MasterPlan 19** answered forty-five review findings with guards, bounds and alerts.
- **MasterPlan 23** built the typed inventory, journal and per-object proof for every resource
  class at once. It closed with 95 findings and the lesson "find defects with interpreters".
- **MasterPlan 26**, "make releases routine", put "weakening any MasterPlan 23 guarantee" out of
  scope. It added a harness, provider interpreters, a gate classifier and a rehearsal. The operator
  cut most of it on 2026-10-10 and closed it on 2026-10-14.
- **MasterPlan 29** made the review cheaper to read: one store open, a blob cache, concurrent
  reads. The review stayed.
- **MasterPlan 30** says "keep the existing reviewed-inventory model" and added five boundaries: a
  compiler, a command session, an observation epoch, a coordinator and a rollout runner.
- **The operator's decisions of 2026-10-10, 2026-10-29 and 2026-11-17** cut ceremony from plans
  and gates. They could not shrink the code, so the same code kept producing the same stops.

This plan changes the contract instead: the strict machinery covers only what can lose data, and
what it no longer covers is deleted with its tests, its recovery states and its rules.


## Exec-Plan Registry

Only D2 touches recovery code that data-bearing operations share, so only D2 gets an ExecPlan.
D1, D3, D4 and D5 are ordinary changes with unit tests.

| Deliverable | ExecPlan | Depends on |
|---|---|---|
| D2 | to be written when D2 starts | D2b after two releases on D2a |
| D1, D3, D4, D5 | none | D4: the intranet usage check |

D1 and D3 are independent of D2 and go first: they pass finish-line tests 1 and 2 without touching
the engine.


## Progress

Each box is ticked with the commit and the measured line change. Floors are estimates from the
file sizes named; a deliverable that misses its floor records why in the Decision Log.

**D1. A CLI-only release has nothing to apply.**
- [ ] The host flake and the cluster stamp stop carrying the source revision. A new revision with
      an unchanged payload plans zero host and platform operations. Deletes the per-revision host
      activation and stamp write from every release.
- [ ] The admin API image is built from the modules it imports (30 of `nagarectl`'s) and from no
      repository tree, so its digest moves only when those modules do. Deletes the `nagareRebuild`
      override and the `sourceForTests` input. Adds one Cabal library stanza; moves code, adds
      none.
- [ ] Evidence: the next CLI-only release's intranet plan has zero operations (finish line 1).

**D2. Stateless Kubernetes objects stop producing stop states.**
Scope: members whose `dataPolicy` is `Stateless` and whose kind is already in the overlap set
(`KubernetesApplication.hs:121`: Deployment, Knative Service, Service, ConfigMap, Secret).
StatefulSets, volumes, credentials and Helm releases that carry a volume stay on the strict path.

D2a, no change to what a review promises:
- [ ] Delete the converged-revision record as a planning input for these members: the unconverged
      clause at `Plan/Changes.hs:902`, `reverifiedScopes`, the transition-commit and harness
      convergence checks, and `4fe9b48b`'s artifact verification. An unchanged member that
      observes as declared gets no operation.
- [ ] Delete the Knative-only restriction on "landed, waiting for readiness"
      (`Adapters/Kubernetes.hs:383`), so a slow Deployment update is awaited, not ambiguous.
- [ ] Evidence: two releases with no ambiguous stop on a stateless member, and the upgrade
      rehearsal reading its seeded row back unchanged.

D2b, a breaking change, started after D2a's evidence:
- [ ] Check the findings ledger for any real stateless problem the per-object proof caught, and
      record the result in the Decision Log before the next box.
- [ ] A stateless apply is recorded once, as "actor X applied review Y", and is not journalled per
      object. A stopped one is rerun from the plan and holds no transaction (finish line 4).
      Deletes `RecoveryAwaitingReadiness`, `SettledLanded` and `SettledTargetGone` for these
      members, the "stamp changed" re-check on resume, `inventory close` for a transaction with no
      data-bearing operation, and the foreign field-manager allow-list
      (`KubernetesConfiguration.hs:117-232`). Target: `RecoveryDecision` 7 → 4, `Settlement` 6 → 4.
- [ ] Floor: −2,500 source lines and −6,000 test lines, from the Kubernetes adapter files (3,329
      lines) and their specs (11,745 lines).

**D3. A release is steps that each run alone.**
- [ ] Delete the candidate run's `record` and `latest` steps and `docs/release-evidence/` (122
      files, 8,819 lines). `release-publish` takes the run directory. A stopped intranet step is
      rerun by itself (finish line 2).
- [ ] Delete the pin-file refusal (`Release/Intranet.hs:208-215`) and
      `scripts/test-release-intranet.sh`; the step writes those files itself.
- [ ] Delete the hard-coded Colima socket and the requirement that two images pre-exist in its
      store; the rehearsal uses the active Docker context and pulls what it needs.
- [ ] Delete the native attachment steps (`check-release.sh`,
      `rehearse-clone-free-release.sh`, `release-native*.sh`, `assemble-release.sh`,
      `test-release.sh`, the Apple-container step and `x86-work`). Floor: −1,200 script lines.
- [ ] Delete the mutation sweep (204 records, `Harness/Mutation.hs`, three
      recipes) and the deep tier (`gate-deep`, `deep-tier-required`, the ledger judge).
- [ ] Evidence: a release cut from a clean checkout on a second machine (finish line 3).

**D4. Features nobody uses, deleted with their adapters and tests.**
- [ ] `registerKubernetesDataFence` and its tests; it has no production caller.
- [ ] List which of these the intranet declares, and delete each one it does not: interactive
      maintenance sessions (cancelled as EP-161, code still present), live database restore,
      context move between base domains (most of v0.24.0's 32 fixes), stuck-pod replacement, VM
      power, CDN and CDN purge, the broker, ClickHouse, previews, image prune. One box per feature
      is added here when the list is known. The delegated deployer and actor recording stay.

**D5. Rules, plans and documents.**
- [ ] Cancel MasterPlans 21 and 25 and close the 36 ExecPlans that still carry open boxes.
- [ ] Delete `docs/audits/` (227 files, 10,565 lines) after moving the fixtures four specs read by
      name into `test/fixtures`, and `docs/evidence/`.
- [ ] Delete from `CLAUDE.md`: the plan-owner Stop hook
      and its rule; the "Decision Log basis" section; the held-plans rule; the heavy-path ceremony
      (a mutation record per fix, recorded API traces, a deferral-ledger entry per finding); the
      "Before a native run" requirement; the readiness checklist's tick-with-evidence paragraph.
      The GCP guardrail and host mutation rules stay word for word.
- [ ] Delete the completed and cancelled plan files from the tree: all ExecPlans and MasterPlans
      with no open box. They stay in git history. ADRs stay.
- [ ] Collapse the gates to two: one per commit, one per landing. `gate-release`, `gate-landable`,
      `gate-post-land` and `gate-verify` go with the sweep.

**Not addressed.** The truncated `nagare-api-server` build was store corruption on the builder,
seen once. D1 makes that image move rarely; nothing is added to detect a repeat.


## Decision Log

- Decision (operator, 2026-11-20): Write this as a new MasterPlan. The rule "no new MasterPlan
  until the readiness checklist is ticked" does not apply and is being removed from `CLAUDE.md`.
  Rationale: the operator asked for cruft removal three times before, and each plan added
  machinery.
  Date: 2026-11-20

- Decision: The strict path is selected by the existing `dataPolicy` field, not by a new
  classification.
  Rationale: `Stateless` and `Durable` already exist on every member and are already branched on
  in two places (`Execute/Driver.hs:347`, `KubernetesApplication.hs:129`).
  Date: 2026-11-20

- Decision: The brief's reading that stage 4 was "controller activity read as a fault" is
  corrected. The stop was Nagare failing to recognise its own landed write after a readiness
  timeout.
  Rationale: the stamp is the `nagare.dev/spec-digest` annotation, which no controller writes
  (`KubernetesConfiguration.hs:33`).
  Date: 2026-11-20

- Decision (operator, 2026-11-20): Drop the release attachments (`nix-output-*.json`,
  `clone-free-*.json`, the byte-identical double assembly). A release is a signed tag, its notes
  and the rehearsal record.
  Rationale: operators pin the tag; nothing reads the attachments.
  Date: 2026-11-20

- Decision (operator, 2026-11-20): Delete the mutation sweep and the deep tier.
  Date: 2026-11-20

- Decision (operator, 2026-11-20): Delete the `CLAUDE.md` rules listed in D5, and delete completed
  and cancelled plan files from the tree. The GCP guardrail and host mutation rules stay.
  Date: 2026-11-20

- Decision (operator, 2026-11-20): The aim is an architecture several engineers can operate
  safely, and the system must stay robust. D2 is split. D2a goes now. D2b is accepted in principle
  with the audit trail kept (actor and review per apply) and starts after two releases on D2a and
  the ledger check. Finish-line test 4 is added.
  Rationale: the protections between engineers are at admission and are untouched; the
  one-transaction rule makes every stop state a team-wide stop. D2b gives up exact resume and the
  stop on a `kubectl` edit made between plan and apply. How a stopped stateless apply holds no
  transaction is not designed yet and belongs to D2's ExecPlan.
  Date: 2026-11-20

- Decision (operator, 2026-11-20): The delegated deployer and actor recording are not deletion
  candidates. The other ten features leave only where the intranet does not declare them.
  Date: 2026-11-20


## Outcomes & Retrospective

(One paragraph at completion.)
