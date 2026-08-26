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


## Purpose / Big Picture

Nagare will publish two stable, role-named Kubernetes Secrets in the `personal`
namespace: `nagare-forge-read` and `nagare-forge-write`. Their values will be
short-lived installation tokens for two GitHub Apps. In this plan, a GitHub App is a
GitHub-managed machine identity, similar to a service account: it has its own name,
private key, permission ceiling, and repository access, but it is not an application
binary, Pod, GitHub Action, OAuth login, or webhook service. The tokens are minted on the
`nagare-01` host and replaced every thirty minutes. A runtime workload selects a role name
and receives `GITHUB_TOKEN`; it does not know an App ID, installation ID, private key, or
a user's personal access token.

An operator can see the feature working by checking the timer state, observing that a
Secret's value changes after a forced refresh, using the read token to fetch an allowed
repository, and observing that the same token cannot write. A reboot and NixOS rebuild
must restore the refreshers without re-entering a live token.

This plan creates two new GitHub App registrations. It does not assume that suitable
Apps already exist, and it does not reuse an unrelated existing App.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-26T00:15:00Z) Register the private, webhook-disabled read App
  `nagare-forge-read-shinzui` under `@shinzui` with only Contents read and mandatory
  Metadata read permission.
- [x] (2026-08-26T00:24:00Z) Register the private, webhook-disabled write App
  `nagare-forge-write-shinzui` under `@shinzui` with Contents and Pull requests
  read/write plus mandatory Metadata read permission.
- [ ] Install both Apps on explicitly selected repositories, generate and immediately
  encrypt one key per App in the active context, and replace the remaining pending
  deployment-record fields with the exact non-secret installation boundaries.
- [x] (2026-08-25T22:54:04Z) Declare all six sops-nix paths and import the forge refresher
  from the reusable `nagare-host` module.
- [x] (2026-08-25T23:18:00Z) Implement independent systemd services and timers, atomic
  role-named Secret publication, sanitized failure handling, and focused success/malformed/
  non-2xx preservation tests.
- [x] (2026-08-25T23:26:00Z) Document workload consumption, inspection, rotation, failure
  behavior, least-privilege probes, and App-key recovery in
  `docs/user/forge-credentials.md` and link it from the operator guide.
- [x] (2026-08-25T23:52:00Z) Pass focused ShellCheck, NixOS option evaluation,
  `git diff --check`, and the complete compatible-system `nix flake check` (all ten
  aarch64-darwin checks passed).
- [ ] Build the x86_64-linux NixOS toplevel when `nix-gcp-builder` is reachable, then pass
  live registration, read, denial, rotation, failure-preservation, journal, and reboot tests.


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
  `formatter.aarch64-darwin`. The current source-tree validation is
  `nix build ./nixos#nixosConfigurations.nagare-01.config.system.build.toplevel`, with
  `nixpkgs-fmt` for the Nix files on this workstation. Evaluation passed; the full Linux
  build is currently blocked because the configured `nix-gcp-builder` SSH connection closes
  before accepting work.

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

- Decision: Keep the refresh logic in a source-visible Bash fragment packaged by
  `pkgs.writeShellApplication`, with role and secret paths passed by each systemd unit.
  Rationale: One package still receives only locked runtime inputs and each role still has an
  independent unit and runtime directory, while the source fragment can be ShellChecked and
  exercised on the development host with fake GitHub and k3s commands. The focused test proves
  successful three-key publication and proves malformed/non-2xx responses do not publish.
  Date: 2026-08-25

- Decision: Use the globally unique registration slugs `nagare-forge-read-shinzui` and
  `nagare-forge-write-shinzui`; keep the stable runtime Secret names suffix-free.
  Rationale: GitHub App names are global and may require an owner suffix, while consumers
  should bind to the provider-independent role names already defined by the platform contract.
  Date: 2026-08-26


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

The repository-owned milestone is complete. Commit `a7470db` adds the reusable NixOS module,
source-visible and ShellChecked refresh helper, two role-isolated service/timer pairs, six
root-only sops declarations, focused success and failure-preservation tests, and the operator
runbook. The full compatible-system `nix flake check` passes. The durable architecture is
recorded in `docs/adr/0008-mint-role-scoped-github-app-tokens-on-the-host.md`.

The plan is not complete. Both least-privilege registrations now exist, but key generation and
both installations are waiting for an explicit selected-repository boundary and a production
sops context that can receive each generated key immediately. Live deployment is also waiting
for a production context-owned host flake, a reachable `nagare-01`, and the configured Linux
remote builder. Those prerequisites block the authorization matrix, rotation/failure evidence,
journal audit, and reboot test; none is represented as passed.


