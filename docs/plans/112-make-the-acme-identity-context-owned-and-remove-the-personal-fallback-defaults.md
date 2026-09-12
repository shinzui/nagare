---
id: 112
slug: make-the-acme-identity-context-owned-and-remove-the-personal-fallback-defaults
title: "Make the ACME identity context-owned and remove the personal fallback defaults"
kind: exec-plan
created_at: 2026-09-12T13:26:36Z
intention: "intention_01m2awrqs2ektseh5wrvbrr07n"
provenance:
  created_by:
    model: "claude-opus-5[1m]"
    harness: "claude-code"
    at: 2026-09-12T13:26:36Z
  revisions:
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-12T15:38:34Z
      mode: "implement"
      note: "Implementing milestones 1-5: context-owned ACME identity"
---

# Make the ACME identity context-owned and remove the personal fallback defaults

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare is a single-operator Platform-as-a-Service: one virtual machine in Google Cloud runs a
small Kubernetes cluster, and applications deployed onto it are served over HTTPS at
`<app>.<namespace>.<your-domain>`. Those HTTPS certificates come from **Let's Encrypt**, a free
certificate authority. To get a certificate from Let's Encrypt a cluster first registers an
**ACME account** — ACME ("Automatic Certificate Management Environment") is the protocol
Let's Encrypt speaks, and an ACME account is identified by a **contact email address** and
backed by a private key. Let's Encrypt sends certificate-expiry warnings and policy notices to
that address. In Nagare the account is described by a single Kubernetes object called a
`ClusterIssuer` named `letsencrypt-dns`, created during `nagare cluster-bootstrap`.

Today that contact address is not something an operator can configure through any documented
interface. It is read from an environment variable, `NAGARE_ACME_EMAIL`, that appears in no
context file, no command flag, and no page of `docs/user/`; and when it is unset — which is the
normal state for anyone who followed the documented onboarding exactly — the renderer falls back
to a hardcoded literal, `nadeem@gmail.com`, in
`cluster/bootstrap/render-context-template.sh:26`. The same line's neighbour,
`cluster/bootstrap/render-context-template.sh:23`, does the same thing to the Google Cloud
project id, defaulting it to `tan-nb-exp`. So a second operator, onboarding their own project by
the book, silently ends up with a cluster that registers a Let's Encrypt account under someone
else's personal address and asks Let's Encrypt to solve its DNS challenge in a Google Cloud
project their cluster has no permission to write to. The second failure is visible but
misleading (a permissions error with no hint of its cause); the first is invisible and
sticky, because the ACME account key already exists after the first apply, so re-rendering the
issuer with the right address does not move the account — recovering means deleting the account
key Secret and bootstrapping again.

After this change, the ACME identity is an ordinary part of the **target context** — the named
bundle of `export VAR=value` lines under
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env` that already holds the project,
region, zone, domain and registry for one deploy target. Concretely, an operator gains four
things they do not have today.

First, `nagarectl init <name> --acme-email you@example.com` records the contact in the context,
and `nagarectl context show <name>` prints it back alongside the project and base domain. On a
terminal, `nagarectl init` prompts for it like it prompts for the project; run without a
terminal and without the flag, it stops and names the flag instead of choosing an address for
you.

Second, the ACME **directory endpoint** — the URL of the Let's Encrypt service the cluster talks
to — becomes a context field too, `NAGARE_ACME_DIRECTORY`, whose value is `production` (the
default), `staging`, or an explicit URL. Let's Encrypt's staging service issues certificates
that browsers do not trust but has far looser rate limits, which is the standard way to rehearse
certificate issuance for a new domain without burning the production quota. Today selecting it
requires hand-editing a file that ships inside a read-only Nix package, which a clone-free
install has no supported way to do.

Third, rendering the issuer becomes **fail-closed**. With no contact configured,
`cluster/bootstrap/render-context-template.sh` prints nothing to standard output, exits non-zero,
and says which field to set and which command sets it; `nagare cluster-bootstrap` then stops
before `kubectl apply` ever runs, so no `ClusterIssuer` is created under a wrong identity. The
project baked into the issuer's DNS-01 solver comes from the resolved active context and is
checked by the same fail-closed project guardrail every other cloud-touching script uses, rather
than from a bare environment variable with a personal default behind it.

Fourth, a continuous-integration check makes the removal permanent: a grep-style guard fails the
build if any personal email address or specific project id reappears as a default anywhere under
`cluster/bootstrap/`.

You can see all of this working without a Google Cloud account and without touching a cluster.
`nix flake check` runs a new hermetic shell test that renders the issuer from a throwaway
context and asserts the rendered `email:`, `server:` and `cloudDNS.project` are the context's own
values; renders it again with no contact and asserts the command fails with empty output; and
renders one of the non-ACME templates to prove the local development path is unaffected.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: The ACME identity is a first-class context field. (2026-09-12)
  - [x] Add `NAGARE_ACME_EMAIL` and `NAGARE_ACME_DIRECTORY` to `_NAGARE_CONTEXT_VARS` and the
        export block in `scripts/lib/target.sh`, with no built-in contact default.
  - [x] Add `nagare_acme_directory_url` to `scripts/lib/target.sh` and export the derived
        `NAGARE_ACME_DIRECTORY_URL`.
  - [x] Add `nagare_acme_email_valid` to `scripts/lib/target.sh`.
  - [x] Add `tpAcmeEmail` / `tpAcmeDirectory` to `TargetProfile` in
        `cli/nagarectl/src/Nagare/Target.hs`, resolved by both `profileFromContextMap` and
        `resolveProfileFrom`.
  - [x] Add `AcmeDirectory`, `parseAcmeDirectory`, `acmeDirectoryUrl`, `validateAcmeEmail` to
        `cli/nagarectl/src/Nagare/Target.hs` and export them. Also added `acmeDirectoryToken`
        (the inverse, mirroring `pulumiBackendToken`) so `init` stores a normalized token.
  - [x] Emit both fields from `renderTargetEnv` in `cli/nagarectl/src/Nagare/Init.hs`.
  - [x] Extend `profileFromOpts` and `InitOpts` for the two new values.
  - [x] Add `--acme-email` / `--acme-directory` to `nagarectl init` and `nagarectl context create`
        in `cli/nagarectl/app/Main.hs`, with a TTY prompt and a non-interactive error for the
        contact in `init`.
  - [x] Document both variables in `nagare.target.env.example`; note their absence in
        `nagare.local.env.example`.
- [x] M2: The issuer renders from the context and refuses to invent an identity. (2026-09-12)
  - [x] Rewrite the resolution block of `cluster/bootstrap/render-context-template.sh` to source
        `scripts/lib/target.sh`, preserving the caller's `NAGARE_REGISTRY_PREFIX` override.
  - [x] Delete the `tan-nb-exp` and `nadeem@gmail.com` fallbacks.
  - [x] Fail closed, with a message naming the field, when a template needs a contact and none is
        configured; validate the address shape and the directory token.
  - [x] Call `_require_target_project` when the template bakes in `${CLOUDSDK_CORE_PROJECT}`.
  - [x] Substitute `${NAGARE_ACME_DIRECTORY_URL}` and use it in
        `cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl`.
  - [x] Make the `cluster-bootstrap` recipe in `justfile` render-then-apply so a refusal cannot
        reach `kubectl apply`.
- [x] M3: Automated proof. (2026-09-12)
  - [x] Add `scripts/test-render-context-template.sh` with the five scenarios.
  - [x] Add the `render-context-template` check to `flake.nix`.
  - [x] Add the `cluster-bootstrap-defaults` grep guard check to `flake.nix`, with the
        RFC 2606 reserved-example-domain carve-out and the two-URL drift guard.
  - [x] Extend `nagare-clone-free-platform` in `flake.nix`: `init` refuses without `--acme-email`,
        accepts it, and the dry-run recipe renders before applying.
  - [x] Add the ACME unit tests to `cli/nagarectl/test/Spec.hs`.
  - [x] Add `--acme-email` to `nagarectl init` in `scripts/rehearse-clone-free-release.sh`
        (not in the plan; the rehearsal drives the same now-mandatory flag).
  - [x] Add `cluster/bootstrap/render-context-template.sh` to the `shellcheck-scripts` file list
        (not in the plan; the renderer was never linted).
  - [x] `nix flake check` green (18 checks, aarch64-darwin).
- [x] M4: Documentation tells an operator the field exists before they need it. (2026-09-12)
  - [x] `docs/user/contexts.md`: the two fields in the core table plus an ACME identity section
        (no default, the refusal, the account-key recovery, the staging rehearsal).
  - [x] `docs/user/reference.md`: the context-variable table, the `init` flags, the
        `context create` flag list, and the local-mode note.
  - [x] `docs/user/onboarding-bring-your-own-project.md`: Step 2's flag table and generated
        context; Step 10's issuer note.
  - [x] `docs/user/cluster-bootstrap.md`: prerequisites, the staging rehearsal, the refusal.
  - [x] `cluster/bootstrap/cert-manager/README.md`: the rendered fields and the staging switch.
  - [x] `docs/user/log.md` entry and a green `just user-documentation-validate`
        (36 + 2 concepts, no findings).
- [ ] M5: Durable context recorded and the improvement request closed.
  - [ ] Write the ADR for the context-owned ACME identity under `docs/adr/`.
  - [ ] Move `docs/improvement-requests/context-owned-acme-identity.md` to `completed` with
        `completedAt` and `resolution`, and log it.
  - [ ] Fill in Outcomes & Retrospective.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Four `TargetProfile` record literals exist outside `Nagare/Target.hs`, not one.** The plan
  named only `initProfile` in `cli/nagarectl/test/Spec.hs`. Adding two strict fields broke three
  more construction sites, each with `[GHC-95909] Constructor 'TargetProfile' does not have the
  required strict field(s)`: a second literal in `cli/nagarectl/test/Spec.hs:798` (`tnbProfile`)
  and one in `cli/nagarectl/test/AppDeploySpec.hs:60` (`testProfile`). All were updated.
  `cli/nagarectl/app/Main.hs:2806` uses record *update* syntax and needed no change.
  Date: 2026-09-12.

- **The grep guard trips on the renderer's own refusal message.** The plan's Decision Log
  expected illustrative addresses to live in *comments*, which the guard skips. They do not: the
  refusal has to print `nagarectl init <name> --acme-email you@example.com` from an `echo`, which
  is not a comment line. Rather than weaken the guard or garble the message, addresses at the
  RFC 2606 / RFC 6761 reserved example domains (`example.com`/`.org`/`.net`, `*.example`) are
  now *erased from each line* before matching — erasing the address rather than exempting the
  whole line keeps a real address on the same line detectable. Verified non-vacuous: run against
  the pre-change tree the guard still reports exactly
  `render-context-template.sh:23` (`tan-nb-exp`) and `:26` (`nadeem@gmail.com`), and nothing
  else. Date: 2026-09-12.

- **The URL drift guard had to exempt `flake.nix` itself.** The check names both Let's Encrypt
  directory URLs in order to assert on them, so `grep -rlF` found the guard as its own offender:
  `https://acme-v02.api.letsencrypt.org/directory is duplicated outside the two resolvers:
  ./flake.nix`. Date: 2026-09-12.

- **`nix flake check` only sees git-tracked files.** The first run of the new
  `render-context-template` check failed with
  `bash: scripts/test-render-context-template.sh: No such file or directory` because the script
  was written but not yet `git add`ed; `src = ./.` in a flake resolves to the git tree.
  Date: 2026-09-12.

- **The local `cabal run test:nagarectl-test` has 8 pre-existing failures unrelated to this
  work.** Every one is `Ambiguous module name 'Nagare.Dsl.*' ... found in multiple packages:
  nagare-dsl-0.1.0 nagare-dsl-0.1.0.0` from `AppDeploySpec`, caused by a stale
  `.ghc.environment.*` in the developer's `cli/nagarectl` checkout holding two registered
  `nagare-dsl` versions. It is an environment artifact, not a regression: the authoritative
  gate is the hermetic `nix build .#checks.<system>.nagarectl-build-test`, which builds the
  suite from a clean package set. Date: 2026-09-12.


