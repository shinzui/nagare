---
type: Improvement Request
title: Make the ACME identity context-owned and remove the personal fallback defaults
description: Add the ACME contact and directory endpoint to the context schema and fail closed instead of registering Let's Encrypt accounts under a hardcoded personal address.
timestamp: "2026-09-12T13:34:52Z"
generated:
  by: process:claude-code
  at: "2026-09-12T12:35:03Z"
requestId: IR-3
status: accepted
targetPlan: docs/plans/112-make-the-acme-identity-context-owned-and-remove-the-personal-fallback-defaults.md
origin: mori://shinzui/nagare
---

# Improvement Request: make the ACME identity context-owned

**Authored by:** a pre-flight audit of `v0.1.0` (HEAD `da24748`) performed while onboarding a second
cloud context whose operator identity differs from the one baked into the defaults.
**Addressed to:** `shinzui/nagare` agents.
**Status:** accepted; planned as [ExecPlan 112](../plans/112-make-the-acme-identity-context-owned-and-remove-the-personal-fallback-defaults.md).
**Created:** 2026-09-12.


## Why

A context is meant to be the single source of truth for a target: `nagarectl init` writes it,
`nagarectl context show` prints it, and every recipe derives its behavior from it. The Let's Encrypt
account identity escapes that model. It is read from an environment variable that is not part of the
context schema, and when that variable is unset the cluster silently registers an ACME account under
a specific person's personal address, in a specific unrelated GCP project.

This is not a cosmetic default. The ACME contact is the address Let's Encrypt uses for expiry and
policy notices about certificates serving a production domain, and an account registered under the
wrong identity is not corrected by later re-rendering the issuer — the account key already exists,
so fixing it requires deleting the account key Secret and re-bootstrapping. An operator who follows
the documented onboarding exactly, and never sets an undocumented variable, gets the wrong answer
with no warning.

The second-order effect is worse than the first. Because the same renderer also defaults the GCP
project, an unset environment yields a `ClusterIssuer` whose DNS-01 solver points at a project the
cluster's service account cannot write to, so issuance fails with a permissions error that gives no
hint about its actual cause.


## What is missing

`cluster/bootstrap/render-context-template.sh:23,26` — the only place either value is resolved:

```bash
project="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"
acme_email="${NAGARE_ACME_EMAIL:-nadeem@gmail.com}"
```

The script sources `scripts/lib/release.sh` (`:13`) but not `scripts/lib/target.sh`, so it has no
access to the resolved target profile and no guardrail.

`NAGARE_ACME_EMAIL` is absent from the context variable list in `scripts/lib/target.sh:34-42`,
absent from `nagarectl context create`'s flags (`docs/user/reference.md:138`), and absent from the
eight keys `nagarectl init` seeds (`cli/nagarectl/src/Nagare/Init.hs:146-156`). It is documented
nowhere in `docs/user/`. An operator who reads the context documentation end to end will not learn
that it exists.

The rendered issuer is applied during `just cluster-bootstrap` (`justfile:142`), which — per IR-2 —
runs through the launcher without the context loaded, making the unset case the *default* clone-free
experience rather than an edge case.

Related, and cheap to fix in the same change: the ACME directory endpoint is hardcoded to production
in `cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl:7-12`, with staging mentioned only in a
comment. Rehearsing issuance against Let's Encrypt staging — the standard way to avoid burning
production rate limits while debugging a new domain — currently requires editing a packaged template,
which a clone-free install has no supported way to do.


## Requested change

- Add the ACME contact to the context schema as a first-class field, seeded by `nagarectl init`
  (flag and interactive prompt) and printed by `nagarectl context show`.
- Add an optional ACME directory endpoint to the same schema, defaulting to production, so that
  `staging` can be selected per context without editing a packaged file.
- Remove both hardcoded fallbacks from `render-context-template.sh`. With no contact configured the
  render must fail with a message naming the field to set; it must never invent an identity. The
  project should come from the resolved target profile rather than a bare environment variable, so
  that the guardrail in IR-2 covers it.
- Document the field in `docs/user/contexts.md` alongside the existing core fields, and in the
  onboarding runbook at the step where the issuer is created.


## Required verification

- A test proving the renderer fails, with a message naming the missing field, when no ACME contact
  is configured — and that no `ClusterIssuer` is applied in that case.
- A test proving the rendered issuer's `email` and `cloudDNS.project` match the active context for a
  context whose values differ from any built-in default.
- A test proving the staging endpoint is selected when the context requests it.
- A grep-style guard in CI asserting that no personal email address and no specific project id
  appear as a default anywhere in `cluster/bootstrap/`.


## Acceptance

An operator onboarding a new context supplies their own ACME contact through the documented
interface, verifies it with `nagarectl context show`, and finds the same value in the cluster's
`ClusterIssuer`. No Nagare installation ever registers an ACME account under an address its operator
did not choose, and an operator who forgets is told so rather than silently defaulted.


## Non-goals

This request does not change the DNS-01 solver mechanism, the wildcard certificate model, the
`nagare-node` credential path, or cert-manager's version. It does not ask for per-application ACME
accounts.