## Context and Orientation

Reusable machine behavior is rooted at `nixos/modules/nagare-host.nix`. That module
imports focused host modules and is consumed by a context-owned host flake under the
operator's XDG configuration root. The context's encrypted `secrets.yaml` is committed to
operator-controlled storage; the age private key and plaintext values are not. The checked-in
`nixos/hosts/nagare-01/configuration.nix` and
`nixos/hosts/nagare-01/secrets/nagare-01.yaml` are compatibility fixtures for source
evaluation, not the live operator identity. This ownership is established by
`docs/adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md`. The worked timer
pattern is `nixos/hosts/nagare-01/registries.nix`, which refreshes a different short-lived
credential. `docs/user/secrets.md` explains current host and application secret practice.

The k3s server runs on the same host. Root's k3s kubeconfig lets a root-owned systemd
unit apply a Secret to `personal`; no token value needs to cross SSH or enter the Nix
store. In this plan, “bootstrap material” means each GitHub App's PEM private key, App
ID, and installation ID. “Installation token” means the roughly one-hour bearer token
returned by GitHub's installation-access-token endpoint. The former is durable and
encrypted at rest; the latter is ephemeral and exists only in a root-only runtime file
and a Kubernetes Secret.

A GitHub App is an authorization identity stored by GitHub. Its registration establishes
the identity and the maximum permissions it may ever receive. Its private key lets
Nagare prove that it controls that identity. The App contains no Nagare code and receives
no webhooks in this design; its only job is to let Nagare request short-lived credentials
that GitHub attributes to the App rather than to a human user.

“Registration” is the one-time creation of that identity under a user or organization
account. “Installation” is the separate grant that attaches the identity to selected
repositories owned by one account. An “installation token” is the temporary credential
created from the registration's private key for one installation; its effective access
is the intersection of the App's permission ceiling and the repositories selected by the
installation. This plan has two registrations and two installations: one
registration/installation pair for the read role and one for the write role. The App
registrations are operator-managed GitHub state, not NixOS or Pulumi resources.

The source requirement is
`mori://shinzui/kikan/plans/27-author-nagare-s-platform-prerequisites-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache`,
under the shared Intention in this file's frontmatter. Kikan's architectural posture is
role binding: Mori or a mirror requests a read or write role; it must not embed a PAT
or choose a provider-specific Secret name. The Kikan C16 contract is still unimplemented
as of 2026-07-14, so do not add repository-coordinate logic here.

The implementation is governed by
`docs/adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md`, which places live
sops material in the active context, and
`docs/adr/0008-mint-role-scoped-github-app-tokens-on-the-host.md`, which records the two-role
GitHub App boundary, host-side minting, stable Secret interface, independent failure domains,
and one-installation-per-role constraint.


## Plan of Work

### Milestone 1: establish the forge identities and encrypted inputs

This milestone creates two new GitHub App registrations rather than discovering or
reusing existing registrations. An owner of the GitHub user or organization account that
owns the target repositories must register the two private Apps through GitHub's Settings,
Developer settings, GitHub Apps, New GitHub App page. Use globally unique names derived
from `nagare-forge-read` and `nagare-forge-write`; the suffix needed for global uniqueness
is not part of the stable Kubernetes Secret name. For both Apps, set the Nagare repository
URL as the homepage,
select the option that restricts installation to the owning account, disable webhooks,
subscribe to no events, request no user authorization, and leave callback and setup URLs
unset.

For the read App, set repository Contents permission to read-only. For the write App,
set repository Contents and Pull requests permissions to read-and-write so the publishing
workflow can push a branch and open or update a pull request. GitHub grants Metadata read
permission automatically. Leave every other repository, organization, account, and
enterprise permission at `No access`; in particular do not grant Administration,
Actions, Workflows, Members, Secrets, or any webhook permission.

After registering each App, generate exactly one private key and install the App on the
same owning account with `Only select repositories`. Install the read App on every
repository the content plane may mirror. Install the write App only on the disposable
publishing target and the narrow production targets it is explicitly allowed to mutate.
All repositories selected for one role must belong to that one installation owner. If
the required repositories span multiple user or organization accounts, stop and revise
the one-installation-per-role bootstrap interface before creating additional
installations.

Write the App owner, actual App slug, installation owner, webhook-disabled state,
permission matrix, and exact selected-repository list into
`docs/user/forge-credentials.md`. Record owners for private-key and installation changes,
but never record App IDs, installation IDs, or keys in plaintext documentation. Copy the
App ID from the App settings page and the installation ID from the installed App's
settings URL directly into the encrypted input described below. After confirming that
sops contains the PEM, remove the browser-downloaded plaintext PEM; sops becomes the
recovery copy.

