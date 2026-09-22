# Typed resource inventory compiler

`nagarectl inventory compile --input FILE --out DIRECTORY [--json]` composes
complete independently owned scopes without consulting a context, credentials,
or provider tools. It is the read-only foundation of MasterPlan 23. Existing
deployment commands have not yet migrated to it.

From `cli/nagarectl`, a working example is:

```bash
cabal run exe:nagarectl -- inventory compile \
  --input test/fixtures/inventory/valid.json --out /tmp/nagare-inventory-example
```

The fixture's platform generation remains seven; the selected application's
generation starts at one. `collision-service.json` refuses the two owners of
`core/Service/nagare-system/nix-cache`; `collision-knative-database.json` catches
the same collision through the Knative controller's reserved Service. JSON
diagnostics go to stderr with a nonzero exit status. Successful compilation prints
the candidate SHA-256 digest.

## Model and composition

The six `Nagare.Resource` modules in `nagare-dsl` contain the pure contract.
`Types` separates context, scope, resource, and physical identities. Resource IDs
are minted from a minting scope, stable logical key, and role, and never change
because a provider name changes. `Policy` requires recovery intent for durable
data and exposes credential references, never credential bytes. `Reference`
provides nominally indexed capability references with runtime witnesses.

`Inventory` builds opaque scopes and snapshots, then composes explicit replacements
and retirements through `composeInventory` (also re-exported by `Compile`). It
preserves unselected scopes and generations, authorizes namespace contributions
before generating their owner-managed declarations, then checks the complete graph.
`contributionDependents` exposes the contributing scope's retention dependency on
each generated Namespace. The first closed contribution kind is namespace
registration; future composers extend this dispatch before any executor can use them.

Managed, external, and observed-child declarations are separate alternatives.
Managed resources declare executor, address, desired spec, lifecycle/data policy,
sensitivity, dependencies, and bounded delegation. Native specs reference immutable
content by digest; controller-specific alternatives derive reservations for Knative
Services, Certificate Secrets, StatefulSet Pods/PVCs, and rendered Helm members.
StatefulSet reservations are bounded to 10,000 replicas and generated names must fit
the name contract. Further native semantics and membership parity belong to the
adapter plans, especially EP-147; this compiler does not establish live ownership.

`kubernetesAddress` converts native API versions and kinds to canonical claims:
`apps/v1` and `apps/v1beta1` name the same logical object. Addresses include logical
targets, never unknown physical cluster identities. Pulumi URNs are aliases of an
owned declaration. Global buckets, hostnames, logical databases, and backend routes
have distinct collision domains.

Consumption, readiness, and operation ordering remain separate relationships.
Declared operation kinds are a closed vocabulary, not shell text. Dependencies,
output capabilities, constraints, sensitivity, cycles, delegation overlaps, and
retained/candidate/transaction reservations are validated together. The compiler
does not infer retirement by reversing creation edges.

## Version-one files and authority

[`schemas/resource-inventory-v1.json`](../../schemas/resource-inventory-v1.json)
describes fixture input, scope documents, member requests, and compiled manifests.
The Haskell decoder additionally rejects unsupported kinds, unknown fields,
duplicate JSON keys, non-integer tokens, and semantic violations. Generic decoding
of ordinary records never produces an inventory proof. No opaque invariant-bearing
type derives `Generic`, and no `FromJSON ValidatedInventory` instance exists.

The output contains `candidate.json`, `candidate.sha256`, `input.json`, and
`scopes/<sha256>.json`. Scope documents hold declarations once; `input.json` binds
the explicit base generations, reservations, and replacement/retirement requests
to those members. `candidate.json` binds that request digest, member digests,
desired content digest, and resulting generations. `candidate.sha256` hashes the
exact manifest bytes, followed by a newline. All other canonical documents have
no trailing newline. Keys are sorted explicitly and set-valued declaration lists
are normalized. Integers and JSON-escaped UTF-8 strings are the only scalar content
beyond booleans/null; aeson's map build flags do not control key order.

`Nagare.Inventory.Digest.contentDigest` is the single SHA-256 implementation for
this protocol. Desired identity excludes generations; candidate identity includes
the base and explicit changes. `loadCandidate` verifies exact filenames, bytes,
and digests, decodes scope members, and composes again. Missing or changed members
refuse. Publication stages a private directory (0700) with private files (0600)
and refuses to overwrite differing evidence. Identical output can be reused.

An input fixture declares its complete base snapshot explicitly. This is not
authenticated ownership history: an actor rewriting the entire fixture and all
digests can create a different coherent candidate. EP-145 must compare the base
against the authoritative persisted state and perform locked admission before any
effect. Later schema support must retain the v1 canonical encoder when reading v1
members; changing it would change identity and is a protocol change.

## Verification

`ResourceInventorySpec` exercises the pure guarantees; `InventorySpec` exercises
member verification, digest separation, output immutability, and all checked-in
collision fixtures. The existing negative runner now requires an intended compiler
diagnostic and a successful positive control, including attempts to forge hidden
types via constructors, `Generic`, `coerce`, or JSON and to serialize credentials.

```bash
(cd cli/nagare-dsl && cabal test nagare-dsl-test --test-show-details=direct)
(cd cli/nagare-dsl && bash test/negative/check-negative-types.sh)
(cd cli/nagarectl && cabal test nagarectl-test --test-show-details=direct)
just haskell-style-check
```
