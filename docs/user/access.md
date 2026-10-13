---
type: Runbook
title: "Identity-aware access"
description: "Configure, verify, operate, and revoke identity-aware access to protected Nagare services."
docId: DOC-2
tags: [access, authentication, authorization, operations]
generated:
  by: human:nadeem
  at: 2026-08-28T12:26:08Z
---

# Identity-aware access

> **Status:** 🟢 **Built and locally validated.**
>
> The DSL field, `nagarectl` deploy-time resolver, grant/revoke/list commands,
> enforcer service, bootstrap manifests, protected example, and shared-host
> routing model exist and have tests. Cookie integrity, login return paths,
> hostile Host headers, en-outage handling, and cache eviction have also been
> hardened. The current Shomei and En dependency pins, authenticated En calls,
> service-owned migrations, and the full 302 → 403 → 200 → 403 grant lifecycle
> have been validated in **local mode**
> (MasterPlan 16 EP-85): the three images build into the local registry, shomei/en
> run on local managed Postgres, and a locally-trusted `nagare-local-ca` issuer
> provides the HTTPS WebAuthn needs — see
> [Local development → optional auth plane](local-development.md#optional-the-auth-plane).

Identity-aware access lets a public Nagare URL stay reachable from the internet
while requiring a signed-in shomei user and an en authorization grant before the
app is served. This is the BeyondCorp-style model: no VPN, but every request is
checked by identity and relationship.

Public sites remain the default. A site becomes protected only when its typed
config opts in. The field is the same on every web workload kind: a
`Deployment`, an `Application`, a `StaticSite` and a `ServerSite`
(MasterPlan 27, EP-186):

```haskell
import Nagare.Dsl.Access (requireLogin)

deployment = do
  ...
  pure dep { access = Just requireLogin }
```

`requireLogin` means: authenticate with shomei, then ask en whether subject
`user:<shomei-user-id>` has permission `access` on object
`app:<public-host>`. Every hostname is its own object: each custom domain,
the default `<name>.<namespace>.<base-domain>` hostname when no domain is
declared, and every preview hostname needs its own grant. Signing in alone
never admits anyone: a protected site with no grants answers 403 to every
signed-in user, and there is no administrator bypass.

This release enforces exactly `requireLogin`. A policy with another
permission or an explicit audience is refused at planning time rather than
silently ignored, because the enforcer checks permission `access` and verifies
the cluster audience. A `StaticSite` or `ServerSite` cannot be the auth
portal; the portal remains a `Deployment` or `Application` role.

## Install the optional auth plane

> **Local mode:** on a local k3d cluster, `cluster/bootstrap/local-auth/install.sh`
> runs the same reviewed platform bootstrap. Build the three images and install local
> TLS first, then export the three image references as shown below. See
> [Local development → optional auth plane](local-development.md#optional-the-auth-plane).

The auth plane is a reviewed platform component. `nagarectl platform bootstrap`
composes it together with the other platform scopes: the `shomei-db` and `en-db`
managed databases, the `nagare-system` namespace, the generated credentials, the
migration Jobs and the three workloads. Build the three images first, then pass
their immutable references to the reviewed bootstrap:

```bash
for service in shomei en nagare-access; do
  cluster/bootstrap/auth-images/build-local-image.sh "$service"   # prints the image reference
done

export NAGARE_AUTH_SHOMEI_IMAGE=<registry>/shomei@sha256:<digest>
export NAGARE_AUTH_EN_IMAGE=<registry>/en@sha256:<digest>
export NAGARE_AUTH_ACCESS_IMAGE=<registry>/nagare-access@sha256:<digest>

nagarectl platform bootstrap plan --out ./platform-review
nagarectl platform bootstrap apply ./platform-review --yes
```

`cluster/bootstrap/auth-install.sh` runs the same plan and apply. Do not create the
namespace, the databases or the `nagare-access` Secret with `kubectl` or
`nagarectl db create` first: they are inventory members of the auth component, and a
pre-existing object at their addresses is refused as unowned. The bootstrap generates
the `nagare-access` cookie key the first time it creates that Secret.

The installer generates and preserves En's read-write/read-only API keys and Shomei's
mandatory key-encryption key. It never prints or commits those generated values.

`cluster/bootstrap/auth-install.sh` renders the `image:` values from the active
target context (`NAGARE_REGISTRY_PREFIX`, `NAGARE_AUTH_TAG`) before applying the
manifests. It also sets the `nagare-access` cookie domain to `.${NAGARE_BASE_DOMAIN}`,
so one sign-in covers every protected host under the context's base domain. Rerun
the installer after changing a context's base domain.

The shomei and en manifests read `POSTGRES_USER`, `POSTGRES_PASSWORD`, and
`POSTGRES_DB` from Nagare's managed DB Secrets `nagare-db-shomei-db` and
`nagare-db-en-db`. They use libpq keyword connection strings / `PG*` environment
variables rather than the managed `DATABASE_URL` key, because generated database
passwords may contain URL metacharacters. The database names include `-db` so
their Kubernetes Services do not collide with the auth services named `shomei`
and `en`.

Each service owns its PostgreSQL schema as an embedded pg-migrate plan. The installer
runs `shomei-migrate up` and `en-migrate up` as explicit Kubernetes Jobs from the same
image tags as their servers, waits for both Jobs to complete, and only then rolls out
the workloads. The ledger makes reruns idempotent while published migration history is
unchanged; Nagare does not carry a duplicate copy of either service's SQL.

> **Shomei 0.2.0.0 upgrade:** the release repaired migration bugs by rewriting its
> existing 36-file history to be schema-qualified. That intentionally changes the
> pg-migrate checksums, so a `shomei-db` initialized by an earlier Shomei revision
> cannot be upgraded in place. The former direct `db delete --yes` procedure is
> unavailable. A managed database must be retired through a saved review, and its
> retained native resources need separate exact collection before the same name
> can be reused. Treat that migration as a separate recovery operation.
>
> This discard policy is specific to Nagare's unused deployment. A deployment with
> data to preserve needs an operator-led ledger remediation instead. See
> `mori://shinzui/shomei/packages/shomei-migrations`.

## Deploy a protected site

The bundled example is `cluster/examples/protected-hello`:

```bash
nagarectl deploy -f cluster/examples/protected-hello/nagare/Config.hs
```

If the auth plane is absent, a protected deploy fails closed before changing the
route:

```text
this site sets `access = requireLogin`, but the nagare auth plane is not installed.
       Install it once with the managed DB, shomei, en, and nagare-access sequence in docs/user/access.md.
       Then redeploy.
```

When the plane is installed, `nagarectl` writes the host to the
`nagare-access-backends` ConfigMap, removes the app-namespace DomainMapping for
that host, and owns the protected host's DomainMapping in `nagare-system` so it
can target the shared `nagare-access` Knative Service.

For an inventory-managed Service or application, save a reviewed deploy with an
accepted auth scope, a published image resource, and an explicit image tag:

```bash
nagarectl deploy -f nagare/Config.hs --tag TAG --image-resource RESOURCE_ID --save-plan ./protected-review
nagarectl inventory apply ./protected-review
nagarectl access portal sync --save-plan ./access-sync-review
nagarectl inventory apply ./access-sync-review --yes
```

The review includes a contribution to the auth owner's backend map and a
DomainMapping in `nagare-system` that points to the accepted enforcer Service.
An auth portal also waits for the owner's Shomei settings. The default Service
hostname is claimed when the config declares no custom domain. Missing auth
history or a different base domain refuses planning. Supplied origin TLS and
CDN intent are not yet supported by this reviewed route. Existing direct
access routes need an explicit ownership transition before a reviewed plan can
claim their live DomainMapping.
`app deploy` and standalone `deploy` always use the reviewed route. Once the
auth backend map has accepted or retained inventory ownership, direct
`app delete` refuses its legacy access resolver; use reviewed retirement for
that scope.
Retirement retains the central DomainMapping. Its later removal is a separate
`inventory collect --resource` review with an exact UID and resource version;
the route is never deleted by a name-only command.

A `StaticSite` or `ServerSite` takes the same reviewed route through
`nagarectl site deploy`, `site rollback` and `site preview deploy`
([static hosting](static-hosting.md#protected-sites);
[`cluster/examples/protected-static-site`](../../cluster/examples/protected-static-site)
is the bundled example). Its origin Service is
cluster-local, so the generated Knative hostname is not a public alternative
to the protected route, and a rollback changes only the image: protection
follows the current config, never older release history. A protected site
cannot use a CDN or supplied origin TLS. An accepted public site cannot
become protected in place, because its route moves from the site namespace to
`nagare-system`: the planner refuses with `migration-review-required`. Retire
the public site (and collect its DomainMapping), then deploy it protected.

## Customize sign-in with an auth portal

The built-in sign-in and plain 403/503 pages remain the default. To supply your own
brand, password-reset pages, account management, and passkey flows, deploy one ordinary
app with `access = Just authPortal`. The bundled implementation lives at
`cluster/examples/auth-portal`:

```bash
cd cluster/examples/auth-portal
nagarectl deploy -f nagare/Config.hs
nagarectl access portal show
```

Once registered, document requests redirect to the portal's `/login` page and the
enforcer embeds its branded error pages without changing the protected URL or status.
The old form stays reachable at `/_nagare/login?builtin=1` as a break-glass path.

Read [Operator-owned authentication portal](auth-portal.md) before implementing or
restyling a portal. It defines the fixed paths, response handoff header, CSRF boundary,
token handling, Shomei synchronization, and safe removal procedure.

## Manage grants

Grant a shomei user access to one protected host:

```bash
nagarectl access grant --host protected-hello.apps.example.com --user alice@example.com
```

`--user` takes the email the person signed up with, or their Shomei user id
(`user_01h455vb4pex5vsknk084sn02q`). The enforcer checks the user id, so the CLI
looks an email up in the context's Shomei database (`shomei-db` in
`nagare-system`, read-only through the selected kubeconfig) and prints the id
it found. The person must sign up first. An email with no Shomei user, an email
matching more than one, and anything that is neither an email nor a `user_…` id
refuse before anything is planned.

The host suffix comes from the active context's `NAGARE_BASE_DOMAIN`. A `labs`
context with `labs.topagentnetwork.net` uses
`protected-hello.labs.topagentnetwork.net` in these commands.

List the host's stored grants, direct users apart from teams (`--json` for a
machine-readable form). This reads stored relationships at a fully consistent
snapshot; it never expands a team into its members, and it is not an effective
access check:

```bash
nagarectl access list --host protected-hello.apps.example.com
```

Revoke the grant:

```bash
nagarectl access revoke --host protected-hello.apps.example.com --user alice@example.com
```

### Check effective access

Ask En, at a fully consistent snapshot, whether one user currently has `access`
on one protected host, through every path (direct grants and teams), with the
same permission the enforcer evaluates:

```bash
nagarectl access check --host protected-hello.apps.example.com --user alice@example.com
nagarectl access check --host protected-hello.apps.example.com --user alice@example.com --json
```

The answer is `allowed`, `denied`, `conditional` (a caveat En could not
evaluate; the enforcer refuses it), or `unavailable` (En did not answer; this
is not a denial and exits nonzero). It names the snapshot token it was decided
at, never a timestamp. The gateway may still serve its cached decision for up to
`NAGARE_ACCESS_DECISION_TTL` seconds after a change, so a fresh `denied` here can
coexist briefly with an admitted session. The command reads En through the
context's private transport with `NAGARE_EN_API_KEY`; it writes nothing, and it
never infers an answer from `access list`.

### Teams

A team is a named group with flat user membership, held in En as
`group:<team>#member` relationships (MasterPlan 27, EP-187). A site grant to a
team (`app:<host>#viewer@group:<team>#member`) admits exactly the team's current
members on that one host. Team keys are lowercase identifiers
(`[a-z][a-z0-9_-]{0,62}`), chosen once and never renamed; a team exists from
its first accepted membership. Team changes are always reviewed:

```bash
nagarectl access team add-member --team engineering --user alice@example.com --save-plan ./member-review
nagarectl inventory apply ./member-review --yes
nagarectl access grant --host protected-hello.apps.example.com --team engineering --save-plan ./team-review
nagarectl inventory apply ./team-review --yes
nagarectl access team list-members --team engineering
nagarectl access team remove-member --team engineering --user alice@example.com --save-plan ./remove-review
nagarectl access revoke --host protected-hello.apps.example.com --team engineering --save-plan ./revoke-team-review
```

Exactly one of `--user` and `--team` goes with `grant` and `revoke`. A
membership depends on the context's accepted En service; a team grant also
depends on the exact protected route, never on a particular member, so the
last member can be removed without disturbing the grant, and removing all
members does not revoke it. Revoking a direct grant leaves an independent
team grant in place, and removing one membership leaves access through a
direct grant or another team. A team grant for a team with no accepted
membership in the context refuses. The reviewed write requires the context's
En to serve the reviewed schema with group membership (`GET /v1/schema`);
until the platform update that ships it is applied, team changes refuse with
the schema as the reason.

The commands talk to En and must use its read-write bearer key: pass `--en-api-key KEY`
or set `NAGARE_EN_API_KEY`. `access list` and the direct grant and revoke forms also
need En's address: pass `--en-url URL` or set `NAGARE_EN_URL`. From a workstation, a
local port-forward keeps the service private while making the CLI usable:

```bash
kubectl -n nagare-system port-forward svc/en 18082:80 &
export NAGARE_EN_URL=http://127.0.0.1:18082
export NAGARE_EN_API_KEY="$(kubectl -n nagare-system get secret nagare-en-api-keys \
  -o jsonpath='{.data.read-write}' | base64 -d)"
```

For an inventory-backed context, save and apply each change:

```bash
nagarectl --context "$CONTEXT" access grant --host "$HOST" --user alice@example.com --save-plan ./grant-review
nagarectl --context "$CONTEXT" inventory apply ./grant-review --yes
nagarectl --context "$CONTEXT" access revoke --host "$HOST" --user alice@example.com --save-plan ./revoke-review
nagarectl --context "$CONTEXT" inventory apply ./revoke-review --yes
```

Set private `NAGARE_EN_API_KEY` for planning, apply, recovery and `inventory status`.
Reviewed grants reach the context's En themselves, through a private port-forward to
its Service that lasts one call, so they need no `NAGARE_EN_URL` and refuse
`--en-url`. A grant therefore does not depend on the local port it was made through;
grants recorded through an older forward are observed and revoked the same way.
Reviews contain the selected relationship, never the key; a grant named by email reads
`grant user_… (alice@example.com) viewer on HOST`. The selected context's
kubeconfig must be available; the CLI checks the accepted En Service and
protected DomainMapping before the tuple write. En must support atomic
relationship preconditions. Older services fail the capability check before a
write. An existing relationship without an accepted owner also refuses.

Without the key, planning refuses with `observation-unavailable: required resource
observation is unavailable: reviewed access requires private NAGARE_EN_API_KEY`, and
`inventory status --json` gives the same reason for each access resource. Other
observation failures name their cause the same way, for example `en port-forward failed`
or `access relationship query refused`. `inventory apply` and `inventory resume` of a
review with access operations refuse before admitting it:

```text
reviewed access requires private NAGARE_EN_API_KEY; export it in this shell and rerun this command (the saved review stays valid)
```

Nothing is claimed or journalled, so export the key and rerun the same command with
the same review. `inventory recover` and `inventory close` are not gated by this check.

If a response is lost, resume the original transaction ID printed by the apply
command with `inventory resume ID --yes`. Recovery observes the exact direct
`viewer` tuple and its reviewed owners rather than repeating an uncertain write.
Grant and revoke preserve other subjects, hosts, and application/auth revisions.

To retire an application that has access grants, revoke each grant first, then retire
the application and the grants' scopes in one review. A revoked grant is retained as
history and grants nothing. Retirement refuses a grant that is still live
(`access-grant-live`): once its scope was retired, no reviewed command could revoke it.

`access portal sync --save-plan DIR` composes all accepted backend and portal
contributions, reviews the shared settings, and rolls Shomei and the access enforcer after the settings
are ready. Both processes load their settings at startup; updating a ConfigMap
alone does not activate a new protected backend. The rollout preserves accepted
images and workload names. Apply that saved review through `inventory apply`. Direct forms
without `--save-plan` remain available only before inventory initialization;
read-only `access list` and `access portal show` remain available afterward.

## Request behavior

For a protected host:

- an unauthenticated browser document request redirects to
  `/_nagare/login?rd=<original-path>`;
- an unauthenticated JSON/API request returns `401` JSON instead of HTML;
- an authenticated but ungranted user receives `403`;
- an authenticated request receives `503` when en cannot answer, rather than a
  misleading denial; transport failures are not cached, so the next request
  retries en;
- a granted user is proxied to the app, with `X-Forwarded-User` set to the
  shomei user id;
- the session cookie is scoped to the parent domain, so one login can work
  across protected subdomains under the same base domain.

En publishes an optimized revision on a short interval, so list results can lag a
successful mutation by several seconds. The enforcer asks En at a fully consistent
snapshot whenever its decision cache misses, so that lag never delays a decision. The
cache itself is the only bound on freshness: `NAGARE_ACCESS_DECISION_TTL` seconds
(default 30, zero disables it), measured on a monotonic clock from the start of the
En check. An acknowledged grant or revoke therefore reaches new requests after at
most that TTL; it does not disconnect a stream that was already admitted. A check
that takes longer than the TTL produces an already-expired entry, and a slower older
check can never replace a newer answer. Live entries are bounded (10,000 by
default); at the bound, expired entries go first, then the oldest.

## Example verification

After deploying `protected-hello`, an unauthenticated request should redirect:

```bash
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://protected-hello.apps.example.com/
# 302 https://protected-hello.apps.example.com/_nagare/login?rd=%2F
```

After signing in as a shomei user without a grant, the site should return
`403`. After:

```bash
nagarectl access grant --host protected-hello.apps.example.com --user alice@example.com
```

the same authenticated user should receive `200` and the hello page body.

## Security model

`nagare-access` owns the browser-facing session cookies. The access token cookie
is `HttpOnly`, `Secure`, `SameSite=Lax`, and scoped to the configured parent
domain. Refresh tokens are wrapped in a signed cookie using
`NAGARE_ACCESS_COOKIE_KEY`; the signature covers the exact token bytes and is
verified with a constant-time comparison, so a modified cookie is rejected.
Generate the key with `openssl rand -base64 48`, keep it in the
`nagare-access` Secret, and rotate it as a session-invalidating credential.

Built-in login return destinations are restricted to same-host absolute paths. Portal
return destinations must be HTTPS URLs whose host is present in the backend map and
whose path passes the same path checks. Protocol-relative paths, unknown hosts,
userinfo, backslashes, and control characters fall back to the portal home, preventing
return parameters from becoming open redirects or response-header injection. Invalid
UTF-8 in a hostile `Host` header is treated as an unknown host instead of crashing the
request handler.

Apps do not implement authentication themselves. They receive requests only
after the enforcer has verified the shomei JWT and en has allowed
`app:<host>#access`. For server-rendered apps that want to know the user, trust
`X-Forwarded-User` only when the app is reached through the internal cluster
path behind `nagare-access`.

Before proxying, the enforcer strips its session, refresh, and CSRF cookies from every
upstream request. The registered portal alone receives a verified bearer access token,
and only its internal response may request a session handoff. The enforcer rotates the
handoff refresh token before setting browser cookies and owns the cookie-signing key.

The future ingress direction is Envoy Gateway `ext_authz`. The DSL field and en
authorization model should stay the same; only the routing mechanism changes.