Resolve the active context with `nagarectl host path --context <name>` and edit its encrypted
`secrets.yaml` with `sops`, adding:

```yaml
github-app:
  read:
    app-id: <integer>
    installation-id: <integer>
    private-key: <PEM>
  write:
    app-id: <integer>
    installation-id: <integer>
    private-key: <PEM>
```

The placeholders above describe decrypted structure only; never paste real values into
this plan, a terminal transcript, or an unencrypted file. In the new
`nixos/hosts/nagare-01/forge-credentials.nix`, declare all six sops paths with root
ownership and mode `0400`. Import that reusable module from
`nixos/modules/nagare-host.nix`.

Milestone 1 is complete when the NixOS configuration evaluates, the encrypted file has
no plaintext diff, and each App installation's repository list matches the documented
boundary.

### Milestone 2: mint and publish independently rotating role Secrets

Implement `nixos/hosts/nagare-01/forge-credentials.nix` with
`pkgs.writeShellApplication`. Give the generated refresh program `runtimeInputs` containing
`pkgs.openssl`, `pkgs.curl`, `pkgs.jq`, `pkgs.coreutils`, and
`config.services.k3s.package`; do not add a Haskell, Node, Python, or dynamically downloaded
GitHub helper. A small Nix helper builds one service/timer pair per role. The refresh
program must:

1. read the role's App ID, installation ID, and PEM from sops-provided paths;
2. create an RS256 GitHub App JWT with `iat` slightly in the past and `exp` no more than
   ten minutes in the future, using `openssl` and base64url encoding;
3. POST to `/app/installations/{installation_id}/access_tokens` with `curl`, using
   `Accept: application/vnd.github+json`, `Authorization: Bearer <JWT>`, and
   `X-GitHub-Api-Version: 2026-03-10`; keep the authorization header in a root-only curl
   config file rather than a process argument, fail on non-2xx responses, and validate
   `.token` and `.expires_at` with `jq`;
4. write the token and expiry to a service `RuntimeDirectory` with umask `077`;
5. use `kubectl create secret generic --from-file ... --dry-run=client -o yaml |
   kubectl apply -f -` to atomically publish `token`, `GITHUB_TOKEN`, and `expires_at`
   in the role Secret; and
6. remove temporary response and JWT files on exit.

Never pass a bearer token via `--from-literal`, interpolate it into a Nix string, echo it,
or enable shell tracing. A failed request or malformed response must exit before the
`kubectl apply`, preserving the last valid Secret. Error messages may name the role and
HTTP status, never a response body that might contain a token.

Create `nagare-forge-read-refresh.service` and
`nagare-forge-write-refresh.service` as root-owned `Type=oneshot` services. Each is
`After=` and `Wants=` `network-online.target` and `k3s.service`, but it is not a
requirement or ordering prerequisite of k3s. Create matching timers with an initial
short delay, `OnUnitActiveSec=30min`, `RandomizedDelaySec=2min`, and `Persistent=true`.
The `writeShellApplication` derivation must pass its ShellCheck phase. The implementation
uses the existing locked Nixpkgs packages only and must not depend on an interactive PATH.

Milestone 2 is complete when starting either unit creates only its own Secret, a failed
mint does not change the Secret's resource version or token hash, and the timer retries
without disrupting k3s.

### Milestone 3: document consumption and prove least privilege

Add `docs/user/forge-credentials.md` and link it from the relevant navigation list in
`docs/user/README.md`. Explain App creation, sops input paths, service/timer inspection,
role selection, the stable Secret names and keys, rotation, expiration alarms, private-key
rotation, installation changes, and safe recovery. Include a `nagare-dsl` example that
maps `GITHUB_TOKEN` with `EnvSecretRef (SecretName "nagare-forge-read")`; consumers must
not call the GitHub App token endpoint themselves.

Perform the live acceptance test with shell tracing disabled. Hash decoded tokens with
SHA-256 and print only hashes. For authorization checks, use a disposable repository:
the read token must read an allowed file but receive 403 or 404 on a write attempt; the
write token must create and delete a probe file in its allowed disposable repository and
must receive 403 or 404 in a repository outside its installation. Finally reboot the
host, wait for both timers, and repeat a read request.

Milestone 3 is complete only when the access matrix, refresh, failure preservation, and
reboot recovery are observed, with no token value in shell history, journal output, or
test artifacts.


## Concrete Steps

Run repository commands from `/Users/shinzui/Keikaku/bokuno/nagare`.

