# protected-hello example

`protected-hello` is the end-to-end identity-aware access example. It deploys the
public Knative hello image, but its Nagare config sets:

```haskell
access = Just requireLogin
```

That one field makes `nagarectl deploy` wire the public host through the shared
`nagare-access` enforcer instead of serving the app directly.

## Prerequisites

Install the optional auth plane first:

```bash
kubectl apply -f cluster/bootstrap/shomei/
kubectl apply -f cluster/bootstrap/en/
kubectl apply -f cluster/bootstrap/nagare-access/
```

The shomei/en database Secrets, shomei/en images, the `nagare-access` image, and
the cookie domain in those manifests must match the target cluster before this
example can be exercised live.

## Deploy

```bash
nagarectl deploy -f cluster/examples/protected-hello/nagare/Config.hs
```

The configured host is:

```text
protected-hello.apps.example.com
```

With the auth plane absent, this deploy should fail closed with the actionable
"nagare auth plane is not installed" error and make no route/backend changes.

## Verify

Unauthenticated document requests redirect to the enforcer login page:

```bash
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://protected-hello.apps.example.com/
# 302 https://protected-hello.apps.example.com/_nagare/login?rd=%2F
```

After login, an ungranted user receives `403 Forbidden`. Granting that shomei
user access writes the en tuple `app:protected-hello.apps.example.com#viewer`:

```bash
nagarectl access grant --host protected-hello.apps.example.com --user alice
```

After the grant, the same authenticated user should receive `200` and the hello
page body. Revoking the tuple returns the user to `403` after the short enforcer
decision-cache TTL:

```bash
nagarectl access revoke --host protected-hello.apps.example.com --user alice
```
