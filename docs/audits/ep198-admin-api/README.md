# EP-198 M2: the admin API on a disposable local context

Run on 2026-10-17 with the packaged `nagarectl` of candidate `6f5ea259`, on Colima profile
`nagare-mp23` (arm64), in local context `site-access` with `NAGARE_ADMIN_API_ENABLED=1`. Images
were built from this tree with `cluster/bootstrap/auth-images/build-local-image.sh` (tag
`ep198-1a34de4d`): `nagare-admin-api@sha256:1333b43a…64f9b4` and
`nagare-access@sha256:647049f7…5bcc`. The En and Shomei pins are unchanged since `df54e94e`.

```bash
R=$HOME/.local/state/nagare-drills/admin-api-20261017   # under $HOME: the VM shares only it
env -i HOME=$HOME PATH=$PATH DOCKER_HOST=unix://$HOME/.colima/nagare-mp23/docker.sock \
  NAGARE_DRILL_NAGARECTL=<packaged nagarectl> NAGARE_DRILL_IMAGE_TAG=ep198-1a34de4d \
  NAGARE_DRILL_ROOT=$R NAGARE_DRILL_ADMIN_API=1 NAGARE_DRILL_BOOTSTRAP_ONLY=1 NAGARE_DRILL_RESET=1 \
  bash scripts/site-access-drill.sh
env -i HOME=$HOME PATH=$PATH DOCKER_HOST=unix://$HOME/.colima/nagare-mp23/docker.sock \
  NAGARE_DRILL_NAGARECTL=<packaged nagarectl> NAGARE_DRILL_ROOT=$R bash scripts/admin-api-drill.sh
```

The bootstrap converged in four plans, the last with 0 operations, the admin API included. The
record is [`admin-api-drill.json`](admin-api-drill.json), and the gateway's backend entry is
[`admin-backend-entry.json`](admin-backend-entry.json).

Observed through the real gateway and Kourier over the local CA:
- **Anonymous clients:** 401 `unauthenticated` (`application/problem+json`,
  `WWW-Authenticate: Bearer`) with no Accept header and with `Accept: */*`. A forged
  `X-Forwarded-User` changes nothing, and the UI document `/` still redirects (302).
- **A signed-in person:** 403 `forbidden` before the grant and 200 after. The head carries
  `Nagare-Head-Revision`, `If-None-Match` answers 304, an unknown route is 404 and POST is 405.
  After the revoke, 403 within the decision TTL.
- **A Shomei service account:** its `client_credentials` token gets 403 before the grant on its
  backing user and 200 after (head and grants). An invalid bearer is 401.
- **Bypass attempts** got no answer (`000`, 5 s timeout) on both the Service and the Pod IP, from
  an application pod in `personal`, from an unrelated pod in `nagare-system`, and from a
  `personal` pod carrying the gateway's label. The control requests from the same pods
  reached other Services. Kubelet readiness kept passing.
- **Warm latency** (100 requests at concurrency 8, through the gateway and a port-forward): p95
  0.041 s for the head, 0.026 s for sites, 0.023 s for scopes; target 250 ms.
- **Server stopped:** 502 `upstream_unavailable` within 1 s, with no exception text; 200 again
  after the restart.
- **Replan** after the drill: 0 operations.

**Not covered here:** the cloud reader, IAM denials, metadata isolation and GCS latency (EP-198 M3).
The server's own total-deadline answer to a hung store is proven offline in EP-197, not through
the gateway.

The pod runs as UID 0 with only `DAC_READ_SEARCH`: the VM shares the store's owner-private files
as root-owned. The cloud pod runs as UID 10001 with no capabilities.
