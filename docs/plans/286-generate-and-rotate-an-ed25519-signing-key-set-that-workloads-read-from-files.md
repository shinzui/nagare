---
id: 286
slug: generate-and-rotate-an-ed25519-signing-key-set-that-workloads-read-from-files
title: "Generate and rotate an Ed25519 signing key set that workloads read from files"
kind: exec-plan
created_at: 2026-11-25T16:08:21Z
intention: "intention_01m89q6asjedws62wy3n95r4e7"
master_plan: "docs/masterplans/39-provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-25T16:08:21Z
---

# Generate and rotate an Ed25519 signing key set that workloads read from files

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).

This plan implements part of IR-55,
[`docs/improvement-requests/provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md`](../improvement-requests/provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md),
requested by `mori://shinzui/hanmoto` (specification `mori://shinzui/hanmoto/docs/initial-spec`,
sections 5, 6 and 9). It is a child of [MasterPlan 39](../masterplans/39-provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md), which holds the order of the four
child plans and the artifacts they share.

Prerequisite: milestone M1 of [283-declare-an-app-object-bucket-with-per-workload-access-on-the-local-object-store.md](283-declare-an-app-object-bucket-with-per-workload-access-on-the-local-object-store.md) is accepted. It provides `PlatformMount`
(`cli/nagare-dsl/src/Nagare/Dsl/Mounts.hs`: ConfigMap, Secret and token sources mounted read-only
into a Knative Service, worker or task by the inventory compilers) and `reviewEffects` on
`ReviewDocument`. Nothing else from that plan is needed.


## Purpose / Big Picture

A service that signs short-lived tokens needs keys that are generated for it and replaced on a
schedule, without a deploy and without the signer and the verifier ever disagreeing. Nagare's
application secrets today are values an operator types in, delivered as environment variables that
change only when a pod restarts.

After this plan an application declares an Ed25519 key set with a rotation period and an overlap.
The platform generates the keys and rotates them. A signing workload reads the private keys from a
file and a verifying workload reads only public keys; both files change in place.

```bash
nagarectl keyset status view-grants
```

```text
view-grants  period 24h  overlap 2h
  next      k4  published 2026-12-01T00:00Z
  active    k3  since     2026-12-01T00:00Z
  previous  k2  until     2026-12-01T02:00Z
rotations: k3 2026-12-01T00:00Z, k2 2026-11-30T00:00Z, k1 2026-11-29T00:00Z
```


## Progress

- [ ] M1. The rotation step is a pure function with property tests showing that a signer's key is
  always known to every verifier and that the overlap is honoured. Evidence: `nagare-core` tests.
  - 2026-11-25: done. `rotateStep` in `cli/nagare-core/src/Nagare/KeySet.hs` withdraws `previous`
    once its overlap has passed, fills an empty set with `active` and `next`, and promotes `next`
    once `active` has served a period, `next` has been published five minutes and `previous` is
    gone; it takes fresh keys as an argument and uses at most two. The public file is a JWK Set of
    RFC 8037 keys with status, times, policy, serial and a 20-entry history; the private file adds
    `d` and alone decodes to the state. `RotationPolicy` and `mkRotationPolicy` are in
    `cli/nagare-dsl/src/Nagare/Dsl/KeySet.hs`. nagare-core has no test suite, so the tests are
    nagarectl's `key set rotation` (8: two examples, the public file, and five QuickCheck
    properties over generated schedules; the withdrawal property requires 40% coverage and gets
    about two thirds), with `tasty-quickcheck` added to that suite; `just gate-commit` green.
- [ ] M2. A `nagare-keyset` executable applies the step to a ConfigMap and a Secret in a cluster
  and survives conflicts and a crash between its two writes. Evidence: tests against the model
  API server.
- [ ] M3. `nagarectl keyset plan` produces a reviewed standalone scope; the keys exist before any
  consumer starts; a rotation is not drift; a `Sign` workload mounts private and public keys and a
  `Verify` workload only public keys. Evidence: `nagare-dsl` and interpreter tests.
- [ ] M4. On a local context with a ten-minute period, a signer and a verifier restarted during a
  rotation still agree, a token signed just before a rotation verifies during the overlap and is
  refused after it, and `keyset status` shows the rotation. Evidence: transcript here (IR-55 AC-4).
