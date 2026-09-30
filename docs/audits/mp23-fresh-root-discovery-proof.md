# MP-23 fresh-root GCS discovery investigation — 2026-09-29

The separate EP-156 discovery defect is proved on installed candidate
`2d6b57c02179`, at source HEAD `71fce0a4`. No production repair was made in this
investigation. The cluster timeout repair `2d6b57c0` and its installed evidence
`71fce0a4` remain separate accepted planning checkpoints. Neither this report nor
the timeout proof accepts cluster convergence or EP-156 M1/M2.

## Native counterexample

The retained fixture is `ep150-preview` in `tan-ng-labs`, with Compute Engine
NixOS/k3s host `nagare-ep150` in `us-west1-a`. A new operator root copied only the
context profile and host inputs. It had separate XDG config, state and cache
directories, no inventory, no migration marker, and no delivery-key environment.
Commands ran outside the checkout with the installed executable. The runner
retained only HOME, USER and PATH before setting exact task environment values.

| Command | Budget | Result | Seconds |
| --- | --- | --- | ---: |
| `inventory store status --json` before bootstrap | 60 s | Correctly bound existing GCS head | 3.434 |
| `platform bootstrap plan --out ...` | 120 s | Two `unverified-owner` refusals | 38.228 |
| `inventory store status --json` after bootstrap | 60 s | Identical GCS head | 3.327 |

Both status calls returned generation 113 and digest
`f536c6d2f48c5d5bde01460a072f15e2d328d2a49433a1f0e20c44baf59416fe`,
bound to `ep150-preview` / `tan-ng-labs` at
`gs://tan-ng-labs-ep150-pmkjjpp-state/inventory`, with no active transaction,
executor claim, data fence or migration tombstone. The first status created
neither local state nor cache. Bootstrap initialized a separate empty local head
(generation 1, sequence 0, no accepted scopes) and refused the already stamped
state bucket and Pulumi stack. It saved no review. The owner refusal is correct;
removing it would erase the protection that exposed the wrong history selection.

An exact read of the private shared `head.json` in 3.055 seconds matched the
above digest and showed sequence 65 and six accepted scopes: cloud foundation,
cloud, host-image-build, host-image, host and kubeconfig. This rules out a merely
initialized but ownership-empty GCS store as the explanation.

The hashes of the workstation's global gcloud active-config file and global
kubeconfig were identical before and after the native plan/status experiment.
No global selection command, cluster apply, marker copy, journal copy or provider
mutation was issued. The deadlines apply to planning/read-only commands; they
are not instructions to kill ambiguous mutation processes.

Private evidence is retained under
`/tmp/nagare-mp23-fresh-root-discovery-20260929` and
`/tmp/nagare-mp23-discovery-native-reads-v2-20260929`. The native runners are
`/tmp/mp23-fresh-root-discovery-probe.py` and
`/tmp/mp23-native-discovery-read-probe.py`; both refuse an occupied evidence root.
The earlier `/tmp/mp23-second-root-plan.py` reproduction remains preserved.
[Redacted results](mp23-native-bootstrap-results-2026-09-29/fresh-root-discovery.json)
contain the retained assertions and results without credentials, native reviews
or full history.

The recording-provider probes are reproducible from the checkout with the
retained installed binary (or another explicitly identified candidate):

```bash
python3 docs/audits/mp23-reproductions/probe-fresh-root-discovery.py \
  --binary /absolute/path/to/nagarectl \
  --platform-root "$PWD" --out /tmp/mp23-discovery-new-evidence-root
cd cli/nagarectl
cabal test nagarectl-test --test-options='--pattern="/inventory object operations/"'
cabal test nagarectl-test --test-options='--pattern="/Gogol inventory transport/"'
```

The probe saves outcomes, not a success assertion for repaired behavior. Its mock
legacy transport deliberately loses the distinction between a failed missing-
bucket describe and a failed unavailable-bucket describe; implementing a typed
discovery boundary requires extending that fixture or using the SDK loopback
fixture for definite provider absence. The native experiment does not require
that fixture or use its provider responses.

## Why bootstrap selects the wrong history

`cli/nagarectl/app/Main.hs` has two independent selectors.
`cloudFoundationPending` returns true when the local store does not exist.
`foundationStageTarget` then returns the local foundation target for the same
condition. Neither opens the selected remote store. If a local head exists,
both use the presence of a migration tombstone as their routing signal; the
latter does not even check the tombstone destination. In contrast,
`Nagare.Inventory.Command.openTargetStoreReadOnly` directly opens the selected
GCS store with initialization disabled. This is why the same fresh root can
read authoritative history through status and ignore it through bootstrap.

