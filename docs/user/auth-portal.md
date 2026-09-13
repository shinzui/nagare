---
type: Runbook
title: "Operator-owned authentication portal"
description: "Deploy, customize, operate, and remove an authentication portal for protected Nagare sites."
docId: DOC-37
tags: [access, authentication, portal, passkeys, operations]
generated:
  by: openai/gpt-5.6-sol
  at: 2026-09-13T05:30:00Z
---

# Operator-owned authentication portal

> **Status:** 🟢 **Built and locally validated.**
>
> Password login, authorization, branded failures and fallback, account password
> changes, logout revocation, reinstall persistence, and removal were exercised on
> local k3d. Passkeys still require the manual trusted-browser ceremony below.

Nagare can replace the built-in sign-in and access-error pages with an ordinary app
that you own. The portal supplies the user experience; `nagare-access` still verifies
sessions, asks En for authorization, and owns every browser-facing `nagare_*` cookie.

One portal serves all protected hosts beneath a target context's base domain. The
portal itself is routed through `nagare-access` in a special mode: anonymous requests
can reach its login pages, while signed-in requests carry the user's identity and
access token to its account pages.

## Before you deploy

Install the optional auth plane as described in
[Identity-aware access](access.md#install-the-optional-auth-plane). The portal host must:

- be the app's only public domain;
- be a subdomain of the active context's `NAGARE_BASE_DOMAIN`; and
- be the only app whose policy is `authPortal`.

`nagarectl` refuses a second portal or an out-of-domain portal before changing the
backend map. Public and `requireLogin` apps remain unaffected.

## Deploy the reference portal

The copyable implementation is in `cluster/examples/auth-portal`. It uses only the
Node 22 standard library and defaults to the host `auth.<base-domain>`:

```bash
node --test cluster/examples/auth-portal/test/contract-test.mjs
cd cluster/examples/auth-portal
nagarectl deploy -f nagare/Config.hs
nagarectl access portal show
```

The last command prints the registered host and cluster-local upstream:

```text
portal: auth.apps.example.com -> http://auth-portal.personal.svc.cluster.local
```

The typed policy is the only special deployment setting:

```haskell
import Nagare.Dsl.Access (authPortal)

deployment = do
  ...
  pure dep { access = Just authPortal }
```

The reference app reads these environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SHOMEI_URL` | `http://shomei.nagare-system.svc.cluster.local` | Private Shomei API base URL. |
| `PORTAL_TITLE` | `Nagare` | Text brand shown on every page. |
| `PORTAL_LOGO_URL` | empty | Optional logo URL. |
| `PORTAL_ALLOW_SIGNUP` | `false` | Whether the portal offers its sign-up page. |

Use `nagarectl env set` to customize these without changing the contract. The sign-up
switch controls only the portal UI. Shomei remains cluster-internal and keeps its own
API policy.

Deploying the portal registers its typed backend entry, points its public DomainMapping
at `nagare-access`, and configures Shomei with:

- `SHOMEI_WEBAUTHN_RP_ID=<base-domain>`;
- the portal origin added to `SHOMEI_WEBAUTHN_ORIGINS`; and
- `SHOMEI_PUBLIC_BASE_URL=https://<portal-host>` for email links.

These changes roll Shomei only when a value differs. Redeploying the same portal is
safe. The managed cloud and local auth-plane installers preserve both the backend map
and Shomei's portal environment. If either is replaced by an older installer or a
manual manifest application, restore the Shomei values with:

```bash
nagarectl access portal sync
```

`sync` exits successfully with `no portal registered` when the backend map has none.

## Finish local passkey validation later on macOS

This procedure completes the one browser-only acceptance check left by ExecPlan 117.
It changes the macOS System keychain, so save any browser work first and run the `sudo`
commands yourself. Trusting this development CA lets the holder of its private key in
the local cluster mint certificates accepted by the machine. Remove the trust after the
test unless you intentionally use this cluster for ongoing browser development.

### 1. Start the saved local cluster

From the Nagare repository root:

```bash
colima start

kubectl --context k3d-nagare-local \
  -n nagare-system wait --for=condition=Available \
  deployment/shomei deployment/en --timeout=180s
kubectl --context k3d-nagare-local \
  -n nagare-system wait --for=condition=Ready \
  ksvc/nagare-access --timeout=180s
```

The explicit context keeps the workstation's current kubectl context unchanged.

### 2. Inspect and trust only Nagare's CA

Export the root from the known local cluster and inspect it before changing the
keychain:

```bash
kubectl --context k3d-nagare-local \
  -n cert-manager get secret nagare-local-ca \
  -o jsonpath='{.data.tls\.crt}' \
  | base64 -d > /tmp/nagare-local-ca.pem

openssl x509 -in /tmp/nagare-local-ca.pem \
  -noout -subject -issuer -fingerprint -sha256
```

Both subject and issuer must be `CN=nagare-local-ca`. If they are not, stop. Install
that inspected certificate into the System keychain:

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  /tmp/nagare-local-ca.pem
```

Fully quit Chrome and reopen it so the browser reloads the trust settings. Do not click
through a certificate interstitial; a bypassed warning does not prove a valid WebAuthn
secure origin.

### 3. Deploy the portal and verify its served certificate

```bash
source "$HOME/.config/nagare/contexts/local.env"
export NAGARE_CONTEXT=local

(
  cd cluster/examples/auth-portal
  nagarectl --context local deploy -f nagare/Config.hs
)

nagarectl --context local access portal show

openssl s_client \
  -connect auth.127-0-0-1.sslip.io:443 \
  -servername auth.127-0-0-1.sslip.io </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer
```

Expect the portal certificate's issuer to be `CN=nagare-local-ca`. If it says
`portless Local CA`, another local endpoint owns port 443. Stop there, quit that
endpoint, restart Colima, and repeat this certificate check. Do not substitute port
18443 for the browser test: WebAuthn validates the exact configured origin
`https://auth.127-0-0-1.sslip.io`.

### 4. Create and grant a disposable test identity

Choose a unique email and enter a temporary password without placing it in shell
history:

```bash
TEST_EMAIL="passkey-$(date +%s)@example.test"
read -s "TEST_PASSWORD?Temporary test password: "
printf '\n'
printf '%s\n' "$TEST_PASSWORD" | \
  kubectl --context k3d-nagare-local \
    -n nagare-system exec -i deploy/shomei -- \
    env LC_ALL=C.UTF-8 shomei-admin users create \
      --email "$TEST_EMAIL" --display-name "Passkey test" --email-verified
printf 'Test login: %s\n' "$TEST_EMAIL"
```

Copy the printed `user_...` identifier. In a second terminal, keep this private En
port-forward running:

```bash
kubectl --context k3d-nagare-local \
  -n nagare-system port-forward service/en 18082:80
```

Back in the first terminal, replace `user_...` and grant the protected example:

```bash
export NAGARE_EN_URL=http://127.0.0.1:18082
export NAGARE_EN_API_KEY="$(kubectl --context k3d-nagare-local \
  -n nagare-system get secret nagare-en-api-keys \
  -o go-template='{{index .data "read-write" | base64decode}}')"
nagarectl --context local access grant \
  --host protected-hello.127-0-0-1.sslip.io --user user_...
unset NAGARE_EN_API_KEY
```

Keep `TEST_PASSWORD` private. If Codex is helping with the browser, fill the password
yourself and complete every native Touch ID/passkey prompt.

### 5. Exercise all three browser ceremonies

1. Open `https://auth.127-0-0-1.sslip.io/login`, sign in with `TEST_EMAIL` and the
   temporary password, then open `https://auth.127-0-0-1.sslip.io/account`.
2. Select **Add a passkey**, complete the native prompt, and confirm that **Browser
   passkey** appears in the account list.
3. Select **Sign out**, open `https://protected-hello.127-0-0-1.sslip.io/`, and submit
   the password login again. Expect the **Use your passkey** page; select **Continue**,
   complete the prompt, and expect the protected app to load.
4. Sign out again, open `https://auth.127-0-0-1.sslip.io/login`, select **Sign in with a
   passkey**, and complete the prompt. Expect a signed-in redirect rather than another
   password form.

If you want Codex to drive the ordinary page interactions, stop after reopening Chrome
and verifying the served certificate, then say: `CA trusted, Chrome restarted, and the
portal certificate is issued by nagare-local-ca.` You retain control of password entry
and native passkey prompts.

### 6. Clean up and remove system trust

Remove the portal through its typed config so its access registration and Shomei origin
are also removed:

```bash
(
  cd cluster/examples/auth-portal
  nagarectl --context local app delete auth-portal \
    --namespace personal --file nagare/Config.hs
)

unset TEST_PASSWORD TEST_EMAIL NAGARE_EN_URL NAGARE_CONTEXT
```

Stop the En port-forward with Control-C. Then remove the exact CA identified by the
exported certificate and stop the local runtime if it was previously stopped:

```bash
NAGARE_CA_SHA1="$(openssl x509 -in /tmp/nagare-local-ca.pem \
  -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
sudo security delete-certificate -Z "$NAGARE_CA_SHA1" \
  /Library/Keychains/System.keychain
unset NAGARE_CA_SHA1
rm -f /tmp/nagare-local-ca.pem
colima stop
```

Fully quit and reopen Chrome once more so removal takes effect.

## Portal HTTP contract

A custom portal may use any language or framework, but it must preserve these paths
and headers. Everything under `/_nagare/` remains reserved for the enforcer.

| Path | Required behavior |
| --- | --- |
| `GET/POST /login` | Render and submit password login; preserve `return_to`. |
| `POST /login/mfa` | Complete Shomei MFA, including a passkey assertion. |
| `POST /login/passkey/begin` and `/complete` | Proxy passwordless passkey login to Shomei. |
| `GET/POST /signup` | Optional account creation; 404 when disabled. |
| `GET/POST /password/forgot` | Request a reset without revealing whether the account exists. |
| `GET/POST /v1/auth/password-reset/confirm` | Render the email-link page, then submit the token and new password to Shomei. |
| `GET /v1/auth/verify-email/confirm` | Consume the email token server-side and render a result. |
| `GET /account` | Show account and passkey state; redirect anonymous users to `/login`. |
| `POST /account/password` | Change the signed-in user's password. |
| `POST /account/passkeys/begin`, `/complete`, and `/<id>/delete` | Manage the signed-in user's passkeys. |
| `GET /errors/403` and `/errors/503` | Return small `text/html` pages for the enforcer to embed. |
| `GET /healthz` | Return 200 for the Knative readiness probe. |

The portal calls Shomei from its server side. Shomei is not a browser CORS API. On an
authenticated portal request, `nagare-access` supplies:

- `X-Forwarded-User: <shomei-user-id>` for display and application decisions; and
- `Authorization: Bearer <access-token>` for authenticated Shomei calls.

Anonymous portal requests receive neither. Client-supplied identity and authorization
headers are stripped before proxying.

After a complete password, MFA, passkey, or sign-up flow, return a response with:

```text
Nagare-Session-Establish: <base64url-unpadded-json>
```

The decoded JSON is:

```json
{
  "accessToken": "<shomei access token>",
  "refreshToken": "<shomei refresh token>",
  "returnTo": "https://a-registered-host.example/path"
}
```

The header is an internal response contract. `nagare-access` removes it before the
browser sees the response, verifies the access token, immediately exchanges the refresh
token for a new pair, validates `returnTo` against registered hosts, and sets its own
cookies. The portal must not put tokens in URLs, HTML, JavaScript storage, or logs.

A portal may send `Nagare-Session-Clear` to ask the enforcer to clear and revoke the
current session. The normal sign-out link is `/_nagare/logout`, which does the same and
then returns the user to `/login?logged_out=1`.

For branded failures, the enforcer sends these internal request headers:

- `X-Nagare-Error-Host`: the protected host;
- `X-Nagare-Return-To`: the URL the user can retry; and
- `X-Forwarded-User`: the signed-in user on a 403, when available.

Escape every displayed value. The enforcer accepts only a 200 `text/html` response,
waits at most two seconds, and reads at most 256 KiB. A timeout, invalid content type,
oversized body, or unavailable portal falls back to the built-in 403 or 503 body.

## CSRF and cookie boundaries

The reference portal sets its own `portal_csrf` cookie (`HttpOnly`, `Secure`,
`SameSite=Lax`, `Path=/`) and checks it on every form or JSON mutation. A custom portal
needs equivalent CSRF protection.

`nagare-access` removes `nagare_session`, `nagare_refresh`, and
`__Host-nagare_csrf` from requests to every upstream, including the portal. It also
removes any forged handoff header returned by a protected app. Only a response from the
single registered portal upstream can establish or clear a session.

The portal is trusted with users' passwords and, on authenticated requests, access
tokens. It is not trusted with the cookie-signing key and never sees refresh-token
cookies. Keep its dependencies, logging, templates, and deployment permissions under
the same review standard as any credential-handling service.

## Recovery and removal

The built-in sign-in form remains available even when a portal is registered:

```text
https://<protected-host>/_nagare/login?builtin=1
```

Use this break-glass URL when the portal is broken. It preserves the old password login
path but does not provide the portal's branded account or passkey UI.

To unregister and delete the reference portal:

```bash
cd cluster/examples/auth-portal
nagarectl app delete auth-portal --namespace personal --file nagare/Config.hs
nagarectl access portal show
```

The delete removes the backend entry and enforcer-owned DomainMapping, removes the
portal origin and public base URL from Shomei, and then deletes the app. Protected hosts
immediately return to their built-in sign-in and error pages. A repeat delete is a
no-op.

If the app was deleted outside `nagarectl`, restore it and use the command above so the
registration can be cleaned up safely. Do not hand-edit the backend ConfigMap while the
resolver can still identify the service.