- [ ] M5. `nagarectl keyset retire` is a review that says the private keys are destroyed and
  existing signatures stop verifying; it is refused while a workload binds the key set. User
  documentation and an ADR exist. Evidence: reviewed-change tests (IR-55 AC-5, key set).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: A key set has three slots: `next`, `active` and `previous`. A rotation promotes `next`
  to `active` and `active` to `previous`, and generates a new `next`. Verifiers accept all three;
  signers use `active`.
  Rationale: Publishing a key a whole period before it signs means no verifier can meet a
  signature from a key it has not seen, whatever order pods restart in or files refresh.
  Date: 2026-11-25

- Decision: Keys are delivered as mounted files: public keys in a ConfigMap, private keys in a
  Secret.
  Rationale: An environment variable is fixed at pod start, so each rotation would need restarts
  in the right order. The kubelet refreshes a mounted file within about a minute. Splitting public
  from private lets a verifier hold no signing key (ADR 38).
  Date: 2026-11-25

- Decision: Rotation runs in a platform-authored CronJob in the key set's namespace, whose
  ServiceAccount may read and update only that key set's two objects.
  Rationale: Host timers (the forge-credential pattern, `nixos/hosts/nagare-01/forge-credentials.nix`)
  do not exist on a local context, and the lifecycle worker has no write authority.
  Date: 2026-11-25

- Decision: A rotation is recorded in the public ConfigMap's bounded history and shown by
  `nagarectl keyset status`. No lifecycle event type is added.
  Rationale: The record lives with the keys and needs no other component enabled. An event source
  can read the same history later.
  Date: 2026-11-25

- Decision: Key sets are not escrowed or backed up. A rebuilt cluster generates new keys.
  Rationale: The keys sign short-lived tokens; after a rebuild every outstanding token fails once
  and is reissued. A key set is not for long-lived signatures, and the documentation says so.
  Date: 2026-11-25

- Decision: A key set is a standalone scope, not a field of `Application`.
  Rationale: An application redeploy or retirement must not regenerate or destroy keys by
  accident; retirement is its own review.
  Date: 2026-11-25

- Decision: No command forces an immediate rotation in this plan.
  Rationale: Not requested by IR-55. Retiring and recreating the key set replaces all keys.
  Date: 2026-11-25


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

Nagare runs applications on one k3s node: a GCE VM running NixOS on a cloud context, or a k3d cluster
on a local context (`mode=local`). An application is a typed Haskell program, `nagare/Config.hs`,
that prints JSON documents. `nagarectl` loads them, compiles them into reviewed inventory scopes,
and applies a saved review with `nagarectl inventory apply DIR --yes`.

Terms used below:

- A scope is a set of resources with one owner and its own revision history
  (`cli/nagare-dsl/src/Nagare/Resource/Types.hs`: `ScopeKind = Platform | Application | Standalone
  | Publication`). A standalone scope holds one data service, such as an app database
  (`cli/nagare-core/src/Nagare/Inventory/AppDatabase.hs`, `compileStandaloneAppDatabase`).
- A managed resource is `ManagedResource` in
  `cli/nagare-dsl/src/Nagare/Resource/Inventory/Types.hs`: an identity, an owner scope, an executor
  (`KubernetesExecutor`, `PulumiExecutor` and others), a provider address, a lifecycle policy
  (`Retain | DeleteWhenUnreferenced | Protect`) and a data policy (`Stateless | Durable`).
- A review is the saved plan, `review.json` (`ReviewDocument` in
  `cli/nagare-core/src/Nagare/Inventory/Plan/Types.hs`). Its `--contract 1` projection is
  `SavedReview` in `cli/nagare-contract/src/Nagare/Contract/V1.hs`.
- Retirement removes a resource from the desired state under an explicit decision
  (`ApproveRetirement`). Removing a member without one refuses with `retirement-required`
  (`cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs`). Retirement deletes nothing at the
  provider; deletion is a separate `inventory collect` review that refuses durable data.
- A credential template is a reviewed Secret with no data. The adapter fills it with generated
  values at creation and afterwards compares only its key set
  (`cli/nagarectl/src/Nagare/Inventory/Adapters/CredentialTemplate.hs`). A `Delegation`
  (`cli/nagare-dsl/src/Nagare/Resource/Policy.hs`) names another writer allowed to change fields.
- The interpreter tests run the real planner, executor and adapters against an in-memory world
  (`cli/nagarectl/test/Nagare/Test/World/`). New `*Spec` modules are registered in
  `cli/nagarectl/test/Nagare/Test/Suite.hs`.

