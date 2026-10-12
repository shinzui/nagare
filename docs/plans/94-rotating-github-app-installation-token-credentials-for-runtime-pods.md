---
id: 94
slug: rotating-github-app-installation-token-credentials-for-runtime-pods
title: "Rotating GitHub App installation-token credentials for runtime pods"
kind: exec-plan
created_at: 2026-07-14T19:28:25Z
intention: "intention_01kx3qz212e989078m6ssetr2b"
master_plan: "docs/masterplans/18-platform-prerequisites-for-the-agent-content-plane-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache.md"
---

# Rotating GitHub App installation-token credentials for runtime pods

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [94-rotating-github-app-installation-token-credentials-for-runtime-pods.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/94-rotating-github-app-installation-token-credentials-for-runtime-pods.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare will provide an optional host capability and reusable operator playbook that publish two
stable, role-named Kubernetes Secrets: `nagare-forge-read` and `nagare-forge-write`. Their values
are short-lived installation tokens for two operator-owned GitHub Apps. In this plan, a GitHub App
is a GitHub-managed machine identity, similar to a service account: it has its own name, private
key, permission ceiling, and repository access, but it is not an application binary, Pod, GitHub
Action, OAuth login, or webhook service. The tokens are minted on the Nagare host and replaced every
thirty minutes. A runtime workload selects a role name and receives `GITHUB_TOKEN`; it does not know
an App ID, installation ID, private key, or a user's personal access token.

The capability is disabled by default, so a Nagare user who does not need GitHub credentials has no
forge-specific secret or service requirements. An operator opts in from their context-owned host
configuration, chooses the Kubernetes namespace, provisions their own GitHub registrations and
repository boundaries, and stores bootstrap material in that context's encrypted sops file. Nagare
does not own or prescribe a maintainer account's live registrations.

An operator can see the feature working by checking the timer state, observing that a Secret's value
changes after a forced refresh, using the read token to fetch an allowed repository, and observing
that the same token cannot write. A reboot and NixOS rebuild must restore the refreshers without
re-entering a live token. The repository proves the disabled and enabled module shapes hermetically;
each opt-in deployment owns its live GitHub acceptance evidence.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-26T00:15:00Z) During the initial maintainer-specific interpretation, register
  a private, webhook-disabled read App under `@shinzui`; it remains uninstalled and keyless and is
  not part of the Nagare product interface.
- [x] (2026-08-26T00:24:00Z) During the same interpretation, register a private,
  webhook-disabled write App under `@shinzui`; it also remains uninstalled and keyless and is not
  part of the product interface.
- [x] (2026-08-26T00:45:00Z) The operator chose to retain both `@shinzui` registrations for a
  future personal opt-in deployment. They remain operator-owned external state and may supply the
  first context-specific live acceptance run.
- [x] (2026-08-26T00:28:00Z) Correct the product boundary: make forge credentials an opt-in
  `nagare.host.forgeCredentials` capability, disabled by default, with a configurable namespace.
- [x] (2026-08-26T00:28:00Z) Convert `docs/user/forge-credentials.md` from a record of one
  maintainer deployment into a reusable provisioning, acceptance, rotation, recovery, and disablement
  playbook whose live state belongs to each operator's context.
- [x] (2026-08-25T22:54:04Z) Declare the six sops-nix paths only when the capability is enabled and
  import the forge refresher from the reusable `nagare-host` module.
- [x] (2026-08-25T23:18:00Z) Implement independent systemd services and timers, atomic
  role-named Secret publication, sanitized failure handling, and focused success/malformed/
  non-2xx preservation tests.
- [x] (2026-08-25T23:26:00Z) Document workload consumption, inspection, rotation, failure
  behavior, least-privilege probes, and App-key recovery in
  `docs/user/forge-credentials.md` and link it from the operator guide.
