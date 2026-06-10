# cdn-spike — CDN substrate feasibility scripts (EP-54)

House-style reference only — **not wired into anything**. These are the exact
hand-run command sequences the EP-54 substrate spike uses to prove that a CDN
can sit in front of Nagare's single-node origin (Kourier on `nagare-01`) for
both providers MasterPlan 11 targets:

- **Google Cloud CDN** — a global external HTTP(S) load balancer with Cloud CDN
  enabled, built from a throwaway `cdn-spike-*` instance group, health check,
  backend service, URL map, target proxy, global IP, and forwarding rule
  (`gcp-cdn-up.sh` / `gcp-cdn-down.sh`).
- **Cloudflare** — a proxied (orange-cloud) DNS record plus a Rulesets cache
  rule in front of the VM's public IP, driven entirely through the Cloudflare
  HTTP API (`cf-cdn-up.sh` / `cf-cdn-down.sh`).

They are the verified input shapes for the four plans that consume EP-54:
EP-55 (the typed `Cdn` model), EP-56 (the Pulumi `NagareCdn` component),
EP-57 (the `Nagare.Cdn.Cloudflare` module), and EP-58 (the deploy seam). See
`docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md` for the full
context, the expected `curl` transcripts, and the Substrate Decisions every
later plan encodes.

## Powered-off caveat (read this first)

The VM `nagare-01` is **currently `TERMINATED` (powered off) to save cost**, and
both providers require a reachable origin. The **live legs are therefore
deferred/manual**: these scripts and the expected transcripts in the plan are
the deliverable now; the live `curl` evidence is captured once an operator
starts the VM (and, for Cloudflare, supplies a real domain and a scoped API
token). This mirrors how EP-43 (`db-spike`) and EP-49 handled the same
constraint.

## Project isolation

Every `gcloud` call runs against **only** GCP project `tan-nb-exp` with an
explicit `--project=tan-nb-exp` flag, and both `gcp-cdn-*.sh` scripts carry the
repo-mandated preflight assertion (see the repository-root `CLAUDE.md`) that
refuses to run if the active gcloud project is anything else.

## Prerequisites

1. The VM running: `gcloud compute instances start nagare-01 --zone=us-west1-a --project=tan-nb-exp`.
2. The origin IP: `pulumi -C infra/pulumi stack output publicIp` (exported as `ORIGIN_IP` for the Cloudflare scripts).
3. A known Knative service hostname to route to and a static asset path under
   it, confirmed with `scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl get ksvc -A'`
   (M0 step 2 in the plan). These are passed to the scripts via the environment
   variables documented in each script's header.
4. For the Cloudflare leg only: a domain whose DNS is hosted at Cloudflare, plus
   a scoped API token (`Zone:DNS:Edit` + `Zone:Cache Rules:Edit`) in
   `CF_API_TOKEN` and the zone id in `CF_ZONE_ID`.

## Run — Google Cloud CDN

```bash
# Stand up the throwaway load balancer (idempotent; safe to re-run).
HC_HOST=notes.personal.apps.example.com cluster/examples/cdn-spike/gcp-cdn-up.sh

# ... capture the routed-response and cache-HIT transcripts per M1 of the plan ...

# Tear down — the global IP and load balancer are BILLABLE; this is mandatory.
cluster/examples/cdn-spike/gcp-cdn-down.sh
```

## Run — Cloudflare

```bash
export CF_API_TOKEN='<scoped-token>'
export CF_ZONE_ID='<zone-id>'                 # or omit to discover from CF_HOST
export CF_HOST='cdn-spike.example.com'
export ORIGIN_IP="$(pulumi -C infra/pulumi stack output publicIp)"

cluster/examples/cdn-spike/cf-cdn-up.sh       # proxied record + ssl mode + cache rule

# ... capture the cf-cache-status MISS->HIT transcript per M2 of the plan ...

cluster/examples/cdn-spike/cf-cdn-down.sh      # delete the test record (+ optional ruleset)
```

## Idempotence and recovery

Both `up` scripts use fixed names (`cdn-spike-*` for Google, a fixed `CF_HOST`
for Cloudflare), so a re-run after a partial failure reports "already exists" /
updates in place rather than duplicating. If `gcp-cdn-up.sh` fails partway, run
`gcp-cdn-down.sh` (its deletes are `--quiet` and tolerate missing objects), then
re-run `gcp-cdn-up.sh` from a clean slate. The Cloudflare SSL-mode change is a
zone setting, not a resource; `cf-cdn-down.sh` only removes the test record, so
record and restore the original SSL mode by hand if the zone is shared.
</content>
</invoke>