The application model (`cli/nagare-dsl/src/Nagare/Dsl/Application.hs`) has one web workload,
`service :: Maybe Deployment` (a Knative Service, `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`), plus
`workers :: [Worker]` (plain Deployments, `cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`) and
`tasks :: [Task]` (CronJobs, `cli/nagare-dsl/src/Nagare/Dsl/Task.hs`). Workloads are named by their
`ServiceName`. In Hanmoto's shape the API is the `service` and the gateway is a worker.

Secrets today. Application secrets are operator-supplied values in one Secret per application
(`cli/nagarectl/src/Nagare/Inventory/Environment.hs`), read by workloads as environment variables;
a change reaches a pod only when it restarts. Generated credentials exist only for the platform
and databases, as credential templates filled with `openssl rand`; an update to one is refused
("generated credential updates require a dedicated data-preserving operation",
`cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`). No code generates an Ed25519
key. The one two-key overlap in the tree is the webhook signing key
(`cli/nagare-core/src/Nagare/Events/Webhook/Subscription.hs`).

Scheduled work today. Tasks are CronJobs (`cli/nagare-dsl/src/Nagare/Dsl/Task/Render.hs`). The
platform's own in-cluster programs are built from `cli/nagare-api-server`
(`nagare-api-server.cabal`; the lifecycle worker `nagare-events` is one executable) and their
image is resolved in `cli/nagarectl/src/Nagare/Inventory/Components/LifecycleEvents.hs`. Updates
reach the cluster by server-side apply with field manager `nagare-inventory`
(`cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`); a field written by another
manager is reported as a foreign writer unless the resource declares a `Delegation`.

Relevant ADRs:

- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md):
  generated values are data-free templates; a delegated controller has explicit field authority;
  one owner per resource.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): the
  rotation logic is proven by M1 and M2 before M4's run.
- [ADR 36](../adr/0036-application-pods-hold-no-kubernetes-api-token-unless-they-name-an-account.md):
  application pods hold no API token. The rotator is a platform pod with its own narrow account;
  consumers still hold none.
- [ADR 38](../adr/0038-a-workload-inherits-its-app-s-managed-store-unless-it-opts-out.md): a
  workload gets only the Secrets it is entitled to; only a `Sign` binding references the private
  Secret.

No ADR covers generated or rotated application secrets; M5 adds one.

Module line caps (`scripts/check-haskell-architecture.py`,
`scripts/haskell-size-allowances.json`) will force new modules; create them up front. A new CLI
command is registered in `scripts/audit-managed-commands.py` and
`docs/architecture/managed-resource-coverage.md`. Changes to the planner, executor or adapters need
`just mutation-check REV BASE` before landing.


## Plan of Work

### M1. The rotation step

Add `cli/nagare-core/src/Nagare/KeySet.hs`. The state is the three slots, each key with an ID, its
public and private parts and three timestamps (published, activated, superseded), plus a history
of the last 20 promotions. `rotateStep now policy state` returns the new state and what happened:

- an empty state gets an `active` key and a `next` key at once;
- when `now` is at least one period after `active` was activated, and `next` has been published
  for at least five minutes, promote: `next` becomes `active`, `active` becomes `previous` with
  its superseded time, a new `next` is generated, and the history gains an entry;
- when `previous` has been superseded for at least the overlap, drop it;
- otherwise nothing changes.

Key generation is passed in as an argument so the function is pure. Encodings: the public file is
a JWK Set whose keys are RFC 8037 keys (`"kty":"OKP"`, `"crv":"Ed25519"`, `x`, `kid`) with
`status` and the timestamps, plus the policy and history; the private file is the same set with
`d` on each key. Decoding the private file alone must reproduce the whole state.

