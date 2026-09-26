# tanstack-start-cdn — TanStack Start fronted by Google Cloud CDN (MasterPlan 11, EP-59)

> 🟡 **Reviewed DNS compilation and disposable-zone provider proof passed.** A
> full site and edge transaction in its target context remains to be verified.

This is the `tanstack-start` example plus **one new field** — `cdn = Just …` in
`nagare/Config.hs`. The reviewed `nagarectl site deploy` declares the Service,
DomainMapping, and a **more-specific** Cloud DNS `A` record for `app.apps.example.com` pointing at the
load balancer's global **anycast** IP (which beats the broad `*.apps.example.com`
wildcard that points at the VM). The backend cache policy is shared and owned
by Pulumi; application deploys cannot change it.

The CDN declaration (see `nagare/Config.hs`):

```haskell
cdn = Just gcpCloudCdn
```

## One-time: stand up the Google Cloud CDN load balancer

The standing load balancer (anycast IP, backend, managed cert) is provisioned by
Pulumi behind an opt-in flag (it is billable):

```bash
pulumi -C infra/pulumi config set nagare:enableCdn true
pulumi -C infra/pulumi up
```

## Reviewed dry run

Publish the exact site image archive with `app image-plan`, and select the
accepted platform BackendService. The dry run prints the canonical public site
scope, including its DomainMapping and reviewed DNS record claim:

```bash
cd cli/nagarectl
cabal run nagarectl -- site deploy --skip-build --tag TAG \
  --image-resource RESOURCE-ID --cdn-backend-resource BACKEND-ID \
  --dry-run --file ../../cluster/examples/tanstack-start-cdn/nagare/Config.hs
```
## End-to-end validation (live legs DEFERRED until `nagare-01` is up)

```bash
# 1. Use the accepted platform backend and image publication, then deploy.
nagarectl site deploy --skip-build --tag TAG \
  --image-resource RESOURCE-ID --cdn-backend-resource BACKEND-ID

# 2. Inspect the edge.
nagarectl cdn status app.apps.example.com

# 3. Prove a cache HIT (DEFERRED). Google Cloud CDN has no CF-Cache-Status header;
#    a non-zero, growing Age: on the second request is the edge-cache signal:
curl -sI https://app.apps.example.com/assets/app.css | grep -i age
#   first request:  age: 0
#   second request: age: 7        <- served from the Google edge cache

# 4. Tear the edge mapping down (delete the more-specific A record; the hostname
#    falls back to the *.apps.example.com wildcard / VM):
nagarectl cdn disable app.apps.example.com
```

See `docs/user/cdn.md` for the full guide and the DNS / origin-TLS runbook.