- [x] (2026-08-25T23:52:00Z) Pass focused ShellCheck, NixOS option evaluation,
  `git diff --check`, and the complete compatible-system `nix flake check` (all ten
  aarch64-darwin checks passed).
- [x] (2026-08-26T00:30:00Z) Add and evaluate the nested-flake option-boundary check: default
  configuration has no forge units or sops paths; enabled configuration has the chosen namespace,
  both timers, and exactly six mode-`0400` sops paths. Re-run the focused refresher test,
  `git diff --check`, and the aggregate root `nix flake check`; all thirteen compatible
  aarch64-darwin checks passed, including ShellCheck.
- [x] (2026-08-26T01:06:00Z) Build the x86_64-linux option-boundary derivation and full
  `nagare-01` NixOS toplevel successfully on `nix-builder-x86`. The managed
  `nix-gcp-builder` ProxyCommand still timed out during SSH banner exchange, so validation used a
  direct local-port IAP tunnel and pinned the scanned ED25519 host key in the temporary Nix builder
  URI. Both builds completed and the tunnel was stopped afterward.
- [ ] Record live registration, read, denial, rotation, failure-preservation, journal, and reboot
  evidence in the first operator context that opts in; this evidence is context-owned rather than a
  prerequisite that forces every Nagare maintainer or user to provision GitHub state.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: The locked Nixpkgs package set contains
  `haskellPackages.github-app-token` 0.0.3.0, but it is a Haskell library rather than an
  executable. Its public exception values retain failed HTTP response bodies, and its
  invalid-key exception retains the supplied private key, so an unhandled exception can
  violate this plan's requirement that journals never contain response or key material.
  The latest upstream tag is also 0.0.3.0, dated 2024-09-26. It is therefore not a
  drop-in host utility.

- Discovery: GitHub's maintained `@octokit/auth-app` package can generate installation
  tokens and currently handles JWT clock skew, but using it here would still require a
  Nagare-owned Node wrapper, a locked npm dependency graph, and a Node runtime. There is
  no existing Nagare package or Nixpkgs command-line executable that removes the need for
  a local wrapper.

- Discovery: ExecPlan 107 externalized operator NixOS inputs after this plan was drafted.
  The checked-in `nixos/hosts/nagare-01/configuration.nix` and encrypted YAML are now
  compatibility fixtures; live secrets belong to the context-owned host flake described by
  `docs/adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md`. The reusable
  behavior must therefore be imported by `nixos/modules/nagare-host.nix`.

- Discovery: The repository root flake has no `nixosConfigurations` output and no
  `formatter.aarch64-darwin`. The source-tree validation is
  `nix build ./nixos#nixosConfigurations.nagare-01.config.system.build.toplevel`, with
  `nixpkgs-fmt` for the Nix files on this workstation. Initial attempts were blocked because the
  configured `nix-gcp-builder` SSH ProxyCommand closed or timed out during banner exchange.

- Discovery: After GCP reauthentication, `nix-builder-x86` was running and a direct
  `gcloud compute start-iap-tunnel --local-host-port` connection reached SSH successfully, while
  the managed `--listen-on-stdin` ProxyCommand still timed out. Nix's
  `base64-ssh-public-host-key` store setting expects the base64 encoding of the complete
  `ssh-ed25519 <key-body>` public-key text, not merely the already-base64 key body returned by
  `ssh-keyscan`. Using that encoding in a temporary direct-tunnel builder URI allowed both the
  focused check and the 98-derivation NixOS toplevel build to complete.

- Discovery: `SecretName` is an abstract public type in `nagare-dsl`; its data constructor
  is not exported. The operator example therefore validates `nagare-forge-read` with
  `mkSecretName` before constructing `EnvSecretRef`, rather than using the plan's earlier
  constructor shorthand.