Property tests over arbitrary schedules of steps and clock advances: the `active` key of any state
is among the keys of the state one step earlier and one step later (so a verifier with a file one
step stale or ahead still knows a signer's key); a key leaves the set no sooner than the overlap
after it stopped being `active`; a step repeated at the same instant changes nothing; the history
gains exactly one entry per promotion; encode then decode is the identity.

### M2. The rotator

Add an executable `nagare-keyset` to `cli/nagare-api-server`. Given a namespace and a key-set
name it reads the Secret `nagare-keyset-<name>` and the ConfigMap `nagare-keyset-<name>-public`
with its in-cluster ServiceAccount token, decodes the state from the Secret (empty when the Secret
has no data), runs `rotateStep` with `crypton`'s Ed25519 generation, and when the state changed
replaces the ConfigMap first and then the Secret, each with a resourceVersion precondition. It
reads the policy from the ConfigMap's reviewed part. On a conflict it exits non-zero and the next
run retries. Writing the public file first matters: a crash between the writes leaves verifiers
knowing a key no signer has, which is harmless, and the next run rebuilds the public file from the
Secret.

Tests against the model API server (`cli/nagarectl/test/Nagare/Test/World/ApiServer.hs`) or an
equivalent in-memory client: first run on empty objects; a normal promotion; a conflict on each
write; a crash after the first write followed by a clean run; a ConfigMap edited by hand is
restored from the Secret.

### M3. The key-set scope and bindings

Types. Add `cli/nagare-dsl/src/Nagare/Dsl/KeySet.hs`, its loader, and `emitKeySets` in `Config.hs`
beside `emitAppDatabases`. Add `keySets :: [KeySetBinding]` to `Deployment`, `Worker` and `Task`.
Adding a strict field means migrating every literal of that record in the libraries,
tests, `cluster/examples/` and `fixtures/inventory-release/`. The new JSON key is omitted when
empty so no accepted config digest moves, as `managedEnv` did; a regression fixture proves a
pre-change Application encodes to the same bytes. The other child plans of MasterPlan 39 add
fields to the same records, so rebase on the landed tree before migrating. `mkRotationPolicy` refuses a period under ten minutes, an overlap over the period, and
an overlap under five minutes.

Scope. Add `cli/nagare-dsl/src/Nagare/Resource/KeySet.hs` and
`cli/nagare-core/src/Nagare/Inventory/KeySet.hs` (`compileStandaloneKeySet`, scope
`keyset-<logicalKey or name>`). Members, all in the key set's namespace:

- the Secret `nagare-keyset-<name>`, a credential template of a new kind whose data is delegated
  to the rotator; `Durable`, lifecycle `Protect`, sensitivity secret;
- the ConfigMap `nagare-keyset-<name>-public`, whose reviewed part is the policy and whose key
  data is delegated to the rotator;
- a ServiceAccount, a Role allowing `get` and `update` on exactly those two names, and a
  RoleBinding;
- a CronJob `nagare-keyset-<name>` running `nagare-keyset` every five minutes with
  `concurrencyPolicy: Forbid`, and a first-run Job with the same pod template that the scope waits
  for, so the keys exist when the review completes.

Extend the Kubernetes adapter so the delegated data of these two objects is neither drift nor a
foreign writer, and a re-plan never clears it. CLI: `nagarectl keyset plan --file CONFIG
--save-plan DIR` and `nagarectl keyset status [NAME]`, which reads only the public ConfigMap.

Bindings. In `cli/nagarectl/src/Nagare/Inventory/Application/`, a workload with a `Sign` binding
gets one `PlatformMount` at `/var/run/nagare/keysets/<name>/` with the ConfigMap and the Secret;
a `Verify` binding gets the ConfigMap alone. Both get `NAGARE_KEYSET_<NAME>_DIR`. The compile
refuses `keyset-missing` when the accepted head has no key set of that name in the workload's
namespace.

Interpreter tests in `cli/nagarectl/test/KeySetSpec.hs` and `KeySetWorldSpec.hs`: create with a
lost acknowledgement; first-run Job failed; the rotator's writes followed by a re-plan that
changes nothing; a third writer reported; a policy change updating only the ConfigMap's reviewed
part; the two binding shapes and that a `Verify` workload's manifest never names the Secret; the
missing-key-set refusal.

Add the key set and the two bindings to `cluster/examples/content-app/nagare/Config.hs` (create
the file with a web service and a worker if the sibling plans have not).

### M4. The rotation run

After [`docs/runbooks/before-a-native-run.md`](../runbooks/before-a-native-run.md), on a
disposable local context: a key set with a ten-minute period and five-minute overlap; a fixture
image with two modes, a signer that returns an Ed25519-signed token naming its `kid`, and a
verifier that checks a token against the public file, both rereading their file on every request.
Run the script in Concrete Steps. It also confirms the kubelet refreshes both mounted files
without a restart, for a Knative Service and for a worker.

### M5. Retirement, documentation and the ADR

`nagarectl keyset retire NAME --save-plan DIR` retires the scope under `ApproveRetirement`, with
an explicit decision that this credential's data is destroyed, and fills `reviewEffects`: the
private keys of key set N are destroyed, and every signature made with them stops verifying. It
refuses `keyset-still-bound` while an accepted workload binds it. Removing the document without
`retire` keeps the `retirement-required` refusal. Tests assert the lines and both refusals.

Write `docs/user/signing-keys.md` (the declaration, the file format, that a consumer must reread
the file, the rebuild behaviour, that it is for short-lived signatures only) and a capability
page; update `config-reference.md` and `backups-and-disaster-recovery.md`. Write the ADR "The
platform generates and rotates application signing key sets", per
`.claude/skills/exec-plan/ADR.md`.


## Concrete Steps

All commands run from the repository root.

```bash
just gate-commit                 # per Haskell commit
just mutation-check HEAD BASE    # before landing planner, executor or adapter changes
just gate-fast && just land HEAD
```

Focused runs:

```bash
cabal test nagare-core-test --project-dir=cli/nagare-core --test-options='-p /KeySet/' --test-show-details=direct
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p /keyset/' --test-show-details=direct
```

Take the real test-suite names from the cabal files. The rotation run (M4), on the disposable
local context `CTX`; `sign` and `verify` call the fixture's two workloads:

```bash
nagarectl --context CTX keyset status view-grants          # note the active kid, K1
T1=$(sign)                                                 # signed with K1
verify "$T1"                                               # ok
# wait for the next promotion; during it, restart both workloads
kubectl -n personal delete pod -l nagare.dev/app=content-app
T2=$(sign); verify "$T2"                                   # ok, signed with K2
verify "$T1"                                               # ok: K1 is previous
nagarectl --context CTX keyset status view-grants          # K2 active, K1 previous, one more rotation listed
# wait for the overlap to pass
verify "$T1"                                               # refused: unknown kid
```

Expected: the four `ok` results, the final refusal, and a `rotations:` line one entry longer.
Record the transcript under Progress.


## Validation and Acceptance

IR-55 AC-4: M1's properties, and M4's transcript showing the overlap window, the recorded rotation
and agreement across mid-rotation restarts. AC-5 (key set): M5's tests.

The plan is accepted when `just gate-fast` is green on the landed commit, the post-land full gate
is green, and the M4 transcript is under Progress.


## Idempotence and Recovery

The rotator can run at any time and any number of times; it changes nothing unless a rule in M1
fires. A conflict or crash is repaired by the next run from the Secret. A re-plan never touches
key data. If the Secret is lost, the next run starts a new key set and outstanding tokens fail
once. Policy changes are ordinary reviews. The run in M4 uses a disposable context.


## Interfaces and Dependencies

In `cli/nagare-dsl/src/Nagare/Dsl/KeySet.hs`:

```haskell
data RotationPolicy = RotationPolicy
  { period :: !Minutes
  , overlap :: !Minutes
  }
  deriving stock (Generic, Eq, Show)

data KeySet = KeySet
  { name :: !KeySetName
  , logicalKey :: !(Maybe LogicalKey)
  , namespace :: !Namespace
  , rotation :: !RotationPolicy
  }
  deriving stock (Generic, Eq, Show)

data KeySetUse = Sign | Verify
  deriving stock (Generic, Eq, Show)

data KeySetBinding = KeySetBinding
  { name :: !KeySetName
  , use :: !KeySetUse
  }
  deriving stock (Generic, Eq, Show)
```

In `cli/nagare-core/src/Nagare/KeySet.hs`:

```haskell
rotateStep :: UTCTime -> RotationPolicy -> NewKey -> KeySetState -> (KeySetState, [RotationEvent])
```

`public.json`, as a verifier reads it (`private.json` adds `"d"` to each key):

```json
{
  "keys": [
    {"kty": "OKP", "crv": "Ed25519", "kid": "k4", "x": "...", "status": "next"},
    {"kty": "OKP", "crv": "Ed25519", "kid": "k3", "x": "...", "status": "active", "activatedAt": "2026-12-01T00:00:00Z"},
    {"kty": "OKP", "crv": "Ed25519", "kid": "k2", "x": "...", "status": "previous", "supersededAt": "2026-12-01T00:00:00Z"}
  ]
}
```

A consumer contract: sign with the key whose `status` is `active` and put its `kid` in the token;
accept any `kid` present in `public.json`; reread the file at least once a minute.

Dependencies: `crypton` for Ed25519 (already used in the tree; confirm the cabal bound).
Kubelet refresh of projected ConfigMap and Secret volumes is confirmed by M4.
