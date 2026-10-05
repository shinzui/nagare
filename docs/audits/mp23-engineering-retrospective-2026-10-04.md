# MP-23 engineering retrospective, 2026-10-04

**Author:** claude-opus-5-5 (session nagare-9), at the operator's request, relayed by nagare-reviewer.
**Scope:** how [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md)
finds and fixes defects, using findings F01–F54 as data. It covers tooling and agent behaviour. It
proposes concrete changes and does not reopen any product decision.
**Outputs:**
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), the rule (accepted);
- [the pre-flight checklist](../runbooks/before-a-native-run.md), for every session before cp3 or cloud work;
- the [MasterPlan 26](../masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md)
  update, which adds [EP-173](../plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md)
  (adversarial interpreters) and [EP-174](../plans/174-gate-every-commit-before-any-native-run.md)
  (per-commit gate) and moves both ahead of MasterPlan 23's remaining native work.

## 1. The finding in one paragraph

Nagare's inventory runs every provider action through a narrow adapter interface (`Adapter`, and
beneath it per-provider operation records such as `KubernetesAdapterOps` and `ObjectOps`). That
design exists so behaviour can be tested with in-memory interpreters in seconds. On 2026-09-29 a
source audit used those interpreters and found eleven defects (F01–F11) in one pass. After that the
project stopped using them as its main way of finding defects. Of the 54 findings, **35 were found by
native runs. 26 of those 35 (74%) could have been found by a type check, a fake-adapter test or a
model test.** Only one (F15, real credential expiry) needed the cloud. In the last two days (F35–F54),
18 of 20 findings were found natively, and 15 of those 18 were cheap-layer defects. Each native
discovery cost a candidate freeze → C1 → C2 → C3 cycle, plus another to confirm the fix. Seven
candidates were frozen in two days, and six were made non-final by findings. **None of those six
invalidations needed the cloud to discover.** Meanwhile no per-commit check ran anywhere for 785
commits: GitHub Actions has been off since 2026-09-22, and no local gate replaced it (F53).

## 2. Data

### 2.1 Method

Two independent read-only passes classified every finding from its full text in
[the register](mp23-findings.md) and [the closed archive](mp23-archive/mp23-findings-closed.md),
cross-checked against the independent-results records. For each finding they recorded where it was
found, the cheapest layer that could have found it given the adapter design, and whether its
regression covers the defect's class or only the instance. "Could have found" means a specific fake
or state would have exposed it; each row names that fake in Appendix A. Where a finding genuinely
needs real platform or transport behaviour, it is classified as such.

Layers:
- **L0**: a type, exhaustiveness or static check.
- **L1**: a unit test with a fake adapter or fake provider operations.
- **L2**: a model test over adversarial provider states.
- **L3**: a local smoke test: k3d, a container, a loopback sshd, a real Pulumi CLI on a file backend.
- **L4**: cp3, the native local acceptance.
- **L5**: a cloud context.

### 2.2 Where findings were found vs where they could have been

| Found at | Count | Cheapest layer of those findings |
|---|---|---|
| Source audit / in-memory probe | 14 | L1–L2 (by construction) |
| Public CLI with recorders | 4 | L0–L3 |
| `nix flake check` at freeze | 1 | L0 |
| Local native (cp3, operator-root roundtrip) | 12 | 10 × L0–L2, 2 × L3 |
| Cloud native | 23 | 16 × L0–L2, 6 × L3, **1 × L5** |
| **Total** | **54** | 44 × L0–L2 (81%), 9 × L3, 1 × L5 |

Cheapest layer across all 54: L0 = 4 (F11, F13, F44, F53), L1 = 27, L2 = 13, L3 = 9 (F14, F20, F21,
F27, F32, F34, F39, F41, F47), L5 = 1 (F15).

The nine L3 findings all needed only local real behaviour: Knative and Kourier semantics on k3s,
CRI sandboxes, OpenSSH option precedence and remote-shell argument joining, http-client's redirect
default, Pulumi's `same` steps, a k3d node restart, a clean Pulumi environment. None needed GCP.

### 2.3 The trend

| Period | Findings | Found natively | Of those, L0–L2 |
|---|---|---|---|
| 09-29 (source audit) | F01–F13 | 0 | — |
| 09-30 to 10-02 | F14–F34 | 17 | 11 |
| 10-03 to 10-04 | F35–F54 | 18 | 15 |

