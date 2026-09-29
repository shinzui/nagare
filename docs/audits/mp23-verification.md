# MP-23 independent verification log

## F01 — closed locally, 2026-09-29T04:47:46.606485+00:00

Ran the checked-in `InventoryHostSpec.inventoryHostTests` via the archived `HostTests.hs` runner, using current source and the package's normal language extensions from `cli/nagarectl`.

```text
host inventory adapter
  host declaration includes system, durable mount, and explicit activation: OK
  preflight refuses a timer-armed host without cancelling rollback: OK
  reverted activation is safe to retry; committed closure has durable proof: OK
  effect-time drift after preflight cannot run host activation: OK
  local flake evidence cannot substitute for a remote committed closure: OK
  fresh-login host receipt binds the committed closure: OK
  subprocess runtime retains the prepared closure across execution: OK
All 7 tests passed (0.40s)
```

The new checked-in drift regression covers replacement VM identity, changed old closure, and a committed replacement VM, and asserts zero activation callbacks. The independent earlier HostAudit probe also produced zero callbacks after the fix.

The current shell activate function was extracted with only command boundaries faked, and supplied a replacement physical identity. `HostIdentityTransportAudit.sh` returned:

```json
{"exit":2,"calls":[],"stderr":"host physical instance differs from reviewed activation"}
```

No host SSH, age-key helper, or host-switch was invoked. This closes the identity/closure refusal defect; it does not claim native host bootstrap or readiness acceptance.

## F11 — closed, 2026-09-29T04:47:46.606485+00:00

Compiled the current ObjectOps source through `PutTests.hs` and exercised the three exact-version parser cases mirrored by the checked-in `conditional upload accepts only an exact version-specific created URL` test: matching URL/generation, another object, and malformed generation.

```text
ObjectOps compiled; 3 exact-generation parser checks passed
```

This closes the unconstrained exception type error only. PUT semantics, ambiguous-result recovery, and measured append performance remain tracked separately by F06.

## Source identities captured after these checks

Base commit: `9bb44baf`; fixes are in the shared working tree. These checks are bound to these source bytes; subsequent relevant changes require re-verification.

```text
9f5d28607bc60a384b7c8031b0c91d360b34817e96468a09b5f4686ec9a9e264  cli/nagarectl/src/Nagare/Inventory/Adapters/Host.hs
016bfbdfee91d6f8b281524e6c2b4dbcdcecc03eb67f4cefe156b31263e9d9dd  cli/nagarectl/test/InventoryHostSpec.hs
76a00a92bbc2cbe07d36a7926d79453da2dcdf54327c49ee50c779aca7fa9e52  scripts/inventory-host-transport.sh
028959447fd85a512c6ef1c28cb5f9b31aeb4193ea624fc4202a7e1334d5eef8  cli/nagarectl/src/Nagare/Inventory/Store/ObjectOps.hs
```

Reproduction commands (run from `cli/nagarectl`):

```bash
cabal exec -- runghc -XGHC2024 -XDeriveAnyClass -XDuplicateRecordFields -XOverloadedLabels -XOverloadedStrings -isrc -itest ../../docs/audits/mp23-reproductions/HostTests.hs
cabal exec -- runghc -XGHC2024 -XDeriveAnyClass -XDuplicateRecordFields -XOverloadedLabels -XOverloadedStrings -isrc ../../docs/audits/mp23-reproductions/PutTests.hs
```

For the shell recorder, set AUDIT_CALLS to a new temporary output file before running the archived script. It freezes the function verified here, so regenerate from the current source before validating a later change.
