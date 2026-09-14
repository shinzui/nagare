---
type: Runbook
title: "Replacement cutover and rollback drill"
description: "Rehearse Nagare's deadline-bound replacement cutover, forced rollback, and guarded cleanup without changing DNS."
tags: [upgrades, replacement, cutover, rollback, operations]
---

# Replacement cutover and rollback drill

> **Implementation status:** The provider-independent executor and deterministic fault drills exist.
> Do not run a production cutover until the replacement plan, candidate provisioning, rehearsal,
> state-transfer, and disposable GCE handoff plans are implemented and their evidence makes the
> transaction `ready`.

This drill exercises one reserved public IP moving from an old host to a fenced candidate and back.
DNS is never edited. Use a disposable project whose resources can be deleted and whose context name,
project, zone, instance IDs, disks, and address exactly match the transaction.

## Local deterministic drill

From the repository root, run the cutover group with the package project as its working directory:

```bash
nix develop -c cabal test nagarectl-test \
  --project-dir=cli/nagarectl \
  --test-options='-p PlatformCutover' \
  --test-show-details=direct
```

The suite injects failures before and after every pre-commit external boundary. It proves that the
deadline begins at the first denied write, forward work stops before the rollback reserve, a crash
after old-address detachment reconciles from observation, and no observed candidate write admission
is rolled back.

## Live-drill entry gate

Before quiescing anything, require all of the following:

- The transaction is `ready`, its blocker list is empty, and its confirmation token is exactly
  `<context>/<transaction-suffix>`.
- Candidate and old resource IDs, project, zone, reserved address, Pulumi outputs, and drift token
  match live observations.
- Rehearsal and state-transfer evidence is unexpired, every retained state item is supported, and
  the complete quiesce/restore snapshot is present.
- Predicted final transfer, address handoff, public verification, rollback reserve, and safety
  margin total no more than 900 seconds.
- A recent backup exists independently of transaction seed/final-transfer artifacts.

If any gate is missing, stop while the old service is still serving. Do not substitute hand-written
`gcloud` or `kubectl` commands for the missing transaction adapters.

## Forward drill

When the prerequisite command surface is available, first inspect without mutation:

```bash
nagarectl platform replacement status "$transaction_id" --json
nagarectl platform replacement cutover "$transaction_id" --dry-run
```

Then use the printed token and retain the JSON record:

```bash
nagarectl platform replacement cutover "$transaction_id" \
  --confirm "$context/$transaction_suffix" --json \
  >cutover-result.json
```

Acceptance requires state `committed`, unchanged DNS, the reserved address attached only to the
candidate, a downtime value no greater than 900 seconds, the post-seed sentinel on the candidate,
candidate writes admitted once, and the old VM stopped rather than deleted.

## Forced rollback drill

Prepare a fresh disposable transaction and inject a failure immediately after candidate address
attachment. The executor must fence candidate writes, detach the candidate, restore the old address
and workloads, and finish in `rolled-back`. Verify the public old sentinel and a new old-side write.
The candidate must reject ordinary writes. If the provider control plane delays recovery past 900
seconds, record an SLO breach and continue until old service is healthy.

## Finalization drill

After the chosen retention period, or after explicitly accepting immediate deletion in the
disposable project, run:

```bash
nagarectl platform replacement finalize "$transaction_id" \
  --confirm "$context/$transaction_suffix" --json
pulumi -C "$context_infra_workspace" preview --diff
```

The preview must be empty. The stack must contain one active VM and data disk, no candidate or
former-active slot, and the original reserved address and DNS record. Finalize must reject a
resource whose ID or role was not recorded by the transaction.

## Recovery boundaries

Before candidate write admission, rerun reconciliation and rollback; never manually double-detach or
double-attach the address. After candidate write admission, do not restore the old service as if it
were current. Fence further writes and design an application-specific reverse transfer that accounts
for candidate-only data. Preserve the transaction JSON and evidence until recovery is complete.