The audit that opened MP-23's verification shows the interpreter-first approach works here. It found
F01–F11 with fakes and recorders, and its regressions are still in the suite. The project then
shifted to native runs as the discovery mechanism. By the last two days, interpreters found only one
defect (F36, by source read).

### 2.4 The dominant class: a reachable stuck state with no reviewed exit

Thirteen findings are exactly "a transaction can reach a state from which no supported command
leads out": F07, F09, F12, F13, F16, F18, F26, F29, F30, F35, F36, F37, F54. Six more strand the
store until a new recovery path is added (F14, F15, F20, F38, F40, F46). All thirteen primaries are
L0–L2. Eight of them were found natively.

The application lifecycle alone produced the same defect seven times, each fixed as one branch:

| Finding | Branch that had no exit | Found |
|---|---|---|
| F16 | create lands, never Ready | cloud |
| F29 | route create refused after admission | cp3 |
| F30 | update never started, status churn moved `resourceVersion` | cp3 |
| F35 | a later operation's preflight refused after admission | cp3 |
| F36 | Redis scratch restore failed | source |
| F37 | foreign field manager at apply | cp3 |
| F54 | update landed, new revision never Ready | cloud |

One test enumerating `{create, update, restore} × {never started, landed-ready, landed-unready,
landed-failed, lost acknowledgement, refused, foreign manager, status churn}` and asserting that each
resulting stopped state has a reviewed exit would have found all seven in one run.

The existing model does not do this. The EP-153 "fixed-seed in-memory driver model"
(`cli/nagarectl/test/InventoryTransactionSpec.hs`, `runFixedSeedDriverModel`) runs four hard-coded
cases. Each case interrupts one effect with `AdapterEffectAmbiguous`, and recovery *always* returns
`RecoveryProvedComplete`. Observation always returns a stable `model:<id>` identity. So the model
covers only "the effect landed and the proof is available". It never produces the other
`RecoveryDecision` constructors (`RecoverySafeToRetry`, `RecoveryAwaitingReadiness`,
`RecoveryLandedUnready`, `RecoveryTerminalFailure`, `RecoveryUnresolved`). It never produces any
`ResourceObservation` other than `ObservedPresent` and `ConfirmedAbsent`. It never fails the store or
a read. The only adversarial interpreters in the suite are the F20 collection world
(`test/Nagare/Test/Effectful/CollectionModel.hs`, 14 faults behind the real kubectl transport) and
the restore model (`test/Nagare/Test/Effectful/Model.hs`, 4 faults). Both show the right pattern;
neither was generalized. None of the project's roughly 1,190 `nagarectl` tests is a property or
state-machine test, and no project package depends on a property-testing library.

### 2.5 Regressions are mostly per instance

| Regression scope | Count |
|---|---|
| Class (covers the defect family) | 12 |
| Partial (one form of the class) | 7 |
| Instance only | 25 |
| None in the suite (native proof only, open, or a gate) | 10 |

"Found natively, fixed narrowly" is the norm. The closure rule in [the register](mp23-findings.md)
requires "the required regression evidence is retained". It does not require that the regression
cover the class, or that it fail on the pre-fix source.

### 2.6 Candidates

Frozen on 10-03: `db808a74`, `44ff0fd7`, `14071e58`, `7d486457`. Frozen on 10-04: `7596632c`,
`84754389`, `b74b7e49`. Six were made non-final:

| Candidate | Made non-final by | Cheapest layer |
|---|---|---|
| `db808a74` | F37 | L2 |
| `44ff0fd7` | F39, F40, F41 | L3, L1, L3 |
| `14071e58` | F42, F43, F44 | L1, L1, L0 |
| `7d486457` | F45, F46, F47 | L1, L2, L3 |
| `7596632c` | F49 | L1 |
| `84754389` | F53 | L0 |

Four of the six invalidations were entirely L0–L2. The other two also had local-L3 triggers. None
needed the cloud.

### 2.7 The per-commit gate did not exist

- **GitHub Actions is disabled.** `gh api repos/shinzui/nagare/actions/permissions` returns
  `{"enabled":false}`. The last CI run is 2026-09-22. Its last four completed runs were red; each
  failed the `haskell-style` flake check.
