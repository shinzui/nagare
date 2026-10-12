---
id: 116
slug: move-operator-private-deployment-material-into-a-private-development-repository
title: "Move operator-private deployment material into a private development repository"
kind: exec-plan
created_at: 2026-09-12T21:32:01Z
intention: "intention_01m2av9m0ge8sbwjy4arw5svf9"
provenance:
  created_by:
    model: "claude-opus-5[1m]"
    harness: "claude-code"
    at: 2026-09-12T21:32:01Z
  revisions:
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-12T21:42:30Z
      mode: "implement"
      note: "Milestone 0 inventory and operator confirmations recorded; implementation begun"
---

# Move operator-private deployment material into a private development repository

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [116-move-operator-private-deployment-material-into-a-private-development-repository.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/116-move-operator-private-deployment-material-into-a-private-development-repository.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare's repository, `shinzui/nagare`, is for the **open-source development** of the platform.
Today it also carries one operator's live deployment: encrypted secrets for the `tan-nb-exp`
installation, sops recipient keys for that installation's machines, and documentation that names
that project. Around the repository sit more private files: the context, the generated host flake,
Pulumi stack configuration and state, and a host age private key. They live in ad hoc places on
one laptop, and nothing backs them up or versions them.

After this plan, a **private GitHub repository** (working name `shinzui/nagare-ops`, confirmed with
the operator before creation) holds everything an operator needs to run their installation. The
Pulumi state lives in a remote backend that the private repository points at. The public
repository holds no operator-specific secret or recipient, and a fresh clone of the public
repository plus the private repository is enough to operate `tan-nb-exp` from a new machine. You
can see it working when three things hold: from a clean checkout of both repositories on a second
directory, `pulumi preview --refresh` for `tan-nb-exp` reports no changes;
`scripts/host-switch.sh --dry-run` resolves the host flake from the private repository; and
`git grep` for `tan-nb-exp` secrets and recipients in the public repository finds nothing but
documented examples.

This plan was requested by the operator on 2026-09-12, during
[ExecPlan 114](114-recover-nagare-01-host-access-and-finish-the-data-disk-grow-deterministically.md).
Their direction: this repository is only for open-source development of Nagare, and a new private
repository holds operator development material from now on, including the Pulumi state.

## Progress

- [x] Milestone 0: confirm the inventory below against the working tree, and get the operator's explicit answers to the three confirmation questions (repository name and visibility, backend choice, which tracked files leave the public repository). (2026-09-12T21:42Z — inventory matched; all answers recorded in the Decision Log, plus the secrets-provider choice.)
- [x] Milestone 1 (partial, 2026-09-12T21:50Z): created private `shinzui/nagare-ops`, populated and staged it locally (not committed or pushed), replaced the context, host flake, cluster-secrets, and stack-config paths with symlinks (backups in `~/.local/state/nagare/tan-nb-exp/pre-private-repo-20260912T214459Z`). Gates passed: context `tan-nb-exp`, host-switch dry run resolves into the clone, flake evaluates, `pulumi preview` 31 unchanged.
- [x] Milestone 1 complete (2026-09-12T22:20Z): operator confirmed the staged list; committed and pushed `shinzui/nagare-ops@79b7af5` on `main` (visibility PRIVATE).
- [x] Milestone 2 prerequisite (2026-09-12T22:40Z): fixed passphrase shadowing/truncation in `.envrc`, `scripts/lib/target.sh`, `scripts/migrate-pulumi-backend.sh`, and `nagarectl`, and symlink-clobbering context writes; commit `9cc4764`. Verified the real stack still decrypts through the empty file with an inherited empty variable.
- [x] Milestone 2 backup (2026-09-12T22:44Z): `~/.local/state/nagare/tan-nb-exp/pre-passphrase-rotation-20260912T224445Z` holds the encrypted export (32 resources), the pre-rotation stack config with its salt, and a copy of `state/`.
- [x] Rebuilt `result/bin/nagarectl` with the passphrase fix (2026-09-12T23:00Z). Passphrase rotation **dropped** by operator decision (see Decision Log).
- [x] Milestone 2 (2026-09-12T23:35Z): first migration run was refused by the bucket-ownership guard (gcloud 570 hides `projectNumber`); fixed with `--raw` in `ed238ba`, verified it accepts our bucket and refuses a foreign one, and re-ran with operator approval. State is in `gs://tan-nb-exp-nagare-pulumi-state/nagare/tan-nb-exp` (versioning on, PAP enforced, UBLA, project number 1087727631858); outputs matched; context flipped through the symlink (`nagare-ops@c057928`). Gate: `pulumi preview --refresh` = `31 unchanged` against GCS from a clean environment. Old local state renamed to `state.migrated-to-gcs-20260912T233425Z`; rollback artifact `pulumi-migrations/pre-gcs-20260912T233218Z.json`.
- [x] Milestone 3 (2026-09-12T23:55Z, `faa60f7`): removed `nixos/hosts/nagare-01/secrets/nagare-01.yaml` and `cluster/secrets/*.yaml`; the fixture now reads `secrets/example.yaml`, encrypted to example recipient `age13dryrvm279xsxwtuun8xuy6u9eehjthz78e0823excrf6yrn6u0s5ssw63` (private key discarded), which both `.sops.yaml` files name. Updated `docs/user/{secrets,reference,onboarding-bring-your-own-project,accessing-the-host,cdn,static-hosting}.md` and `docs/runbooks/disaster-recovery.md`. Gates: `./nixos` fixture evaluates and `nix flake check ./nixos --no-build --all-systems` passes; `just docs-validate` OK; recipient grep empty outside `docs/plans/`; only `example.yaml` tracked under the secrets paths.
- [x] Milestone 4 (2026-09-13T00:05Z): fresh clones of both repositories in the session scratchpad, scratch `XDG_CONFIG_HOME`/`XDG_STATE_HOME`, wired per the private `README.md`. Target check OK; backend `gs://tan-nb-exp-nagare-pulumi-state/nagare/tan-nb-exp`; `pulumi preview --refresh` = `31 unchanged`; `scripts/host-switch.sh --dry-run` resolves the scratch host flake into the `nagare-ops` clone; cluster secrets resolve into the clone. Private repo PRIVATE, with no keys, passphrases, or state tracked. ADR 13 written.
- [x] Documentation pass (2026-09-13): `docs/user/contexts.md` (passphrase file, reload after migration, private operator repositories), `docs/user/provisioning-with-pulumi.md`, `docs/runbooks/disaster-recovery.md`, ADR 9 amendment (`--raw`), `docs/guides/running-multiple-clusters.md`, `CLAUDE.md` (GCS backend, operator material rule), and the `nagare-ops` README (`3407dbb`).
- [ ] Deferred to the operator: delete `~/.local/state/nagare/tan-nb-exp/state.migrated-to-gcs-20260912T233425Z` and the rotation/private-repo backups once satisfied (kept for now).

## Surprises & Discoveries

Findings from the inventory made while authoring this plan (2026-09-12, read-only; secret values
were not printed):

- The Pulumi passphrase file for the context,
  `~/.local/state/nagare/tan-nb-exp/home/passphrase`, is **empty (0 bytes)**, and
  `infra/pulumi/Pulumi.tan-nb-exp.yaml` has an `encryptionsalt`. Stack secrets are therefore
  encrypted under an empty passphrase, which is effectively no protection. Any backend that stores
  this state must not be treated as secret-safe until the stack's secrets provider is rotated
  (Milestone 2).
- A **host age private key** sits on the workstation at `~/.config/nagare/nagare-01-age-key.txt`
  (mode 600). The host itself has been missing its age key since before 2026-09-12
  (`/run/secrets/tailscale/authkey` absent, `tailscaled-autoconnect.service` failing). This file
  may be that key. Verify it by comparing its public half with the host recipient in
  `nixos/.sops.yaml`, without printing the private half.
- The generated host flake keeps a second copy of the encrypted host secrets at
  `~/.config/nagare/hosts/tan-nb-exp/secrets.yaml` (copied from the tracked
  `nixos/hosts/nagare-01/secrets/nagare-01.yaml` by `nagarectl host init --sops-file`).
- Milestone 0 (2026-09-12T21:40Z): `age-keygen -y ~/.config/nagare/nagare-01-age-key.txt` prints
  `age1rc26869fukux3k5rqjwf0e9gs3j7p98ekp47pxrtge6m5sc9zerssk9r99`, identical to `&host_nagare01` in
  `nixos/.sops.yaml:2`. The workstation file **is** the host's age private key, so the host's missing
  key is recoverable from it. It stays out of every repository; restoring it to the host is a
  separate, guarded follow-up.
- Milestone 0: `~/.local/state/nagare/default/state/.pulumi/stacks/nagare/default.json` is 372 bytes
  (an empty stack, last written 2026-06-30). It is not live; this plan leaves it and the leftover
  git-ignored `infra/pulumi/Pulumi.{acme-demo,default,prod,ep90-*}.yaml` files untouched.
- Milestone 0: cluster secrets already have an out-of-repository source. `cluster/observability/install.sh`
  reads them through `nagare_require_cluster_secret` from a secrets directory that honors
  `NAGARE_CLUSTER_SECRETS_DIR`, and `flake.nix` checks that packaged payloads carry no
  `cluster/secrets`. Tracked `cluster/secrets/` is only a source-checkout fallback (ADR 4).
- Scratch-stack experiments (throwaway stacks in the session scratchpad, never the real stack):
  Pulumi prefers `PULUMI_CONFIG_PASSPHRASE` whenever it is **set, even empty**, over
  `PULUMI_CONFIG_PASSPHRASE_FILE`. `scripts/lib/target.sh` always exports it, so a passphrase written
  to the context's `home/passphrase` file is never read. `stack change-secrets-provider passphrase`
  reads the old passphrase from the environment and prompts on a TTY for the new one. Pulumi config
  writes follow a symlinked `Pulumi.<stack>.yaml`. The real stack holds 18 secret-marked values.
- `nagarectl`'s Pulumi setup (`cli/nagarectl/app/Main.hs`, `ensurePulumiInWorkspace`) ran
  `writeFile (peHome </> "passphrase") ""` on every invocation, so a real passphrase kept in that
  file would have been silently erased by the next `nagarectl` Pulumi operation. `.envrc`,
  `renderContextShellEnv`, and the migration script also forced `PULUMI_CONFIG_PASSPHRASE=""`.
  Rotating the stack before fixing these would have broken every tool path. Fixed in `9cc4764`.
- `writeContextPlatformVersion` and the migration script's `set_context_var` replaced the context
  file by rename, which would detach a symlinked context from `nagare-ops`. Fixed in `9cc4764` with
  a regression test.
- `cabal test nagarectl-test` reports 8/419 failures, all in `AppDeploySpec` with "Ambiguous module
  name … nagare-dsl-0.1.0 nagare-dsl-0.1.0.0" while compiling the `kizashi` fixture: a duplicate
  `nagare-dsl` registration in the local package environment, unrelated to this plan. The new and
  updated tests pass.
- Removing `.claude/hooks/guard_host_mutation.py` at the operator's request was refused by Claude
  Code's auto-mode classifier as a security weakening; it was left in place. Writing a plaintext
  `stack export --show-secrets` backup was also refused, so the rotation backup is the encrypted
  export plus the old salt and a state copy (equivalent, because the old passphrase is empty).
- Editing `.envrc` blocks direnv until the operator runs `direnv allow`.
- gcloud 570.0.0 omits `projectNumber` from `gcloud storage buckets describe` formatted output, so
  `_require_bucket_in_target_project` (and `nagarectl`'s `bucketProjectNumberArgs`) refused every
  bucket, including one just created in the target project. `--raw` returns the API field. The
  first migration run had already created the bucket before refusing; nothing was imported.
- A shell that loaded the context before the migration keeps `NAGARE_PULUMI_BACKEND=local` and
  `PULUMI_BACKEND_URL=file://…` in its environment, and environment beats the context file, so it
  silently targets the old local state. The first post-migration preview in this session did exactly
  that. Renaming the old `state/` directory makes such a shell see an empty stack instead of stale
  state; operators must reload direnv (or open a new shell) after a backend migration.

## Decision Log

- Decision: Keep Pulumi state out of git. Use the supported `gcs` backend for `tan-nb-exp`, and have
  the private repository hold the context file that names the backend (`NAGARE_PULUMI_BACKEND=gcs`
  and `NAGARE_PULUMI_BACKEND_URL`). Do not commit an encrypted file backend. The operator must
  confirm this in Milestone 0, because their stated direction was to move the state into the
  private repository.
  Rationale: Pulumi state holds every resource's inputs and outputs in plaintext. Only values
  marked secret are encrypted, and here they are encrypted with an empty passphrase (Surprises).
  Committed state stays in git history forever, even after a later rotation. A file backend in git
  also has no locking, so two machines can corrupt it. The `gcs` backend is already built and
  documented here (`docs/user/contexts.md`, "Remote GCS Pulumi state"). It creates a versioned,
  uniform-access, public-access-prevented bucket, and `scripts/migrate-pulumi-backend.sh` migrates
  with a rollback artifact. The private repository still makes the state reachable: it records the
  backend URL, and a new machine needs only the repository and gcloud credentials.
  Date: 2026-09-12

- Decision: Creating the GitHub repository needs the operator's explicit confirmation of name and
  visibility immediately before `gh repo create`. Pushing operator material there also needs it.
  Rationale: Both are outward-facing and hard to reverse. A public repository created by mistake
  would publish secrets, recipients, and state pointers.
  Date: 2026-09-12

- Decision: Point Nagare at the private repository through its existing XDG paths, not a new
  configuration mechanism. The private repository's directories are either cloned into, or
  symlinked from, `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/` and `.../nagare/hosts/`.
  Rationale: `scripts/lib/target.sh` and `nagarectl` already resolve contexts and host flakes from
  those paths (ADR 5), so no code change is needed to prove the move. Adding a "private repository
  root" setting can be a later plan if symlinks prove awkward.
  Date: 2026-09-12

- Decision (Milestone 0 operator answers, 2026-09-12T21:42Z): (1) the private repository is
  `shinzui/nagare-ops`, visibility **private**, cloned to `/Users/shinzui/Keikaku/bokuno/nagare-ops`;
  (2) Pulumi state moves to the **GCS backend** as decided above, not into git; (3) **all five**
  tracked files leave the public repository: the three encrypted secret files move, and both
  `.sops.yaml` files get placeholder recipients; (4) the stack's secrets provider is rotated to a
  **non-empty passphrase** the operator keeps in a password manager and exports as
  `PULUMI_CONFIG_PASSPHRASE` (no KMS resource).
  Rationale: operator's explicit selections in this session.
  Date: 2026-09-12

- Decision: The stack passphrase lives in the per-context file
  `~/.local/state/nagare/<context>/home/passphrase` (mode 600, outside every repository) with the
  authoritative copy in the operator's password manager. Tooling never truncates the file and never
  shadows it with an empty `PULUMI_CONFIG_PASSPHRASE`; a non-empty export still wins.
  Rationale: every tool path already names that file, an empty file keeps today's contexts working,
  and the operator required that the passphrase cannot be lost. The rotation is typed by the
  operator into Pulumi's TTY prompt so the agent never sees or invents the value.
  Date: 2026-09-12

- Decision (supersedes answer 4 above): keep the **empty passphrase** for the `tan-nb-exp` stack; do
  not rotate the secrets provider.
  Rationale: the operator judged the rotation steps not worth it for this cluster (2026-09-12T23:10Z).
  Consequence accepted: the 18 secret-marked state values are effectively plaintext to anyone who
  can read the state bucket, which is private, uniform-access, public-access-prevented, and inside
  `tan-nb-exp`. The tooling fixes from `9cc4764` remain, so a future rotation works.
  Date: 2026-09-12

- Decision: Scope the recipient grep gate to exclude `docs/plans/`, and leave historical ExecPlans
  that quote the operator's recipients unchanged. Replace the host secret with a sops file encrypted
  to a throwaway example key rather than deleting it.
  Rationale: ExecPlans are durable records, and recipients are public keys. The NixOS evaluation
  fixture needs a real sops file declaring `tailscale/authkey`, so a discarded-key example keeps
  `nix flake check ./nixos` meaningful.
  Date: 2026-09-12

- Decision: The private repository keeps `.sops.yaml` at its root rather than `sops/.sops.yaml`, and
  cluster secrets under `cluster-secrets/tan-nb-exp/`, wired to
  `~/.config/nagare/cluster-secrets/tan-nb-exp` (already honored by `scripts/lib/cluster-secrets.sh`).
  Rationale: sops finds the nearest `.sops.yaml` above the working directory; the per-context
  cluster secrets path needs no code change.
  Date: 2026-09-12

## Outcomes & Retrospective

Completed 2026-09-13. The purpose holds: a private `shinzui/nagare-ops` repository plus the public
repository and gcloud credentials operate `tan-nb-exp` from a clean checkout. Pulumi state lives in a
versioned GCS bucket, and the public repository ships no operator secret or recipient. All three
acceptance observations were made in Milestone 4: a no-change preview against GCS, a host flake
resolved from the private repository, and an empty recipient grep outside historical plans.

The move surfaced three latent tooling defects that would have bitten any operator:

- Pulumi passphrase handling made a real passphrase unusable. An empty variable was forced
  everywhere, and `nagarectl` truncated the passphrase file.
- Two context writers turned a symlinked context into a detached regular file.
- The ADR 9 bucket-ownership guard refused every bucket on current gcloud.

All three are fixed with tests (`9cc4764`, `ed238ba`). The operator chose to keep the empty
passphrase for this cluster.

Lessons:

- Stale shell environments silently override context files, which nearly produced a false
  "migrated" gate.
- Rehearse gates from a scrubbed environment.
- A guard refusal that turns out to be a tooling bug is still reported before re-running.

Durable context is recorded in
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md).

Not done:

- Removing `.claude/hooks/guard_host_mutation.py`, which the operator asked for, was blocked by the
  harness safety classifier and remains in place.
- The old local state and backups await operator confirmation before deletion.
- The 8 `AppDeploySpec` failures (duplicate `nagare-dsl` package registration) predate this plan.

