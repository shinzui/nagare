---
title: "Operator deployment material lives in a private repository with remote state"
status: accepted
date: 2026-09-12
authors: [shinzui]
related:
  - docs/plans/116-move-operator-private-deployment-material-into-a-private-development-repository.md
  - docs/plans/99-protect-stateful-infrastructure-and-make-secrets-and-state-recoverable.md
  - docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md
  - docs/adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md
  - docs/adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md
---

# ADR 13 — Operator deployment material lives in a private repository with remote state

## Status

Accepted, 2026-09-12. Implemented by
[ExecPlan 116](../plans/116-move-operator-private-deployment-material-into-a-private-development-repository.md).

## Context

`shinzui/nagare` is for the open-source development of the platform. Until this decision it also
carried one operator's live installation (`tan-nb-exp`): the sops-encrypted host secrets, the
encrypted cluster bootstrap secrets, and the operator's workstation and host age recipients. The
rest of that installation sat in unversioned workstation paths: the target context, the generated
host flake, the Pulumi stack config, and the Pulumi file-backend state.

[ADR 4](0004-separate-immutable-platform-payloads-from-context-workspaces.md) and
[ADR 5](0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md) had already moved operator
inputs out of the platform payload and into context-owned XDG paths. Nothing versioned or backed
those paths up.

Evidence gathered while delivering ExecPlan 116 shaped the decision:

- Pulumi state stores every resource's inputs and outputs in plaintext. Only secret-marked values
  are encrypted, and this stack's passphrase is empty. State committed to git would stay in its
  history, and a file backend in git has no locking.
- The existing XDG resolution (`scripts/lib/target.sh`, `scripts/lib/cluster-secrets.sh`,
  `nagarectl`) follows symlinks, so a private repository can be wired in with no new configuration
  mechanism. Two writers replaced a file by rename and would have detached a symlinked context;
  both now write through the link.
- Pulumi uses `PULUMI_CONFIG_PASSPHRASE` whenever it is set, even to an empty string, and ignores
  `PULUMI_CONFIG_PASSPHRASE_FILE` in that case. Several tool paths forced the empty variable, and
  `nagarectl` truncated the passphrase file on every run.
- With gcloud 570, the formatted output of `gcloud storage buckets describe` has no `projectNumber`
  field. The ADR 9 bucket-ownership assertion needs `--raw` to read it.

## Decision

1. Each operator keeps deployment material in their own **private** git repository. For
   `tan-nb-exp` that is `shinzui/nagare-ops`, which holds `contexts/<context>.env`,
   `hosts/<context>/` (the generated host flake with its sops `secrets.yaml`),
   `cluster-secrets/<context>/`, `pulumi/Pulumi.<context>.yaml`, and a root `.sops.yaml`.
2. That repository is wired to Nagare through the existing paths by symlink:
   `${XDG_CONFIG_HOME}/nagare/contexts/`, `.../hosts/`, `.../cluster-secrets/`, and
   `infra/pulumi/Pulumi.<context>.yaml`. Tooling that rewrites these files must write through the
   link or rename over its canonical target, never over the link.
3. Pulumi state never enters git. A cloud context uses the GCS backend
   (`NAGARE_PULUMI_BACKEND=gcs`). The state bucket is versioned, uniform-access,
   public-access-prevented, and owned by the target project. The private repository records only
   the backend URL.
4. Private keys and passphrases enter no repository. Stack passphrases live in the per-context
   `home/passphrase` file, which tooling creates when absent and never truncates or shadows. An
   operator's non-empty `PULUMI_CONFIG_PASSPHRASE` export still wins. `tan-nb-exp` deliberately
   keeps an empty passphrase.
5. The public repository ships no operator's encrypted secrets or recipients. The NixOS evaluation
   fixture reads `nixos/hosts/nagare-01/secrets/example.yaml`, which is encrypted to an example
   age recipient whose private key was discarded. Both `.sops.yaml` files name only that example
   recipient. `tan-nb-exp` remains in the documentation as the built-in default example.

## Consequences

A new machine needs a clone of both repositories, the symlinks listed in the private repository's
`README.md`, and gcloud credentials. From that state, `pulumi preview --refresh` reports no changes
against the GCS backend.

A shell that resolved the context before a backend migration keeps the old
`NAGARE_PULUMI_BACKEND`/`PULUMI_BACKEND_URL` in its environment. The environment beats the context
file, so after a migration operators must reload direnv or open a new shell.

Git history in the public repository still contains the removed encrypted files and recipients.
Recipients are public keys and the files are encrypted by design, so history is not rewritten. A
secret that must be treated as exposed is rotated in a follow-up plan.

With an empty passphrase, the secret-marked values in `tan-nb-exp` state are readable by anyone
with read access to the state bucket. That access is limited to principals in `tan-nb-exp`.

## Amendment — 2026-09-13: the Pulumi stack config has a context-owned home

Nagare 0.2.0 showed that point 2's checkout symlink is not enough. The installed CLI and
`nagarectl platform upgrade` run Pulumi in payload workspaces (ADR 4), which exclude every
`Pulumi.<stack>.yaml` and are replaced by each release. For `tan-nb-exp` the project guard
refused and the upgrade's Pulumi phases would have run without the stack's image link and
disk types.

Since 0.2.1 the stack config's one real location is
`${XDG_CONFIG_HOME}/nagare/pulumi/Pulumi.<context>.yaml`, alongside `contexts/`, `hosts/`,
and `cluster-secrets/`. A private repository wires it there by symlink like the others.
Before any Pulumi command, `nagarectl` links `Pulumi.<context>.yaml` in the workspace, and in
a source checkout's `infra/pulumi`, to that path. It adopts a lone pre-0.2.1 workspace copy.
It refuses when two different copies exist or when the canonical path is a dangling symlink,
because Pulumi silently reads a dangling stack file as empty configuration. Pulumi writes
through the link, which was verified for `config set`, `--secret`, and `config rm`. The
existing checkout symlink keeps working when it resolves to the same real file. The same
change installs the Pulumi program's locked Node dependencies (`npm ci`) in a workspace that
lacks them, because payloads exclude `node_modules`. Implemented by
[ExecPlan 121](../plans/121-give-operator-pulumi-stack-config-a-context-owned-home-so-guarded-platform-upgrades-are-safe-ship-0-2-1-and-upgrade-tan-nb-exp.md).

## Amendment — 2026-09-16: recovery identities are offline and explicitly enrolled

Operational secrets have distinct consumer, workstation-editing, and offline-recovery
roles. The recovery private identity belongs in the operator's vault, independent of
the host and workstation identities. A backed-up host identity remains a host identity;
it does not provide that separation. An operator may share a recovery identity across
contexts, but coverage is established per ciphertext, never inferred from the vault
item's name or a policy change alone.

Recovery recipients are added only to private operator policies and operational
ciphertext. The public policies and intentionally undecryptable evaluation fixture
remain examples. Inventory the actual context paths and versioned backups separately:
a regular XDG host directory can coexist with a cluster-secret symlink into another
private repository. Updating one does not update the other.

Re-keying preserves consumer recipients and secret values, proves independent
decryption by each required identity, and includes a no-key failure check to detect
ambient credentials masking a failed recovery proof. For multi-document YAML, every
document must carry the recovery recipient. Host verification uses the guarded switch
from ADR 11. Temporary recovery-key material is removed after verification and
operator-confirmed vault custody; vault confirmation and cryptographic checks are
recorded as separate evidence, without claiming automated vault retrieval when the
operator performed the handoff manually.