## Decision Log

Record every decision made while working on the plan.

- Decision: The ACME contact has **no** built-in default anywhere — not in
  `scripts/lib/target.sh`, not in the Haskell resolver, not in the renderer. An unset contact is
  an error at the moment a template needs one, never a substitution.
  Rationale: This is the whole point of the improvement request. Every other context field has a
  safe generic default (`apps.example.com` is deliberately non-routable, `nagare-01` is a local
  name); an email address cannot have one, because any value is somebody's real mailbox and the
  resulting ACME account cannot be corrected after the fact without deleting the account key.
  Date: 2026-09-12.

- Decision: The renderer fails **only when the template it is rendering actually references the
  ACME fields**, detected by grepping the template, rather than whenever a contact is missing.
  Rationale: `cluster/bootstrap/render-context-template.sh` renders eight other templates —
  shomei, en, nagared and nagare-access service and migration manifests — none of which mention
  ACME, and `cluster/bootstrap/local-auth/install.sh` renders four of them on a laptop in local
  mode where no ACME contact exists or should. The existing `NAGARE_AUTH_TAG` branch at
  `cluster/bootstrap/render-context-template.sh:32` already establishes this
  "resolve-only-what-the-template-asks-for" pattern; reusing it keeps the local path untouched.
  Date: 2026-09-12.

- Decision: The renderer resolves the target by sourcing `scripts/lib/target.sh`, and calls
  `_require_target_project` when — and only when — the template contains
  `${CLOUDSDK_CORE_PROJECT}`.
  Rationale: The improvement request asks for the project to come from the resolved profile "so
  that the guardrail covers it". Sourcing the resolver alone would fix the personal default but
  still allow an ambient `CLOUDSDK_CORE_PROJECT` to bake a foreign project into a cluster object.
  A template that writes a project id into a live Kubernetes object is exactly the case the
  guardrail exists for. Restricting the call to project-bearing templates — today only
  `cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl` — means the auth-plane templates,
  which carry only `${NAGARE_REGISTRY_PREFIX}`, keep rendering with no new preconditions.
  Date: 2026-09-12.

- Decision: `NAGARE_ACME_DIRECTORY` accepts the tokens `production` and `staging`, or an absolute
  `https://` URL, and an unrecognized value is an error rather than a silent fallback to
  production.
  Rationale: The two existing token parsers in this repository, `parseMode` and
  `parsePulumiBackendKind` in `cli/nagarectl/src/Nagare/Target.hs`, deliberately map an
  unrecognized value onto the safe original behavior, because for those fields one choice is
  strictly safer. ACME has no such direction: silently choosing production burns a real rate
  limit against a real domain, and silently choosing staging installs certificates no browser
  trusts. Both mistakes are worse than refusing. The refusal is confined to the render step so a
  typo cannot break every shell that enters the repository.
  Date: 2026-09-12.

- Decision: `nagarectl init` **requires** a contact — flag or prompt — while
  `nagarectl context create` leaves it optional.
  Rationale: `init` is the documented onboarding path for a cloud target and always produces a
  cloud context, so demanding the contact there gives the earliest and clearest failure, matching
  how `--project` is already treated. `context create` is the low-level writer that also creates
  local contexts (`--mode local`), where an ACME contact is meaningless; forcing one there would
  break `just local-smoke` and the hermetic clone-free check. The render-time refusal is the
  backstop for contexts written by the low-level path.
  Date: 2026-09-12.

- Decision: Requiring `--acme-email` for non-interactive `nagarectl init` is a deliberate
  breaking change to an existing command line, and the hermetic fixture that exercises it is
  updated in the same change rather than exempted.
  Rationale: `flake.nix` runs `nagarectl init trial --project example --dry-run
  --skip-preflight` inside the `nagare-clone-free-platform` check. Seeing that invocation start
  to fail is the proof that the requirement is real; keeping a green build by weakening the
  requirement for the fixture would prove nothing. The release notes and
  `docs/user/onboarding-bring-your-own-project.md` state the new flag.
  Date: 2026-09-12.

- Decision: The token-to-URL mapping is implemented twice — once in `scripts/lib/target.sh` for
  the shell renderer, once in `cli/nagarectl/src/Nagare/Target.hs` for validation and display —
  and a CI check pins the two literal URLs to those two files.
  Rationale: The renderer is a standalone bash script invoked directly by
  `cluster/bootstrap/auth-install.sh` and `cluster/bootstrap/local-auth/install.sh`, so it cannot
  call back into `nagarectl` without creating a circular runtime dependency. Duplication of two
  constant strings is acceptable; undetected drift between them is not, so the guard makes drift
  a build failure.
  Date: 2026-09-12.

- Decision: The grep guard covers `cluster/bootstrap/` only, and skips comment lines.
  Rationale: That is the scope the improvement request asks for, and it is the directory whose
  contents are substituted into live cluster objects. `cluster/examples/` legitimately contains
  `tan-nb-exp` in prose READMEs describing the original worked example, and the issuer template's
  own comments will name `you@example.com` as an illustration; a guard that tripped on those
  would be turned off within a week.
  Date: 2026-09-12.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of this repository. Everything below was verified
against the working tree at the time of writing; line numbers are given for orientation and may
drift.

### Vocabulary

