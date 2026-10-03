# MP-23: validated Effectful restore pilot

Date: 2026-10-02. Baseline: `794064f0`. Parent: [MP-23](../../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md). Owners: EP-153 (shared boundary), EP-160 (restore), EP-156 (native agreement).

## Result and architectural implication

The bounded pilot succeeds. Six restore/recovery scenarios run in about two seconds without a cluster or cloud account. The actual rendered download command fails when its generation environment is removed, reproducing the class of F19 defect locally. This supports incremental external-effect interpreters as the next implementation direction. It does not establish that Effectful alone improves productivity or that every MP-23 architectural problem is solved: the testable boundary and retained production logic provide the benefit.

The ownership/inventory/review/journal foundation stays. Replace test substitution above the risky code with substitution below native rendering, parsing, preconditions and recovery. Keep model/provider agreement explicit. The next bounded application is F20 collection, where delete acceptance, parent absence, descendant deletion and finalizer completion must be distinguished.

## Implemented boundary

[The transport](../../../cli/nagarectl/src/Nagare/Inventory/KubernetesTransport.hs) defines a dynamic `Kubectl` effect with context, arguments and stdin, returning the existing exit/output/unknown result. The production interpreter retains the existing context and request-timeout flags and IOException handling. Existing callers continue selecting it. Tests select an interpreter by explicit injection; no production environment variable switches to simulation.

This is a small request program with no `IOE`, interpreted beneath the existing IO runtime. The complete planner/orchestrator has **not** been converted to an effect stack. Other transports, filesystem persistence, target selection and authorization are not newly effect-isolated. No public dry-run command is added.

[The fixture](../../../cli/nagarectl/test/Nagare/Test/Effectful/Fixture.hs) uses production database, manual backup, receipt-only and isolated restore compilers. It seeds synthetic accepted history with real canonical scopes/native bytes, an absent producer Job, a source StatefulSet/PVC and a neighboring ConfigMap. [The scenarios](../../../cli/nagarectl/test/InventoryEffectfulSpec.hs) use production composition, observations, planning, immutable review publication, apply/resume, filesystem store and Kubernetes runtime/adapters. A fresh test-binary process reloads the saved review and content-addressed source native inputs without rerendering them. Its source-registry loader is test support; this does not cover the entire public CLI source-selection path.

[The model](../../../cli/nagarectl/test/Nagare/Test/Effectful/Model.hs) persists provider objects separately from history. Create has before-write and after-write lost-ack faults; it retains an unready Job and refuses duplicate creation. Wait advances virtual time rather than sleeping. Unsupported request shapes fail. It is deliberately limited to this workflow, not a general Kubernetes simulator.

The actual rendered init-container shell command executes with its declared environment against a strict local `gcloud` fixture. That fixture requires exact generation-qualified URLs and output paths. Real local tools check the receipt/hash and decompress known SQL bytes. Missing generation variables and corrupt archive bytes must fail. Only then does the workload model mark the Job complete. Database loading itself is simulated.

## Validation

Run from the repository root in the existing development environment:

```bash
just test-inventory-effects
cabal build exe:nagarectl test:nagarectl-test --project-dir=cli/nagarectl
(cd cli/nagarectl && cabal test nagarectl-test --test-show-details=direct)
python3 scripts/test-manual-receipt-public.py --gcs
scripts/check-haskell-style.sh
python3 scripts/check-cli-architecture.py
nix eval --raw .#nagarectl.drvPath
```

Observed results:

| Check | Result |
| --- | --- |
| Lost acknowledgement after create | Saved-review recovery converges in another process; one Job total; replay does not recreate it. |
| Failure before create | No initial write; recovery creates once and waits for completion. |
| Readiness timeout | Records 300 virtual seconds without sleeping; resumes the original Job. |
| Changed source PVC UID | Recovery stays unresolved and the original transaction remains active. |
| Rendered download command | Valid receipt/archive succeeds; omitted generations and corrupt bytes fail. |
| Unsupported effect | Throws rather than returning synthetic success. |
| Focused suite | All 6 pass: initial run 1.78 s; final stricter request model 2.18 s while other validation ran. |
| Full test binary | All 1,023 pass in 115.69 s, run from `cli/nagarectl` after building. |
| CLI build | Pass. |
| Existing public GCS receipt fixture | Pass: review/apply, conditional Job collection, Job-free restore, foreign producer and wrong-version refusals, through real subprocess execution with local provider shims. |
| Haskell structure/style and CLI architecture | Pass. |
| Nix dependency evaluation | Pass; full Nix package build not performed. |

Compilation and first-time dependency installation took minutes and are excluded from the scenario timings. The focused recipe includes Cabal build checking; its printed test duration is scenario time, not cold-build wall time. The full suite was initially launched from the wrong directory and could not locate a fixture; rerunning from its required package directory produced the passing result above.

The broad `scripts/check-haskell-architecture.py` gate remains red on two existing baseline modules: `AppDeploySpec.hs` has 2,496 lines against 2,491, and `InventoryKubernetesSpec.hs` has 4,235 against 3,851. These counts were verified against baseline HEAD. This pilot changes neither file nor the limits. Do not report the whole repository's gates green.

The dependency source was located through mori://effectful/effectful/packages/effectful-core and read locally. Version 2.7.1.2 was checked against Hackage and upstream tag `effectful-core-2.7.1.2` (commit `1c91cf4987ee8249fb54e2f50ad3e69fb56df162`). Cabal bounds are `>=2.7.1.2 && <2.8`. The pinned Nix package index lacks this release, so hash-pinned Hackage tarballs supply Effectful and its required strict-mutable-base 2.0.0.0; no broad bound relaxation was added.

## Proof boundary and next work

This validates a useful local iteration method. It does not prove real PostgreSQL execution, other engines, new-PVC restore, real GCS IAM/version semantics, image utilities, Kubernetes admission/defaulting, controller/finalizer behavior, concurrency races, target guards, lease takeover or all public command routing. Existing native evidence remains credited separately. No cloud mutation, installation, finalizer patch or cascade exception was executed.

EP-153 next adds the real collection adapter with finalizer/descendant state and interrupted recovery to this style of test. Do not turn that into a full-provider emulator or framework migration. EP-160 extends generated-command and recovery scenarios when touching the remaining data paths. EP-156 requires affected real-interpreter contract checks and bounded native proof when a component changes. The existing F20 transaction and all native/release gates remain open.
