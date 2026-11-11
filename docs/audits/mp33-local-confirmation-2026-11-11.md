# MasterPlan 33: the batched local confirmation

Date: 2026-11-11. One disposable local context (`mode=local`, context `mp33`) confirms EP-247 D1 and D9, EP-251
D7, EP-249 D6 and EP-252 D5 (MasterPlan 33 Decision Log, 2026-11-10). Scripts, fixtures and transcripts are in
[`mp33-local-confirmation-2026-11-11/`](mp33-local-confirmation-2026-11-11/); home paths in the transcripts are
shortened to `~`.

Verdict: every deliverable passed at `e748a55031d8b799380f1d55fe774af8f7669796` (green fast gate), on a cluster
bootstrapped from that revision's packaged `nagarectl`. Before that run, rehearsing on an earlier cluster found four
defects that the interpreter tests had missed. Each was fixed with a test, in the commits listed below.

## Environment

| Item | Value |
|------|-------|
| Workstation CLI | `nix build git+file://…?rev=e748a550…#nagarectl`, `/nix/store/v35skkykgd6ap719lxqk8mrcgs0cc8nz-nagarectl-0.18.0` |
| Docker daemon | Colima profile `nagare-c4-amd64` (aarch64 VM, 16 GiB), k3d `nagare-local`, `NAGARE_TARGET_PLATFORM=linux/arm64` |
| Auth plane | the arm64 `en`, `shomei` and `nagare-access` images at tag `9577009` (the transition rehearsal pins), copied from `nagare-mp23` |
| In-cluster CLI | `packages.aarch64-linux.nagarectl` at `e748a550`, built natively in the Apple container `nagare-ep253-arm64` with [`image.nix`](mp33-local-confirmation-2026-11-11/scripts/image.nix) (`dockerTools.buildLayeredImage`: nagarectl, kubectl, bash, coreutils, tar; user 65532) |
| Deployer Pod image | that image plus the packaged platform payload of the same revision ([`deployer-image.sh`](mp33-local-confirmation-2026-11-11/scripts/deployer-image.sh)); see Findings |
| Bootstrap | `scripts/site-access-drill.sh` with `NAGARE_DRILL_BOOTSTRAP_ONLY=1`, converged in 5 minutes |
| Shell | every phase from `env -i` with only `PATH`, `HOME`, `TMPDIR`, `USER` and `LANG`; [`lib.sh`](mp33-local-confirmation-2026-11-11/scripts/lib.sh) asserts the loopback API server and the single k3d node |

The deployer `ci` is "made by hand" as EP-247 D9 allows. On the workstation it has its own home with the same
context name and `NAGARE_DEPLOYER=ci`, laid out as EP-248's bundle will be. In the cluster it is a Pod with a
ServiceAccount token. Both hold fixture credentials: the object store's administrator key and a cluster-admin
binding. EP-248 issues the scoped ones.

## Results

