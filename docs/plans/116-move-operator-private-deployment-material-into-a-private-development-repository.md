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
- [ ] Milestone 2 remaining: rebuild `result/bin/nagarectl`; operator saves a new passphrase in the password manager, runs `stack change-secrets-provider` interactively, writes the passphrase file; verify decrypt with the file and failure with an empty passphrase; commit the new salt to `nagare-ops`.
- [ ] Milestone 2: migrate Pulumi state to the chosen backend with `scripts/migrate-pulumi-backend.sh`; gate on a clean `pulumi preview --refresh`.
- [ ] Milestone 3: remove operator-private tracked files from the public repository, replacing them with examples; update documentation.
- [ ] Milestone 4: prove the setup from a clean second checkout; write Outcomes and ADR.


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

- Decision: The private repository keeps `.sops.yaml` at its root rather than `sops/.sops.yaml`, and
  cluster secrets under `cluster-secrets/tan-nb-exp/`, wired to
  `~/.config/nagare/cluster-secrets/tan-nb-exp` (already honored by `scripts/lib/cluster-secrets.sh`).
  Rationale: sops finds the nearest `.sops.yaml` above the working directory; the per-context
  cluster secrets path needs no code change.
  Date: 2026-09-12


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Nagare is a single-node personal platform-as-a-service. One Google Compute Engine VM, `nagare-01`,
runs NixOS and k3s in Google Cloud project `tan-nb-exp`, zone `us-west1-a`. Pulumi, a TypeScript
infrastructure-as-code tool in `infra/pulumi/`, manages the cloud resources. NixOS host
configuration is built from a **context-owned host flake** that `nagarectl host init` generates.

