---
type: Guide
title: "Signing short-lived tokens with a platform-rotated key set"
description: "Declare an Ed25519 key set, let the platform generate and rotate it, and read its keys from files in a signing or verifying workload."
docId: DOC-47
tags: [keys, signing, secrets, workers, rotation]
generated:
  by: process:claude-code
  at: 2026-11-26T03:30:00Z
---

# Signing short-lived tokens with a platform-rotated key set

A key set is a set of Ed25519 keys that the platform generates for you and replaces on a schedule.
A workload that signs short-lived tokens reads the private keys from a file; a workload that only
checks them reads the public keys. Both files change in place when a key rotates, so no deploy or
restart is needed. Use a key set for tokens that live minutes or hours. Do not use it for
signatures that must stay valid for longer than the key set's overlap, or across a cluster rebuild.

## Declare the key set

A key set is its own document, like an app database. It names a namespace, a rotation period and
an overlap, and it outlives the applications that use it. `cluster/examples/content-app/nagare/KeySets.hs`
is a complete example:

```haskell
viewGrants = do
  name <- mkKeySetName "view-grants"
  ns <- mkNamespace "personal"
  day <- mkMinutes (24 * 60)
  twoHours <- mkMinutes 120
  rotation <- mkRotationPolicy day twoHours
  pure KeySet {name = name, logicalKey = Nothing, namespace = ns, rotation = rotation}

main = either (ioError . userError . Text.unpack) (emitKeySets . pure) viewGrants
```

The period is at least ten minutes and the overlap at least five, and the overlap is never longer
than the period, because the rotator runs every five minutes. Review and apply it:

```bash
nagarectl keyset plan --file nagare/KeySets.hs --save-plan ./keyset-review
nagarectl inventory apply ./keyset-review --yes
```

The review creates the key set's Secret and public ConfigMap, the rotator's account, a Role that
may read and update only those two objects, a CronJob that runs the rotator every five minutes,
and a first run that generates the first keys. The review completes only once the keys exist. No
review ever holds a key.

## Bind it from a workload

A workload names the key set and what it does with it:

```haskell
api & #keySets .~ [KeySetBinding viewGrants Sign]
gateway & #keySets .~ [KeySetBinding viewGrants Verify]
```

A standalone service, a standalone worker, a task, or an Application's service and workers can
bind a key set in their own namespace. The binding is refused with `keyset-missing` until a key set
of that name is accepted there, and the workload starts only after the key set's first run.

A bound workload gets the read-only directory `/var/run/nagare/keysets/NAME/` and the variable
`NAGARE_KEYSET_NAME_DIR` naming it (the name upper-cased, `-` as `_`). A `Sign` workload's
directory holds `public.json` and `private.json`; a `Verify` workload's holds only `public.json`,
and its manifest never names the key set's Secret.

## The files

`public.json` is a JWK Set of RFC 8037 keys. Each key carries a `status`:

```json
{"keys": [
  {"kty": "OKP", "crv": "Ed25519", "kid": "k4", "x": "…", "status": "next", "publishedAt": "…"},
  {"kty": "OKP", "crv": "Ed25519", "kid": "k3", "x": "…", "status": "active", "activatedAt": "…"},
  {"kty": "OKP", "crv": "Ed25519", "kid": "k2", "x": "…", "status": "previous", "supersededAt": "…"}
 ],
 "policy": {"periodMinutes": 1440, "overlapMinutes": 120}, "serial": 4, "history": [ … ]}
```

`private.json` is the same document with each key's private seed in `d`.

The contract for a consumer:

- a signer signs with the key whose `status` is `active` and puts its `kid` in the token;
- a verifier accepts a token whose `kid` is any key in `public.json`;
- both reread the file at least once a minute, because the kubelet replaces it in place.

A key is published as `next` at least five minutes before it signs, and a replaced key stays
published as `previous` for the overlap. So a verifier whose file is a rotation behind or ahead of
the signer's still knows the signer's key, whatever order pods restart in.

## See the rotation

```bash
nagarectl keyset status view-grants
```

```text
view-grants  period 24h  overlap 2h
  next      k4  published 2026-12-01T00:00:00Z
  active    k3  since     2026-12-01T00:00:00Z
  previous  k2  until     2026-12-01T02:00:00Z
rotations: k3 2026-12-01T00:00:00Z, k2 2026-11-30T00:00:00Z, k1 2026-11-29T00:00:00Z
```

A policy change is an ordinary review. It changes only the reviewed policy; the keys stay.

## Rebuilds and backups

Key sets are not backed up or escrowed. A rebuilt cluster generates new keys on the key set's first
run, so every token outstanding at the rebuild fails once and must be reissued.

## Retire a key set

Remove every binding and deploy first; `keyset retire` refuses `keyset-still-bound` while any
workload binds the key set. Then:

```bash
nagarectl keyset retire view-grants --save-plan ./keyset-retire
nagarectl inventory apply ./keyset-retire --yes
```

The retirement keeps the objects and prints the collect reviews that delete them, one per step,
each applied before the next (a member is collected only once nothing retained depends on it).
The last collect review says what it removes:

```text
This review removes:
  the private keys of key set view-grants in personal are destroyed; every signature made with them stops verifying
```