A **target context** is a named file of `export VAR=value` lines describing one deploy target:
which Google Cloud project, region and zone to use, which wildcard domain apps are served under,
which container registry to push to, and whether the target is a real cloud VM (`NAGARE_MODE=cloud`)
or a throwaway local cluster on the operator's laptop (`NAGARE_MODE=local`). Contexts live outside
the repository, under `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`, and the
selected one is named either by `--context NAME`, by the `NAGARE_CONTEXT` environment variable, or
by a one-line pointer file `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/current-context`.

**cert-manager** is a third-party Kubernetes add-on that obtains TLS certificates. A
**`ClusterIssuer`** is one of its objects: a cluster-wide description of *where* certificates come
from. Nagare's is called `letsencrypt-dns` and lives in
`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl`.

**DNS-01** is the ACME challenge type in which the certificate authority asks you to publish a
specific DNS TXT record to prove you control a domain. Nagare uses it because it is the only
challenge type that can issue a *wildcard* certificate (`*.personal.apps.example.com`), and it
solves the challenge by writing into Google Cloud DNS — which is why the issuer needs a Google
Cloud **project id** baked into it.

A **template** here is an ordinary YAML file containing `${VARIABLE}` placeholders, rendered by a
small `sed` wrapper rather than by any templating engine.

The **platform payload** is the read-only Nix package that ships Nagare's scripts, manifests,
Pulumi program and recipes to an operator who never clones this repository. This matters below
because "just edit the file" is not an available answer for anything inside it.

### The files this plan touches

`cluster/bootstrap/render-context-template.sh` (50 lines) is the renderer. It takes exactly one
argument, a template path, and writes the rendered YAML to standard output. Today its whole
resolution logic is four assignments (`:23-26`) plus two conditional blocks:

```bash
project="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"
registry_host="${NAGARE_REGISTRY_HOST:-us-west1-docker.pkg.dev}"
artifact_repo="${NAGARE_ARTIFACT_REGISTRY_ID:-nagare}"
acme_email="${NAGARE_ACME_EMAIL:-nadeem@gmail.com}"
```

It substitutes four placeholders — `${CLOUDSDK_CORE_PROJECT}`, `${NAGARE_ACME_EMAIL}`,
`${NAGARE_REGISTRY_PREFIX}` and `${NAGARE_AUTH_TAG}` — and sources only
`scripts/lib/release.sh` (`:13`), which resolves the immutable image tag. It does **not** source
`scripts/lib/target.sh`, so it has no access to the resolved context and no guardrail.

One conditional block in it is the pattern this plan copies (`:28-35`): the release tag is
resolved *only if* the template actually mentions `${NAGARE_AUTH_TAG}`, because resolving it
requires Git or a packaged `release.json` and would otherwise fail for templates that do not need
it.

`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl` (24 lines) is the only template that
mentions ACME or the project. Its `server:` field (`:11`) is the hardcoded production endpoint,
with staging mentioned only in a comment (`:7-10`); `email:` (`:12`) is `${NAGARE_ACME_EMAIL}`;
and `project:` inside the DNS-01 solver (`:19`) is `${CLOUDSDK_CORE_PROJECT}`.

`scripts/lib/target.sh` (330 lines) is the single shell-side resolver for the active context and
the home of the isolation guardrail. Three parts of it matter here. `_NAGARE_CONTEXT_VARS`
(`:34-42`) is the list of variables the resolver owns: before sourcing a context file it unsets
every one of them, so a value present afterwards can only have come from that file, and then it
re-applies a snapshot of the caller's environment so that per-field precedence stays
"environment > context > default". `_nagare_resolve_context` (`:82-217`) ends with a block of
`export VAR="${VAR:-default}"` lines and then derives `NAGARE_REGISTRY_PREFIX` (`:207-211`).
`_require_target_project` (`:276-330`) is the fail-closed guardrail: in local mode it asserts the
target really is loopback; in cloud mode it refuses unless the effective project equals the one
the active context declares, and when no context declares one it cross-checks gcloud's own
configured project with `CLOUDSDK_CORE_PROJECT` stripped from the environment so the check cannot
become a tautology.

Note a subtlety that will bite an implementer who skips it: `NAGARE_REGISTRY_PREFIX` is **not** in
`_NAGARE_CONTEXT_VARS`, and `scripts/lib/target.sh:207-211` exports it unconditionally. So merely
sourcing that file overwrites any `NAGARE_REGISTRY_PREFIX` the caller passed in — and
`cluster/bootstrap/local-auth/install.sh:87-104` calls the renderer five times with exactly such a
per-invocation override. The renderer must therefore capture the caller's value *before* sourcing
the resolver and prefer it afterwards, or local auth installs would silently start pointing at the
cloud registry prefix.

`cli/nagarectl/src/Nagare/Target.hs` is the Haskell twin of that resolver. `TargetProfile`
(`:255-305`) is the record of fully-resolved fields; `profileFromContextMap` builds one from a
context file alone (used by `context create` and `context show`, deliberately ignoring the process
environment), and `resolveProfileFrom` builds one with environment precedence applied. Two small
parsers there, `parseMode` and `parsePulumiBackendKind`, show the house style for token fields.

`cli/nagarectl/src/Nagare/Init.hs` owns `nagarectl init`'s pure parts: `renderTargetEnv` (`:116`)
turns a profile into the `export` lines written to a context file — and the same function backs
`nagarectl context show` — while `seedKeys` (`:146`) lists the eight values copied into Pulumi's
per-stack configuration. `profileFromOpts` (`:98`) is a small trick: it writes the four chosen
values into the process environment and then calls the ordinary resolver, so derived fields follow
exactly one derivation.

`cli/nagarectl/app/Main.hs` (4119 lines) holds the command-line parsers and handlers.
`initOptsParser` is at `:837`, `contextCreateOptsParser` at `:857`, the `runInit` handler at
`:2738` (its prompt helper `resolveField` at `:2820`), the `runContext` handler at `:2835`, and
`contextEnvPairs` — which turns `context create` flags into context-file lines — at `:2927`.

`justfile:142` is the single line that applies the issuer during `just cluster-bootstrap`:

```make
    cluster/bootstrap/render-context-template.sh cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl | kubectl apply -f -
```

`just` runs each recipe line in its own `sh -cu` shell with no `pipefail`, so in a pipeline the
renderer's exit status is discarded and only `kubectl`'s counts.

`flake.nix:81-318` defines the `checks` attribute set, which *is* this project's CI: the GitHub
workflow `.github/workflows/ci.yml` does nothing but run `nix flake check`. The existing checks
show every pattern this plan needs — `shellcheck-scripts` (`:278`) lints shell at error severity,
`forge-credential-refresh` (`:289`) and `release-consistency-source` (`:300`) each run a plain
bash test script from `scripts/`, and `nagare-clone-free-platform` (`:130`) builds an isolated
`HOME`/`XDG_CONFIG_HOME`/`XDG_STATE_HOME`, creates a real context with the installed CLI, and
asserts on real command output.

`cli/nagarectl/test/Spec.hs` is a `tasty` test suite (HUnit-style `testCase`, `@?=`,
`assertBool`). The `Nagare.Init (EP-63)` group at `:397` already asserts on `renderTargetEnv`
output and on the token parsers; new ACME assertions belong beside them.

### The operator-facing documents

`docs/user/contexts.md` (`DOC-10`) is the reference for the context model and carries the table of
core fields at `:44-56`. `docs/user/reference.md` carries the full context-variable table and the
`nagarectl context create` flag list. `docs/user/onboarding-bring-your-own-project.md` (`DOC-24`)
is the zero-to-running runbook: Step 2 (`:55`) documents `nagarectl init` flag by flag and prints
the generated context; Step 10 (`:219`) is where `nagare cluster-bootstrap` creates the issuer.
`docs/user/cluster-bootstrap.md` (`DOC-8`) describes what bootstrap installs and its
prerequisites. These four are part of an OKF documentation bundle validated by
`just user-documentation-validate`, which requires the frontmatter to stay well-formed and the
bundle's `docs/user/log.md` to record meaningful revisions.

### Relevant architecture decisions

Two records under `docs/adr/` bear on this work; the rest of the corpus does not.

[`docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md`](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)
decides that release-owned assets — including everything under `cluster/bootstrap/` — ship as one
immutable payload that runtime code resolves through `NAGARE_PLATFORM_ROOT`, and that
operator-owned configuration lives outside it, under the XDG configuration root, per context. It
is the reason "edit the template to use staging" is not an acceptable answer for a clone-free
install, and the reason the ACME endpoint has to become a context field rather than a comment in a
packaged file.

