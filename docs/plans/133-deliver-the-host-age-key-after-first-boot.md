---
id: 133
slug: deliver-the-host-age-key-after-first-boot
title: "Deliver the host age key after first boot"
kind: exec-plan
created_at: 2026-09-14T03:44:11Z
intention: "intention_01m2ezxphwejxtj51bbm5cy63r"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T03:44:11Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T18:02:13Z
      mode: "implement"
      note: "Implemented the post-boot host age-key delivery plan"
---

# Deliver the host age key after first boot

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [133-deliver-the-host-age-key-after-first-boot.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/133-deliver-the-host-age-key-after-first-boot.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this change, an operator can create a cloud VM from a secret-free Nagare image, then run one
documented command to stream that context's age private key over Identity-Aware Proxy (IAP) SSH.
Nagare installs the key as root with mode `0400`, re-runs sops-nix decryption, and starts the existing
Tailscale autoconnect unit without exposing the key in an argument, log, repository, image, or
temporary file. IAP is Google Cloud's authenticated TCP tunnel and is available before the host has
joined the private Tailscale network.

The operator can see the result in three ways. `nagarectl host place-age-key --context prod
--key-file /secure/path/prod-host-age-key.txt` reports a verified checksum and successful secret
activation; `nagarectl --context prod server status` and `nagarectl --context prod doctor` report the
host age key as ready; and `/run/secrets/tailscale/authkey` exists while the host joins the tailnet.
A NixOS virtual-machine test proves the complete missing-key-to-decrypted-secret transition without
touching a real cloud project.

## Progress

- [x] (2026-09-14T18:02Z) Milestone 1 implementation: made host secret activation retryable, added
  the host-side age-key helper and Tailscale pre-start guard, and added the missing-to-ready NixOS
  VM test.
- [x] (2026-09-14T18:03Z) Milestone 1 evaluation: `nix flake check ./nixos --no-build
  --all-systems` reached the new check, and its focused derivation evaluated successfully after
  fixing Nix-string escaping and disabling only the test's evaluation-time ciphertext check.
- [x] (2026-09-14T18:36Z) Milestone 1 runtime validation: the focused
  `host-age-key-delivery` VM check passed on the configured x86_64-linux builder. Its log proves
  secretless boot fails with `age key missing`, placement verifies root:root 0400 and the exact
  checksum, sops decrypts the runtime-generated canary, Tailscale autoconnect recovers, and neither
  secret reaches the journal or serial console. It also proves same-key placement does not rewrite
  the key and a different key is refused before changing the installed digest.
- [x] (2026-09-14T18:13Z) Milestone 2: added retry-safe `send-file` stdin streaming to the IAP
  helper and exposed `nagarectl host place-age-key` with exact-byte local validation, explicit
  child-context confinement, checksum construction, local-mode refusal, `--force`, packaged-payload
  assertions, and fake-transport secrecy coverage. All 523 Haskell tests passed and
  `cabal build exe:nagarectl` succeeded.
- [x] (2026-09-14T18:19Z) Milestone 3: combined the host age-key status record and both `df`
  observations into one IAP call; confirmed missing/invalid states grade `FAIL`, ready grades `OK`,
  and unsupported, malformed, skipped, or unreachable observations remain `UNKNOWN`. Doctor now
  prints the exact placement remedy and only confirmed failure changes its exit grade. All 527
  Haskell tests passed.
- [x] (2026-09-14T18:27Z) Milestone 4 documentation and durable context: rewrote onboarding and
  secret recovery around the intentional secretless first boot and explicit IAP handoff; updated
  the host-image, Pulumi, reference, and changelog surfaces; synchronized the user-documentation
  log; and amended ADR 5 with the no-copy, context-confined, idempotence, and forced-rotation
  boundaries. ADR 11 remains unchanged because no NixOS generation is activated.
- [x] (2026-09-14T18:46Z) Milestone 4 validation and closure: all 527 focused Haskell tests, all 25
  declared native root-flake checks, and three app-validity checks passed; the Haskell style,
  operator-package, platform-asset,
  documentation, 23-concept improvement-request, nested-flake evaluation, shell syntax, diff
  hygiene, secret-marker, and focused VM gates passed. Completed IR-18 and synchronized its OKF log
  as the final durable content update.

## Surprises & Discoveries

- Observation: the pinned sops-nix module can install regular secrets through
  `sops-install-secrets.service`, but Nagare does not set `sops.useSystemdActivation`; depending on
  the NixOS user-management mode, decryption can therefore remain an activation script with no
  service to restart after a post-boot key handoff.
  Evidence: `nixos/modules/nagare-host.nix` currently sets only `sops.defaultSopsFile`,
  `sops.age.keyFile`, and the Tailscale secret. The pinned sops-nix revision
  `c591bf665727040c6cc5cb409079acb22dcce33c` in `nixos/flake.lock` exposes
  `sops.useSystemdActivation` and the `sops-install-secrets` oneshot.

- Observation: the pinned nixpkgs Tailscale unit interpolates `cat <authKeyFile>` directly into
  `tailscale up --auth-key`. A missing decrypted file therefore still invokes `tailscale up` with
  an empty key, which explains the interactive login URL in IR-18.
  Evidence: the nixpkgs revision `eaad089433ca2bb662274377d33df3d0e51ef28b` in
  `nixos/flake.lock` defines that script, and `nixos/hosts/nagare-01/tailscale.nix` supplies
  `config.sops.secrets."tailscale/authkey".path` as `authKeyFile` without a pre-start guard.

- Observation: the existing IAP wrapper retries a command after transport failures, but a generic
  command consuming inherited stdin cannot replay bytes already consumed by a failed attempt.
  Evidence: `scripts/iap-ssh.sh` implements retry around `_do_ssh`; its `recv-file` operation
  deliberately reopens/truncates its destination for each attempt. Sending a key needs the symmetric
  source-file operation so each retry reopens the operator's key file without staging a copy.

- Observation: the focused NixOS VM derivation evaluates on the aarch64-darwin workstation, but its
  runtime proof requires the configured x86_64-linux remote builder, which was unreachable during
  the first validation attempt.
  Evidence: `nix build ./nixos#checks.x86_64-linux.host-age-key-delivery --print-build-logs`
  reported `socat ... localhost:24668: Connection refused` and then `Failed to find a machine for
  remote build`; the failure occurred before the test derivation ran.

- Observation: the plan's root-working-directory Cabal commands do not resolve this repository's
  package layout because `cabal.project` lives under `cli/nagarectl/` and refers to its sibling
  `../nagare-dsl` relative to that directory.
  Evidence: the literal command reported `No cabal.project file`; passing only `--project-file`
  from the root then resolved the sibling relative to the wrong directory. Running `nix develop
  ../.. -c cabal ...` from `cli/nagarectl/` built the suite, where all 523 tests passed.

- Observation: an additional `cabal test all` experiment is not a supported substitute for the
  plan's focused command in this multi-package project: its concurrently built nagare-dsl suite
  could not expose the config-as-program packages to its fixture subprocesses and reported 14
  module-resolution failures.
  Evidence: the required `cabal test nagarectl-test` command passed all 527 tests, the root flake's
  `examples-compile` and `nagare-dsl-build-test` checks passed, and this plan changes neither the
  nagare-dsl package nor its test harness.

- Observation: the first executable VM run exposed two assumptions in the new test harness before
  the production lifecycle completed: Nix indented strings preserve ordinary backslashes, and the
  pinned Tailscale autoconnect unit is `Type=notify`.
  Evidence: the first assertion searched for literal `\t` characters despite receiving the correct
  tab-delimited status record. After fixing that, the plain test `ExecStart` completed but systemd
  reported `protocol`; evaluating the pinned unit showed `Type = "notify"`. The hermetic stub now
  overrides the type to `oneshot` with `RemainAfterExit`, while the real module leaves the upstream
  notification behavior intact. The subsequent focused VM build passed.

## Decision Log

- Decision: implement the supported post-boot placement option requested by IR-18, using the existing
  IAP SSH transport, rather than introducing Secret Manager delivery at boot.
  Rationale: the image already contains the operator's public SSH key and IAP is deliberately the
  break-glass path before Tailscale works. This keeps the private key in operator custody, adds no
  project IAM or secret-resource lifecycle, and addresses the contradictory “before first boot but
  not in the image” documentation directly.
  Date: 2026-09-14.

- Decision: put installation, metadata checks, sops reactivation, and Tailscale restart in one
  host-side `nagare-host-age-key` helper generated by the NixOS module.
  Rationale: the host module knows the configured `nagare.host.ageKeyFile` even when it is not the
  default path. The same helper gives the CLI, status probe, and VM test one behavior instead of
  duplicating a hard-coded path on the workstation.
  Date: 2026-09-14.

- Decision: stream the key body directly from the operator's source file to the final configured
  host path. Reopen the source file for each IAP retry; never put the body in argv, stdout, stderr,
  an environment variable, an image, a repository, or a local/remote staging file.
  Rationale: this is IR-18's requested confidentiality boundary. Direct final-path installation is
  not atomic, so first placement is the normal path, a matching key is an idempotent no-op, and
  replacement of a different existing key requires `--force` plus an explicit interruption warning.
  Date: 2026-09-14.

- Decision: make `sops-install-secrets.service` the retryable activation boundary, order the
  Tailscale autoconnect unit after it, and add a pre-start check that prints `age key missing` before
  the upstream script can call interactive `tailscale up`.
  Rationale: restarting a well-defined oneshot is narrower and more observable than rebooting or
  running a full NixOS activation. An `After=` relationship preserves the Tailscale unit's own
  explicit failure message even when sops decryption failed; a hard `Requires=` would skip the
  Tailscale process and hide that message behind “dependency failed.”
  Date: 2026-09-14.

- Decision: extend the existing `nagarectl server status` inventory and `doctor` remediation rather
  than adding host-secret state to `nagarectl platform status`.
  Rationale: platform status compares release identities, while server status already performs one
  best-effort IAP host probe for disk health. Age-key readiness is operational host health and can be
  collected in the same SSH round trip without changing the release-compatibility JSON contract.
  Date: 2026-09-14.

- Decision: amend local ADR 5 during implementation; do not create a new ADR or amend ADR 11 unless
  implementation changes the guarded NixOS-generation activation boundary.
  Rationale: ADR 5 owns context-specific host inputs and currently says `host init` records only the
  age-key path. It is the durable home for the separate, explicit private-key handoff. Restarting
  secret and Tailscale units does not activate a NixOS generation and therefore does not weaken ADR
  11's guarded-switch rule.
  Date: 2026-09-14.

- Decision: accept IR-18 and point it to this plan at plan creation; change it to completed only when
  the implementation and verification in this plan are complete.
  Rationale: the bidirectional link establishes ownership without claiming that the defect is fixed.
  Date: 2026-09-14.

- Decision: require `nagare.host.ageKeyFile` to be an absolute path without tabs or newlines, and
  refuse to replace a symlink or other non-regular object even with `--force`.
  Rationale: the configured path is embedded in a root-running helper and serialized in a
  tab-delimited status protocol. Constraining its shape keeps that protocol unambiguous, while
  refusing non-regular targets prevents the explicit rotation escape hatch from following a
  link or recursively displacing a directory.
  Date: 2026-09-14.

## Outcomes & Retrospective

The supported post-boot handoff is complete. A new cloud host can boot from a secret-free image,
fail Tailscale autoconnect immediately with an actionable `age key missing` diagnostic, accept the
context-selected private identity only through retried IAP SSH stdin, verify its exact SHA-256 and
root:root 0400 metadata, rerun sops decryption, and recover Tailscale autoconnect without rebooting.
Matching placement is retry-safe; replacement requires explicit `--force` and retains the documented
interruption boundary. Server status and doctor distinguish confirmed missing/invalid state from an
unsupported or unreachable probe.

The focused x86_64-linux VM check is the strongest result: it generated both the age identity and a
random secret inside the disposable guest, observed the secretless failure, exercised the installed
host helper, compared the decrypted secret byte-for-byte, observed successful autoconnect, and
preserved the key mtime on same-key re-placement while rejecting a different key before its digest
changed. It also proved neither secret appeared in the journal or serial console. The final
validation set comprised
527 focused Haskell tests, 25 declared native root-flake checks plus three app-validity checks, all
eight nested NixOS checks at evaluation, the focused runtime VM check,
Haskell/Fourmolu/Cabal formatting, both changed operator package
checks, shell syntax, documentation bundles (37 user concepts and 2 guides), and all 23 improvement
requests.

Two implementation lessons are durable. A secret-bearing retry wrapper must own and reopen the
source file rather than inherit already-consumed stdin. A hermetic systemd test replacement must
also model the original unit protocol deliberately: the production autoconnect unit remains
`Type=notify`, while the no-network test stub is explicitly a retained `oneshot`. No real context or
host was mutated during validation. IR-18 is completed, ADR 5 records the handoff boundary, and ADR
11 remains unchanged because the workflow activates services rather than a NixOS generation.

