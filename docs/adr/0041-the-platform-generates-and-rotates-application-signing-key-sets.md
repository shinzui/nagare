---
title: "The platform generates and rotates application signing key sets"
status: accepted
date: 2026-11-26
authors: [shinzui]
related:
  - docs/plans/286-generate-and-rotate-an-ed25519-signing-key-set-that-workloads-read-from-files.md
  - docs/masterplans/39-provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md
  - docs/improvement-requests/provision-app-object-storage-isolated-content-domains-and-rotating-signing-keys.md
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
  - docs/adr/0036-application-pods-hold-no-kubernetes-api-token-unless-they-name-an-account.md
  - docs/adr/0038-a-workload-inherits-its-app-s-managed-store-unless-it-opts-out.md
---

# ADR 41 — The platform generates and rotates application signing key sets

## Status

Accepted and implemented by [EP-286](../plans/286-generate-and-rotate-an-ed25519-signing-key-set-that-workloads-read-from-files.md)
(MasterPlan 39), for IR-55 from `mori://shinzui/hanmoto`.

## Context

An application secret was a value an operator typed in, delivered as an environment variable that
changes only when a pod restarts. A service that signs short-lived tokens needs keys generated for
it and replaced on a schedule, without a deploy, and without the signer and a verifier ever
disagreeing about which key is valid. The inventory treated any field written by another writer as
foreign, and it compared a credential's whole content, so a value changed after creation was drift.

## Decision

1. **A key set is a standalone scope**, `keyset-<key>`, declared by its own document, like an app
   database. An application redeploy or retirement never regenerates or destroys its keys.
2. **Keys are files, in three slots.** `next` is published at least five minutes before it signs,
   `active` signs, and `previous` stays published for the overlap. Public keys are in a ConfigMap
   and private keys in a Secret, mounted read-only; a `Verify` binding mounts only the ConfigMap,
   so a verifier holds no signing key (ADR 38). Both files change in place.
3. **A platform rotator owns exactly the key files.** A CronJob in the key set's namespace runs
   `nagare-keyset` every five minutes under its own ServiceAccount, which may get and update only
   the key set's two objects (ADR 36 still holds for application pods). It writes as field manager
   `nagare-keyset`, and the Kubernetes adapter accepts that manager owning exactly `private.json`
   of the Secret and `public.json` of the ConfigMap. Any other field it owns, or any other writer of
   a key file, is still a foreign writer. Inventory owns the reviewed policy, and its server-side
   apply never clears the rotator's keys.
4. **No escrow.** Key sets are not backed up; a rebuilt cluster generates new keys and outstanding
   tokens fail once. A key set is for short-lived signatures only.
5. **Retirement then collection** (ADR 22). `keyset retire` keeps the objects and is refused while a
   workload binds the key set; the collect reviews that follow delete them. Collection admits a
   Secret only when it is a key set's own, and collecting it says that the private keys are
   destroyed and their signatures stop verifying.

## Consequences

- A workload's binding is resolved against the accepted key set in its namespace and ordered after
  the key set's first run, so its files exist before it starts.
- The rotator runs from the admin API image. A context publishes that image only with the admin API
  or the lifecycle worker enabled; otherwise `keyset plan` needs `NAGARE_ADMIN_API_IMAGE`.
- A collect review refuses a member another retained member depends on, so retired members are
  collected one wave at a time, leaves first; `keyset retire` prints the waves.
