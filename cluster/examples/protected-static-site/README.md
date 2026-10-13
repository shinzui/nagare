# protected-static-site example

The `static-site` example with one more field in its config:

```haskell
access = Just requireLogin
```

That field makes the reviewed `nagarectl site deploy` route the site's hostname
through the shared `nagare-access` enforcer and keep the Nginx origin Service
cluster-local, so the generated Knative hostname is not a public alternative. A
`ServerSite` opts in with the same field (MasterPlan 27).

## Prerequisites

The auth plane must be accepted in the context (`nagarectl platform bootstrap`;
see [identity-aware access](../../../docs/user/access.md)). A protected site refuses
to plan without it.

## Deploy, grant, check

With the site's image published and accepted as `IMAGE-ID`:

```bash
nagarectl site deploy --skip-build --tag TAG --image-resource IMAGE-ID \
  -f cluster/examples/protected-static-site/nagare/Config.hs
```

The hostname is `protected-static-site.personal.<base-domain>` (`NAGARE_BASE_DOMAIN`).
It is its own authorization object; nobody is admitted until a grant names it:

```bash
nagarectl access grant --host protected-static-site.personal.apps.example.com \
  --user alice@example.com --save-plan ./grant-review
nagarectl inventory apply ./grant-review --yes

nagarectl access team add-member --team engineering --user bob@example.com --save-plan ./member-review
nagarectl inventory apply ./member-review --yes
nagarectl access grant --host protected-static-site.personal.apps.example.com \
  --team engineering --save-plan ./team-review
nagarectl inventory apply ./team-review --yes

nagarectl access check --host protected-static-site.personal.apps.example.com --user bob@example.com
nagarectl access list --host protected-static-site.personal.apps.example.com
```

`access check` asks En at a fully consistent snapshot; the gateway may still
serve its cached decision for up to `NAGARE_ACCESS_DECISION_TTL` seconds
(default 30) after a change. A preview (`nagarectl site preview deploy --name
feature-x …`) inherits the protection and is a separate hostname with its own
grants. The site cannot use a CDN or supplied origin TLS while protected, and
an accepted public site cannot become protected in place: retire it first.