- **785 commits** have landed since then, and no local per-commit gate replaced it.
- **The operator does not want GitHub Actions back** (2026-10-04: too slow; the flake-check job took
  about 18 minutes per push). The gate must therefore be local. No document recorded the change, and
  [EP-169](../plans/169-run-the-local-acceptance-in-ci.md) still assumes GitHub Actions.
- **F53's evidence matches.** "Nothing had run the flake check for many commits, so earlier
  candidates carried most of these failures."
- **The Linux builder was down** during at least one "passing" Linux check. Nothing checked that it
  actually built.
- **Exhaustiveness is mostly only a warning.** The shared cabal stanza uses `-Wall` without
  `-Werror`. Only 15 of 362 `nagarectl` modules opt in to `-Werror=incomplete-patterns` through a
  per-module pragma. The `Execute` driver modules opt in. The Kubernetes adapters
  (`Adapters/Kubernetes*.hs`), `Plan.hs` and `Plan/History.hs` do not, and those are where recovery
  decisions are produced and matched. The F13 class (an unhandled new constructor) can therefore
  recur there. The F54 repair in the working tree adds a `RecoveryDecision` constructor.
- **The adapter wiring is untested.** `cli/nagarectl/app/` holds 23,866 lines the test suite cannot
  import, including 3,911 lines of adapter wiring in `app/Nagare/Cli/Inventory/`. F45(a), F45(b) and
  F47 lived there and have no unit regression. F44's regression compares a list, not the executable's
  real registry.

## 3. Root causes

### 3.1 Process and tooling

1. **Native evidence was the unit of progress.** Phase C measures a candidate by C1/C2/C3 and closes
   findings by native verification. Nothing measured interpreter coverage. Sessions did what was
   measured. The fastest-looking path to closure was a native run, and each one found the next defect.
2. **Closure accepts instance regressions.** A fix with one named test for the observed branch was
   closable. So F16, F30, F35, F37 and F54 each fixed one branch of the same missing invariant.
3. **The interpreters were not adversarial.** The model's fakes return success or a recoverable
   ambiguity. Nobody asked "what can a provider do that this fake never does?" The answer is: replace
   the object, rename it, report it unready forever, have another field manager, fail once.
4. **No per-commit gate.** Nothing ran per commit, and the flake check ran only at freeze. A whole class of
   defects (F53) was therefore found at the most expensive moment.
5. **The production wiring is not testable.** Code in `app/` can only be exercised natively.
6. **Hand-written native drivers.** The C2 and C3 drivers were session-written shell, re-derived per
   run ([ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md)
   and EP-168 address this). Evidence-pipeline mismatches cost whole reruns (harness rules 1–3).
7. **Deferral as a pressure valve.** Eight items are deferred or recorded as known limits under time
   pressure (§5). Each one is a known gap that the next native run may hit.

### 3.2 Agent behaviour

The operator's judgment is that the mistakes were avoidable. They were. Each item below happened on
2026-10-03/04, and each has a rule that would have prevented it. The rules are in
[the pre-flight checklist](../runbooks/before-a-native-run.md).

| Behaviour | Instance | Rule |
|---|---|---|
| Rehearsed that a review *plans*, not that its workload *runs* | Phase-3a correction reused the scenario-b image (needs `REDIS_URL`) with a PostgreSQL binding; crash-loop wedged `mp23-c3i` (F54). F29 was also a fixture error. | Prove the workload runs locally, or read its entrypoint, before any cluster apply. |
| Went native before checking interpreter coverage | F54 exercised first on cloud; the model never produces landed-unready | Name the interpreter test that covers each path before a native run; write it if missing. |
| Destructive write | A Python one-liner opened the archive for writing before reading it and truncated 915 lines (caught at diff) | Never write a file in the same expression that reads it; check `git diff --numstat` before every commit. |
| Repeated known environment traps despite memory | zsh word-splitting and glob aborts, GNU vs BSD `date`, `rm -rf` inside `bash -c` blocked, mutation edits that did not compile | Live scripts go in files, dry-run on scratch data; the environment facts are in the checklist. |
| Proposed deferring a P1 to save time | The reviewer recommended deferring F54; the operator rejected it | Only the operator defers, with the ledger shown. Stuck-state P1s are not deferrable. |
| Recorded an inference as fact (nearly) | F52's "recorded" UIDs | Label each value observed or inferred when written. |
| Typed commit hashes from memory | Three wrong hashes sent to a peer on 10-03/04, one for a freeze point, despite an existing memory rule | Copy from `git` output. |
| Sampled instead of exhaustive assertions | A driver sampled listings, so receipt C was never attempted; zero-count assertions missed F52's migration window | Zero-count assertions read the full listing over the whole window. |
| Trusted an exit status | Linux check "passed" with the builder down | Check that the builder actually built. |
| Accepted narrow fixes as closure | Implementers and reviewer alike, F16 → F30 → F35 → F37 → F54 | Every native defect gets a class-level interpreter regression that fails on the pre-fix source. |

