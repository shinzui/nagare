---
type: Guide
title: "Serving untrusted content from a content domain"
description: "List a content domain on a context, delegate it, and route every host under it to one application worker with the request's own Host header."
docId: DOC-46
tags: [domains, tls, workers, isolation, dns]
generated:
  by: process:claude-code
  at: 2026-11-25T22:00:00Z
---

# Serving untrusted content from a content domain

> 🟡 **In progress.** The context setting, the Cloud DNS zone, the compile, the
> composition rule and the retirement are in place with tests. The native runs
> on a local and a cloud context (EP-285 M4) are still open.

For **app developers** whose service hosts HTML or files that users upload, and
for the **operator** who owns the context.

A browser sends an application's cookies, including the login cookie, to every
host under the application's domain. Content a user uploaded must therefore be
served from a different registrable domain, and from one host per document, so
each document is its own browser origin and can read nothing of the others.

A **content domain** is such a domain. The context lists it, owns its DNS zone,
and lets one worker of one application serve `*.D` and `D`. Every request
reaches that worker with its original `Host` header (`alpha.D`, `beta.D`, …), so
the worker decides which document to serve from the host alone.

## 1. List the domain on the context (operator)

Add the domain to the context file:

```bash
export NAGARE_CONTENT_DOMAINS=content.example.org
```

It is a comma-separated list. Loading the context refuses a domain that
**equals, contains or is under the base domain**, since the login cookie's
domain is `.` plus the base domain, and a domain listed twice. A name may have
at most 48 characters, so its zone name, `nagare-content-<domain with . as ->`,
fits Cloud DNS.

On a **direct cloud context** the next cloud review creates, per domain:

- a Cloud DNS managed zone `nagare-content-<slug>` for `D`;
- `*.D` and `D` A records to the VM's address;
- `roles/dns.admin` on that zone, and only that zone, for the VM's account, so
  cert-manager's DNS-01 solver can issue the wildcard certificate.

A **local context** creates no zone: the certificate comes from the local CA
and a request reaches Kourier with `curl --resolve HOST:443:127.0.0.1`. A
**Cloudflare Tunnel context** creates none either and refuses a content route:
the tunnel's ingress rules cover only the base zone (ADR 34).

## 2. Delegate the domain (operator)

Delegating a registrable domain is an act at its registrar, or in the parent
zone's DNS for a subdomain. Read the zone's name servers and whether public
DNS already sends the domain to them:

```bash
nagarectl domains check
```

```text
Content domains:
  content.example.org  zone name servers: ns-cloud-a1.googledomains.com., …  delegation: does not match: no public resolver answers NS; delegate the domain at its registrar to …
```

Set those name servers as the domain's NS records at the registrar, then run
`domains check` again until it reports `delegation: matches`. `domains check`
fails while the delegation does not match. A certificate cannot be issued
before it does.

## 3. Route the domain to a worker (app developer)

A worker declares an HTTP port and a content route. The route names the domain
and, for documentation and for claims, the fixed hosts the worker also serves;
each must be the domain itself or one label below it.

```haskell
import Nagare.Dsl.ContentDomain (WorkerHttp (..), mkContentDomain, mkContentRoute)

gatewayRoute = do
  port <- mkPort 8080
  domain <- mkContentDomain "content.example.org"
  share <- mkDomain "share.content.example.org"
  route <- mkContentRoute domain [share]
  ready <- mkHttpProbe "/healthz" (Just port) HTTP defaultProbeTiming
  pure
    ( gateway
        & #http ?~ WorkerHttp {port = port, content = Just route}
        & #readiness ?~ ready
    )
```

A worker with a content route **must** declare a readiness probe: the platform
sends it public requests only while it reports ready. The example
[`cluster/examples/content-app`](../../cluster/examples/content-app/nagare/Config.hs)
serves the context's first content domain from its `content-gateway` worker.

`nagarectl app deploy` then adds to the application scope:

| Member | What it is |
|---|---|
| Service `<worker>` | a ClusterIP Service selecting the worker's pods, on its port |
| Certificate `nagare-content-<worker>` | `*.D` and `D`, from `letsencrypt-dns` on a cloud context or `nagare-local-ca` on a local one, labelled `nagare.dev/content-domain: D` |
| Ingress `nagare-content-<worker>` | a Kourier Ingress for `*.D` and `D`, TLS with plain HTTP redirected, ordered after the Certificate and the Service |

The deploy refuses:

| Code | When |
|---|---|
| `content-domain-not-listed` | the context does not list the domain |
| `content-route-needs-direct-ingress` | the context serves through a Cloudflare Tunnel |
| `content-domain-claimed` | the application's own service claims a host equal to or under the domain, two of its workers serve one domain, or **any other scope** holds a host under the domain |
| `claim-conflict` | another scope holds the domain itself |
| `worker-http-needs-application` | a standalone worker (`nagarectl worker deploy`) declares a port; only an application's worker can |

The last two rows are the composition's: a content route keeps every host of
its domain, so no other application can take one of them.

## What the worker receives

- Every request for `*.D` and `D`, over HTTPS, with the **original `Host`
  header**; a plain HTTP request is redirected to HTTPS.
- **No authentication.** A content route never passes the platform's login
  enforcer: the content domain carries no login cookie by design. The worker
  must authorise each request itself, for example with a signed, short-lived
  token in the URL.
- No scale to zero. A worker is a plain Deployment, and so is always running.

## Retiring a route

Remove the route from the config, then review its retirement:

```bash
nagarectl app deploy -f nagare/Config.hs --save-plan DIR --retire-content-route content-gateway
nagarectl inventory apply DIR --yes
```

The review takes the Certificate and the Ingress out of the application, and
the worker's Service too when its port is gone. The objects stay live until
they are collected; the command prints that step:

```bash
nagarectl inventory collect --resource <certificate> --resource <ingress> --out DIR2
nagarectl inventory apply DIR2 --yes
```

The collect review lists what it removes:

```text
This review removes:
  *.content.example.org and content.example.org stop being served (Ingress personal/nagare-content-content-gateway)
  the certificate personal/nagare-content-content-gateway and the Secret holding its private key are deleted
```

cert-manager runs with `--enable-certificate-owner-ref`, so deleting a
Certificate deletes the Secret it wrote. The zone belongs to the context and
stays. Removing a domain from `NAGARE_CONTENT_DOMAINS` is not yet a reviewed
change: the next cloud review refuses, because the accepted cloud scope still
holds the zone. Keep the domain listed until that retirement exists.

## See also

- [Running workers](workers.md)
- [Choosing an ingress](choosing-ingress.md)
- [Configuration reference](config-reference.md)
- [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md), amended for content domains
