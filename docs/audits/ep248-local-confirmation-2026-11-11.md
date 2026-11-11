# EP-248: the local confirmation of a deployer that holds only its bundle

Date: 2026-11-11. One disposable local context (`mode=local`, context `ep248`) confirms EP-248 D5, D7, D8
and D10. Scripts and transcripts are in [`ep248-local-confirmation-2026-11-11/`](ep248-local-confirmation-2026-11-11/),
with home paths shortened to `~`.

Verdict: every phase passed at `59d103322b27215e2601a701ca9620bd04e32613`, which had a green fast gate. The
cluster was freshly bootstrapped from that revision's packaged `nagarectl`. The deployer Pod ran the same
revision's `packages.aarch64-linux.nagarectl` with no payload overlay. Before this run, a rehearsal on an
earlier cluster found seven defects that the interpreters had missed. Each was fixed, with a test where an
interpreter can see it, in the commits listed below.

## Environment

| Item | Value |
|------|-------|
| Workstation CLI | `nix build git+file://…?rev=59d10332…#nagarectl`, `/nix/store/f5d0h5yr925wrm685djanh2qpp8c4ky7-nagarectl-0.18.0` |
| Docker daemon | Colima profile `nagare-c4-amd64` (aarch64 VM), k3d `nagare-local`, `NAGARE_TARGET_PLATFORM=linux/arm64` |
| Auth plane | the arm64 `en`, `shomei` and `nagare-access` images at tag `9577009` |
| Deployer image | `packages.aarch64-linux.nagarectl` at `59d10332`, built natively in the Apple container `nagare-ep253-arm64` with [`image.nix`](ep248-local-confirmation-2026-11-11/scripts/image.nix). `nagarectl platform root` answers `source: installed`, so the package carries its own deploy payload. |
| Deployer Pod | uid 65532, read-only root, all capabilities dropped, `automountServiceAccountToken: false`. Its only credentials are the bundle copied into `/work/home`. Commands run under `env -i` with `PATH`, `HOME`, `XDG_CONFIG_HOME`, `TMPDIR` and the in-cluster `KUBERNETES_SERVICE_*` alone. |
| Bootstrap | [`bootstrap.sh`](ep248-local-confirmation-2026-11-11/scripts/bootstrap.sh) (`site-access-drill.sh`, bootstrap only), then the store moved to MinIO with `inventory store migrate --to object` |

## Results