- Discovery: The workstation has only a legacy local Nagare target; `nagarectl context list`
  reports no named `prod` context, `nagarectl --context prod host path` reports that
  `prod.env` is absent, and `nagare-01` does not resolve over SSH. The current kubectl context
  is `k3d-nagare-local`. Consequently there is no operator-owned production host flake into
  which this session can encrypt bootstrap material and no live host on which it can switch or
  reboot the timers.

- Discovery: GitHub sudo mode required the operator to reauthenticate before registration.
  After reauthentication both App registrations succeeded with their intended effective
  permission matrices. Key generation and installation remain deliberately deferred because
  there is no production sops context in which to encrypt a downloaded private key and no
  explicit selected-repository boundary.

- Discovery: The initial implementation confused reference-deployment state with the Nagare
  product boundary. Importing the module unconditionally caused every generated Nagare host to
  declare six GitHub sops keys and two timers, while the user guide embedded `@shinzui` App slugs.
  A user correctly challenged that scope. The reusable capability must be disabled by default,
  and registration records, selected repositories, encrypted values, and live evidence must
  belong to the operator context that opts in.

## Decision Log

Record every decision made while working on the plan.

- Decision: Use two GitHub Apps, one read-only and one write-capable, rather than one App
  whose token permissions vary per request.
  Rationale: Installation boundaries are the strongest control. The write App can be
  installed only on the small set of repositories it may mutate, while the read App can
  cover the portfolio without ever receiving write permission.
  Date: 2026-07-14

- Decision: Keep App private keys in the existing host sops-nix file and mint tokens on
  the host.
  Rationale: The host already has an age identity and a root kubeconfig. This adds no
  in-cluster controller holding long-lived forge credentials and follows the existing
  `nixos/hosts/nagare-01/registries.nix` timer pattern.
  Date: 2026-07-14

- Decision: Refresh each role independently every thirty minutes and leave the previous
  Secret untouched on any mint failure.
  Rationale: Installation tokens last one hour. A thirty-minute cadence leaves a full
  retry window, and per-role units stop an outage or configuration error in one App from
  suppressing the other.
  Date: 2026-07-14

- Decision: Publish both `token` and `GITHUB_TOKEN` keys with the same value.
  Rationale: Kikan's provider acceptance reads a conventional `token` key, while
  `nagare-dsl`'s `EnvSecretRef` maps an environment variable to a same-named Secret key.
  Supplying both avoids teaching either consumer a provider-specific exception.
  Date: 2026-07-14

- Decision: Use the role names `nagare-forge-read` and `nagare-forge-write` and do not
  include Mori in the names.
  Rationale: The credential is a platform capability shared by future mirror,
  publishing, and recovery workloads; it is not owned by one application.
  Date: 2026-07-14

- Decision: Register both Apps once through the owning account's GitHub settings rather
  than provisioning them through Pulumi or implementing GitHub's App Manifest flow.
  Rationale: Registration chooses an owner and requires an authorized GitHub user to
  review the requested permissions. The manifest flow would add a temporary redirect
  service and a one-hour code exchange solely to automate two one-time registrations;
  GitHub exposes no ordinary create-App REST resource for Pulumi to own. The repository
  will document the exact settings and treat the resulting App registrations and
  installations as operator-managed external state.
  Date: 2026-08-25

- Decision: Mint tokens with a `pkgs.writeShellApplication` helper whose runtime inputs
  are the locked Nixpkgs `openssl`, `curl`, `jq`, and `coreutils` packages, rather than
  adding `haskellPackages.github-app-token` or `@octokit/auth-app`.
  Rationale: Both specialized candidates are libraries that still need a wrapper. The
  Haskell library's default exceptions can retain private key or HTTP response material,
  while Octokit adds a Node package/runtime closure. The direct GitHub flow is small—sign
  one RS256 JWT, make one versioned HTTP request, and validate two response fields—and a
  shell helper can keep all credentials in root-only files and emit only sanitized
  errors. Pinning comes from the existing Nix flake rather than a second package lock.
  Date: 2026-08-25