| Deliverable | Observed | Transcript |
|-------------|----------|------------|
| EP-249 D6, D1 empty environment | `app`, `worker` and `site render` under `env -i PATH=/usr/bin:/bin` print `rendered-application`, `rendered-worker` and two `rendered-site` documents | [p0](mp33-local-confirmation-2026-11-11/evidence/p0-render.log) |
| EP-251 D6, D7 | `inventory store migrate --to object` moved the bootstrapped history (generation 467) to `http://minio.nagare-system.svc.cluster.local:9000/nagare-inventory/mp33` and wrote `NAGARE_INVENTORY_STORE=object` into the context | [p1](mp33-local-confirmation-2026-11-11/evidence/p1.log) |
| EP-251 D7 | the operator deployed `op-hello` from the workstation | [p2](mp33-local-confirmation-2026-11-11/evidence/p2.log) |
| EP-247 D1 | `delegation create ci` applied; `kubectl get ns -l nagare.dev/delegation=ci` lists exactly `team-a` and `team-a-build`; ResourceQuota, LimitRange and the record ConfigMap exist; `delegation show --contract 1` answers revision 1, `active` | [p3](mp33-local-confirmation-2026-11-11/evidence/p3.log) |
| EP-247 D3, EP-249 D6 | in the deployer context `delegation create` and `platform status` are refused by name; `app check -f` and `app deploy -f` are refused before any process runs | [p4](mp33-local-confirmation-2026-11-11/evidence/p4.log) |
| EP-252 D5 | Pod `mp33-builder` in `team-a-build` (uid 65532, `readOnlyRootFilesystem`, all capabilities dropped, no ServiceAccount token, no Docker socket or binary) ran `site package --builder layered --base-archive`; the archive `48dcea6d…` was copied out byte for byte | [p5](mp33-local-confirmation-2026-11-11/evidence/p5.log) |
| EP-247 D9, EP-249 D6, EP-252 D5 | the deployer published that archive and the hello image under `…/team-a`, then deployed `site deploy --rendered` (protected static site `docs`) and `app deploy --rendered` (protected app `hello`) | [p5](mp33-local-confirmation-2026-11-11/evidence/p5.log) |
| EP-247 D4, D9 | `rogue.127-0-0-1.sslip.io` (outside suffix `-docs`) was refused with `delegation-bounds … (hostname)`; the store head (generation 545, 27 accepted scopes) was unchanged and no review was saved | [p5](mp33-local-confirmation-2026-11-11/evidence/p5.log) |
| Serving | both DomainMappings target `nagare-access`; anonymous requests through the ingress over the local CA answer `302`; the cluster-local origins answer `200` with the fixture's own files | [p5](mp33-local-confirmation-2026-11-11/evidence/p5.log) |
| EP-251 D7, EP-247 D9 | Pod `mp33-deployer` reached the store directly at its Service address and applied `worker deploy --rendered` as `deployer:ci` with its source; the worker logs `tick` | [p6](mp33-local-confirmation-2026-11-11/evidence/p6.log) |
| EP-251 D7, EP-247 D11 | the operator's saved `op-hello` v2 review was refused `review_stale` (409, `retryable: true`); re-planned, it converged and `op-hello` runs v2 | [p6](mp33-local-confirmation-2026-11-11/evidence/p6.log) |
| EP-247 D6, D9 | `inventory history --contract 1` lists every deployer transaction as `{"kind":"deployer","name":"ci"}` with repository, revision and run, and every operator transaction as `operator` with no source | [p7](mp33-local-confirmation-2026-11-11/evidence/p7.log), [history.json](mp33-local-confirmation-2026-11-11/evidence/history.json) |
| EP-247 D5, D9 | after `delegation revoke ci` (revision 2, `revoked`), a deployer review saved before it is refused `admission_refused` naming `stale-head`, `stale-base` and `delegation-revoked`; a new deployer plan is refused `delegation-revoked`; the head did not move; both namespaces and the apps in them remain | [p7](mp33-local-confirmation-2026-11-11/evidence/p7.log) |

## Defects found and fixed

| Commit | Plan | Defect |
|--------|------|--------|
| `9568cc5e`, `2ee5ced8` | EP-251 | `migrate --to object` needed the store URL in the stored context, but the reviewed context update refuses to change a store URL once history exists, so a bootstrapped context could not migrate. The migration now derives `…/nagare-inventory/CONTEXT` from the local object store. |
| `7a879fe8` | EP-251 | The dry run stopped at `object store read answered 404` because MinIO answers a read or listing in a missing bucket with `NoSuchBucket`. That answer is now absence. The destination label also now comes from the object target, where before it would have written an empty URL into the context. |
| `e4bbf425` | EP-247 | `--image-repository k3d-registry.localhost:5000/…` was refused because the registry port was read as a tag, so no local context could delegate. A record failing this check also decoded as no delegation. |
| `e748a550` | EP-247 | `inventory apply` verifies a saved review before admission and refused a stale one as `review_changed` (not retryable), so D11's `review_stale` never reached a client. A stale review is now `review_stale` unless its delegation also refuses it. |

## Findings, not fixed here

- The `aarch64-linux` package has no platform payload (EP-253 decision), but every deploy plan prepares the platform
  workspace (`resolvePlatformWorkspace` in the app, worker and site commands), so that package cannot deploy. The run
  layered the same revision's packaged payload onto the Pod image. The `x86_64-linux` package, which production hosts
  use, carries its payload. An arm64-hosted deployer would need a payload in that package.
- A deployer's unscoped `inventory status` needs the platform workspace for the platform's own scopes, which only
  operator commands prepare. `inventory status --scope KIND:NAME` and `inventory history` work.
- nagarectl reaches the cluster through the ambient `KUBECONFIG` (or `~/.kube/config`), not the context's
  `kubeconfigs/CONTEXT.yaml`. A hosted deployer's environment must set it, as the Pod's script does.
