# MasterPlan 27 site-access drill, 2026-10-13

The native proof of [EP-188](../../plans/188-check-effective-site-access-and-verify-user-and-team-isolation.md)
M3, run once by `scripts/site-access-drill.sh` on a disposable local context
(`site-access`, Colima profile `nagare-mp23`, k3d) from an empty environment.
Native runs confirm what the interpreters proved
([ADR 25](../../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md));
the gate record for the candidate was green before the run (`just gate-verify f6dd3ea0bd17029e0fd8edbf13b2f1e01f4dbc32`).

| what | value |
| --- | --- |
| candidate `nagarectl` | 0.6.2 at `f6dd3ea0bd17029e0fd8edbf13b2f1e01f4dbc32` (nix package, packaged payload) |
| harness | `nagare-harness route-check` from the same revision |
| auth images | built by `cluster/bootstrap/auth-images/build-local-image.sh` from the tree at `df54e94e` (enforcer sources unchanged since) with En `c3ee100a` and Shomei `0eedad13` pinned by `cli/nagare-access/cabal.project`; tag `mp27-df54e94e`, digests in [`images.tsv`](images.tsv) |
| served En schema | `GET /v1/schema` hash `fnv1a64:40b7b82bdaeea49e`, source in [`en-schema.json`](en-schema.json): the bootstrap `group { relation member: user }` and `app { relation viewer: user, group#member; permission access = viewer }` text |
| En rollout digest | the `en` Deployment's `nagare.dev/en-schema-digest` is `decdbed52e34bda29d1f973996f451061ac744f42d852af9c861b82a3be2a668`, the SHA-256 of that schema text in `cluster/bootstrap/en/configmap.yaml` |
| site | `cluster/examples/protected-static-site` (`access = Just requireLogin`), image built as a static release builds it (generated Nginx config and Dockerfile) and published under review, deployed at `protected-static-site.personal.127-0-0-1.sslip.io`; preview `drill` at `drill.protected-static-site.preview.127-0-0-1.sslip.io` |
| record | [`site-access-drill.json`](site-access-drill.json); observations in [`observations.tsv`](observations.tsv); the route check's lines in [`route-check.log`](route-check.log) |

## Timeline

| time (UTC) | step |
| --- | --- |
| 08:00:21 | context created on a reset daemon; reviewed bootstrap stages 1–4 (218 operations in stage 3, one ambiguous apply resumed twice), converged at 08:06:16 |
| 08:05:29 | served schema and digest read; shomei, en and nagare-access ready at the recorded images |
| 08:06:30 | image published under review (`app image-plan`), site deployed (`site deploy`), production route answered 302 within 1 s |
| 08:07:05 | the four environment stores accepted under review ([`stores.txt`](stores.txt)); preview deployed under review; preview route answered 302 after 68 s (the enforcer's backend-map reload) |
| 08:08:16 | origin ksvc URL `http://protected-static-site.personal.svc.cluster.local`, visibility `cluster-local`; both DomainMappings in `nagare-system` target `nagare-access` |
| 08:08–08:09 | `route-check --team engineering --other-team finance`: wrong CA refused; anonymous 302 to the built-in login; anonymous API 401; disposable user signed in without a grant: 403, `access check` denied; membership plus team grant: 200, check allowed; a member of `finance`: 403, check denied; membership removed: check denied at once, session 403 within the wait |
| 08:09:18 | anonymous preview document 302, preview API 401; a raw `X-Forwarded-User` header on an anonymous API request 401 |
| 08:09:20 | direct grant (reviewed): check production allowed, check preview denied; login 302; production 200 with the example page; preview 403 with the same session; `Host: protected-static-site.personal.svc.cluster.local` through the ingress 404 |
| 08:09:25 | revoke (reviewed): check denied at once while the cached session still got 200; 403 after 26 s (TTL 30 s from the check's start) |
| 08:09:58 | second release (one more file) deployed, `/release.txt` 200 for the granted session; `site rollback` to the first release under review: `/release.txt` 404, `/` 200 for the granted session, anonymous 302, ksvc image is the first release's reference ([`releases.txt`](releases.txt)) |
| 08:10:37 | drill OK |

No secret appears in these files: the disposable users' passwords, the En API key
and the session cookies were read into the drill's process and never written.
