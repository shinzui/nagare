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
short-lived GitHub App installation tokens minted on the `nagare-01` host and replaced
every thirty minutes. A runtime workload selects a role name and receives
`GITHUB_TOKEN`; it does not know an App ID, installation ID, private key, or a user's
personal access token.

An operator can see the feature working by checking the timer state, observing that a
Secret's value changes after a forced refresh, using the read token to fetch an allowed
repository, and observing that the same token cannot write. A reboot and NixOS rebuild
must restore the refreshers without re-entering a live token.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Create two least-privilege GitHub Apps and record their installation boundaries.
- [ ] Declare the App bootstrap material with sops-nix and add the host refresh module.
- [ ] Atomically publish the role-named Kubernetes Secrets from independent systemd timers.
- [ ] Document workload consumption, rotation, failure behavior, and App-key recovery.
- [ ] Pass Nix evaluation plus live read, denial, rotation, and reboot acceptance tests.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The machine configuration is rooted at `nixos/hosts/nagare-01/configuration.nix`.
That file imports focused modules and configures sops-nix to decrypt
`nixos/hosts/nagare-01/secrets/nagare-01.yaml` with the host age key. The encrypted
file is committed; the age private key and plaintext values are not. The worked timer
pattern is `nixos/hosts/nagare-01/registries.nix`, which refreshes a different
short-lived credential. `docs/user/secrets.md` explains current host and application
secret practice.

The k3s server runs on the same host. Root's k3s kubeconfig lets a root-owned systemd
unit apply a Secret to `personal`; no token value needs to cross SSH or enter the Nix
store. In this plan, “bootstrap material” means each GitHub App's PEM private key, App
ID, and installation ID. “Installation token” means the roughly one-hour bearer token
returned by GitHub's installation-access-token endpoint. The former is durable and
encrypted at rest; the latter is ephemeral and exists only in a root-only runtime file
and a Kubernetes Secret.

The source requirement is Kikan's `shinzui/kikan` plan
`docs/plans/27-author-nagare-s-platform-prerequisites-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache.md`,
under the shared Intention in this file's frontmatter. Kikan's architectural posture is
role binding: Mori or a mirror requests a read or write role; it must not embed a PAT
or choose a provider-specific Secret name. The Kikan C16 contract is still unimplemented
as of 2026-07-14, so do not add repository-coordinate logic here.


## Plan of Work

### Milestone 1: establish the forge identities and encrypted inputs

Create two GitHub Apps outside this repository and write their non-secret installation
boundaries into `docs/user/forge-credentials.md`. The read App has repository Contents
read permission and is installed on every repository the content plane may mirror. The
write App has only the minimum Contents and pull-request permissions required by the
publishing workflow and is installed on a deliberately narrow repository set. Do not
grant organization administration, Actions administration, Members, Secrets, or Webhook
permissions. Record owners for App-key and installation changes, but never record IDs or
keys in plaintext documentation.

Edit the encrypted `nixos/hosts/nagare-01/secrets/nagare-01.yaml` with `sops`, adding:

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
ownership and mode `0400`. Import that module from
`nixos/hosts/nagare-01/configuration.nix`.

Milestone 1 is complete when the NixOS configuration evaluates, the encrypted file has
no plaintext diff, and each App installation's repository list matches the documented
boundary.

### Milestone 2: mint and publish independently rotating role Secrets

Implement `nixos/hosts/nagare-01/forge-credentials.nix` with a small local helper that
builds one service/timer pair per role. The refresh program must:

1. read the role's App ID, installation ID, and PEM from sops-provided paths;
2. create an RS256 GitHub App JWT with `iat` slightly in the past and `exp` no more than
   ten minutes in the future, using `openssl` and base64url encoding;
3. POST to `/app/installations/{installation_id}/access_tokens` with `curl`, fail on
   non-2xx responses, and validate `.token` and `.expires_at` with `jq`;
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
Use `curl`, `jq`, `openssl`, `coreutils`, and the k3s-provided `kubectl` explicitly from
Nix packages; do not depend on an interactive PATH.

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

First edit the encrypted input and evaluate the machine configuration:

```bash
sops nixos/hosts/nagare-01/secrets/nagare-01.yaml
nix fmt
nix build .#nixosConfigurations.nagare-01.config.system.build.toplevel
```

The build must finish with a `result` link and must not print a GitHub key. Inspect the
encrypted diff without decrypting it:

```bash
git diff -- nixos/hosts/nagare-01/secrets/nagare-01.yaml
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

The implementation uses GitHub's App JWT and installation-token HTTP APIs, sops-nix for
durable bootstrap material, systemd for scheduling, and k3s's `kubectl` for publication.
No new long-running service, operator, Haskell dependency, or external secret manager is
introduced.

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
