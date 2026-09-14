---
title: "The active context owns the ACME identity"
status: accepted
date: 2026-09-12
authors: [shinzui]
related:
  - docs/plans/112-make-the-acme-identity-context-owned-and-remove-the-personal-fallback-defaults.md
  - docs/plans/138-keep-bootstrap-tls-issuance-within-intended-names.md
  - docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md
  - docs/adr/0007-publish-immutable-nix-releases-from-validated-tags.md
  - docs/adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md
---

# ADR 10 — The active context owns the ACME identity

## Status

Accepted, 2026-09-12. Implemented by
[ExecPlan 112](../plans/112-make-the-acme-identity-context-owned-and-remove-the-personal-fallback-defaults.md)
and amended 2026-09-14 by
[ExecPlan 138](../plans/138-keep-bootstrap-tls-issuance-within-intended-names.md).
Together they close [IR-3](../improvement-requests/context-owned-acme-identity.md),
[IR-22](../improvement-requests/system-internal-cert-sent-to-acme.md), and
[IR-23](../improvement-requests/wildcard-certs-for-system-namespaces.md).

## Context

Nagare serves apps over HTTPS using certificates from Let's Encrypt. To obtain them a
cluster registers an **ACME account**, identified by a contact email address and backed by a
private key that cert-manager stores in a Kubernetes Secret. The account is described by one
cluster object, the `letsencrypt-dns` `ClusterIssuer`, created during
`nagare cluster-bootstrap` by rendering
`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl`.

Before EP-112 that identity was not part of any documented interface. The renderer resolved
it from a bare environment variable with a literal fallback:

```bash
project="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"
acme_email="${NAGARE_ACME_EMAIL:-nadeem@gmail.com}"
```

`NAGARE_ACME_EMAIL` appeared in no context file, no command flag, and no page of
`docs/user/`. An operator who followed the documented onboarding exactly therefore got a
cluster that registered a Let's Encrypt account under someone else's personal address and
asked Let's Encrypt to solve its DNS-01 challenge in a Google Cloud project their cluster had
no permission to write to.

Three properties of this problem shaped the decision.

**The mistake is invisible.** Nothing warns; the issuer reaches `READY=True` and serves
certificates. The only symptom is expiry notices arriving at a stranger's mailbox.

**The mistake is sticky.** An ACME account is keyed by the private key in the Secret named
by `privateKeySecretRef`, not by the `email:` field. Re-rendering the issuer with the right
address does not move the account. Recovery means deleting
`letsencrypt-dns-account-key` in the `cert-manager` namespace and bootstrapping again.

**There is no safe default to fall back to.** Every other context field has a generic
default that is safe because it is inert — `apps.example.com` is deliberately non-routable,
`nagare-01` is a local name. An email address has no such value: every syntactically valid
address is somebody's real mailbox.

The related endpoint problem has the same root. Selecting Let's Encrypt's staging service —
the standard way to rehearse issuance on a new domain without burning production rate limits
— required editing a template that ships inside the read-only Nix payload that
[ADR 4](0004-separate-immutable-platform-payloads-from-context-workspaces.md) established,
which a clone-free install has no supported way to do.

## Decision

**Identity a cluster registers with an external certificate authority belongs to the
operator's target context, never to a packaged default.** `NAGARE_ACME_EMAIL` and
`NAGARE_ACME_DIRECTORY` are ordinary context fields: both resolvers know them,
`nagarectl context show` prints them, and `nagarectl init` / `nagarectl context create`
write them. Nothing about the identity lives in the payload.

**A missing identity is a refusal, not a substitution.** There is no built-in contact
anywhere — not in `scripts/lib/target.sh`, not in `Nagare.Target`, not in the renderer. When
a template needs a contact and the active context has none,
`cluster/bootstrap/render-context-template.sh` writes **nothing** to standard output, exits
non-zero, and names the field and the command that sets it. `just cluster-bootstrap` renders
to a temporary file and applies only on success, because `just` runs each recipe line under
`sh -cu` with no `pipefail`, so a pipeline would discard the renderer's exit status and hand
`kubectl` an empty document. Empty standard output is the machine-checkable form of "no
`ClusterIssuer` is applied", and the automated proof asserts exactly that.

**The refusal is scoped to the templates that actually ask for the identity**, detected by
grepping the template, rather than firing whenever a contact is missing. Eight other
bootstrap templates mention neither ACME nor the project, and four of them are rendered on a
laptop by `cluster/bootstrap/local-auth/install.sh` in local mode, where no ACME account is
ever registered. This reuses the resolve-only-what-the-template-asks-for pattern the
`NAGARE_AUTH_TAG` branch already established.

**For the ACME endpoint, an unrecognized value is an error rather than a fallback.** This
deliberately differs from `parseMode` and `parsePulumiBackendKind`, which map an unknown
token onto the safe original behavior. Those fields have a safe direction; ACME does not.
Silently choosing production burns a real rate limit against a real domain; silently
choosing staging installs certificates no browser trusts. Both are worse than refusing. The
refusal is confined to the render and CLI-write steps so a typo cannot break every shell
that enters the repository.