| Deliverable | Observed | Transcript |
|-------------|----------|------------|
| D2, D3, D10 | `delegation create ci` applied: ServiceAccounts `nagare-deployer-ci` (nagare-system) and `nagare-builder-ci` (team-a-build). Roles and RoleBindings carry the derived rules (team-a: configmaps, deployments, cronjobs and jobs, Knative services; nagare-system: `nagare-access-backends` get, patch and update, plus DomainMappings; builder: serviceaccounts, networkpolicies, jobs, pods and pods/log). The read-only ClusterRole and its binding exist. The store grant Job ran: `Created policy`, `Added user`. The policy reaches only `nagare-inventory/ep248/*`. | [p2](ep248-local-confirmation-2026-11-11/evidence/p2.log) |
| D4 | `delegation credentials ci --out … --contract 1` printed a `deployer-credentials` document with no secret. The directory is 0700 and every file 0600. The context file adds `NAGARE_DEPLOYER=ci`. The kubeconfig server is `https://kubernetes.default.svc`, with user `nagare-deployer-ci`. The store file holds only `accessKeyId` and `secretAccessKey`. One handle Secret per account remains. | [p3](ep248-local-confirmation-2026-11-11/evidence/p3.log), [credentials-1.json](ep248-local-confirmation-2026-11-11/evidence/credentials-1.json) |
| D5 | In the Pod, with only `HOME` and `XDG_CONFIG_HOME` at the bundle: the cluster guard passed, `inventory history` read the store, and `inventory publications` answered an empty list. `inventory status --scope standalone:site-docs` answered `not an accepted scope` (exit 1) before the deploy and the scope's 3 resources after it. | [p4](ep248-local-confirmation-2026-11-11/evidence/p4.log) |
| D8 (refusals) | The deployer bundle got Forbidden for: creating a ConfigMap in `personal`, reading `nagare-minio-credentials` in `nagare-system`, patching `nagare-shomei-settings`, creating a Namespace, and listing Secrets in its own namespace. | [p4](ep248-local-confirmation-2026-11-11/evidence/p4.log) |
| D5, D8, D10 (deploy) | From the Pod, the deployer ran the following, each converging as `deployer:ci` with its repository, revision and run: `app image-plan` published the site and app images under `…/team-a`; `site deploy --rendered` deployed protected `docs`; `app deploy --rendered --save-plan` then `inventory apply` deployed protected `hello`; `worker deploy --rendered` deployed `ticker`. Both protected DomainMappings in `nagare-system` target `nagare-access`, and `nagare-access-backends` gained both hosts. No grant beyond the derived rules was needed. | [p4](ep248-local-confirmation-2026-11-11/evidence/p4.log) |
| D3, D8 (builder) | The builder kubeconfig created a tokenless ServiceAccount, a NetworkPolicy and a Job in `team-a-build`, and the Job completed (`built in a credential-free Job`). The builder got Forbidden creating a Deployment there, creating a ConfigMap in `team-a`, and listing Secrets. Its `exec` was refused because the Pod had completed, so that observation proves nothing about RBAC. D3's unit test is the evidence that no `pods/exec` rule exists. | [p5](ep248-local-confirmation-2026-11-11/evidence/p5.log) |
| D10 (store) | A client Pod given only the bundle's key: listed, read, wrote and deleted beneath `nagare-inventory/ep248/`. It was refused listing the bucket root, listing `nagare-backups` and writing to `nagare-inventory/other/`. | [p6](ep248-local-confirmation-2026-11-11/evidence/p6.log), [store checks](ep248-local-confirmation-2026-11-11/evidence/p6-store-first.txt) |
| D7 (rotation) | Running `delegation credentials` again retired the previous handles and store key. The old token then got `Unauthorized` and the old key was refused at `mc alias set`, while the new token and key work. | [p6](ep248-local-confirmation-2026-11-11/evidence/p6.log), [credentials-2.json](ep248-local-confirmation-2026-11-11/evidence/credentials-2.json) |
| D7, D8, D10 (revocation) | `delegation revoke ci` converged in one review. Every deployer Role now has no rules, and the revoke Job ran: `Removed user`, `Removed policy`. The current bundle then got Forbidden listing Knative services in `team-a` and reading the backend map, its store key was refused, and a deploy failed at the store (403). The apps and the worker keep running. | [p7](ep248-local-confirmation-2026-11-11/evidence/p7.log) |

## Defects found by the rehearsal and fixed

| Commit | Defect |
|--------|--------|
| `aa0987b1` | A deployer's opening of the object store tried to create the bucket and got 403. It also could not publish without `skopeo` and `jq`, which the packaged `nagarectl` now carries on its PATH. |
| `877f919a` | `app image-plan` hashed the archive with `shasum`, which Linux does not have. It now hashes in process. |
| `cb7f8d2e` | The artifact transport was executed through its `#!/usr/bin/env` line, but the image has no `/usr/bin/env`. It now runs through `bash` on PATH. |
| `e1d75f42` | The transport read the local registry through `docker exec`. Inside the cluster it now uses `skopeo`. |
| `c2256182` | The transport hashed with `shasum` and `awk`. It now uses `sha256sum` where present. |
| `96c8166f` | A revoked Role with `rules: []` never verified, because the API server stores it as `null`. A revoked Role now omits `rules`. |

Also from the rehearsal: `8b49c4ef` gives `aarch64-linux` its deploy payload (finding 1 of
[the MasterPlan 33 confirmation](mp33-local-confirmation-2026-11-11.md)). Seen here as `source: installed`.

## Not covered here

D6, the cloud principal, is proved by `infra/pulumi/test/delegatedDeployerResources.test.ts`, the parity variant
and `Nagare.Test.DeployerCloudAccess`. A native IAM refusal check on a disposable cloud context is the
operator's to run. Cloud Storage cannot limit listing to a prefix: the deployer can list every object name
in the inventory bucket but read, write and delete only beneath the context's prefix
(`NagareDelegatedDeployer.ts`).