**Why memory did not help.** Most of these were already written down. The rules in
`rehearse-live-steps-and-batch-approvals` and `copy-commit-hashes-from-git-output` existed before
the mistakes were repeated. Memory and runbook prose are read at session start and are not consulted
at the moment of action, under time pressure. The changes below therefore put the important rules
into **tools that refuse**:
- a freeze that refuses without a gate record for the exact revision;
- a harness that refuses a native run whose paths have no interpreter-coverage record;
- a fixture smoke built into the scripted acceptance.

Prose is kept only for what a tool cannot check.

## 4. Changes

### 4.1 The rule ([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), accepted)

Defects are found by interpreters. Native runs confirm that the interpreters match reality. A native
run is never the first execution of a path. Every defect found natively is treated as a defect in the
interpreters too: its fix lands with a class-level interpreter regression that fails on the pre-fix
source, and the finding records why the interpreters missed it.

### 4.2 Adversarial provider interpreters and the stuck-state invariant ([EP-173](../plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md))

**Seams.** The seams already exist at three levels:
- **The `Adapter` record** (`cli/nagarectl/src/Nagare/Inventory/Adapter.hs`), used by the driver
  model.
- **Provider operation records beneath each real adapter**:
  - `KubernetesAdapterOps`: observe to `KubernetesState`; a conditional mutate;
  - `PulumiAdapterOps`, `HelmAdapterOps`, `FoundationAdapterOps`/`GcloudRunner`;
  - `ObjectOps` for the store, `HostTransport`, and the data-fence transports.
- **The process level**: fake `kubectl`/`gcloud` executables, as in the F20 collection world.

**Provider worlds.** EP-173 adds one pure *provider world* per provider family. A world is a small
state model that implements the operation record faithfully. The Kubernetes world keeps, per object:
- UID, generation and observed generation, resourceVersion;
- spec digest, field managers, ownership annotations;
- readiness: Ready, NotReady or Failed.

Its conditional writes check `resourceVersion` and UID exactly as the API server does.

**Adversary.** An adversary schedules faults at named points:

| Fault | Meaning | Findings it reproduces |
|---|---|---|
| lost acknowledgement | the write lands, the call reports ambiguous | F38, many |
| refused before effect | known no effect | F12, F35 |
| landed unready / landed failed | controller never reports Ready, or reports Failed | F16, F54 |
| status churn | `resourceVersion` moves with no spec change | F30 |
| replaced | out-of-band delete and recreate at the same address, new UID, same annotations | F49, F51 |
| renamed | a reviewed address change, observed mid-transaction | F52 |
| foreign manager | another field manager owns a reviewed field | F37 |
| foreign object | an object appears at an address planned for creation | F35 |
| transient read failure | one observe or `gcloud` read fails, then succeeds | F50, F22 |
| store fault | a head or journal put is refused or lands unacknowledged | F38 |
| interruption | the process dies at any boundary, and resume starts from the store | F18 |

**Invariant model.** The model runs the real planner, review publisher, driver, recovery policy and
real Kubernetes adapter over the world, on the memory store with a faulting `ObjectOps`. It
enumerates a bounded scenario space:
- one or two application scopes, each a database plus a Service;
- review sequences of create, good update, bad update, rename, retire and restore;
- at most two faults per run, at every boundary.

After every stop it explores the supported exits (resume, each `inventory recover` action, a new
review) with persistent faults left in place. It asserts:

- **I1, exit.** Every reachable stopped state reaches an idle head through supported commands
  alone, with no out-of-band world write.