First complete the two GitHub UI registrations and installations described in Milestone
1. Before handling a PEM, turn shell tracing off and create no plaintext notes. Confirm
on each installed App's settings page that the account owner, selected repositories, and
permissions exactly match `docs/user/forge-credentials.md`. Then edit the encrypted input
and evaluate the machine configuration:

```bash
host_root="$(nagarectl host path --context prod)"
sops "$host_root/secrets.yaml"
nixpkgs-fmt nixos/hosts/nagare-01/forge-credentials.nix nixos/modules/nagare-host.nix
nix build ./nixos#nixosConfigurations.nagare-01.config.system.build.toplevel
```

The build must finish with a `result` link and must not print a GitHub key. Inspect the
encrypted diff without decrypting it:

```bash
git diff -- "$host_root/secrets.yaml"
rg -n -- 'BEGIN (RSA )?PRIVATE KEY|ghs_[A-Za-z0-9]+' nixos docs
```

The first command shows only sops ciphertext/metadata changes. The second prints no
matches.

After reviewing the active target context, deploy through the existing host workflow:

```bash
just context-show
just host-switch
ssh nagare-01 'systemctl status nagare-forge-read-refresh.timer nagare-forge-write-refresh.timer --no-pager'
```

Expected status includes `active (waiting)` for both timers. Force refresh and inspect
metadata, not values:

```bash
ssh nagare-01 'sudo systemctl start nagare-forge-read-refresh.service nagare-forge-write-refresh.service'
kubectl -n personal get secret nagare-forge-read nagare-forge-write
kubectl -n personal get secret nagare-forge-read -o jsonpath='{.data.expires_at}' | base64 -d
```

Expected output names both Secrets and shows an expiry less than one hour in the future.
For rotation, use a local helper shell with `set +x`, decode each token into a mode-0600
temporary file, run `shasum -a 256`, force the matching unit again, and compare a second
hash. Expected output is two different hashes and no token text.

For a safe failure test, temporarily point one role's installation ID at a nonexistent
installation in the encrypted input, apply the host configuration, and record the
Secret resource version and token hash. Starting that refresher must fail and leave both
values unchanged. Restore the valid encrypted value immediately and reapply. Never test
failure by revoking the production App key without a recovery window.

Run repository checks before handoff:

```bash
nix flake check
git diff --check
```

Record concise, redacted evidence in this plan's Progress and Surprises sections as work
proceeds.


## Validation and Acceptance

Acceptance requires all of the following behaviors:

* `nix flake check` and the `nagare-01` toplevel build succeed from a clean checkout that
  has access to the host age key only at activation time.
* GitHub shows two private, webhook-disabled App registrations. The read registration has
  only Metadata read and Contents read permissions; the write registration has only
  Metadata read plus Contents and Pull requests read-and-write permissions. Each has one
  installation on the documented owner account with exactly the documented selected
  repositories.
* Each timer creates its named Secret independently. Each Secret contains exactly the
  required `token`, `GITHUB_TOKEN`, and `expires_at` data keys, and the two token keys
  decode to identical bytes.
* A forced successful refresh changes the token hash and expiry without requiring a
  consumer restart. A forced mint failure leaves the existing Secret unchanged and logs
  a role-scoped, non-secret error.
* A Pod consuming `GITHUB_TOKEN` from `nagare-forge-read` can read an installed
  repository. A write request made with that token is denied. The write token can mutate
  only its deliberately installed disposable repository and is denied outside it.
* `journalctl -u 'nagare-forge-*-refresh.service'`, the Git diff, shell history, and test
  artifacts contain no PEM or installation token.
* After reboot, both timers are active and the read check succeeds without manual token
  entry.

The GitHub authorization checks are live integration tests, not unit tests. Use probe
content and clean it up; never perform them against an important branch.


## Idempotence and Recovery

The refresh services are idempotent: each successful run server-side-applies the same
Secret names with a new value. Re-running a timer, NixOS switch, or reboot is safe. The
old Secret remains usable until expiry if GitHub is temporarily unavailable because
publication occurs only after the complete response has been validated.

If an App private key is exposed, generate a new App key, replace the sops value, deploy,
force the role refresher, and only then revoke the old key. If a live installation token
is exposed, suspend affected workloads, revoke the App installation or key as appropriate,
rotate, and republish; deleting only the Kubernetes Secret does not revoke a copied
token. If a deployment breaks minting, revert the NixOS module and switch back; do not
delete the last valid Secret while diagnosing.

