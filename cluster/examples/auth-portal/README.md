# Reference authentication portal

This dependency-free Node 22 app implements Nagare's operator-owned authentication
portal contract. It talks to Shomei only from the server, hands completed sessions to
`nagare-access` through `Nagare-Session-Establish`, and never owns the `nagare_*`
cookies. Copy it to change the HTML, CSS, title, or logo while keeping the paths and
headers described in the auth portal user guide.

The typed config deploys `auth-portal` in `personal` at
`auth.<NAGARE_BASE_DOMAIN>`, marks it with `access = Just authPortal`, and defaults to:

- `SHOMEI_URL=http://shomei.nagare-system.svc.cluster.local`
- `PORTAL_TITLE=Nagare`
- `PORTAL_ALLOW_SIGNUP=false`

Set `PORTAL_LOGO_URL` as a managed environment variable if desired. Sign-up is a UI
policy only; Shomei remains cluster-internal and its API behavior is unchanged.

Run the offline contract tests:

```bash
node --test cluster/examples/auth-portal/test/contract-test.mjs
```

Preview the deployment from `cli/nagarectl` (the access registration is a deploy-time
side effect, so dry-run output contains only ordinary app manifests):

```bash
cabal run -v0 nagarectl -- deploy --dry-run \
  --file ../../cluster/examples/auth-portal/nagare/Config.hs \
  --base-domain apps.example.com --tag test
```

For a live deployment, run the same command without `--dry-run`. The auth plane must
already be installed. Deleting the app with `nagarectl app delete auth-portal
--namespace personal` also removes its portal registration and Shomei origin.