- **I2, nothing unreviewed is accepted.** Accepted revisions change only through a reviewed,
  completed transaction. A scope is converged only when every member matches its reviewed spec, its
  recorded incarnation, and Ready.
- **I3, incarnation.** Status never reports `converged` for a member whose UID differs from its
  recorded incarnation. Receipts from another incarnation never plan for ingestion. Retirement retains
  the accepted incarnation. A reviewed rename in progress is not reported `replaced-incarnation`.
- **I4, at most once.** No proved effect is repeated.
- **I5, store.** A store fault never wedges the store and never loses a published event.
- **I6, transient.** A single transient read never ends a run without a resume path.

**Acceptance: it would have caught them.** For each of F16, F30, F35, F37, F38, F49 and F50, a
documented mutation reverts the fix's guard, and the model fails within its budget. F54 is caught
against the pre-fix source. The model also reports the open F51 and F52. The bounded enumeration is
deterministic and runs in the ordinary suite. EP-173 also moves adapter-registry construction out of
`app/` into the library, so the model runs the production wiring rather than a test-local copy.

**Fidelity.** Native runs keep one job the interpreters cannot do: checking that the worlds match
reality. EP-173 adds fidelity fixtures. Real `kubectl`, `gcloud` and `pulumi` outputs recorded on cp3
or cloud are fed through the runtime parsers, and the test asserts the same states the world model
produces. Each of the nine L3 findings becomes a fidelity fixture. A native run that sees an
unmodelled response produces a new fixture and a world change, not only a fix.

### 4.3 The per-commit gate ([EP-174](../plans/174-gate-every-commit-before-any-native-run.md))

- **`just gate`** runs:
  - both Haskell suites, serially;
  - the style and architecture checks;
  - `nix flake check --all-systems`, with a builder-health proof: a salted derivation actually
    built on x86_64-linux, and the check log shows Linux checks built rather than skipped.

  It writes a gate record bound to the exact revision and tree hash.
- **A pre-push hook** runs the fast part (suites, style, architecture). The full gate runs per push
  batch and before any candidate.
- **No GitHub Actions** (operator decision, 2026-10-04). Everything runs locally. x86_64-linux runs
  through the remote Nix builder, and a missing builder fails the gate instead of being skipped.
- **`-Werror=incomplete-patterns`** and `-Werror=incomplete-uni-patterns` in the shared cabal stanza.
- **Freezing refuses** without a green gate record for the candidate revision.
- **A fixture-workload smoke** runs every fixture image a scenario uses, locally with its declared
  environment, and checks that it serves. Native drivers call it before any apply.

### 4.4 Gate order (cloud last, confirm-only)

1. **Per commit:** both suites, style, architecture, `-Werror` exhaustiveness. Seconds to minutes.
2. **Per push or candidate:** `nix flake check --all-systems` with builder health, run locally.
3. **Before any native run:**
   - the stuck-state invariant model and adversarial worlds pass;
   - the interpreter-coverage record names a model test for every native path;
   - fidelity fixtures pass;
   - fixture workloads smoke locally.
4. **C1/C2 on cp3**, through the scripted harness (EP-168), never session-written.
5. **C3 on cloud**, last. Its expected new information is world fidelity only.

[EP-170](../plans/170-size-the-release-gate-to-the-change.md)'s release gate adds step 3 as a
precondition for accepting native evidence.

### 4.5 Rules for findings and deferrals

- **A native finding is two findings.** One is the product defect. The other is the interpreter gap
  that let it reach a native run. The fix lands with a class-level interpreter regression that fails
  on the pre-fix source (a recorded mutation or parent-revision run). The finding states which world
  fault or invariant now covers it.
- **Closure requires class coverage.** An instance-only regression leaves a finding Verifying.
- **Only the operator defers.** Implementers and reviewers never propose deferral to save time. A
  deferral request shows the full current ledger and what each item blocks.
- **A "known limitation" recorded inside a closed finding is a deferral.** It goes on the ledger.
- **Stuck-state P1s are never deferred.** A reachable state with no reviewed exit is fixed before the
  next native run.

## 5. Deferral ledger (as of 2026-10-04)

