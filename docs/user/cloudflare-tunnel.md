---
type: Guide
title: "Serving a new context through a Cloudflare Tunnel"
description: "Create a Nagare context with no inbound web ports, served through one Cloudflare Tunnel on a full Cloudflare zone."
docId: DOC-40
tags: [cloudflare, tunnel, ingress, domains, onboarding]
generated:
  by: human:nadeem
  at: 2026-11-03T00:00:00Z
---

# Serving a new context through a Cloudflare Tunnel

> 🟡 **Built and tested offline. The topology was proven by hand on a disposable context
> ([EP-240](../plans/240-prove-a-cloudflare-zone-and-tunnel-can-serve-a-context-with-no-inbound-ports.md)), but this
> command path has not yet had a native run.** It covers a new context. Moving an existing context is not built.

The VM accepts no connection from the internet. A small program in the cluster, `cloudflared`, connects outbound to
Cloudflare, and Cloudflare sends each browser request down that connection. SSH stays limited to Google's IAP range and
the Kubernetes API stays on your tailnet. [ADR 34](../adr/0034-a-context-may-serve-through-one-cloudflare-tunnel-on-a-full-zone.md)
has the design and threat model.

## What you accept

- **Cloudflare decrypts traffic at its edge,** including session cookies and page content.
- **Limits:** a 100 MB upload and no edge request logs on Free or Pro. A response silent for 125 seconds is reset; one
  that keeps sending is not.
- **Your Cloudflare account and registrar control every site.** Turn on two-factor authentication on both, and use an
  account that holds nothing else.
- **The tunnel token and the API token are interception credentials.** Anyone with the tunnel token can start a connector
  that receives a share of every request.
- **Protected sites are not cached in the browser or at the edge,** so their assets reload on each visit.

## Before you begin

- A domain whose name servers point at Cloudflare. Remove any DS record at your registrar before the change, and turn DNSSEC on at
  Cloudflare after it. The base domain must be the zone itself: the free certificate covers the apex and one label below it.
- Two-factor authentication on your Cloudflare account and registrar. Use an account that holds nothing else.
- A Cloudflare API token scoped to that account and zone with exactly Cloudflare Tunnel Edit, DNS Edit, Zone Settings Edit
  and Cache Rules Edit.
- Everything in [GCP prerequisites](gcp-prerequisites.md), and a `builder` key your user can read, named in the context
  by `NIX_BUILDER_SSH_KEY`.
- **If your tailnet uses Tailnet Lock,** a pre-signed Tailscale auth key, or be ready to sign the new node. An unsigned node
  joins but has no connectivity, and the host stage reports only that the host does not match.

Keep the three Cloudflare values in your shell, never in a context file:

```bash
export CF_ACCOUNT_ID=...
export CF_ZONE_ID=...
export CF_API_TOKEN=...
```

## Create the context

```bash
nagarectl context create "$CONTEXT_NAME" --project "$PROJECT_ID" \
  --base-domain "$ZONE_NAME" --ingress cloudflare-tunnel \
  --acme-email you@yourdomain.example
```

`--ingress` is refused on a local context and beside `--enable-external-tls`. Do not run `nagarectl init` or
`context guard` before the first bootstrap stage; the reviewed foundation creates the Pulumi stack.

Add the host secrets and `grafana-admin.yaml`, as in [onboarding](onboarding-bring-your-own-project.md), and keep a
`.sops.yaml` in the context's `cluster-secrets` directory.

## Bootstrap in reviewed stages

Each plan shows what it will do. Apply it, then plan again until a review has no operations. Start the x86 builder first;
planning refuses to start it implicitly.

```bash
nagarectl platform bootstrap plan --out ./review
jq '.operations' ./review/review.json
nagarectl platform bootstrap apply ./review --yes
```