**`nagarectl init` requires the contact; `nagarectl context create` does not.** `init` is
the documented onboarding path and always produces a cloud context, so demanding the contact
there gives the earliest, clearest failure — matching how `--project` is already treated. On
a terminal it prompts; without one it exits non-zero naming the flag. `context create` is
the low-level writer that also creates local contexts (`--mode local`), where an ACME contact
is meaningless. The render-time refusal is the backstop for contexts written that way.

**The project baked into the issuer is guarded like every other cloud write.** The renderer
sources `scripts/lib/target.sh` and calls `_require_target_project` when — and only when —
the template contains `${CLOUDSDK_CORE_PROJECT}`. A template that writes a project id into a
live cluster object is exactly the case
[ADR 9](0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) exists for.
Restricting the call to project-bearing templates keeps the auth-plane templates, which carry
only `${NAGARE_REGISTRY_PREFIX}`, free of new preconditions.

**The two Let's Encrypt directory URLs are duplicated between the shell and Haskell
resolvers, under a CI drift guard.** The renderer is a standalone bash script invoked
directly by `cluster/bootstrap/auth-install.sh` and
`cluster/bootstrap/local-auth/install.sh`, so it cannot call back into `nagarectl` without
creating a circular runtime dependency. Duplicating two constant strings is acceptable;
undetected drift between them is not, so the `cluster-bootstrap-defaults` flake check asserts
each URL appears in both resolvers and nowhere else.

**The public issuer is authorized by certificate role and namespace, not merely
by possession of the cluster-wide issuer.** `letsencrypt-dns` is the external-domain
issuer. System-internal and cluster-local certificate roles explicitly select
`knative-selfsigned-issuer`. Namespace wildcards require the opt-in label
`nagare.dev/app-namespace=true`; Nagare's application workload paths reconcile
that label and reject fixed platform namespaces. A parsed policy diagnostic
checks both rules before bootstrap stamps success and as part of day-two doctor.

**Nagare carries the minimum controller correction inside its immutable payload.**
The latest and final `mori://knative-extensions/net-certmanager` release aliases
the three issuer defaults through one mutable pointer, and archived upstream
`main` retains the defect. Nix fetches its exact v1.14.0 source commit, applies a
small patch plus upstream-style regression case, builds a Linux/amd64 controller
image, and embeds the archive in `nagare-platform`. Bootstrap imports the archive
directly into the selected k3s image store and replaces only the controller
Deployment; it does not introduce a mutable registry dependency or a separately
hosted fork. Artifact-level Mori coverage for the upstream source file is pending.

## Consequences

**`nagarectl init` gains one more required answer.** A non-interactive run without
`--acme-email` now fails. This is a deliberate breaking change to an existing command line;
the hermetic fixture in `flake.nix` that exercises it was updated to assert the refusal
*and* the accepted form, rather than exempted — a fixture weakened to stay green would prove
nothing.

**A cluster bootstrapped before this change keeps its existing account.** Context files stay
compatible in both directions: a context written by the new code carries two extra `export`
lines that older code ignores, and a context written before this change is read correctly and
simply has no contact — which is the case the refusal exists for. An operator who already
bootstrapped under the wrong address recovers by deleting
`letsencrypt-dns-account-key` and re-running bootstrap with the right contact in the context.
Certificates already issued stay valid and keep serving; they are re-issued under the new
account at their next renewal. This procedure is documented in
[Target contexts](../user/contexts.md#acme-identity) and
[cluster bootstrap](../user/cluster-bootstrap.md), because a decision that makes a mistake
unrecoverable-by-default owes the operator the recovery.

**Selecting staging no longer requires editing a packaged file**, so the rehearse-then-switch
workflow works on a clone-free install, consistent with ADR 4.

**Reintroducing a personal default fails the build.** The `cluster-bootstrap-defaults` check
refuses any specific project id or email-shaped literal in a non-comment line under
`cluster/bootstrap/`. Addresses at the RFC 2606 / RFC 6761 reserved example domains
(`example.com`/`.org`/`.net`, `*.example`) are erased from each line before matching — those
names are reserved in perpetuity and can never be a real mailbox, and the renderer's own
refusal message has to print one to tell an operator what a contact looks like. Erasing the
address rather than exempting the whole line keeps a real address on the same line
detectable.

**The refusal is a non-event.** The renderer only ever writes to standard output and never
contacts a network, so a refused render mutates nothing and is safe to re-run once the
context carries a contact.

**Certificate authorization is now fail-closed and observable.** Adding a new
platform namespace never makes it public-certificate eligible by default. Each
eligible public wildcard still consumes CA rate budget and may publish its names
through Certificate Transparency, so the opt-in label is a security boundary.
Already-issued certificates are not bulk-deleted automatically; operators must
inventory and remove exact stale Certificate, CertificateRequest, Order, and
Secret objects after reviewing ownership.

**The controller patch is version-coupled and release-tested.** Changing the
net-certmanager pin requires rechecking authoritative releases, applying the
patch cleanly, running the combined native upstream regression, and passing the
disposable-cluster certificate-policy proof. Once upstream or a successor
controller provides equivalent behavior, Nagare can remove the carried patch
and bundled replacement together.