| Item | Kind | What it leaves open | Covered by EP-173? |
|---|---|---|---|
| F40 remainder | deferred to MasterPlan 25 by operator | full-context teardown | partly (retire scenarios) |
| F48 | deferred to EP-168 port; procedural guard | evidence names an unchecked payload | no (harness) |
| F51 | deferred known limitation | retirement keeps a replacement's UID | yes (I3) |
| F52 | deferred known limitation | rename reads `replaced-incarnation` mid-transaction | yes (I3) |
| F35 | limit in closed finding | no admission-time absence check | yes (foreign object fault) |
| F37 | limit in closed finding | no planning-time refusal; `inventory plan` lacks the takeover opt-in | yes (foreign manager fault) |
| F49 | limit in closed finding | incarnation recording is fail-open; members without a record pass | yes (I3) |
| F38 | limit in closed finding | no native injected head failure | yes (store fault; native injection unnecessary) |
| F50 | limit in closed finding | `FoundationRuntime` observation reads still stop on one failure | yes (transient fault) |

Out of scope by plan, not by pressure: D4, the data-protection and production gates, MasterPlan 26.

## 6. Decisions the operator needs to make

**Resolved 2026-10-04.** The operator accepted all four recommendations below:
1. EP-169 is cancelled.
2. MasterPlan 23's remaining native work waits for EP-173 M1–M2.
3. F51 and F52 are un-deferred and fixed in MasterPlan 23.
4. ADR 25 is accepted, and `CLAUDE.md` links the pre-flight checklist.

Decisions are recorded in the MasterPlan 23 and 26 Decision Logs and in the F51/F52 register entries.

1. **EP-169 needs re-scoping.** The operator decided on 2026-10-04 that gating does not use GitHub
   Actions, so the gate is local (EP-174). [EP-169](../plans/169-run-the-local-acceptance-in-ci.md)
   ("run the local acceptance in CI") is built on GitHub Actions. Options:
   - cancel it, and treat EP-168's one-command run on a maintainer machine as the acceptance path;
   - re-scope it to another runner the operator accepts.

   Recommendation: cancel it. EP-168 plus EP-174 cover the need, and nothing in this retrospective
   depends on a hosted runner.
2. **Ordering.**
   - Recommended: MasterPlan 23's remaining native work waits for EP-173's first two milestones,
     covering phase 3b, the F54 native verification and any new candidate. Those milestones are the
     Kubernetes application world and the stuck-state invariant.
   - The F54 repair is then verified by the model before it goes native. This delays the release by
     the time EP-173 M1–M2 take. The alternative is a native run that discovers defects again.
3. **F51 and F52.** Recommended: un-defer both and fix them in MasterPlan 23, because EP-173's
   incarnation invariant will flag them and they are cheap at that layer.
4. **ADR 25 and the checklist.**
   - Accept [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md).
   - Approve a one-line link from `CLAUDE.md` to
     [the pre-flight checklist](../runbooks/before-a-native-run.md), so every session reads it. This
     retrospective does not edit `CLAUDE.md`.

## Appendix A. Every finding

Columns:
- **Found**:
  - SRC: source audit or in-memory probe;
  - REC: public CLI with recorders;
  - LOC: local native (cp3 or operator-root roundtrip);
  - CLD: cloud native;
  - FLK: `nix flake check`.
- **Cheapest** is the cheapest layer that could have found the finding.
- **Reg**: C class, P partial, I instance, – none in the suite.

