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
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T14:53:19Z
      mode: "update"
      note: "Record resolved improvement-request review validation follow-up"
---

# Make the ACME identity context-owned and remove the personal fallback defaults

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [112-make-the-acme-identity-context-owned-and-remove-the-personal-fallback-defaults.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/112-make-the-acme-identity-context-owned-and-remove-the-personal-fallback-defaults.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
- [x] M5: Durable context recorded and the improvement request closed. (2026-09-12)
  - [x] Write the ADR for the context-owned ACME identity under `docs/adr/`:
        `docs/adr/0010-the-active-context-owns-the-acme-identity.md` (0009 was taken by EP-113).
  - [x] Set `docs/improvement-requests/context-owned-acme-identity.md` to `status: completed`
        with `completedAt` and `resolution`, and log it. (In place, per the Plan of Work: the
        bundle has no `completed/` directory and the shared profile tracks the terminal state
        in frontmatter — see the Decision Log.)
  - [x] Fill in Outcomes & Retrospective.

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

- Decision: RFC 2606 / RFC 6761 reserved example domains are **erased from each line** before
  the `cluster-bootstrap-defaults` guard matches, rather than the guard skipping the whole line.
  Rationale: the plan assumed illustrative addresses would live in comments, which the guard
  already skips. They do not — the renderer's refusal must *print*
  `--acme-email you@example.com` from an `echo` to tell an operator what a contact looks like.
  `example.com`/`.org`/`.net` and `*.example` are reserved in perpetuity and can never be a real
  mailbox, so exempting them costs nothing; erasing the address instead of the line keeps a real
  address appearing on the same line detectable. `flake.nix` itself is exempt from the URL drift
  half of the guard, because it has to name both URLs in order to check them.
  Date: 2026-09-12.

- Decision: `renderContextShellEnv` (the `nagarectl context env` contract the packaged `nagare`
  launcher evaluates) does **not** gain the two ACME variables.
  Rationale: the launcher exports `NAGARE_CONTEXT`, and the renderer sources
  `scripts/lib/target.sh`, which resolves the ACME fields from that context's own file. Adding
  them would buy nothing and would widen a contract whose values are re-applied over the
  context file by the snapshot-restore step in `_nagare_resolve_context`. The strip list in
  `scripts/rehearse-clone-free-release.sh` was still extended with both names so the "clean
  contract" invocation keeps describing the context under test rather than the developer's
  machine. Date: 2026-09-12.

- Decision: IR-3 is closed **in place** by setting `status: completed` in its frontmatter, not by
  moving the file into a `completed/` directory as the Progress checklist worded it.
  Rationale: the plan's own Plan of Work specifies the in-place form, and it is the one that
  matches reality — `docs/improvement-requests/` has no `completed/` directory, and the shared
  `okf-profiles` improvement-request profile models the terminal state as the `status`,
  `completedAt` and `resolution` frontmatter fields
  (`mori://shinzui/okf-profiles` + `profiles/coordination/improvement-requests.dhall:70-125`).
  Date: 2026-09-12.

- Decision: The four improvement requests' pre-existing "missing profile-recommended field:
  reviews" findings are reported, not silenced.
  Rationale: `okf validate --strict` emits the same four findings on the unmodified tree
  (verified by stashing only `docs/improvement-requests/` and re-running), including for two
  requests this plan never touches. Review provenance records who actually reviewed a document;
  inventing entries to turn the command green would make the corpus lie. Closing IR-3 introduced
  no new finding. Date: 2026-09-12.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

All five milestones are complete, and every acceptance criterion in
**Validation and Acceptance** holds except the last, which needs a live cluster.

**What the operator can now do that they could not before.** `nagarectl init <name>
--acme-email you@example.com` records the Let's Encrypt contact in the context;
`nagarectl context show <name> | grep ACME` prints it back; and the rendered `letsencrypt-dns`
`ClusterIssuer` carries that address, the context's chosen ACME endpoint, and the context's
own project. `nagarectl context create <name> --acme-directory staging` selects Let's
Encrypt's staging service without editing anything inside the read-only Nix payload. With no
contact configured, `nagare cluster-bootstrap` stops before `kubectl apply` and names the
field, so no cluster can register an account under an address its operator did not choose.

**Measured against the purpose.** The two personal literals are gone —
`grep -rn 'nadeem@\|tan-nb-exp' cluster/bootstrap/` is empty — and the
`cluster-bootstrap-defaults` guard was proven non-vacuous by running it against the pre-change
tree, where it reports exactly `render-context-template.sh:23` and `:26` and nothing else.
IR-3's acceptance sentence is satisfied in both halves, and all four of its "Required
verification" items are CI checks rather than prose.

**Evidence.** `nix flake check --print-build-logs` is green on `aarch64-darwin`: 14 built
checks including the new `render-context-template` (five hermetic scenarios) and
`cluster-bootstrap-defaults`, the extended `nagare-clone-free-platform` (which now asserts
`init` *refuses* a missing contact before asserting it accepts one) and `shellcheck-scripts`
(which now lints the renderer), plus `nagarectl-build-test` carrying seven new ACME unit
tests. `just user-documentation-validate` reports no findings (36 + 2 concepts).

**Gaps, stated plainly.**

- **Live acceptance is unrun.** The `kubectl get clusterissuer letsencrypt-dns` assertions in
  Validation and Acceptance need a real cluster and a delegated domain; this work was done
  without either. Everything below that line is proven hermetically. The first operator to run
  `nagare cluster-bootstrap` after this change closes that gap.
- **At implementation completion, `okf validate docs/improvement-requests --strict` exited
  non-zero**, with four pre-existing `missing profile-recommended field: reviews` findings — the
  same four, verbatim, on the unmodified tree. They were left alone rather than papered over. A
  2026-09-14 audit later performed the reviews, recorded their provenance, and made strict
  validation pass for all 23 requests.
- **`cabal run test:nagarectl-test` on a developer's machine has 8 unrelated failures** from a
  stale `.ghc.environment.*` registering two `nagare-dsl` versions. See Surprises & Discoveries.

**Lessons worth carrying.**

- *A guard written against imagined code finds real code.* The `cluster-bootstrap-defaults`
  regex was designed assuming illustrative addresses live in comments. Its first run failed on
  the renderer's own refusal message — which has to print an example address from an `echo` —
  and its second failed on `flake.nix`, which has to name both Let's Encrypt URLs to check
  them. Both were the guard doing its job on code the plan had not yet written.
- *Adding a strict field to a shared record is never a one-file change.* Two strict fields on
  `TargetProfile` broke three construction sites the plan did not name. The compiler found all
  of them, which is the argument for the fields being strict and positional rather than
  defaulted.
- *`nix flake check` sees the git tree, not the working tree.* A new test script that is
  written but not `git add`ed fails its check with a bare "No such file or directory".
- *Duplication is acceptable when drift is detectable.* The two ACME directory URLs live in
  both resolvers because the renderer cannot call back into `nagarectl` without a circular
  runtime dependency. Pinning them with a CI check turns an invisible risk into a build
  failure, which is the trade this repository already makes for the bucket-ownership guard.

**Durable context distilled to**
[ADR 10 — The active context owns the ACME identity](../adr/0010-the-active-context-owns-the-acme-identity.md).