`Command.openTargetStore` already refuses a nonmigrated, nonempty local head
when selecting GCS, checks an exact migration destination, and refuses a missing
remote head after migration. A repair must preserve these protections. Discovery
must not call `loadTargetSnapshot` as its initial probe: that calls the writable
opener and `initializeStore`, so it can manufacture a new head rather than prove
which authority already exists.

## Absence, foreign state and unavailable state

Installed CLI fault probes used a recording gcloud substitute and
`NAGARE_INVENTORY_GCS_TRANSPORT=gcloud`, separate roots for every command, and
30-second process deadlines. Pulumi and kubectl substitutes refused all calls;
there was no real provider access or apply. These are public-command boundary
experiments, not native cloud absence or foreign-bucket acceptance evidence.
The source diagnostic executable still contained old timeout trace prints;
the results below were rerun with the clean installed executable instead.

| Controlled state | Direct store status | Fresh bootstrap plan |
| --- | --- | --- |
| Bucket absent from project list; its describe fails | Refuses unknown owner, 0.601 s | Two-create review, 1.744 s |
| Visible foreign bucket, owner 99999 vs selected project 12345, omitted from selected project list | Refuses foreign owner, 0.183 s | Two-create review, 1.181 s |
| Bucket metadata unavailable, omitted from selected project list | Refuses unknown owner, 0.181 s | Two-create review, 1.083 s |
| Project bucket list unavailable | Refuses unknown owner, 0.177 s | `observation-unavailable`, 1.140 s |