A **context** is a file of `export VAR=value` lines at
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`. The pointer
`~/.config/nagare/current-context` selects the active one. `scripts/lib/target.sh` resolves it and
exports the project, zone, and derived names, plus `PULUMI_BACKEND_URL` and `PULUMI_HOME`. The
backend defaults to a per-context local file backend at
`~/.local/state/nagare/<context>/state`. A cloud context may set `NAGARE_PULUMI_BACKEND=gcs`
instead (`scripts/lib/target.sh`, the "EP-93" block). The repository's `CLAUDE.md` requires every
cloud command to act only on the active context's project, and it requires human approval for
each cloud-mutating command.

**sops** encrypts YAML files so that only holders of listed **age** private keys can decrypt them.
The encrypted file can be committed; the public "recipient" keys that may decrypt each path are
listed in `.sops.yaml` files. **Pulumi state** is the JSON record of every managed resource. With
the file backend it is a directory of JSON files, and resource outputs in it are plaintext unless
marked secret.

### Inventory of operator-private material (2026-09-12, names only)

Outside the repository, on the operator's workstation:

- `~/.config/nagare/contexts/tan-nb-exp.env` — the context (project, zone, bucket names, domain, instance name).
- `~/.config/nagare/current-context` — the pointer (`tan-nb-exp`).
- `~/.config/nagare/hosts/tan-nb-exp/` — generated host flake: `flake.nix`, `flake.lock`, `host.nix` (operator SSH public key), `secrets.yaml` (sops-encrypted host secrets).
- `~/.config/nagare/nagare-01-age-key.txt` — an age **private** key (see Surprises). This must never enter any git repository, private or not.
- `~/.local/state/nagare/tan-nb-exp/state` — Pulumi file-backend state for stack `tan-nb-exp` (22 resources in state, 31 in previews).
- `~/.local/state/nagare/tan-nb-exp/home/` — `PULUMI_HOME`, including the empty `passphrase` file.
- `~/.local/state/nagare/tan-nb-exp/legacy-in-repo-state-20260912T174602Z` — archive of the pre-migration in-repo state (stack `dev`) and old `Pulumi.dev.yaml`.
- `~/.local/state/nagare/default/` — state for a `default` context; inspect it and ask the operator whether it is live.
- `~/.config/sops/age/keys.txt` — the workstation age private key (named in `.sops.yaml`); stays only on the workstation.

Inside this repository, git-ignored (not published, but in the working tree):

- `infra/pulumi/Pulumi.tan-nb-exp.yaml` — stack config, including `nagare:bootDiskType: pd-standard`, the pinned `nagare:nagareImageSelfLink`, `nagare:dataDiskSizeGb: "110"`, and the `encryptionsalt`.
- `infra/pulumi/Pulumi.{acme-demo,default,prod,ep90-*}.yaml` — leftover stack configs from earlier plans; probably disposable, confirm with the operator.
- `nagare.local.env` — a local-mode profile (lower precedence than contexts).

Tracked in this public repository (published):

- `nixos/hosts/nagare-01/secrets/nagare-01.yaml` — sops-encrypted host secrets for the operator's host.
- `cluster/secrets/grafana-admin.yaml`, `cluster/secrets/notes-db-url.yaml` — sops-encrypted cluster secrets for the operator's cluster.
- `.sops.yaml` and `nixos/.sops.yaml` — the operator's workstation and host **age recipients** (public keys). They are not secret, but they are operator-specific.
- Documentation naming `tan-nb-exp`: 60 matching lines under `docs/user/`, many of them deliberate "default example" text (see `CLAUDE.md`). Classify each; do not blanket-replace.

### Relevant ADRs

[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) and
[ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md) establish that
operator inputs live in context-owned workspaces and generated host flakes, outside the platform
payload. This plan extends that separation from "outside the payload" to "outside the public
repository, in a versioned private one".
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) requires
every cloud-mutating path to assert the active context's project; the state migration in
Milestone 2 runs through such a path.
[ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md) governs any host switch done
while proving Milestone 4 (only `just host-switch`).


## Plan of Work

### Milestone 0 — Confirm the inventory and the decisions

Changes nothing. Re-run the read-only inventory commands in Concrete Steps and update the inventory
above with anything new, recording only file names, sizes, and modes. Check whether
`~/.config/nagare/nagare-01-age-key.txt` is the host key by deriving its public key with
`age-keygen -y` and comparing it with the host recipient in `nixos/.sops.yaml`. Print only the
public key. Then ask the operator, and record the answers in the Decision Log: the private
repository's name and that it is **private**; whether they accept the `gcs` backend decision or
still want state inside the repository (if so, stop and revise this plan's Decision Log before
continuing); and which tracked files (the three encrypted secret files and the two `.sops.yaml`
files) leave the public repository. Gate: all three answers are recorded.

### Milestone 1 — Create and populate the private repository

Only after Milestone 0's confirmation, create the repository with `gh repo create <name> --private`
and clone it to a sibling directory, for example `/Users/shinzui/Keikaku/bokuno/nagare-ops`. Lay it
out as `contexts/tan-nb-exp.env`, `hosts/tan-nb-exp/` (the whole generated flake),
`pulumi/Pulumi.tan-nb-exp.yaml`, `sops/.sops.yaml` (recipients for its own secret paths), and
`cluster-secrets/` (the two encrypted cluster secrets). Add a `.gitignore` that refuses `*age-key*`,
`keys.txt`, `passphrase`, and `.pulumi/`. Add a `README.md` that explains how to wire it up on a new
machine. Then point Nagare at it: replace `~/.config/nagare/contexts/tan-nb-exp.env` and
`~/.config/nagare/hosts/tan-nb-exp` with symlinks into the clone, and replace
`infra/pulumi/Pulumi.tan-nb-exp.yaml` with a symlink as well. Keep dated backups of the originals
under `~/.local/state/nagare/tan-nb-exp/pre-private-repo-<timestamp>/`. Gate:
`nagarectl context current` prints `tan-nb-exp`; `scripts/host-switch.sh --dry-run` prints
`host flake: /Users/shinzui/.config/nagare/hosts/tan-nb-exp`, which resolves into the clone; and
`pulumi preview` (local backend, still unchanged) reports no changes. Commit and push only after the
operator confirms the staged file list (`git -C <clone> status`).

### Milestone 2 — Move Pulumi state to the chosen backend and fix its secrets

First, rotate the stack's secrets provider away from the empty passphrase. Use
`pulumi stack change-secrets-provider` with a non-empty passphrase stored outside every repository,
for example in the operator's password manager and exported as `PULUMI_CONFIG_PASSPHRASE`, or
with a Google Cloud KMS key (`gcpkms://...`). Choosing a KMS key creates a cloud resource and needs
approval. Then set `NAGARE_PULUMI_BACKEND=gcs` in the private context file and run
`scripts/migrate-pulumi-backend.sh --context tan-nb-exp`. It exports a rollback artifact, creates the
versioned state bucket, imports, verifies outputs, and flips the context only on a match. Gate:
`pulumi preview --refresh` for `tan-nb-exp` reports `31 unchanged` (or the current count) against
the GCS backend. Keep the local `state/` directory until Milestone 4 passes.

### Milestone 3 — Remove operator material from the public repository

Move `nixos/hosts/nagare-01/secrets/nagare-01.yaml` and `cluster/secrets/*.yaml` into the private
repository (already copied in Milestone 1). Replace them in the public repository with clearly
labeled examples, or remove them where nothing public reads them: `grep -rn` for each path first,
and fix every reader, including `nagarectl host init --sops-file` defaults and any `just` recipe.
Replace the operator's recipients in `.sops.yaml` and `nixos/.sops.yaml` with documented
placeholders, keeping the file shape. Classify each `tan-nb-exp` mention in `docs/user/`: keep
"default example" wording, and change anything that instructs an operator to target that specific
project. Note in the Decision Log that git **history** still contains these files. Recipients and
encrypted blobs are not secret by design, but if any host secret must be treated as exposed,
rotate it (that is a follow-up plan, not a history rewrite). Gate: `just docs-validate` passes,
`nix flake check` for `nixos/` still evaluates, and `git grep -n 'age1rc26869\|age1pqfv2y3'`
returns nothing.