The stages run in this order: the Pulumi stack, a perimeter with no internet-facing rule and no Cloud DNS, the image, the
VM, the host, the kubeconfig, then **the Cloudflare zone stage**, which creates the tunnel, its rules, proxied apex and
wildcard records, the edge policy and a cache bypass.

The next plan refuses until you save the tunnel's token:

```bash
nagarectl tunnel token
```

This writes the token, sops-encrypted, to `cloudflare-tunnel-token.yaml` in the context's `cluster-secrets` directory.
Commit it with your other encrypted material. Then keep planning and applying; the platform stage starts the connector.

## Check it

```bash
nagarectl tunnel status
nagarectl doctor
```

`tunnel status` fails on a wrong connector count or a connector from another address. `doctor` reports `Tunnel ingress`,
which is healthy only when the connector is ready, `kourier` is `ClusterIP` and the public IP does **not** answer.

## Hostnames

Default names are one label below the base, because a two-label name fails TLS on the free certificate:

| Workload | Name |
|---|---|
| Site or service | `<name>-<namespace>.<base>` |
| Preview | `<preview>-<site>-preview.<base>` |

Planning refuses:

- two workloads that flatten to one name, such as `a-b` in namespace `c` and `a` in namespace `b-c`;
- a default name ending in `-nagare-system` outside that namespace, or with a first label over 63 characters;
- a custom domain outside the zone;
- a custom domain deeper than one label, which needs Cloudflare's Advanced Certificate Manager at $10 a month;
- a per-site CDN, because the whole zone is already proxied;
- a supplied origin TLS Secret, because Cloudflare ends TLS.

Deploying a site makes no Cloudflare call: the zone's two records carry every name.

`nagarectl domains check` probes the apex and the wildcard as well as your routes. Each must answer in public DNS with an
address other than the VM's and complete a TLS handshake with a certificate that verifies. `nagarectl domains tls HOST`
reports the edge certificate; there is no origin certificate to renew.

## Deploy a protected site and sign in

Deploy as in [Protected sites](static-hosting.md#protected-sites), with a site config that names no domain. It answers on
`<site>-<namespace>.<base>`, and the deploy makes no Cloudflare call. A request with no session gets a 302 to `/_nagare/login`.

A new protected name can answer 502 for about a minute after the deploy reports success, while the gateway picks up its route.

Create the first user and grant them the site as in [the auth portal](auth-portal.md), with `--host` set to that name, then open it in
a browser. A sign-in form left open for more than ten minutes comes back asking you to sign in again.

To retire a site, revoke its grants first, then review each step:

```bash
nagarectl access revoke --host HOST --user USER --save-plan ./revoke && nagarectl inventory apply ./revoke --yes
nagarectl inventory retire --scope ACCESS_SCOPE --out ./grant && nagarectl inventory apply ./grant --yes
nagarectl inventory retire --scope standalone:site-NAME --out ./site && nagarectl inventory apply ./site --yes
nagarectl inventory collect --resource DOMAIN_MAPPING_ID --out ./mapping && nagarectl inventory apply ./mapping --yes
nagarectl inventory collect --resource SERVICE_ID --out ./service && nagarectl inventory apply ./service --yes
```

The name stops reaching the site once the gateway picks up the retirement. Its release history stays as a record.

## Rotate the token

```bash
nagarectl tunnel rotate --yes          # new secret; saves the new token
nagarectl platform bootstrap plan --out ./review
nagarectl platform bootstrap apply ./review --yes   # rolls the connector
nagarectl tunnel status
nagarectl tunnel evict CONNECTOR_ID --yes           # anything still listed that is not yours
```

Rotation refuses the old token for **new** connections only. A connector already running keeps serving until it restarts,
so after a suspected leak, always check `tunnel status` and evict what you do not recognize.

## Removing a context

There is no reviewed way to remove a cloud context once it has history
([F137](../audits/mp23-findings.md)). Delete the tunnel, records and cache rule at Cloudflare yourself, and destroy the stack
deliberately.