Changing repository permissions or installation scope is security-sensitive. Apply
the narrow change in GitHub first, force refresh, rerun the access matrix, and update the
documented boundary. Removing this feature consists of disabling the timers, removing
the NixOS declarations, switching the host, and then deleting the two Kubernetes Secrets;
reverse that order when restoring it.


## Interfaces and Dependencies

The two GitHub App registrations and their selected-repository installations are created
once in GitHub's settings UI and remain operator-managed external state. No package,
Pulumi resource, or NixOS module creates them. The repository records their non-secret
configuration in `docs/user/forge-credentials.md` and stores their bootstrap credentials
only through sops-nix.

The runtime implementation uses GitHub's App JWT and installation-token HTTP APIs,
sops-nix for durable bootstrap material, systemd for scheduling, and k3s's `kubectl` for
publication. `pkgs.writeShellApplication` packages the local refresh helper with the
locked Nixpkgs `openssl`, `curl`, `jq`, `coreutils`, and k3s packages as runtime inputs.
No new long-running service, operator, Haskell/Node/Python dependency, external secret
manager, or runtime package download is introduced. The researched
`haskellPackages.github-app-token` and `@octokit/auth-app` libraries are deliberately not
part of the implementation.

At completion, `nixos/hosts/nagare-01/forge-credentials.nix` must expose these systemd
units:

```text
nagare-forge-read-refresh.service
nagare-forge-read-refresh.timer
nagare-forge-write-refresh.service
nagare-forge-write-refresh.timer
```

Their Kubernetes interface is:

```text
Namespace: personal
Secret: nagare-forge-read | nagare-forge-write
data.token: installation token bytes
data.GITHUB_TOKEN: the same installation token bytes
data.expires_at: GitHub's RFC 3339 expiry text
```

The bootstrap interface consists of six sops paths under `github-app/read` and
`github-app/write`: `app-id`, `installation-id`, and `private-key`. Only the NixOS
module reads them. Downstream workloads consume a role Secret through a SecretKeyRef or
Nagare's existing `EnvSecretRef`; they never consume the sops paths.


## Revision Notes

2026-07-14: Replaced every indented command, configuration, and interface excerpt with
an explicitly language-tagged fenced code block, as required by the ExecPlan formatting
specification. No implementation scope or acceptance behavior changed.

2026-08-23: Replaced the informal cross-repository Kikan source-plan reference with its
canonical `mori://` URI as part of the Nagare plan-registry update. Scope and status are
unchanged.

2026-08-25: Defined the complete GitHub UI registration and selected-repository
installation procedure, made the one-installation-per-role constraint explicit, and
resolved the dependency question. The refresher now explicitly uses a
`pkgs.writeShellApplication` built from existing locked Nixpkgs command packages; the
available Haskell `github-app-token` and JavaScript `@octokit/auth-app` libraries were
researched and rejected because neither is a ready-to-run host command and each would
require an additional wrapper/runtime. This revision removes the earlier ambiguity about
which state is operator-managed and which code is implemented in Nagare.

2026-08-25: Clarified that “GitHub App” means a GitHub-managed machine identity rather
than a deployed application, GitHub Action, OAuth login, or webhook service. Also defined
how registration, installation, private-key proof, and installation-token scope relate;
the architecture and implementation scope are unchanged.

2026-08-25: Made explicit that Milestone 1 creates two new GitHub App registrations and
does not assume or reuse existing Apps. Creation remains a one-time operator action in
GitHub's UI; Nagare code begins with storing the resulting bootstrap credentials.

2026-08-25: Reconciled implementation with the completed context-owned-host work in
ExecPlan 107 and ADR 5. Live sops inputs now belong to the active context, reusable
behavior is imported by `nixos/modules/nagare-host.nix`, validation uses the nested
`nixos` flake, and the public DSL example uses `mkSecretName`. Recorded the completed
module, focused failure-preservation tests, operator documentation, offline remote-builder
constraint, and remaining GitHub/live acceptance work.

2026-08-25: Recorded the passing aggregate flake check, added ADR 8, and split hermetic
completion from the blocked external acceptance work. The plan now states the observed absence
of a production context/reachable host and GitHub's sudo-mode reauthentication requirement; it
does not claim registration or live validation.

2026-08-26: Recorded the successful read App registration after operator sudo-mode
reauthentication, chose globally unique owner-suffixed App slugs, and left key generation and
installation pending until the private key can be encrypted immediately and exact repository
boundaries are supplied.

2026-08-26: Recorded the successful write App registration and verified its effective
Contents/Pull requests read-write plus Metadata read-only permission matrix. Both registrations
now exist; installation and private-key generation remain pending on explicit repository and
production sops boundaries.
