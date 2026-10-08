# mp23-c3i staged teardown with candidate 3ae20f8c (2026-10-07)

Session `mp23-c3i`, on brief from `nagare-verify`. Context `mp23-c3i` (project `tan-ng-labs`, gcloud
config `labs`, VM `nagare-c3-1008`). Operator root `/private/tmp/nagare-mp23-c3i`. Wrapper
`runctl-3ae20f8c.sh` is `runctl-96c1da11.sh` with only the binary changed, to
`/private/tmp/result-3ae20f8c-nagare/bin/nagarectl`. `NAGARE_PLATFORM_ROOT` is unchanged (the c3i
payload `nagare-0.4.0-847543896d07-9442ead5f5362fd3`). The operator approved the five-step
sequence in this session by AskUserQuestion. Every value below was observed.

## Result: stopped at step 3 on a retirement refusal

| Step | Result |
| --- | --- |
| Pre: `just gate-verify 3ae20f8c9ed5…` | `green, tree f93114988654…, systems x86_64-linux aarch64-darwin` |
| Pre: `inventory status` | 329 resources, 6 retained, 9 collected, no fence, store idle; 50 accepted scopes; 245 `unrecorded`, 0 `replaced-incarnation` |
| 1. `inventory export` | `evidence-private/pre-teardown-3ae20f8c-export` written (175 s): backup.json, format.json, head.json, image-prune, journal, native, reviews, scopes, vm-power |
| 2. `infra destroy --save-plan` (stage 1) | review `db7c0ef2…`, 14 `VerifyResource`, each "0 declared mutation(s); stack mp23-c3i; project tan-ng-labs" (142 s) |
| 2. `inventory apply --yes` | `converged tx-db7c0ef2ba7d15fc5fc1e9941a2a7273ac012d937d184e964d165f581726be58` (115 s) |
| 3a. retire every `application:` scope | plan refused, `dangling-reference` "dependency producer is absent": `standalone:access-0234…/viewer/grant` consumes `application:scenario-a/…/domain-mapping` |
| 3b. retire every application, standalone and publication scope jointly | plan refused: `access resource is not declared` |
| 4–6 | not run |

No review was saved for 3a or 3b, so nothing beyond the verify-only stage 1 was applied. Status after
the refusal: 50 accepted scopes, 6 retained, 9 collected, no active transaction, no fence, 245
`unrecorded`.

## Why 3b refuses

The refusal comes from the access adapter's `observe`
(`cli/nagarectl/src/Nagare/Inventory/Access.hs:341`). A retirement candidate drops the grant's
declaration, so there is no binding to observe. The same adapter's `selected` also rejects every
action except Create, Update and Verify: "access retirement, adoption, and arbitrary operations are not
admitted". So a context holding an accepted access grant (`standalone:access-…/viewer/grant`) has no
reviewed retirement exit. `application:scenario-a` cannot retire without that grant (3a), so no
application, platform or cloud scope can retire either. Status also lists `AccessExecutor` among the
unavailable providers (no `NAGARE_EN_URL`/`NAGARE_EN_API_KEY` in the wrapper). This refusal fires
before any provider call, though, so supplying the En credentials would not change it.

## Findings exercised

- **F39** (Pulumi teardown prep): exercised by step 2. Stage 1 prepared 14 Pulumi verify operations on
  the real stack, and they converged.
- **F40** (scope retirement): exercised by step 3, which refused. The earlier F40 native evidence
  covered platform scopes only. A full context with an access grant is blocked at the access
  adapter, which is a new F40 gap.
- **F33** (collection recheck): not reached. No collection, and no gcloud disposal, ran.

## Disposal (prepared, not executed)

The `pulumi stack export` taken before teardown (33 gcp resources) was regenerated with `dispose-gen.py`.
It is byte-identical to nagare-verify's 35-command dry run `dispose-c3i.sh`; digests are in
`dispose-pre-digests.txt`. Step 5 was gated on the inventory retirement, so it did not run. VM
`nagare-c3-1008` is still RUNNING.

## Files

- `01-prep-status-export-stage1-plan.log`, `02-stage1-apply.log`, `03-retire-applications-refused.log`,
  `04-retire-workloads-refused.log`: command logs (no secrets; ADC warnings left in).
- `retire-group.sh`: the plan, check and apply driver used for step 3.
- `stage1-review-digest.json`: operation IDs, resources, adapter, native digests and summaries of
  the stage-1 review (no private native bytes).
- `status-before-summary.json`, `status-after-refusal-summary.json`.
- `dispose-c3-1008-dryrun-pre-teardown.sh`, `dispose-pre-digests.txt`.

## Disposal (nagare-verify, 2026-10-08)

The operator approved the cloud sequence in session nagare-verify on 2026-10-07: "exact-name deletes from each context's own Pulumi stack export". Staged retirement could not run (F84), so nagare-verify:
- took a final history export, `evidence-private/final-before-disposal-export`, at generation 1025, idle, 50 accepted;
- ran `dispose-c3i.sh` with `DISPOSE_EXECUTE=1`. All 35 commands completed ([log](disposal-executed.log)).

A read-only sweep afterwards found no instance, disk, snapshot, image, address, firewall, network, CDN component, service account, bucket, registry repository or DNS zone for `c3-1008`.
