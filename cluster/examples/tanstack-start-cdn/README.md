# tanstack-start-cdn — TanStack Start fronted by Google Cloud CDN (MasterPlan 11, EP-59)

> 🟡 **Built and tested offline; live edge deploy pending `nagare-01`.** The
> `--dry-run` below works today; the live cache-`Age:` curl is deferred until the
> VM is powered on, `app.apps.example.com` is delegated, and the Google Cloud CDN
> load balancer is provisioned.

This is the `tanstack-start` example plus **one new field** — `cdn = Just …` in
`nagare/Config.hs`. The same `nagarectl site deploy` builds the Node image and
applies the Service/DomainMapping as before, and then provisions Google Cloud CDN:
a **more-specific** Cloud DNS `A` record for `app.apps.example.com` pointing at the
load balancer's global **anycast** IP (which beats the broad `*.apps.example.com`
wildcard that points at the VM), plus the per-path cache behaviour on the backend
service.

The CDN declaration (see `nagare/Config.hs`):

```haskell
cdn' <-
  first show
    ( withCacheRule "/api/" Nothing
        =<< withCacheRule "/assets/" (Just 31536000) (withDefaultTtl 600 gcpCloudCdn)
    )
-- ... cdn = Just cdn'
```

## One-time: stand up the Google Cloud CDN load balancer

The standing load balancer (anycast IP, backend, managed cert) is provisioned by
Pulumi behind an opt-in flag (it is billable):

```bash
pulumi -C infra/pulumi config set nagare:enableCdn true
pulumi -C infra/pulumi up
```

## Dry-run (works offline today)

From `cli/nagarectl/`:

```bash
cd cli/nagarectl
cabal run nagarectl -- site deploy --dry-run \
  --file ../../cluster/examples/tanstack-start-cdn/nagare/Config.hs
```

After the generated Dockerfile, the Knative Service, and the `app.apps.example.com`
DomainMapping, it prints the planned CDN changes — the exact `gcloud` commands the
deploy would run, each pinned to the project (no cloud side effects):

```text
--- CDN plan (GcpCloudCdn) ---
gcloud dns record-sets create app.apps.example.com. --type=A --ttl=300 --rrdatas=<cdnGlobalIp> --zone=<dnsZoneName> --project=tan-nb-exp
gcloud compute backend-services update <cdnBackendService> --cache-mode=CACHE_ALL_STATIC --default-ttl=600 --project=tan-nb-exp
```

(`<cdnGlobalIp>`, `<dnsZoneName>`, `<cdnBackendService>` are the EP-56 stack
outputs — the real values are substituted when the stack is available.)

## End-to-end validation (live legs DEFERRED until `nagare-01` is up)

```bash
# 1. Stand up the load balancer (above), then deploy.
nagarectl site deploy

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