All three successful mock foundation plans made **zero bucket-describe and zero
remote-object calls**. `Adapters/FoundationRuntime.inspectBucket` and the
backend readiness portion of `inspectStack` interpret omission from a successful
selected-project list as absence. That list cannot establish that a global name
is free. GCS names occupy one namespace shared by all users, as documented by
[Google](https://docs.cloud.google.com/storage/docs/buckets#bucket_name_considerations)
and required by [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md).
The experiment proves incorrect creation-review intent; it does not prove a
foreign resource can be mutated through the later effect guards.

The current remote ownership helper safely refuses both absent and unreadable
bucket descriptions, but collapses both into the same text-based
`StoreConditionFailed` result. A generic fallback on that error would conflate
missing buckets, permissions, authentication, connectivity and foreign ownership.
Successful bucket metadata with a matching project number proves provider-project
ownership, not Nagare accepted ownership.

Additional installed read-only probes establish why a successful opener or a
particular error string is not a complete discovery result:

| Controlled state | Result |
| --- | --- |
| Owned bucket; failed format metadata read followed by successful empty object list | `inventory object prefix is not initialized`, 0.232 s |
| Owned bucket; failed format metadata read and failed list | `StoreIoError "object listing failed"`, 0.281 s |
| Owned bucket; format bound to another context | Binding/format refusal, 0.283 s |
| Matching format; canonical head bound to another context | Status succeeds and displays the foreign binding, 1.069 s |
| Matching format; missing head | `inventory history is not initialized`, 0.337 s |
| Missing format; head still present | `inventory object prefix is not initialized`, 0.224 s |

`Store.openObjectStore` validates format bytes but does not validate a head.
`readHead` decodes it; `initializeStore` checks its binding. Status displays the
decoded binding without comparing it with the requested context. Thus discovery
must explicitly validate **both** format and head, and must treat a missing format
with other remaining objects as incomplete history, not an empty prefix.

A real read-only status of a separate prefix in the owned fixture bucket returned
the expected uninitialized-prefix refusal in 2.873 seconds and created neither
state nor cache. The final probe changed only its isolated saved profile to select
`gs://tan-ng-labs-ep150-pmkjjpp-state/mp23-discovery-empty-prefix-20260929`.
An earlier environment-only attempt still selected the persisted store URL; that
attempt was discarded as an empty-prefix test. No remote object was created.

The default SDK transport already preserves useful object-read semantics:
`Store/Gogol.hs` reports `ObjectAbsent` only after a 404 and a successful listing
that excludes the exact object; denial, malformed/incomplete responses and failed
listing remain `GetUnknown`. Its request and gcloud credential/ownership timeouts
are 20 and 15 seconds respectively. Those per-call limits do not supply a total
discovery deadline or a bound on pagination. Existing tests passed: 38 inventory
object-operation tests and 17 Gogol transport tests, including absence versus
denial, foreign format, uninitialized read-only open, active writer, fences and
migration recovery. The gated real-bucket test was not enabled; the native reads
above supply the actual cloud evidence for this investigation.

## Effective repair plan

First add one read-only discovery service in
`cli/nagarectl/src/Nagare/Inventory/Command.hs` and
`cli/nagarectl/src/Nagare/Inventory/Store/Remote.hs`, supported by the existing
SDK in `Store/Gogol.hs`. Its input is the exact selected context/project and
resolved inventory URL. Its result distinguishes validated existing history,
proved missing bucket, proved empty prefix in an owned bucket, foreign binding or
owner, incomplete/migrated history, and unavailable state. Do not derive those
variants from rendered `StoreError` strings. Capture selected authentication once;
use structured global bucket metadata and numeric owner comparison. The pinned
SDK exposes bucket metadata requests; source was located with Mori at
`mori://brendanhay/gogol/repos/gogol`. No dependency upgrade or new bound workaround
is proposed.

Validate URL, stored/active/ambient project agreement, bucket ownership, canonical
format, supported canonical head, exact head binding and migration direction.
Retain active transaction, claim and fence state so existing admission/recovery
guards see it. A valid prefix with no head is incomplete, not a new foundation.
If format is missing, list the exact prefix with a small result cap: one remaining
object is enough to refuse, rather than loading an archive. Only a definite
structured bucket-not-found response after successful identity/project validation
can enter the missing-bucket branch. A project-list miss or failed describe is
insufficient. Errors, denial, timeout and malformed replies remain unavailable.
Conditional creation and immediate owner checks must still handle subsequent
name races.

Apply a proposed **60-second total discovery deadline**, preserving shorter
individual call limits and bounding any negative-proof pagination. A deadline
breach returns unavailable and makes no state, format or provider write. Present
the refused prerequisite promptly. Discovery of established history needs only
bucket/format/head authority, not enumeration of every historical review or
provider resource; ordinary validated history loading follows selection.

Next replace the two selectors in `Main.hs` with one selection result carried
through pending checks and foundation planning. For an empty local root and valid
remote history, use GCS regardless of the absence of a local tombstone. Load the
accepted scopes and compute actual foundation readiness from that authority.
Choose local first-bootstrap history only on a proved fresh case. When the selected
remote prefix is empty, existing bucket/stack stamps without accepted history
still require an ownership refusal; an empty prefix is not permission to rebuild
lost authority. When local history is nonempty, retain explicit migration,
exact destination and conflict
rules; never silently ignore it in favor of remote history. Retain the existing
verified migration algorithm for a converged local foundation with a compatible
empty destination. A migrated source whose destination is missing must refuse.
Recheck store authority for foundation apply; a changed destination or newly
appearing remote history must not cause a saved local review to run through a
different authority. Do not acquire or steal a writer merely to discover it.

Also repair the bucket observations in
`cli/nagarectl/src/Nagare/Inventory/Adapters/FoundationRuntime.hs` so global-name
absence uses the same structured classifier; omission from a project list must
not bypass a foreign/unavailable result. Keep owner stamps, accepted-history
requirements and effect-time ownership checks intact.

Before promising complete fresh-root bootstrap, address the next portability
boundary. Source inspection of `buildKubeconfigStageCandidate` shows a raw
accepted-scope equality check. The accepted scope stores the first operator's
absolute prepared-source and destination paths; a freshly compiled scope uses the
new XDG roots. Even identical credential bytes therefore produce different
scopes. The retained accepted review confirms those paths. This is a **risk
established by source inspection**, not a native refusal observed after fixing discovery.
Add a representative two-root test immediately after selection is repaired.
Provide an explicit context-local credential materialization/transition route
bound to the accepted context, host and credential content, with a current private
execution envelope. Preserve original immutable reviews and refusal of changed
host/content; do not relocate old envelopes or copy authority markers. This follows
[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md).

Acceptance must cover genuinely fresh foundation, existing bound history with no
local state/cache, nonmigrated local conflicts, exact/wrong migration destinations,
missing migrated destination, foreign bucket/format/head, missing format with
remaining objects, missing head, unsupported schema, denied/failed/slow reads,
partial listings, active writer/fence and a remote race before apply. Assert zero
discovery writes and no unrelated cluster/provider setup on refusal. Use the actual
public bootstrap plan with the default SDK and the explicit legacy transport,
then one clean installed native second-root run from another never-used root.
Require that it preserves all six accepted scopes and does not propose bucket,
stack, image or host creation. Its next credential review or explicit validated
credential-materialization step must concern only that operator root. Continue to
use the established 120-second credential-stage planning bound; diagnose any
breach before another native retry. If the credential already exists and the next
stage is cluster planning, use its separate established 360-second bound and
inspect the review without applying it. Verify the shared head and global contexts
afterward. These are repairs to EP-156's existing two-root acceptance, not a new
milestone or authorization for cluster apply.
