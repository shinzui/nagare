---
title: "Operator deployment material lives in a private repository with remote state"
status: accepted
date: 2026-09-12
authors: [shinzui]
related:
  - docs/plans/116-move-operator-private-deployment-material-into-a-private-development-repository.md
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