- Decision: Model exactly one GitHub installation per role in this plan.
  Rationale: A GitHub App installation belongs to one user or organization account, and
  the current bootstrap schema has one `installation-id` per role. Every repository in a
  role's documented boundary must therefore have the same owner account. Supporting
  repositories owned by multiple accounts requires an explicit schema and service fanout
  revision rather than silently choosing one installation.
  Date: 2026-08-25

- Decision: Install `forge-credentials.nix` through the reusable `nagare-host` module and
  store live bootstrap material only in the active context's operator-owned `secrets.yaml`.
  Rationale: ADR 5 made the checked-in host configuration an evaluation fixture. Importing
  reusable behavior from that fixture or storing live credentials beside it would bypass the
  context isolation and immutable-payload boundary already established by the project.
  Date: 2026-08-25

- Decision: Expose the refresher as `nagare.host.forgeCredentials`, disabled by default, with a
  configurable Kubernetes namespace that defaults to `personal`.
  Rationale: Forge access is an optional workload capability, not a prerequisite for operating a
  Nagare host. An unconfigured user must not be forced to supply GitHub keys or run unused timers,
  while an operator who opts in still receives a stable runtime Secret contract.
  Date: 2026-08-26

- Decision: Keep GitHub registrations, installation boundaries, non-secret deployment records,
  encrypted bootstrap material, and live acceptance evidence in each enabling operator's context.
  Nagare ships a copyable record template and an operational playbook rather than a completed
  maintainer-specific record.
  Rationale: A Nagare release cannot own or safely generalize one account's authorization state.
  Context ownership makes the trust boundary explicit and lets every user review their own account,
  repositories, and responsible operators.
  Date: 2026-08-26

- Decision: Keep the refresh logic in a source-visible Bash fragment packaged by
  `pkgs.writeShellApplication`, with role and secret paths passed by each systemd unit.
  Rationale: One package still receives only locked runtime inputs and each role still has an
  independent unit and runtime directory, while the source fragment can be ShellChecked and
  exercised on the development host with fake GitHub and k3s commands. The focused test proves
  successful three-key publication and proves malformed/non-2xx responses do not publish.
  Date: 2026-08-25

- Decision: Let each operator choose globally unique registration slugs derived from
  `nagare-forge-read` and `nagare-forge-write`; keep the stable runtime Secret names suffix-free.
  Rationale: GitHub App names are global and normally require an operator-specific suffix, while
  consumers should bind to provider-independent role names. The two `-shinzui` slugs created during
  initial validation are examples of external state, not names prescribed by Nagare.
  Date: 2026-08-26

- Decision: Retain the two uninstalled, keyless `@shinzui` registrations for the operator's
  personal use rather than deleting them after the product-boundary correction.
  Rationale: They have the intended least-privilege permission ceilings and can bootstrap a future
  personal context, while remaining clearly separate from Nagare's reusable module and release
  documentation.
  Date: 2026-08-26

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Commit `a7470db` established the source-visible refresh helper, role-isolated service/timer pairs,
focused success and failure-preservation tests, and the first operator guide. That first pass made
the module unconditional and embedded one maintainer's GitHub state in release documentation. The
2026-08-26 correction in commit `ea63a64` makes the capability opt-in, keeps the namespace
configurable, and turns the guide into a reusable playbook. ADR 8 now records the product/context
ownership boundary.

The hermetic implementation is complete: the corrected option boundary passes evaluation, the
aggregate flake checks pass, and both the focused x86_64-linux check and the full `nagare-01` NixOS
toplevel build succeed on the remote Linux builder. Live acceptance is intentionally not
Nagare-owned global state: each operator who enables the feature must retain redacted evidence with
their context's deployment record. The two `@shinzui` registrations created during the initial
interpretation are uninstalled and keyless. They are not required by the feature; the operator has
chosen to retain them for a future personal opt-in deployment and possible live acceptance run.

