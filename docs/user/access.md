# Identity-aware access

> **Status:** 🟡 **Built, with live routing fixes in place.**
>
> The DSL field, `nagarectl` deploy-time resolver, grant/revoke/list commands,
> enforcer service, bootstrap manifests, protected example, and shared-host
> routing model exist and have tests. The auth plane also runs in **local mode**
> (MasterPlan 16 EP-85): the three images build into the local registry, shomei/en
> run on local managed Postgres, and a locally-trusted `nagare-local-ca` issuer
> provides the HTTPS WebAuthn needs — see
> [Local development → optional auth plane](local-development.md#optional-the-auth-plane).

Identity-aware access lets a public Nagare URL stay reachable from the internet
while requiring a signed-in shomei user and an en authorization grant before the
app is served. This is the BeyondCorp-style model: no VPN, but every request is
checked by identity and relationship.

Public sites remain the default. A site becomes protected only when its typed
config opts in:

```haskell
import Nagare.Dsl.Access (requireLogin)

deployment = do
  ...
  pure dep { access = Just requireLogin }
```

`requireLogin` means: authenticate with shomei, then ask en whether subject
`user:<shomei-user-id>` has permission `access` on object
`app:<public-host>`.

## Install the optional auth plane

> **Local mode:** the steps below are the cloud install. To run the auth plane on
> a local k3d cluster, use the scripted local installer
> `cluster/bootstrap/local-auth/install.sh`, which builds the three images into the
> local registry, creates the `shomei-db`/`en-db` managed Postgres, applies the
> manifests, and stands up the `nagare-local-ca` issuer with Knative auto-TLS. See
> [Local development → optional auth plane](local-development.md#optional-the-auth-plane).

The auth plane is not part of `just cluster-bootstrap`. Install it only on
clusters that need protected sites:

```bash
kubectl create namespace nagare-system --dry-run=client -o yaml | kubectl apply -f -

nagarectl db create postgres shomei-db --namespace nagare-system
nagarectl db create postgres en-db --namespace nagare-system

cp cluster/bootstrap/nagare-access/secret.example.yaml.tmpl /tmp/nagare-access-secret.yaml
# edit /tmp/nagare-access-secret.yaml before applying it
kubectl apply -f /tmp/nagare-access-secret.yaml

cluster/bootstrap/auth-install.sh
```

Before applying for real, edit the Secret template:

- `cluster/bootstrap/nagare-access/secret.example.yaml.tmpl` needs a long random
  `cookie-key`.

`cluster/bootstrap/auth-install.sh` renders the `image:` values from the active
target context (`NAGARE_REGISTRY_PREFIX`, `NAGARE_AUTH_TAG`) before applying the
manifests. The `nagare-access` cookie domain still defaults to `.apps.example.com`;
patch it for a real domain if needed.

The shomei and en manifests read `POSTGRES_USER`, `POSTGRES_PASSWORD`, and
`POSTGRES_DB` from Nagare's managed DB Secrets `nagare-db-shomei-db` and
`nagare-db-en-db`. They use libpq keyword connection strings / `PG*` environment
variables rather than the managed `DATABASE_URL` key, because generated database
passwords may contain URL metacharacters. The database names include `-db` so
their Kubernetes Services do not collide with the auth services named `shomei`
and `en`.

Build and push the enforcer image with:

```bash
cluster/bootstrap/nagare-access/build-image.sh
```

shomei runs its migrations during startup. en currently expects its PostgreSQL
migrations to have been run before `en-server` starts; the bootstrap wrapper is
`cluster/bootstrap/en/migrations.yaml`, which uses `psql` from the `postgres:18`
image and skips when the en tables already exist.

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

## Manage grants

Grant a shomei user access to one protected host:

```bash
nagarectl access grant --host protected-hello.apps.example.com --user alice
```

List users that expand to the host's `access` permission:

```bash
nagarectl access list --host protected-hello.apps.example.com
```

Revoke the grant:

```bash
nagarectl access revoke --host protected-hello.apps.example.com --user alice
```

The commands talk to en. Pass `--en-url URL` or set `NAGARE_EN_URL`, for
example:

```bash
export NAGARE_EN_URL=http://en.nagare-system.svc.cluster.local
```

## Request behavior

For a protected host:

- an unauthenticated browser document request redirects to
  `/_nagare/login?rd=<original-path>`;
- an unauthenticated JSON/API request returns `401` JSON instead of HTML;
- an authenticated but ungranted user receives `403`;
- a granted user is proxied to the app, with `X-Forwarded-User` set to the
  shomei user id;
- the session cookie is scoped to the parent domain, so one login can work
  across protected subdomains under the same base domain.

The enforcer caches en decisions briefly, defaulting to 30 seconds. A grant or
revoke may therefore take up to that TTL to affect an already active session.

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
nagarectl access grant --host protected-hello.apps.example.com --user alice
```

the same authenticated user should receive `200` and the hello page body.

## Security model

`nagare-access` owns the browser-facing session cookies. The access token cookie
is `HttpOnly`, `Secure`, `SameSite=Lax`, and scoped to the configured parent
domain. Refresh tokens are wrapped in a signed cookie using
`NAGARE_ACCESS_COOKIE_KEY`.

Apps do not implement authentication themselves. They receive requests only
after the enforcer has verified the shomei JWT and en has allowed
`app:<host>#access`. For server-rendered apps that want to know the user, trust
`X-Forwarded-User` only when the app is reached through the internal cluster
path behind `nagare-access`.

The future ingress direction is Envoy Gateway `ext_authz`. The DSL field and en
authorization model should stay the same; only the routing mechanism changes.
