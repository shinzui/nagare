# MP-23 prerelease fixture disposition — 2026-10-02

The operator confirmed that Nagare has no users, its existing contexts are
disposable development fixtures, and completing MP-23 is blocking production
provisioning. Failed prerelease transactions are not a compatibility promise.
This decision supersedes instructions to keep the old F15 transaction and
candidate on the implementation, safe-use or release critical path.

## Disposition

`f15-preview` is retired from acceptance and quarantined for eventual scoped
teardown. This is an administrative fixture disposition, not an inventory
terminal event: its transaction remains unresolved in its original history.
Do not reset that history, manufacture a tombstone, resume the old deletion,
or build an old-review migration/exception mechanism to finish this rehearsal.
Neither successful recovery nor physical teardown of this retired fixture is
an MP-23 completion prerequisite. It must not become the production context.

The last recorded state is generation 752, sequence 673, digest
`28b5d60e438d80d7d8e9e4cf3b1156f4ed64637d772d73513e8baff864e7dc48`, transaction
`tx-b6886179d40d4618442997221cc02ca986f142ccdeef1661448cfca627765472`, operator
`4c4b667e867b0ed1a732fe9a0839f4a09bfa0f5c` and payload
`nagare-0.4.0-d73c1dc4d379`. These are recorded observations, not a new live check.
No provider mutation, complete private-history export or physical cleanup is
claimed by this disposition.

Retain the original private roots and checked-in diagnostic records:

- [Failure and accepted restore evidence](mp23-native-bootstrap-results-2026-10-02/f15-receipt-only-restore-and-web-cleanup.json).
- [Unexecuted exception proposal](mp23-native-bootstrap-results-2026-10-02/f15-knative-collection-exception-review.json), now historical and withdrawn from the execution queue.
- [Earlier restore failure](mp23-native-bootstrap-results-2026-10-02/f15-receipt-collection-and-download-failure.json).
- [Corrected collection and recovery proof](mp23-reviewed-controller-collection-proof.md), using a separate disposable target.

EP-156 owns non-blocking teardown debt for the retired fixture, including the
terminating Service, its descendants and failed restore Job. Before teardown,
inventory actual fixture-owned resources and shared dependencies, preserve the
private diagnostic history, and bind cleanup to exact target identities. Do not
delete a shared VM, namespace, bucket or project based on the fixture name.
Disposal is not evidence of successful managed collection. No new teardown
framework is required, and continued live preservation is not an acceptance gate.

## Acceptance after this decision

EP-153/156 retain the corrected reviewed controller-collection contract and its
interruption, fresh-process resume, no-duplicate-effect and data-preservation
tests. F20 requires independent verification of that behavior and the remaining
native same-scope retained-data assertion; recovering the retired F15 transaction
is removed from its required verification. Other supported assertions remain.

Use the existing idle `ep150-preview` fixture where its recorded inputs are
applicable; recheck its binding and state before native work. Installed
`8a820ce8` is the latest bounded controller-proof candidate, not a claim that all
release gates passed on it. Group remaining fixes into a candidate, preserve
applicable evidence and run only missing or invalidated assertions. Final
local/cloud/native-system evidence must bind the final release candidate.

The safe-use runbook check may use the selected eligible context rather than
the retired `f15-preview`. Its results still require recording. The prior stop
before step 5 is superseded: implementation of remaining supported work and
release verification continues while the safe-use review is pending. Production
use still requires its applicable acceptance; no release or production deployment
is claimed or authorized merely by changing this plan.

Do not extend backward compatibility to every development review, journal format
or failed fixture. Preserve existing regression coverage and production recovery
semantics. New refactoring, compatibility mechanisms or fixture repair must name
the supported acceptance assertion they unblock; preserving an obsolete
prerelease transaction is not such an assertion.

## Fresh credential diagnostic fixture, 2026-10-02

The independently bootstrapped `mp23-host-acceptance` fixture on payload
`nagare-0.4.0-3905012e36d4-813556791f39f601` exposed F27 at the real SSH
credential-streaming boundary. Its original active transaction
`tx-39831e0147ad6db0065437c89c3815bafecd18056101bbedd51c4e92369f5257`,
head generation 44 / sequence 29, VM identity `4759788940635795681`, private
history and payload remain preserved as diagnostic evidence. A read-only check
confirms the key is missing and the enrollment input was not delivered.

Apply the same disposable development-fixture decision: do not patch that
accepted payload or add an old-transaction transport override. The corrected
immutable candidate uses the new isolated `mp23-host-fixed` fixture under the
existing technical verification authorization. F27 still requires successful
corrected native acceptance; replacing this diagnostic fixture does not close it.
No teardown or terminal transaction event is claimed.