### Milestone 4 — Prove it from a clean checkout

In a scratch directory, clone both repositories fresh. Wire the symlinks as the private `README.md`
says, with `XDG_CONFIG_HOME` pointed at a scratch config root so the real one is untouched. Run the
target check, `pulumi preview --refresh`, and `scripts/host-switch.sh --dry-run`. Gate: the preview
shows no changes against GCS, and the dry run resolves the scratch host flake. Then delete the local
file-backend `state/` only with operator confirmation, write Outcomes & Retrospective, and add an
ADR recording that operator deployment material lives in a private repository with remote state.


## Concrete Steps

Working directory `/Users/shinzui/Keikaku/bokuno/nagare` unless stated. Every cloud command begins
with the target check:

```bash
source scripts/lib/target.sh
test "$CLOUDSDK_CORE_PROJECT" = tan-nb-exp && test "$NAGARE_MODE" = cloud || { echo "WRONG TARGET"; exit 1; }
```

Milestone 0 inventory, read-only, names and sizes only:

```bash
ls -la ~/.config/nagare ~/.config/nagare/contexts ~/.config/nagare/hosts/tan-nb-exp
ls -la ~/.local/state/nagare ~/.local/state/nagare/*/
ls -la infra/pulumi/Pulumi.*.yaml nagare.local.env
git ls-files | grep -E 'secrets/|\.sops\.yaml$'
git grep -n 'tan-nb-exp' -- docs/user | wc -l
age-keygen -y ~/.config/nagare/nagare-01-age-key.txt      # prints the PUBLIC key only
grep -n age1 nixos/.sops.yaml
```

Milestone 1, after confirmation:

```bash
gh repo create shinzui/nagare-ops --private --description "Operator deployment material for Nagare (private)"
git clone git@github.com:shinzui/nagare-ops.git /Users/shinzui/Keikaku/bokuno/nagare-ops
```

Milestone 2:

```bash
source scripts/lib/target.sh
test "$CLOUDSDK_CORE_PROJECT" = tan-nb-exp && test "$NAGARE_MODE" = cloud || { echo "WRONG TARGET"; exit 1; }
pulumi -C infra/pulumi stack change-secrets-provider passphrase --stack "$NAGARE_CONTEXT"
nagarectl init --dry-run --pulumi-backend gcs     # review the bucket commands first
scripts/migrate-pulumi-backend.sh --context tan-nb-exp
pulumi -C infra/pulumi preview --refresh --stack "$NAGARE_CONTEXT" 2>&1 | tail -4
```

Commit public-repository changes with Conventional Commits, staging by explicit path, with the
trailers `ExecPlan: docs/plans/116-move-operator-private-deployment-material-into-a-private-development-repository.md`
and `Intention: intention_01m2av9m0ge8sbwjy4arw5svf9`.


## Validation and Acceptance

From a fresh clone of both repositories with a scratch `XDG_CONFIG_HOME`:
`pulumi preview --refresh --stack tan-nb-exp` reports only `unchanged` resources against the GCS
backend, and `scripts/host-switch.sh --dry-run` prints a host flake that resolves inside the private
clone. In the public repository, `git grep -n 'age1rc26869\|age1pqfv2y3'` prints nothing,
`git ls-files | grep -E '^(cluster/secrets|nixos/hosts/nagare-01/secrets)/'` lists only example
files, and `just docs-validate` passes. The private repository is private
(`gh repo view shinzui/nagare-ops --json visibility` prints `PRIVATE`) and contains no private key,
no passphrase, and no `.pulumi/` state.


## Idempotence and Recovery

Milestone 0 is read-only. In Milestone 1, symlink replacement keeps dated backups; restore by
moving them back. The migration script writes a rollback artifact, and
`scripts/migrate-pulumi-backend.sh --rollback --context tan-nb-exp` returns to the local backend
without deleting the bucket. The local `state/` directory is kept until Milestone 4 passes.
Changing the secrets provider is recoverable only with the new passphrase or KMS key, so store it
before running the command. Milestone 3 is ordinary git changes that can be reverted. Nothing in
this plan touches the host or rewrites git history.


## Interfaces and Dependencies

Tools: `gh` (repository creation), `git`, `pulumi` (secrets provider change and backend),
`scripts/migrate-pulumi-backend.sh`, `nagarectl` (context and host path resolution), `sops` and
`age-keygen` (recipient verification only), `okf` via `just docs-validate`. Files: the private
repository layout from Milestone 1; `scripts/lib/target.sh` (read-only; resolution already
supports `gcs`); `.sops.yaml`, `nixos/.sops.yaml`, `nixos/hosts/nagare-01/secrets/nagare-01.yaml`,
and `cluster/secrets/*.yaml` in the public repository. Cloud resources, in project `tan-nb-exp` only:
the Pulumi state bucket `tan-nb-exp-nagare-pulumi-state` (created by the migration) and, if chosen,
a KMS key for the secrets provider.