| ID | Pri | Found | Cheapest | Class | Reg | What would have exposed it |
|---|---|---|---|---|---|---|
| F01 | P1 | SRC | L1 | identity | I | host fake whose second preflight sees a changed VM or closure |
| F02 | P1 | SRC | L1 | cost | I | ObjectOps fake counting GETs |
| F03 | P2 | SRC | L1 | cost | I | count journal batches across resume |
| F04 | P2 | SRC | L1 | cost | C | grow unrelated reviews, assert flat GET count |
| F05 | P1 | SRC | L1 (+L3) | transport | C | argv recorder; real loopback sshd for option precedence |
| F06 | P1 | SRC | L1 (+L5 latency) | cost | C | subprocess count recorder |
| F07 | P1 | SRC | L1 | stuck | I | command fakes: key matches, Tailscale fails |
| F08 | P2 | SRC | L1 | spec gap | P | replan with env cleared, other root, permuted inputs |
| F09 | P1 | SRC | L2 | stuck | P | admitted interrupted prune, assert an exit |
| F10 | P2 | SRC | L1 | cost | I | count provider calls for one-resource explain |
| F11 | Build | SRC | L0 | build | – | type checker |
| F12 | P1 | REC | L2 | stuck | P | two-op review, prerequisite ambiguous |
| F13 | P1 | REC | L0 | stuck | P | `-Werror=incomplete-patterns` |
| F14 | P1 | CLD | L3 | platform, stuck | I | local k3d bootstrap ordering |
| F15 | P1 | CLD | L5 | platform | I | real credential expiry and re-pull |
| F16 | P1 | CLD | L2 | stuck | C | Service that never becomes Ready |
| F17 | P1 | CLD | L1 | spec gap | I | zero-op retirement through the runtime with fakes |
| F18 | P1 | CLD | L2 | stuck | I | interrupt first bootstrap at each boundary |
| F19 | P1 | CLD | L1 | spec gap | I | rendered script with only declared env, strict gcloud shim |
| F20 | P1 | CLD | L3 | platform, stuck | C | real k3s GC plus Knative webhook |
| F21 | P1 | REC | L3 | transport | I | real http-client via local proxy |
| F22 | P1 | CLD | L1 | transient | I | first SELECT refused |
| F23 | P1 | SRC | L1 | version skew | C | old payload shell against new runtime |
| F24 | P1 | REC | L1 | spec gap | I | recorder: planning performs no mutation |
| F25 | P2 | LOC | L1 | spec gap | I | supported builder fields in profile fixture |
| F26 | P1 | CLD | L2 | stuck | – | remove-then-restore context model |
| F27 | P1 | CLD | L3 | transport | I | real OpenSSH remote shell |
| F28 | P1 | LOC | L1 | spec gap | – | cleanup over scope with adjacent member |
| F29 | P1 | LOC | L2 | stuck (fixture) | – | DomainConflict on create, exit invariant |
| F30 | P1 | LOC | L2 | stuck, churn | I | status-only resourceVersion bump |
| F31 | P1 | CLD | L1 | platform, spec | C | static cadence invariant vs documented cache floor |
| F32 | P1 | CLD | L3 | transport | C | real CRI sandbox listing |
| F33 | P1 | SRC | L1 | identity | I | Pulumi stack entry changes ID before `up` |
| F34 | P1 | LOC | L3 | platform | I | k3d: collect DomainMapping then new route |
| F35 | P1 | LOC | L2 | stuck | P | foreign object at a later op's address |
| F36 | P1 | SRC | L2 | stuck | I | scratch StatefulSet init fails |
| F37 | P1 | LOC | L2 | stuck | P | foreign field manager |
| F38 | P2 | CLD | L1 | lost-ack, store | C | ObjectOps head put fails once |
| F39 | P1 | CLD | L3 | transport | I | real `pulumi preview` on a file backend |
| F40 | P1 | CLD | L1 | spec gap, stuck | I | retire the full platform scope set in memory |
| F41 | P1 | LOC | L3 | platform | I | k3d node stop/start |
| F42 | P1 | LOC | L1 | evidence | C | replay real runner output through assembler |
| F43 | P1 | CLD | L1 | spec gap | I | every Pulumi flag has a context field |
| F44 | P1 | CLD | L0 | spec gap | C | totality: every executor has an observer |
| F45 | P1 | CLD | L1 | spec gap | P | dependency-permutation property; wiring testable from library |
| F46 | P1 | CLD | L2 | stuck | I | graph property: no Retain member after collectable |
| F47 | P2 | CLD | L3 | environment | – | clean-env Pulumi on file backend |
| F48 | P2 | CLD | L1 | evidence | – | assembler test with mixed-revision run |
| F49 | P1 | LOC | L1 | identity | C | observation with accepted annotations, new UID |
| F50 | P2 | CLD | L1 | transient | I | gcloud fails once |
| F51 | P2 | LOC | L1 | identity | – | F49 fake on a retire review |
| F52 | P2 | LOC | L2 | identity | – | status mid-transaction during reviewed rename |
| F53 | P1 | FLK | L0 | build | – | flake check per commit |
| F54 | P1 | CLD | L2 | stuck (fixture) | – | update lands, never Ready, exit invariant |
