# EP-248 D6: the native IAM check on a disposable cloud context

Date: 2026-11-11 (UTC 2026-11-12). This run checks [EP-248](../plans/248-issue-least-privilege-credentials-to-a-delegated-deployer.md)
D6 against real GCP IAM. The cloud is supposed to refuse a delegated deployer everything outside its delegation. The
context was `ep248` in project `tan-nb-exp`. It was bootstrapped with the reviewed path, given the delegation `ep248ci`,
then torn down. Scripts are in [`ep248-cloud-iam-check-2026-11-11/scripts/`](ep248-cloud-iam-check-2026-11-11/scripts/)
and transcripts in [`evidence/`](ep248-cloud-iam-check-2026-11-11/evidence/).

**Verdict.**
- Every allow and every refusal behaved as designed: 22 of 22 checks.
- Rotation retires the old key.
- The run found three defects that stopped a cloud deployer outright. All three are fixed with tests.
- Two findings are not fixed here.
- Revoking disables the account through Pulumi, but that was not confirmed natively: the context wedged first (finding 2).

## Environment

| Item | Value |
|------|-------|
| CLI | packaged `#nagare`, `14ec55ad` for the bootstrap, then `24cb442f`, `940395bb` and `064479d4` as each fix landed in the drill |
| Context | `ep248`, `mode=cloud`, Cloudflare Tunnel ingress, local Pulumi backend, inventory in GCS at `gs://tan-nb-exp-ep248-state/inventory` |
| Shell | every step from `env -i` (`run.sh`), a named gcloud configuration, a private ADC copy, the operator pointer left on `intranet` |
| Delegation | `ep248ci`: namespace `team-a`, suffix `-docs`, image repository `us-west1-docker.pkg.dev/tan-nb-exp/ep248-deploy/team-a` |
| Deployer | only its bundle: `HOME` and `CLOUDSDK_CONFIG` at `delegation credentials --out DIR`, nothing of the operator's gcloud |

## Results

| Check | Observed | Transcript |
|-------|----------|------------|
| Bootstrap | converged at stage 11. The host stage signed exactly `ep248-nagare` under Tailnet Lock and then resumed | [bootstrap-drive](ep248-cloud-iam-check-2026-11-11/evidence/bootstrap-drive.txt) |
| Delegation | `delegation create` plus apply gave revision 1, `active`. The foundation then created the deployer's service account, repository, custom role and writer bindings | [delegation-create](ep248-cloud-iam-check-2026-11-11/evidence/delegation-create.txt), [foundation-after-close](ep248-cloud-iam-check-2026-11-11/evidence/foundation-after-close.txt) |
| Allowed | read, write and delete under `inventory/`; list the bucket (a documented limit); push to the delegation's repository; the deployer's own `nagarectl inventory history` | [iam-active](ep248-cloud-iam-check-2026-11-11/evidence/iam-active.txt) |
| Refused (403) | read, overwrite, delete or write beside the prefix; read or write another context's state bucket; the context's backup and image buckets; list project buckets; change bucket IAM; list instances or service accounts; create a key for itself; read project IAM; list secrets; push to the platform's repository | [iam-active](ep248-cloud-iam-check-2026-11-11/evidence/iam-active.txt) |
| Rotation | the second `delegation credentials` left one user-managed key. The first bundle's key is refused with `invalid_grant: Invalid JWT Signature` once its cached access token is gone | [iam-rotated-b1](ep248-cloud-iam-check-2026-11-11/evidence/iam-rotated-b1.txt), [credentials-b2](ep248-cloud-iam-check-2026-11-11/evidence/credentials-b2.json) |
| Revoke | `delegation revoke` gave revision 2, `revoked`. The foundation stage that disables the account was not applied (finding 2) | [delegation-revoke](ep248-cloud-iam-check-2026-11-11/evidence/delegation-revoke.txt) |
| Teardown | 25 Pulumi resources deleted and none left. The new image, the state bucket, the tunnel and its DNS records were also removed, and the Tailscale key was revoked | [teardown](ep248-cloud-iam-check-2026-11-11/evidence/teardown.txt) |

## Defects found and fixed

| Commit | Defect |
|--------|--------|
| `24cb442f` | `delegation credentials` asserts the project (ADR 9) by reading the stack's `gcp:project`, but it never selected the context's Pulumi backend. From a clean environment it refused with "no stack named". It now selects the backend and stack first, like every other guard caller. |
| `940395bb` | The bundle selected its key with `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE`. gcloud 581's `config config-helper`, which the GCS store session reads, crashes on it: `'Credentials' object has no attribute 'private_key_id'`. Issuing now activates the key in the bundle's own gcloud configuration before retiring anything, and the deployer context no longer sets the override. |
| `064479d4` | Every GCS inventory request named the context's project as `userProject`, which needs `serviceusage.services.use`. The deployer holds no project-level role, so its first read was refused. A service account of the context's own project now names no quota project; every other identity is unchanged. |

v0.19.0 shipped before these fixes, so a deployer on a cloud context needs the release that carries them.

## Findings, not fixed here

1. **The first foundation apply after a delegation fails once.** The bucket binding names the custom role created in
   the same Pulumi update, and IAM had not yet propagated the role ("does not exist in the resource's hierarchy").
   `inventory resume` cannot retry a Pulumi create, so it refuses. The documented exit worked: `inventory close`
   kept the partial scope, and the next review created the one missing binding
   ([resume](ep248-cloud-iam-check-2026-11-11/evidence/resume-stage13.txt), [close](ep248-cloud-iam-check-2026-11-11/evidence/close-stage13.txt)).
2. **A revoke whose foundation is not reconverged wedges the next platform transition.** Revoking changes the
   derived `nagare:delegatedDeployers` (`disabled: true`), which is part of the foundation stack's target digest.
   In the run, the transition's host stage applied, then its foundation stage refused with "reviewed foundation
   target digest differs from the selected context". The new package's bootstrap plan refuses on the old context
   pin, and the old package refuses on minor version skew. With one package, the same order wedges the same way:
   revoke, skip `platform bootstrap`, then transition. The run stopped there
   ([transition-2](ep248-cloud-iam-check-2026-11-11/evidence/transition-2-refused.txt)).
3. Smaller points:
   - An access token minted before rotation stays valid until it expires (at most an hour). GCP does not revoke
     tokens when a key is deleted.
   - The deployer's account ID is per project (`nagare-deployer-NAME`), not per context.
   - A deleted custom role keeps its ID for about 37 days.
   - gcloud writes some files in the bundle's configuration group-readable; the bundle directory itself is 0700.