[`docs/adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md`](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
establishes that the context file is versioned operator state that commands rewrite carefully
rather than clobber, which is why new fields are added through `renderTargetEnv` and the existing
writers rather than by hand-editing context files in documentation.

No existing ADR covers the ACME identity, the issuer, or certificate policy. `docs/adr/` in this
repository is a plain filesystem convention — sequentially numbered `NNNN-slug.md` files with
`title`/`status`/`date`/`authors`/`related` frontmatter, no OKF profile and no `docId` — so
Milestone 5 follows that convention and allocates the next unused number at implementation time.
Note that `docs/plans/110-seed-and-pin-the-vm-shape-keys-at-init-and-guard-instance-replacing-applies.md`
also plans to write an ADR; whichever plan lands first takes `0009`, and the other takes the next
number. Do not assume a number before checking `ls docs/adr/`.

### The improvement request this plan answers

`docs/improvement-requests/context-owned-acme-identity.md` is `IR-3`, part of a pre-flight audit
of release `v0.1.0` performed while onboarding a second cloud context. Its acceptance criterion is
the sentence this plan is measured against: *"An operator onboarding a new context supplies their
own ACME contact through the documented interface, verifies it with `nagarectl context show`, and
finds the same value in the cluster's `ClusterIssuer`. No Nagare installation ever registers an
ACME account under an address its operator did not choose, and an operator who forgets is told so
rather than silently defaulted."*

The same audit produced `IR-2`
(`docs/improvement-requests/confine-cloud-mutations-to-context-project.md`), which asks for
project confinement across four *other* paths — the Pulumi state bucket, the image bucket, the two
image-build scripts, and `infra-up`. IR-2 is still `proposed` and has no plan. **This plan does not
depend on IR-2 and must not wait for it.** Where the two touch — the renderer calling
`_require_target_project` — this plan does that work itself for the one path it owns.


## Plan of Work

The work divides into five milestones. The first two are the change itself, split so that the
schema exists and is observable before anything starts depending on it. The third makes the
behavior permanent in CI, the fourth makes it discoverable, and the fifth records the durable
decision and closes the improvement request.

### Milestone 1 — The ACME identity becomes a context field

At the end of this milestone `NAGARE_ACME_EMAIL` and `NAGARE_ACME_DIRECTORY` are ordinary members
of the context schema: both resolvers know them, `nagarectl context show` prints them,
`nagarectl init` and `nagarectl context create` can set them, and the two tracked
`*.env.example` files document them. Nothing consumes them yet, so the cluster behaves exactly as
before; this milestone is verified entirely through the CLI.

In `scripts/lib/target.sh`, add both names to the `_NAGARE_CONTEXT_VARS` array so the
unset/restore discipline covers them. In the export block at the end of `_nagare_resolve_context`,
add `export NAGARE_ACME_EMAIL="${NAGARE_ACME_EMAIL:-}"` — an empty default, meaning unset — and
`export NAGARE_ACME_DIRECTORY="${NAGARE_ACME_DIRECTORY:-production}"`. Immediately after the
existing `NAGARE_REGISTRY_PREFIX` derivation, derive the endpoint URL with a new helper:

```bash
# The Let's Encrypt (or other ACME) directory endpoint for a context token. The
# tokens are deliberately few: 'production' and 'staging' are the two Let's
# Encrypt services, and an absolute https:// URL covers any other ACME CA. An
# unrecognized token yields an EMPTY url; the renderer that needs it fails with a
# precise message rather than silently choosing an endpoint. Keep these two
# literals in sync with acmeDirectoryUrl in cli/nagarectl/src/Nagare/Target.hs;
# the flake check `cluster-bootstrap-defaults` fails the build if they drift.
nagare_acme_directory_url() {
  case "${1:-production}" in
    production|"") printf '%s\n' "https://acme-v02.api.letsencrypt.org/directory" ;;
    staging) printf '%s\n' "https://acme-staging-v02.api.letsencrypt.org/directory" ;;
    https://*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "" ;;
  esac
}
```

and `export NAGARE_ACME_DIRECTORY_URL="$(nagare_acme_directory_url "${NAGARE_ACME_DIRECTORY}")"`.
Add a second helper, `nagare_acme_email_valid`, that returns success for a value containing
exactly one `@`, at least one character before it, a `.` with characters on both sides after it,
and no whitespace or comma. It is a sanity check for empty, placeholder or multi-address values,
not an RFC 5322 validator, and the comment above it must say so.

In `cli/nagarectl/src/Nagare/Target.hs`, add `tpAcmeEmail :: !Text` and
`tpAcmeDirectory :: !Text` to `TargetProfile` with Haddock comments naming the variables and
stating that an empty contact means "not configured". Resolve them in `profileFromContextMap` with
`mapOr ctx "NAGARE_ACME_EMAIL" ""` and `mapOr ctx "NAGARE_ACME_DIRECTORY" "production"`, and in
`resolveProfileFrom` with the corresponding `ctxOr` calls. Add the typed directory alongside the
existing parsers and export all four new names:

```haskell
-- | Which ACME service a context's issuer talks to. 'AcmeProduction' is Let's
-- Encrypt's real service; 'AcmeStaging' issues certificates that are NOT
-- browser-trusted but has far looser rate limits, for rehearsing issuance on a
-- new domain; 'AcmeCustom' is any other ACME directory URL.
data AcmeDirectory = AcmeProduction | AcmeStaging | AcmeCustom Text
  deriving stock (Eq, Show)

-- | Parse the NAGARE_ACME_DIRECTORY token. Empty means 'AcmeProduction'. Unlike
-- 'parseMode' and 'parsePulumiBackendKind', an unrecognized value is an ERROR,
-- not a fallback: silently choosing production burns a real rate limit and
-- silently choosing staging installs untrusted certificates, so neither is a
-- safe default for a typo.
parseAcmeDirectory :: Text -> Either Text AcmeDirectory

-- | The directory URL for a parsed endpoint. Keep the two literals in sync with
-- nagare_acme_directory_url in scripts/lib/target.sh.
acmeDirectoryUrl :: AcmeDirectory -> Text

-- | Accept a single usable contact address, or explain why not. This is a
-- sanity check (one '@', a dotted domain, no whitespace or comma), not an
-- RFC 5322 validator: its job is to reject empty, placeholder and multi-address
-- values before they reach Let's Encrypt.
validateAcmeEmail :: Text -> Either Text Text
```

In `cli/nagarectl/src/Nagare/Init.hs`, emit both fields from `renderTargetEnv` — placed after
`NAGARE_BASE_DOMAIN`, since they are domain-adjacent — and extend `profileFromOpts` to take the
contact and the directory token. Two facts matter for that extension. `profileFromOpts` works by
writing values into the process environment before calling the resolver, and
`System.Environment.setEnv` with an empty value *removes* the variable rather than throwing
(verified on this toolchain with GHC 9.12.3), so `setEnv "NAGARE_ACME_DIRECTORY" ""` is a safe way
to express "no explicit choice". Even so, write the case split explicitly (`setEnv` for a
non-empty value, `unsetEnv` otherwise) so the behavior does not depend on that detail. Do **not**
add either field to `seedKeys`: Pulumi provisions cloud resources and has no use for the ACME
identity, exactly as `NAGARE_TARGET_PLATFORM` is deliberately excluded today.

In `cli/nagarectl/app/Main.hs`, add `ioAcmeEmail`/`ioAcmeDirectory` to `InitOpts` (in
`cli/nagarectl/src/Nagare/Init.hs`, where the record lives) and `ccoAcmeEmail`/`ccoAcmeDirectory`
to `ContextCreateOpts`, with `--acme-email ADDRESS` and `--acme-directory production|staging|URL`
options on both commands and the two new pairs appended to `contextEnvPairs`. In `runInit`,
resolve the contact through the existing `resolveField` helper with `required = True`, which
prompts on a terminal and otherwise fails with `nagarectl init: --acme-email is required in
non-interactive mode`. Validate both values before anything is written — `validateAcmeEmail` and
`parseAcmeDirectory` — and exit with their message on failure, so a typo is caught before a
context file exists rather than at bootstrap time.

Finally, document both variables in `nagare.target.env.example` under a new "Certificates (ACME)"
heading, with the placeholder shown as a comment rather than a live default so copying the file
does not re-create the problem:

```bash
# --- Certificates (ACME) ---

# Contact address for the cluster's Let's Encrypt account. Let's Encrypt sends
# certificate-expiry and policy notices here. THERE IS NO DEFAULT: rendering the
# cert-manager ClusterIssuer refuses to proceed without it, because an ACME
# account cannot be re-pointed at a different address after it is registered.
export NAGARE_ACME_EMAIL=you@example.com

# Which ACME service to use: `production` (the default), `staging` (certificates
# are NOT browser-trusted, but the rate limits are far looser — use it to
# rehearse issuance on a new domain), or an absolute https:// directory URL.
export NAGARE_ACME_DIRECTORY=production
```

Add a one-line comment to `nagare.local.env.example` stating that local mode never contacts
Let's Encrypt and therefore needs neither variable.

Acceptance: with a throwaway configuration root, `nagarectl context create` writes and
`nagarectl context show` prints both lines; `nagarectl init` without a terminal and without
`--acme-email` exits non-zero naming the flag; `nagarectl context create` with
`--acme-directory typo` exits non-zero naming the field; and `nix build .#checks.<system>.nagarectl-build-test`
still passes.

### Milestone 2 — The issuer renders from the context, or not at all

At the end of this milestone the two personal literals are gone from the repository, the rendered
issuer carries the active context's contact, endpoint and project, and a missing contact stops
`nagare cluster-bootstrap` before `kubectl` sees anything. This milestone is verified by running
the renderer by hand.

Rewrite the resolution block of `cluster/bootstrap/render-context-template.sh`. The order of
operations matters, because sourcing the resolver overwrites `NAGARE_REGISTRY_PREFIX`:

```bash
template="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Capture the caller's explicit registry override BEFORE sourcing the resolver:
# scripts/lib/target.sh exports NAGARE_REGISTRY_PREFIX unconditionally, and
# cluster/bootstrap/local-auth/install.sh passes it per invocation.
caller_registry_prefix="${NAGARE_REGISTRY_PREFIX:-}"

# shellcheck source=scripts/lib/target.sh
source "${repo_root}/scripts/lib/target.sh"
# shellcheck source=scripts/lib/release.sh
source "${repo_root}/scripts/lib/release.sh"

project="${CLOUDSDK_CORE_PROJECT}"
registry_prefix="${caller_registry_prefix:-${NAGARE_REGISTRY_PREFIX}}"
```

Then add the two conditional resolution blocks, modelled on the existing `NAGARE_AUTH_TAG` one.
The first fires when the template mentions the project, and applies the guardrail:

```bash
if grep -q '\${CLOUDSDK_CORE_PROJECT}' "${template}"; then
  # This template writes a project id into a live cluster object, so it must be
  # rendered under the same fail-closed confinement every cloud-touching script
  # uses. In local mode the guardrail asserts the target is genuinely loopback.
  _require_target_project || exit 1
fi
```

The second fires when the template mentions either ACME placeholder:

```bash
acme_email=""
acme_directory_url=""
if grep -q '\${NAGARE_ACME_EMAIL}\|\${NAGARE_ACME_DIRECTORY_URL}' "${template}"; then
  acme_email="${NAGARE_ACME_EMAIL:-}"
  if [ -z "${acme_email}" ]; then
    echo "nagare: no ACME contact is configured for context '${NAGARE_CONTEXT:-default}'." >&2
    echo "  Set NAGARE_ACME_EMAIL in the active context:" >&2
    echo "    nagarectl init <name> --acme-email you@example.com" >&2
    echo "    nagarectl context create <name> --acme-email you@example.com" >&2
    echo "  Refusing to render ${template}: a Let's Encrypt account registered under" >&2
    echo "  the wrong address cannot be re-pointed without deleting its account key." >&2
    exit 1
  fi
  if ! nagare_acme_email_valid "${acme_email}"; then
    echo "nagare: NAGARE_ACME_EMAIL='${acme_email}' is not a usable ACME contact address (expected one address of the form you@example.com)." >&2
    exit 1
  fi
  acme_directory_url="${NAGARE_ACME_DIRECTORY_URL:-}"
  if [ -z "${acme_directory_url}" ]; then
    echo "nagare: NAGARE_ACME_DIRECTORY='${NAGARE_ACME_DIRECTORY:-}' is not recognized (expected 'production', 'staging', or an absolute https:// ACME directory URL)." >&2
    exit 1
  fi
fi
```

Extend the final `sed` with a fifth substitution for `${NAGARE_ACME_DIRECTORY_URL}`, and change
`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl` so `server:` reads
`server: ${NAGARE_ACME_DIRECTORY_URL}`. Replace the stale comment above it with one that names the
context field instead of telling the reader to edit the file:

```yaml
    # The ACME directory endpoint and contact come from the active target
    # context (NAGARE_ACME_DIRECTORY / NAGARE_ACME_EMAIL). Select Let's
    # Encrypt's staging service — untrusted certificates, much looser rate
    # limits — for a context with:
    #   nagarectl context create <name> --acme-directory staging
    server: ${NAGARE_ACME_DIRECTORY_URL}
    email: ${NAGARE_ACME_EMAIL}
```

Finally, make `justfile`'s issuer line fail closed. Because `just` runs recipe lines under
`sh -cu` without `pipefail`, a pipeline hides the renderer's exit status; render to a temporary
file first and apply only on success:

```make
    issuer="$(mktemp)"; trap 'rm -f "$issuer"' EXIT; \
      cluster/bootstrap/render-context-template.sh cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl > "$issuer" && \
      kubectl apply -f "$issuer"
```

Acceptance: rendering the issuer under a context whose project and contact differ from every
built-in value emits those values and the expected endpoint; rendering it with the contact removed
prints nothing to standard output, exits 1, and names `NAGARE_ACME_EMAIL`; rendering
`cluster/bootstrap/shomei/service.yaml` with no ACME contact configured still succeeds and still
honors a caller-supplied `NAGARE_REGISTRY_PREFIX`; and `grep -rn 'nadeem@\|tan-nb-exp' cluster/bootstrap/`
returns nothing.

### Milestone 3 — Automated proof, and a guard against regression

At the end of this milestone `nix flake check` proves every claim in Milestone 2 without a cluster
or a cloud account, and reintroducing a personal default fails the build.

Add `scripts/test-render-context-template.sh`, following the structure of the existing
`scripts/test-forge-credentials-refresh.sh`: `set -euo pipefail`, a `mktemp -d` root removed by an
`EXIT` trap, and small assertion helpers. It builds an isolated `XDG_CONFIG_HOME` and
`XDG_STATE_HOME`, writes two context files by hand, and runs the renderer in a scrubbed
environment (`env -u CLOUDSDK_CORE_PROJECT -u NAGARE_ACME_EMAIL -u NAGARE_ACME_DIRECTORY ...`) for
five scenarios:

1. A cloud context declaring `CLOUDSDK_CORE_PROJECT=acme-prod` and
   `NAGARE_ACME_EMAIL=ops@acme.example` renders the issuer with `email: ops@acme.example`,
   `project: acme-prod`, and `server: https://acme-v02.api.letsencrypt.org/directory`. This is the
   improvement request's "values differ from any built-in default" test.
2. The same context with `NAGARE_ACME_DIRECTORY=staging` renders
   `server: https://acme-staging-v02.api.letsencrypt.org/directory`.
3. The same context with the contact line deleted fails: exit status non-zero, standard output
   empty (asserted with `[ ! -s "$out" ]`, which is the machine-checkable form of "no
   `ClusterIssuer` is applied"), and standard error containing `NAGARE_ACME_EMAIL`.
4. The same context with `NAGARE_ACME_DIRECTORY=stagingg` fails with a message naming
   `NAGARE_ACME_DIRECTORY`.
5. A local context (`NAGARE_MODE=local`, loopback registry and domain) with no ACME contact at all
   renders `cluster/bootstrap/shomei/service.yaml` successfully, and with
   `NAGARE_REGISTRY_PREFIX=k3d-registry.localhost:5000` in the environment the rendered image line
   carries that prefix. This is the regression test for the two traps in Milestone 2.

Wire it into `flake.nix` beside `forge-credential-refresh`:

```nix
          render-context-template = pkgs.runCommand "nagare-render-context-template-test"
            {
              nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
              src = ./.;
            }
            ''
              cd "$src"
              bash scripts/test-render-context-template.sh
              touch "$out"
            '';
```

The test needs no `gcloud`: every fixture context declares a project, which is the guardrail
branch that compares two strings. It needs no `pulumi` either — `_nagare_select_pulumi_stack`
returns immediately when the binary is absent.

Add the regression guard as a second check:

```nix
          cluster-bootstrap-defaults = pkgs.runCommand "nagare-cluster-bootstrap-defaults"
            { nativeBuildInputs = [ pkgs.gnugrep pkgs.findutils ]; src = ./.; }
            ''
              cd "$src"
              # No specific project id and no email-shaped literal may appear as a
              # value in anything under cluster/bootstrap/. Comment lines are
              # skipped so illustrative addresses in documentation comments stay
              # legal; *.md files are out of scope (IR-3 scopes this guard to the
              # rendered assets).
              offenders="$(find cluster/bootstrap -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.tmpl' \) \
                -exec grep -Hn -v '^[[:space:]]*#' {} + \
                | grep -E 'tan-nb-exp|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' || true)"
              if [ -n "$offenders" ]; then
                echo "cluster/bootstrap must not carry a personal address or a specific project id:" >&2
                echo "$offenders" >&2
                exit 1
              fi
              touch "$out"
            '';
```

That guard also owns the drift check from the Decision Log: assert that each of the two Let's
Encrypt directory URLs appears in `scripts/lib/target.sh`, in
`cli/nagarectl/src/Nagare/Target.hs`, and — outside documentation and the two test files — nowhere
else.

Extend the existing `nagare-clone-free-platform` check where it runs `nagarectl init`. Today it
reads:

```bash
nagarectl init trial --project example --dry-run --skip-preflight > init.out
```

Replace it with a refusal assertion followed by the accepted form, and add a dry-run assertion for
the recipe:

```bash
if nagarectl init trial --project example --dry-run --skip-preflight > init-no-acme.out 2> init-no-acme.err; then
  echo "nagarectl init unexpectedly accepted a missing ACME contact" >&2
  exit 1
fi
grep -q -- '--acme-email' init-no-acme.err
nagarectl init trial --project example --acme-email ops@example.com \
  --dry-run --skip-preflight > init.out
grep -q 'DRY RUN: would run:' init.out
nagare --dry-run cluster-bootstrap > cluster-bootstrap-dry-run.out 2>&1
grep -q 'render-context-template.sh' cluster-bootstrap-dry-run.out
grep -q 'kubectl apply -f "\$issuer"' cluster-bootstrap-dry-run.out
```

Add the unit tests to the `Nagare.Init (EP-63)` group in `cli/nagarectl/test/Spec.hs`: extend
`initProfile` with the two new fields; assert `renderTargetEnv` emits both lines; assert
`profileFromContextMap` reads them from a parsed context; assert `parseAcmeDirectory` maps
`""`/`production`/`staging`/`https://…` and rejects `stagingg` and a bare `http://` URL; assert
`acmeDirectoryUrl` produces the two exact strings; and assert `validateAcmeEmail` accepts
`ops@acme.example` and rejects `""`, `ops`, `ops@acme`, `a@b.c,d@e.f` and `ops @acme.example`.

Acceptance: `nix flake check` is green; deleting `--acme-email` from the clone-free fixture, or
re-adding a default contact to the renderer, turns it red.

### Milestone 4 — An operator learns the field exists before they need it

At the end of this milestone every place that describes the context schema or the bootstrap step
names the two fields, and the documentation bundle still validates.

In `docs/user/contexts.md`, add two rows to the core-field table — "ACME contact"
(`NAGARE_ACME_EMAIL`) and "ACME endpoint" (`NAGARE_ACME_DIRECTORY`) — and a short section after
"Cloud and local modes" explaining what the account is, that there is no default, what the
failure looks like, why a wrong address is expensive to fix, and how to rehearse against staging.

In `docs/user/reference.md`, add both variables to the context-variable table with their defaults
(`—` and `production`), add `--acme-email` and `--acme-directory` to the `nagarectl context create`
flag list, and add a note to the local-variable section that local mode uses neither.

In `docs/user/onboarding-bring-your-own-project.md`, add both flags to Step 2's flag table, note
in the same step that `--acme-email` makes an interactive run non-interactive only in combination
with `--project` and is otherwise prompted for, add the two lines to the printed example context,
and extend Step 10 with one sentence: bootstrap refuses to create the issuer if the active context
has no ACME contact.

In `docs/user/cluster-bootstrap.md`, add the contact to the prerequisites list, add a short
"Rehearsing with Let's Encrypt staging" subsection under the DNS and TLS model, and state what the
refusal looks like. Update `cluster/bootstrap/cert-manager/README.md` the same way, replacing its
implicit claim that the issuer is simply applied.

Record the change in `docs/user/log.md` and run `just user-documentation-validate`.

Acceptance: `just user-documentation-validate` passes, and
`grep -rn 'NAGARE_ACME_EMAIL' docs/user/` names at least `contexts.md`, `reference.md`,
`onboarding-bring-your-own-project.md` and `cluster-bootstrap.md`.

### Milestone 5 — Durable context recorded, improvement request closed

Write the ADR. Check `ls docs/adr/` for the next unused number, then create
`docs/adr/<NNNN>-the-active-context-owns-the-acme-identity.md` in the established format
(frontmatter with `title`, `status: accepted`, `date`, `authors`, `related`; then Status, Context,
Decision, Consequences). The decision to record is narrow and durable: identity that a cluster
registers with an external certificate authority belongs to the operator's context, never to a
packaged default, and a missing identity is a refusal rather than a substitution — with the
consequence that a new context costs one more required answer at `init`, and the two ACME
directory URLs are duplicated between the shell and Haskell resolvers under a CI drift guard.
Reference this plan and ADR 4 in `related`.

Then close the improvement request: in
`docs/improvement-requests/context-owned-acme-identity.md`, set `status: completed`, add
`completedAt` and a one-line `resolution`, bump `timestamp`, and update the in-body **Status**
line; add an entry to `docs/improvement-requests/log.md`; and validate the bundle with

```bash
okf validate docs/improvement-requests \
  --strict \
  --profile docs/improvement-requests/profile.dhall \
  --profile-enforce \
  --log-enforce
```

Finally, fill in Outcomes & Retrospective in this plan.


## Concrete Steps

All commands run from the repository root unless stated otherwise. Enter the toolchain first —
either `direnv allow` once (then every shell in this directory has it) or `nix develop` for a
one-off shell — so that `nagarectl`, `just`, `pulumi`, `kubectl` and the Haskell toolchain are on
`PATH`.

### Before you start: see the current behavior

Reproduce the problem so you can recognize the fix. With no ACME contact anywhere in the
environment, today's renderer invents one:

```bash
env -u NAGARE_ACME_EMAIL -u CLOUDSDK_CORE_PROJECT \
  cluster/bootstrap/render-context-template.sh \
  cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl | grep -E 'email:|project:'
```

Expected today (this is the defect):

```text
    email: nadeem@gmail.com
            project: tan-nb-exp
```

After Milestone 2 the same command exits 1, prints nothing on standard output, and explains which
field to set.

### Milestone 1

Edit, in this order: `scripts/lib/target.sh`, `cli/nagarectl/src/Nagare/Target.hs`,
`cli/nagarectl/src/Nagare/Init.hs`, `cli/nagarectl/app/Main.hs`, `nagare.target.env.example`,
`nagare.local.env.example`. Then build and exercise the CLI against a throwaway configuration
root so your real contexts are never touched:

```bash
cabal build --project-file=cli/nagarectl/cabal.project nagarectl
export DEMO_ROOT="$(mktemp -d)"
env -u CLOUDSDK_CORE_PROJECT -u NAGARE_ACME_EMAIL -u NAGARE_ACME_DIRECTORY \
  XDG_CONFIG_HOME="$DEMO_ROOT/config" XDG_STATE_HOME="$DEMO_ROOT/state" \
  nagarectl context create acme-demo \
    --project acme-prod --region us-west1 --zone us-west1-a \
    --base-domain apps.acme.example --acme-email ops@acme.example
```

Expected:

```text
Wrote context 'acme-demo' (<DEMO_ROOT>/config/nagare/contexts/acme-demo.env)
```

Confirm the round-trip through `context show`:

```bash
env XDG_CONFIG_HOME="$DEMO_ROOT/config" XDG_STATE_HOME="$DEMO_ROOT/state" \
  nagarectl context show acme-demo | grep ACME
```

Expected:

```text
export NAGARE_ACME_EMAIL=ops@acme.example
export NAGARE_ACME_DIRECTORY=production
```

Confirm the two refusals:

```bash
env -u CLOUDSDK_CORE_PROJECT -u NAGARE_ACME_EMAIL \
  XDG_CONFIG_HOME="$DEMO_ROOT/config" XDG_STATE_HOME="$DEMO_ROOT/state" \
  nagarectl init trial --project example --dry-run --skip-preflight < /dev/null
echo "exit=$?"
```

Expected (non-zero, and the message names the flag):

```text
nagarectl init: --acme-email is required in non-interactive mode
exit=1
```

```bash
env XDG_CONFIG_HOME="$DEMO_ROOT/config" XDG_STATE_HOME="$DEMO_ROOT/state" \
  nagarectl context create bad-acme --project acme-prod \
  --acme-email ops@acme.example --acme-directory stagingg
echo "exit=$?"
```

Expected:

```text
nagare: NAGARE_ACME_DIRECTORY='stagingg' is not recognized (expected 'production', 'staging', or an absolute https:// ACME directory URL).
exit=1
```

Commit:

```text
feat(contexts): make the ACME contact and directory first-class context fields

Add NAGARE_ACME_EMAIL and NAGARE_ACME_DIRECTORY to the context schema in both
resolvers, seed them from `nagarectl init` (flag + prompt, required) and
`nagarectl context create`, and print them from `nagarectl context show`.
Neither has a personal default.

ExecPlan: docs/plans/112-make-the-acme-identity-context-owned-and-remove-the-personal-fallback-defaults.md
Intention: intention_01m2awrqs2ektseh5wrvbrr07n
```

### Milestone 2

Edit `cluster/bootstrap/render-context-template.sh`,
`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl` and `justfile`. Then render the issuer
from the demo context created above. The `env -u CLOUDSDK_CORE_PROJECT` is **not** optional in a
`direnv`-loaded shell: `.envrc` has already exported the project of whatever context is current,
and an ambient project that disagrees with the selected context is exactly what the guardrail
refuses.

```bash
env -u CLOUDSDK_CORE_PROJECT -u NAGARE_ACME_EMAIL -u NAGARE_ACME_DIRECTORY \
  XDG_CONFIG_HOME="$DEMO_ROOT/config" XDG_STATE_HOME="$DEMO_ROOT/state" \
  NAGARE_CONTEXT=acme-demo \
  cluster/bootstrap/render-context-template.sh \
  cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl
```

Expected (abridged — the comments are omitted here, not from the output):

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ops@acme.example
    privateKeySecretRef:
      name: letsencrypt-dns-account-key
    solvers:
      - dns01:
          cloudDNS:
            project: acme-prod
```

Select staging for that context and render again:

```bash
printf 'export NAGARE_ACME_DIRECTORY=staging\n' >> "$DEMO_ROOT/config/nagare/contexts/acme-demo.env"
env -u CLOUDSDK_CORE_PROJECT -u NAGARE_ACME_EMAIL -u NAGARE_ACME_DIRECTORY \
  XDG_CONFIG_HOME="$DEMO_ROOT/config" XDG_STATE_HOME="$DEMO_ROOT/state" \
  NAGARE_CONTEXT=acme-demo \
  cluster/bootstrap/render-context-template.sh \
  cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl | grep server:
```

Expected:

```text
    server: https://acme-staging-v02.api.letsencrypt.org/directory
```

Now remove the contact and prove the refusal produces nothing:

```bash
sed -i.bak '/NAGARE_ACME_EMAIL/d' "$DEMO_ROOT/config/nagare/contexts/acme-demo.env"
env -u CLOUDSDK_CORE_PROJECT -u NAGARE_ACME_EMAIL -u NAGARE_ACME_DIRECTORY \
  XDG_CONFIG_HOME="$DEMO_ROOT/config" XDG_STATE_HOME="$DEMO_ROOT/state" \
  NAGARE_CONTEXT=acme-demo \
  cluster/bootstrap/render-context-template.sh \
  cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl > "$DEMO_ROOT/issuer.yaml"
echo "exit=$?"
test -s "$DEMO_ROOT/issuer.yaml" && echo "FAIL: wrote output" || echo "OK: no output"
```

Expected:

```text
nagare: no ACME contact is configured for context 'acme-demo'.
  Set NAGARE_ACME_EMAIL in the active context:
    nagarectl init <name> --acme-email you@example.com
    nagarectl context create <name> --acme-email you@example.com
  Refusing to render cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl: a Let's Encrypt account registered under
  the wrong address cannot be re-pointed without deleting its account key.
exit=1
OK: no output
```

Prove the local auth path is untouched — no ACME contact, an explicit registry override, and the
override still wins:

```bash
env -u CLOUDSDK_CORE_PROJECT -u NAGARE_ACME_EMAIL \
  XDG_CONFIG_HOME="$DEMO_ROOT/config" XDG_STATE_HOME="$DEMO_ROOT/state" \
  NAGARE_MODE=local NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000 \
  NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io \
  NAGARE_REGISTRY_PREFIX=k3d-registry.localhost:5000 NAGARE_AUTH_TAG=testtag \
  cluster/bootstrap/render-context-template.sh cluster/bootstrap/shomei/service.yaml | grep 'image:'
```

Expected:

```text
          image: k3d-registry.localhost:5000/shomei:testtag
```

Confirm the literals are gone, then clean up:

```bash
grep -rn 'nadeem@\|tan-nb-exp' cluster/bootstrap/ || echo "clean"
rm -rf "$DEMO_ROOT"
```

Commit:

```text
fix(cluster)!: render the ACME issuer from the active context or refuse

Remove the hardcoded nadeem@gmail.com and tan-nb-exp fallbacks from
render-context-template.sh, resolve the target through scripts/lib/target.sh,
apply _require_target_project to project-bearing templates, and render the ACME
directory endpoint from the context. cluster-bootstrap now renders before it
applies, so a refusal never reaches kubectl.

BREAKING CHANGE: rendering the cert-manager ClusterIssuer requires an ACME
contact in the active context; there is no default.

ExecPlan: docs/plans/112-make-the-acme-identity-context-owned-and-remove-the-personal-fallback-defaults.md
Intention: intention_01m2awrqs2ektseh5wrvbrr07n
```

### Milestone 3

Write `scripts/test-render-context-template.sh` and make it executable
(`chmod +x scripts/test-render-context-template.sh`). Run it directly first — it is an ordinary
bash script and needs no Nix:

```bash
bash scripts/test-render-context-template.sh
```

Expected (the script prints one line per scenario and exits 0):

```text
ok: cloud context renders its own contact, project and production endpoint
ok: staging token selects the staging directory
ok: missing contact refuses with empty stdout
ok: unrecognized directory token refuses
ok: non-ACME template renders with no contact and honors the caller's registry prefix
```

Add the two new checks and the clone-free assertions to `flake.nix`, add the unit tests to
`cli/nagarectl/test/Spec.hs`, then run the full suite:

```bash
nix flake check --print-build-logs
```

The grep guard was validated against the pre-change tree while writing this plan; it matches
exactly the two lines this work removes and nothing else, so a green result after Milestone 2 is
meaningful rather than vacuous:

```text
$ find cluster/bootstrap -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.tmpl' \) \
    -exec grep -Hn -v '^[[:space:]]*#' {} + \
  | grep -E 'tan-nb-exp|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
cluster/bootstrap/render-context-template.sh:23:project="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"
cluster/bootstrap/render-context-template.sh:26:acme_email="${NAGARE_ACME_EMAIL:-nadeem@gmail.com}"
```

Commit:

```text
test(cluster): prove the ACME identity comes from the context and cannot regress

ExecPlan: docs/plans/112-make-the-acme-identity-context-owned-and-remove-the-personal-fallback-defaults.md
Intention: intention_01m2awrqs2ektseh5wrvbrr07n
```

### Milestone 4

Edit the four pages plus `cluster/bootstrap/cert-manager/README.md`, add the `docs/user/log.md`
entry, then:

```bash
just user-documentation-validate
```

Expected: `okf validate` reports no findings for `docs/user` and `docs/guides`, and both `okf
graph` invocations succeed silently.

Commit with a `docs:` type.

### Milestone 5

```bash
ls docs/adr/
```

Take the next unused number — do not assume `0009`; another plan in flight may have taken it —
and write the ADR. Then update the improvement request and validate the bundle:

```bash
okf validate docs/improvement-requests \
  --strict \
  --profile docs/improvement-requests/profile.dhall \
  --profile-enforce \
  --log-enforce
```

Expected: no findings. Finish by filling in this plan's Outcomes & Retrospective and committing
with a `docs:` type.


## Validation and Acceptance

The plan is complete when all of the following hold.

**Hermetic, no cloud account required.** `nix flake check --print-build-logs` passes, including
the new `render-context-template` and `cluster-bootstrap-defaults` checks, the extended
`nagare-clone-free-platform` check, `shellcheck-scripts` (the renderer and the new test script are
both covered by it once the test script lives in `scripts/`), and `nagarectl-build-test` with the
new unit tests.

**The schema is real.** In a throwaway configuration root, `nagarectl context create <name>
--acme-email ops@acme.example` followed by `nagarectl context show <name>` prints
`export NAGARE_ACME_EMAIL=ops@acme.example`. This is the first half of the improvement request's
acceptance sentence.

**The renderer is faithful.** Rendering
`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl` under a context whose project is
`acme-prod` and whose contact is `ops@acme.example` — values that match no built-in default —
produces `email: ops@acme.example` and `project: acme-prod`. This is the second half.

**The renderer is fail-closed.** With the contact removed from that context, the same command
exits non-zero, writes nothing to standard output, and names `NAGARE_ACME_EMAIL` on standard
error. `nagare --dry-run cluster-bootstrap` shows the issuer being rendered to a file and applied
from that file, so the refusal cannot be swallowed by a pipeline.

**Staging is selectable without editing a packaged file.**
`nagarectl context create <name> --acme-directory staging` yields a rendered issuer whose
`server:` is `https://acme-staging-v02.api.letsencrypt.org/directory`.

**The local path is unharmed.** Rendering `cluster/bootstrap/shomei/service.yaml` with no ACME
contact configured succeeds, and a caller-supplied `NAGARE_REGISTRY_PREFIX` still wins over the
resolver's derived value. If you have Docker available, `just local-up && just local-bootstrap`
still completes, which exercises the same renderer through
`cluster/bootstrap/local-auth/install.sh`.

**The defaults cannot come back.** `grep -rn 'nadeem@\|tan-nb-exp' cluster/bootstrap/` is empty,
and re-introducing either literal turns `nix flake check` red.

**Live acceptance (on a real cluster, optional for merging).** After `nagare cluster-bootstrap`
against a context carrying your own contact:

```bash
kubectl get clusterissuer letsencrypt-dns \
  -o jsonpath='{.spec.acme.email}{"\n"}{.spec.acme.server}{"\n"}{.spec.acme.solvers[0].dns01.cloudDNS.project}{"\n"}'
```

prints your contact, your endpoint and your project, and

```bash
kubectl get clusterissuer letsencrypt-dns -o wide
```

shows `READY=True` within about a minute — which is the proof that Let's Encrypt accepted the
account registration under that address.


## Idempotence and Recovery

Every step in Milestones 1 through 5 is an ordinary file edit plus a read-only verification
command, and all of them can be repeated. The renderer only ever writes to standard output and
never contacts a network, so running it any number of times changes nothing. Creating the demo
context writes into a `mktemp -d` root that the steps delete at the end; if you interrupt the work
midway, `rm -rf "$DEMO_ROOT"` is the whole cleanup. `nagarectl context create` refuses to
overwrite an existing context unless `--force` is passed, so a re-run cannot silently clobber a
real context even if you forget the `XDG_CONFIG_HOME` override.

Context files stay compatible in both directions. A context written by the new code carries two
extra `export` lines; older code ignores them, because the shell resolver simply sources the file
and `parseContextEnv` in `cli/nagarectl/src/Nagare/Target.hs` collects unknown keys into a map
nothing reads. So reverting this change does not strand a context, and a context written before
this change is read correctly by the new code — it simply has no contact, which is the case the
refusal exists for.

There is one genuinely irreversible operation in this problem domain, and it is the reason the
plan exists: once cert-manager has registered an ACME account, changing the `email:` field of the
issuer does **not** change the account, because the account is keyed by the private key stored in
the Secret named by `privateKeySecretRef` — `letsencrypt-dns-account-key` in the `cert-manager`
namespace. An operator who has already bootstrapped under the wrong address recovers like this,
and should be told so in the documentation written in Milestone 4:

```bash
kubectl -n cert-manager delete secret letsencrypt-dns-account-key
# then re-apply the issuer, now rendered from a context with the right contact:
nagare cluster-bootstrap
kubectl get clusterissuer letsencrypt-dns -o wide   # READY=True again
```

Deleting that Secret makes cert-manager register a fresh account on the next reconcile.
Certificates already issued remain valid and keep serving; they are re-issued under the new
account at their next renewal. Do this deliberately and only after the context carries the right
address. Let's Encrypt applies per-domain issuance rate limits, so if you expect to iterate on a
new domain, point the context at `--acme-directory staging` first and switch back to `production`
once issuance works end to end.

If a milestone's verification fails, nothing downstream depends on a partially applied state:
Milestone 1 is inert until Milestone 2 consumes the fields, and Milestone 2's change to
`justfile` is a strictly safer version of the existing line. The safe rollback at any point is
`git revert` of that milestone's commit.


## Interfaces and Dependencies

No new third-party dependency is introduced, in any language. The Haskell work uses only
`base`, `text` and `containers`, all already dependencies of `nagarectl`; the new tests use
`tasty`/`tasty-hunit`, already in the `nagarectl-test` stanza of
`cli/nagarectl/nagarectl.cabal`; the new Nix checks use only `pkgs.bash`, `pkgs.coreutils`,
`pkgs.gnugrep`, `pkgs.gnused` and `pkgs.findutils`, all of which appear in existing checks in
`flake.nix`.

### Contract after Milestone 1

`scripts/lib/target.sh` gains two context variables and one derived export, and two functions
callable by anything that sources the file:

```bash
# Context fields (members of _NAGARE_CONTEXT_VARS, subject to the usual
# env > context > default precedence):
#   NAGARE_ACME_EMAIL        default "" (unset; there is deliberately no default)
#   NAGARE_ACME_DIRECTORY    default "production"
# Derived export (NOT a context field, recomputed on every source, exactly like
# NAGARE_REGISTRY_PREFIX):
#   NAGARE_ACME_DIRECTORY_URL   "" when the token is unrecognized

nagare_acme_directory_url <token>   # prints the URL, or "" for an unknown token; always exits 0
nagare_acme_email_valid <address>   # exit 0 if usable as a single ACME contact, non-zero otherwise
```

`cli/nagarectl/src/Nagare/Target.hs` gains two record fields and four exported names:

```haskell
data TargetProfile = TargetProfile
  { -- ... existing fields ...
    tpAcmeEmail :: !Text
  -- ^ NAGARE_ACME_EMAIL. Empty means NOT CONFIGURED; there is no default,
  -- because any default would be somebody's real mailbox.
  , tpAcmeDirectory :: !Text
  -- ^ NAGARE_ACME_DIRECTORY: "production" (default), "staging", or an absolute
  -- https:// ACME directory URL.
  }

data AcmeDirectory = AcmeProduction | AcmeStaging | AcmeCustom Text
  deriving stock (Eq, Show)

parseAcmeDirectory :: Text -> Either Text AcmeDirectory
acmeDirectoryUrl   :: AcmeDirectory -> Text
validateAcmeEmail  :: Text -> Either Text Text
```

`cli/nagarectl/src/Nagare/Init.hs`:

```haskell
-- Two new lines in the rendered context file, after NAGARE_BASE_DOMAIN:
--   export NAGARE_ACME_EMAIL=<contact or empty>
--   export NAGARE_ACME_DIRECTORY=<token>
renderTargetEnv :: TargetProfile -> Text

-- Extended with the contact and the directory token. Existing argument order is
-- preserved and the two new parameters are appended.
profileFromOpts :: Text -> Text -> Text -> Text -> Text -> Text -> IO TargetProfile

data InitOpts = InitOpts
  { -- ... existing fields ...
    ioAcmeEmail :: !(Maybe String)
  , ioAcmeDirectory :: !(Maybe String)
  }

-- UNCHANGED: seedKeys still returns exactly eight pairs. The ACME identity is a
-- cluster concern, not a Pulumi one.
seedKeys :: TargetProfile -> [(Text, Text)]
```

`cli/nagarectl/app/Main.hs`:

```haskell
data ContextCreateOpts = ContextCreateOpts
  { -- ... existing fields ...
    ccoAcmeEmail :: !(Maybe String)
  , ccoAcmeDirectory :: !(Maybe String)
  }

-- contextEnvPairs gains two entries:
--   pair "NAGARE_ACME_EMAIL" (ccoAcmeEmail o)
--   pair "NAGARE_ACME_DIRECTORY" (ccoAcmeDirectory o)
```

Command-line surface added: `--acme-email ADDRESS` and
`--acme-directory production|staging|URL` on both `nagarectl init` and
`nagarectl context create`. On `init` the contact is required (prompted on a terminal, an error
naming the flag otherwise); everywhere else both are optional.

### Contract after Milestone 2

`cluster/bootstrap/render-context-template.sh` keeps its single-argument interface — one template
path in, rendered YAML on standard output — and adds these guarantees:

- It substitutes five placeholders: `${CLOUDSDK_CORE_PROJECT}`, `${NAGARE_ACME_EMAIL}`,
  `${NAGARE_ACME_DIRECTORY_URL}`, `${NAGARE_REGISTRY_PREFIX}`, `${NAGARE_AUTH_TAG}`.
- It resolves every value from the active context via `scripts/lib/target.sh`, with one
  exception: an explicit `NAGARE_REGISTRY_PREFIX` in the caller's environment still wins, which
  `cluster/bootstrap/local-auth/install.sh` depends on.
- It calls `_require_target_project` when, and only when, the template contains
  `${CLOUDSDK_CORE_PROJECT}`.
- It exits non-zero with an empty standard output, and a message on standard error naming the
  field to set, when a template needs an ACME contact and the context has none, when the contact
  is unusable, or when the directory token is unrecognized.
- It has no default contact and no default project.

`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl` takes `server:` from
`${NAGARE_ACME_DIRECTORY_URL}`. `justfile`'s `cluster-bootstrap` recipe renders the issuer to a
temporary file and applies it only on success.

### Contract after Milestone 3

`scripts/test-render-context-template.sh` is a standalone bash test: no arguments, no network, no
`gcloud`, no `pulumi`, no cluster. It exits 0 on success and prints one `ok:` line per scenario.
`flake.nix` exposes `checks.<system>.render-context-template` and
`checks.<system>.cluster-bootstrap-defaults`.
