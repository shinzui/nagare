---
id: 248
slug: issue-least-privilege-credentials-to-a-delegated-deployer
title: "Issue least-privilege credentials to a delegated deployer"
kind: exec-plan
created_at: 2026-11-07T16:50:58Z
master_plan: "docs/masterplans/33-delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-07T16:50:58Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-09T03:56:32Z
      verdict: "changes-requested"
      note: "Credential rules omit protected DomainMapping writes in nagare-system; specify EP-251 scoped local credential issuance and revocation."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-09T04:04:19Z
      mode: "update"
      note: "Add protected DomainMapping authority and own scoped local S3 credential lifecycle with EP-251 prerequisite and integration proof."
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-11T17:27:16Z
      mode: "implement"
      note: "D1-D10 implemented and confirmed on one local run at 59d10332; Complete"
---

# Issue least-privilege credentials to a delegated deployer

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current.


## Purpose / Big Picture

After EP-247 an operator can review a delegation, but deploying still needs the operator's cluster-admin kubeconfig and
`gcloud` session. After this plan the operator runs `nagarectl deployer credentials NAME --out DIR` and hands `DIR` to
the deployer (for Kotei, its deploy runner's home). With only that directory the deployer plans and applies inside its
delegation. Kubernetes refuses it everything outside the delegated namespaces except the named reads, backend ConfigMap and protected DomainMapping authority described in D2, the registry refuses a push outside the delegation's image repository, and on a cloud context the store
credential reaches only the inventory prefix. A second directory, the builder kubeconfig, can only run Nagare's hardened
one-shot build Jobs in the delegation's build namespace and cannot deploy. `nagarectl deployer revoke NAME` and
`nagarectl deployer rotate NAME` withdraw and replace both.

This is a child of
[MasterPlan 33](../masterplans/33-delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing.md)
and delivers UC-4's `least-privilege-deployer-credentials`
([UC-4](../use-cases/004-engineers-deploy-sites-by-pushing-through-a-delegated-deployer.md)). It hard-depends on
[EP-247](247-review-a-bounded-namespace-delegation-for-a-named-deployer-and-record-who-applied-each-change.md) for the
delegation record and the actor. It also hard-depends on
[EP-251](251-keep-a-local-context-s-inventory-store-in-its-in-cluster-object-store-so-an-in-cluster-deployer-can-apply.md)
for the accepted S3 transport, credential-file input and migration behavior; the local object-store bundle is required acceptance. Kotei's
`mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application` mounts the bundle and
`mori://shinzui/kotei/plans/150-run-forge-builds-in-credential-free-kubernetes-jobs` uses the builder kubeconfig.


## Progress

Interpreter and fake-adapter evidence comes first; native runs only confirm
([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)). The local run is
[ep248-local-confirmation-2026-11-11](../audits/ep248-local-confirmation-2026-11-11.md), at `59d10332`.

- [x] D1, rules derived from the compilers. `Nagare.Inventory.DeployerAccess` maps each delegated kind to the
  resources its compilers write. Evidence: `Nagare.Test.DeployerAccess`, "D1: each delegated kind's rules are
  exactly what its compiled scopes write and read". It compiles a web app with workers, a hook and a scheduled
  task; a standalone worker; a task run; a protected static site; and a server site. It fails on any missing
  or extra grant, and on any nagare-system object not granted or granted without use.
- [x] D2, the deployer identity in the delegation scope: a ServiceAccount, a Role per delegated namespace, a
  nagare-system Role (`nagare-access-backends` get, update and patch; the DomainMapping lifecycle), and a
  read-only ClusterRole for nodes, DomainMappings and ClusterDomainClaims. All are Retain, and present
  whenever the delegation is active (Decision Log). Evidence: "D2: an active delegation compiles the
  deployer's identity…" and the audit's P2.
- [x] D3, the builder identity. Evidence: "D3: the builder can create every object a one-shot Job renders, and
  nothing more" (it renders `oneShotJob`), and the audit's P5.
- [x] D4, the bundle: `nagarectl delegation credentials NAME --out DIR [--duration D] [--contract 1]`
  (Decision Log). Evidence: `Nagare.Test.DeployerCredentials` for the files, their modes and the refusals of
  non-empty, symbolic-link and in-repository directories; the `deployer-credentials` golden sample; and the
  audit's P3.
- [x] D5, the guard and the store with only the bundle. Evidence: the audit's P4, run in a Pod with `HOME` and
  `XDG_CONFIG_HOME` at the bundle: `inventory history`, `inventory status --scope`, `app image-plan`,
  `app deploy --save-plan` then `inventory apply`, `site deploy` and `worker deploy`.
- [x] D6, the cloud principal: `NagareDelegatedDeployer` built from the derived `nagare:delegatedDeployers`.
  The key is created after the ADR 9 project guard. Evidence: `infra/pulumi/test/delegatedDeployerResources.test.ts`,
  the `foundation-managed-delegated-deployer` parity variant and `Nagare.Test.DeployerCloudAccess`. A native
  IAM refusal check is the operator's to run on a disposable cloud context.
- [x] D7, revoke and rotate. `delegation revoke` empties every deployer and builder Role, removes the store
  user, and disables the cloud account. Running `delegation credentials` again rotates. Evidence: "D7:
  revoking keeps every identity object and empties every Role…", "D7: running it again retires every earlier
  handle and key, only after the new bundle is written", the cloud derivation test, and the audit's P6 and P7.
- [x] D8, the local confirmation. Evidence: the audit, P4 to P7.
- [x] D9, docs and decisions: [Delegating deployments](../user/delegating-deployments.md) and its
  [reference rows](../user/reference.md#nagarectl-delegation). [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
  is amended (2026-11-11).
- [x] D10, the scoped local object-store identity: `Nagare.Inventory.DeployerStoreAccess`. Evidence:
  "D10: a failed key issue writes no bundle and retires nothing…", "D10: the store policy reaches only the
  inventory prefix…", and the audit's P2, P6 and P7. That covers an in-cluster apply, prefix isolation, old
  keys refused after rotation and revocation, and the protected DomainMapping created by the deployer's own
  credentials.

## Surprises & Discoveries

- 2026-11-11, D1. No compiled delegated scope reads the delegation record, `nagare-shomei-settings` or any
  Secret. Runtime Secret references are dependencies, not observed members. The draft D2 grants were
  dropped, and P4 deployed with the derived rules alone.
- 2026-11-11, D6. Cloud Storage checks `storage.objects.list` against the bucket, so no IAM condition limits
  listing to a prefix. The deployer can list every object name in the inventory bucket but read, write and
  delete only beneath its prefix.
- 2026-11-11, the rehearsal. The deploy path assumed workstation tools (`shasum`, `awk`, `docker`,
  `/usr/bin/env`). Each surfaced only in a Linux Pod, one 10-minute image build at a time (FRIC-11).

- 2026-11-07, while writing this plan. The MasterPlan says the guard must verify the cluster "without node listing". It
  does not need to change: the guard (`serverNodes` in `ClusterSession.hs`) only lists nodes and compares the sole
  server node and its UID with the context host. A ClusterRole with `get, list` on nodes keeps the guard, including its
  node-replacement check, unchanged, and node objects are not secret. D2 grants that instead of writing a second guard.
  Reported to the MasterPlan.
- 2026-11-07, same reading. On a local context the inventory store is always a private directory,
  `$XDG_STATE_HOME/nagare/CONTEXT/inventory` (`effectiveInventoryStore` in `cli/nagarectl/src/Nagare/Target.hs`,
  `openTargetStoreReadOnly` in `cli/nagarectl/src/Nagare/Inventory/Store/Target.hs`), and the client identity lives in
  the same state root. A deployer running in a pod on a local context cannot reach that store at all, so Kotei hosted in
  the cluster of a local context cannot deploy through it; MasterPlan 33's local end-to-end gate assumes it can. This
  plan supports a local deployer that runs on the operator's machine, with its own state root and the operator's store
  directory named by a new `NAGARE_INVENTORY_STORE_ROOT` override in the bundle's context. An in-cluster deployer on a
  local context needs an object-store inventory backend. EP-251 now owns that transport; D10 owns
  scoped identities and bundle integration. The directory override remains only for filesystem contexts.
- 2026-11-07, same reading. A protected site deploy writes the `nagare-access-backends` ConfigMap in `nagare-system`
  (the composer regenerates it from `RegisterBackend` contributions in `cli/nagare-dsl/src/Nagare/Resource/Inventory.hs`).
  The deployer therefore needs `update` on that one ConfigMap. Kubernetes cannot limit which keys of it the deployer
  changes, so the bound on hostnames rests on nagarectl's checks (EP-247 D4), which is the MasterPlan's trust model.


## Decision Log

- Decision: Credentials are one command, `nagarectl delegation credentials NAME --out DIR`. Running it again rotates,
  and revocation is EP-247's `delegation revoke`. There is no `deployer` command group and no `--issue-deployer` switch.
  An active delegation scope always carries its identities.
  Rationale: one issuing path and one reviewed revocation are fewer steps than three commands and a flag. The
  identities are reviewed members, while issued material (tokens, keys) is never reviewed, so rotation needs no review.
  Date: 2026-11-11

- Decision: Each issue creates a handle Secret `nagare-deployer-NAME-ISSUE` (and `nagare-builder-NAME-ISSUE` in the
  build namespace), and its token is a TokenRequest bound to that handle. Rotation deletes every earlier handle, which
  refuses every earlier token at once, and removes every earlier store key. That happens only after the new bundle is
  written, so a failed run leaves the previous bundle working and a rerun completes it.
  Rationale: a bound token can only be withdrawn early through its bound object. Handles give per-issue rotation
  without long-lived token Secrets.
  Date: 2026-11-11

- Decision: Revocation updates every deployer and builder Role in place to `rules: []`. That needed Role updates in the
  Kubernetes adapter (`supportedUpdateKinds`, kind table, mutation record regenerated). The read-only ClusterRole
  (nodes, DomainMappings, ClusterDomainClaims) and every binding stay unchanged.
  Rationale: collection takes a second review after retirement, so deleting bindings would leave a window in which a
  revoked token still deploys. Emptying Roles takes effect in the one reviewed change. The ClusterRole grants no write
  and no Secret, and a ClusterRole update would need new recorded API traces (`InventoryKindSemanticsSpec`).
  Date: 2026-11-11

- Decision: The rules are derived from production-compiled scopes. The nagare-system Role grants `get, update, patch`
  on `nagare-access-backends` and the DomainMapping lifecycle, nothing else. The `get` on the delegation record and on
  `nagare-shomei-settings` (D2's draft) and any Secret access were dropped: no delegated scope reads them. Runtime
  Secret references are dependencies, not observed members.
  Rationale: D1's property test fails on any grant no fixture uses, so the grants stay least privilege. The local run
  confirms the planner needs nothing more.
  Date: 2026-11-11

- Decision: On a local object-store context, the deployer's MinIO user and its prefix policy are reviewed members of
  the delegation scope. A grant Job and, on revocation, a revoke Job write them, using the store's own client image.
  Keys are MinIO service accounts of that user, added and retired in one-shot Pods with the key on standard input.
  Filesystem-store contexts are refused and pointed to `inventory store migrate --to object`, and
  `NAGARE_INVENTORY_STORE_ROOT` is not added.
  Rationale: the MinIO admin API encrypts its bodies, so `mc` in the cluster is the narrowest reliable administrator.
  Removing the user removes every key with it. The in-cluster deployer is the use case, and a workstation deployer
  would be a second path to prove.
  Date: 2026-11-11

- Decision: The bundle is for in-cluster use: its kubeconfig server is `https://kubernetes.default.svc` and its store
  endpoint is the in-cluster Service. A deployer context defaults `KUBECONFIG` and
  `NAGARE_INVENTORY_STORE_CREDENTIALS_FILE` to the bundle's own files when they are unset (finding 3 of the 2026-11-11
  confirmation).
  Rationale: then `HOME` and `XDG_CONFIG_HOME` at the bundle are the whole configuration, as D5 requires. Kotei's
  explicit `KUBECONFIG` still wins.
  Date: 2026-11-11

- Decision: `packages.aarch64-linux.nagarectl` carries a deploy payload: the platform payload without the two x86_64
  bootstrap image archives (finding 1). This reverses EP-253's no-payload decision for that system.
  Rationale: every deploy prepares the platform workspace, and Kotei's runner must deploy natively on ARM64 (Kotei
  plan 148 D6 runs the UC-4 gate on Apple silicon). Kotei pins one immutable output per architecture and needs no
  overlay. Only platform bootstrap reads the archives, and a deployer never bootstraps.
  Date: 2026-11-11

- Decision: D5's acceptance reads `inventory history` and `inventory status --scope KIND:NAME`, not unscoped
  `inventory status` (finding 2). An unscoped status reports the platform's own scopes, which only operators prepare.
  Date: 2026-11-11

- Decision: Own local S3 policy and credential lifecycle here; require EP-251 before completion.
  Rationale: a transport alone cannot supply a usable hosted deployer. The same reviewed revoke must remove Kubernetes authority and local object-store access.
  Date: 2026-11-08


- Decision: The Kubernetes identity is a ServiceAccount with short-lived bound tokens from the TokenRequest API, not a
  long-lived token Secret.
  Rationale: bound tokens expire on their own and are not stored in the cluster; rotation is re-issue. Revocation removes
  the bindings, which takes effect immediately for every token. Rejected: a `kubernetes.io/service-account-token`
  Secret, which never expires and would sit in `nagare-system` where other readers could copy it.
  Date: 2026-11-07

- Decision: Rules are derived from what the compilers emit for the allowed kinds and tested against fixtures, not
  written by hand.
  Rationale: a hand list drifts the first time a compiler adds a member, and fails only in a native run. A property
  test fails at `gate-fast`.
  Date: 2026-11-07

- Decision: The cloud principal follows EP-196's pattern (a Pulumi component built per entry of a derived config,
  reviewed through the cloud catalog, with a resource test), with its own Artifact Registry repository.
  Rationale: Artifact Registry permissions are granted per repository; the node account already holds project-level
  writer (`infra/pulumi/src/components/NagarePerimeter.ts`), so a repository-level writer on a delegation repository is
  the narrowest grant that still lets the node pull. Rejected: reusing the node account (it can write every repository
  and the backup bucket, as EP-196 also found), and a project-level role with a resource-name condition, which Artifact
  Registry does not support as reliably.
  Date: 2026-11-07

- Decision: The deployer holds write access to the inventory store's objects under the context's inventory prefix,
  including `head.json`.
  Rationale: the executor is client-side and the store has one head per context (ADR 22), so a writer must be able to
  replace the head. MasterPlan 33 accepts this: the deployer is trusted, repository content is not. The IAM condition
  keeps Pulumi state and other contexts' objects out of reach.
  Date: 2026-11-07


## Outcomes & Retrospective

A delegated deployer now runs from one private directory. In the cluster, Kubernetes, the object store and
(on a cloud context) IAM refuse it everything outside its delegation except the access backend map and
protected routes, which the delegation bounds govern. One review revokes it, and running the credentials
command again rotates it. The local run found seven defects that the interpreters could not see, all
Linux-host assumptions in the deploy path plus the API server's `null` for empty rules
([FRIC-11](../friction-log/11-linux-host-tool-assumptions-in-the-deploy-path-surfaced-one-per-10-minute-image-build.md)).
The fast gate's audit steps cost three runs ([FRIC-10](../friction-log/10-the-fast-gate-s-audit-and-mutation-steps-failed-one-at-a-time-for-a-new-subcommand-and-a-new-update-kind.md)).
What remains: the operator's native IAM check on a cloud context, and Kotei EP-148's end-to-end UC-4 gate.
The trust model's second layer and its limits move to an ADR 35 amendment, and the cloud path to ADR 9's.


## Context and Orientation

**Terms.** A *bundle* is the directory this plan writes for a deployer. A *ServiceAccount* is a Kubernetes identity for
programs; a *Role* lists allowed verbs on resource kinds in one namespace, a *ClusterRole* does so cluster-wide, and a
*binding* attaches either to an identity. A *bound token* is a ServiceAccount token issued by the Kubernetes API with an
expiry. The *builder* is the identity that starts build Jobs; the *deployer* is the identity that deploys.

**What deploying uses today.** `nagarectl kubeconfig fetch` writes the k3s administrator kubeconfig to
`$XDG_CONFIG_HOME/nagare/kubeconfigs/CONTEXT.yaml` (`cli/nagarectl/src/Nagare/Cluster/Kubeconfig.hs`);
[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps kubeconfigs as operator state.
The cluster session guard (`ClusterSession.hs`) flattens the selected context into a private file and lists nodes. On a
cloud context the store is opened through a `gcloud` session in `cli/nagarectl/src/Nagare/Inventory/Store/GcloudAuth.hs`,
which honors `credential_file_override`, checks the ambient project, and the bucket's owner (`Store/Remote.hs`); image
publication runs `scripts/inventory-artifact-transport.sh`, which logs `skopeo` in with `gcloud auth print-access-token`.
So a gcloud configuration with a key override is enough for both, and the bundle sets `CLOUDSDK_CONFIG` through its
context file. The platform workspace is prepared from the installed package by `resolvePlatformWorkspace`
(`cli/nagarectl/app/Nagare/Cli/Runtime/Target.hs`), so the bundle carries no payload.

**Existing models to copy.** EP-196 (`docs/plans/196-read-the-inventory-store-from-an-in-cluster-service-identity.md`)
created a read-only store account with a custom role and an object-name condition through
`infra/pulumi/src/components/NagareAdminApiReader.ts`, wired in `infra/pulumi/index.ts` and tested in
`infra/pulumi/test/adminApiReaderResources.test.ts`. `cluster/bootstrap/nagared/rbac.yaml` is a hand-written site
deployer's RBAC, including the hostname preflight reads. `cli/nagare-dsl/src/Nagare/Dsl/Job.hs` renders a tokenless
ServiceAccount, a default-deny NetworkPolicy and one Job ([Bounded one-shot jobs](../user/one-shot-jobs.md)).

**Decisions this rests on.** [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
confines cloud mutations to the active project. [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
keeps operator material private; the bundle is operator material and never enters a repository.
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) keeps one client-side executor.
The accepted trust model is [ADR 35](../adr/0035-a-delegated-deployer-is-trusted-and-repository-content-is-not.md); EP-247 supplies its implementation evidence.


## Plan of Work

Add a new module `cli/nagarectl/src/Nagare/Inventory/DeployerAccess.hs` with the rule derivation, and compile the
deployer and builder members into the delegation scope from `compileDelegationScope` (EP-247) behind an `issue`
switch, so `delegation create --issue-deployer` or a later `deployer issue NAME --save-plan DIR` adds them. Add the
`deployer` command group (`credentials`, `revoke`, `rotate`) in a new `cli/nagarectl/app/Nagare/Cli/Commands/Deployer.hs`.
`credentials` calls the TokenRequest API through kubectl (`kubectl create token SA -n nagare-system --duration D`) with
the operator's guarded session, writes the files atomically through a private sibling directory as
`kubeconfig fetch` does, and on a cloud context creates the key with `gcloud iam service-accounts keys create` after
the project assertion. Add `NAGARE_INVENTORY_STORE_ROOT` to the local store opener for D5's local deployer. Add the
Pulumi component, its config projection from accepted delegations, and its tests. Implement D10
through a new `Nagare.Inventory.DeployerObjectStoreAccess` module with injectable administration operations,
reviewed policy/identity resources, idempotent recovery and no plaintext keys in review bytes. Then the local confirmation and docs.


## Validation

```bash
just haskell-style-check
just gate-fast
cd cli/nagarectl && cabal test nagarectl-test --test-options='-p /Deployer/'
cd infra/pulumi && npm test
```

D8 runs on a local context after [Before a native run](../runbooks/before-a-native-run.md), in a clean environment:

```bash
env -i HOME="$DIR" XDG_CONFIG_HOME="$DIR/.config" XDG_STATE_HOME="$DIR/.local/state" PATH="$PATH" \
  nagarectl --context CONTEXT inventory status --contract 1
env -i KUBECONFIG="$DIR/.config/nagare/kubeconfigs/CONTEXT.yaml" PATH="$PATH" \
  kubectl auth can-i create configmaps -n personal
```

The second command must print `no`. Every refusal listed in D8 is recorded with its exact message.


## Interfaces

```haskell
-- cli/nagarectl/src/Nagare/Inventory/DeployerAccess.hs (new)
data KubernetesRule = KubernetesRule {apiGroups :: ![Text], resources :: ![Text], verbs :: ![Text], resourceNames :: ![Text]}
deployerRules :: NonEmpty DelegatedKind -> [KubernetesRule]
builderRules :: [KubernetesRule]
```

```text
DIR/
  .config/nagare/contexts/CONTEXT.env      NAGARE_DEPLOYER=NAME, no secrets
  .config/nagare/kubeconfigs/CONTEXT.yaml  bound token for nagare-deployer-NAME
  .config/gcloud/                          cloud contexts: key override, core/project
  .config/nagare/credentials/CONTEXT-s3.json  local object contexts: scoped S3 keys
  builder/kubeconfig.yaml                  bound token for nagare-builder-NAME (build namespace only)
```

Kotei's runner checks that `$HOME/.config/nagare/kubeconfigs/CONTEXT.yaml` equals its explicit kubeconfig byte for byte;
the bundle satisfies it when the runner's `KOTEI_KUBECONFIG` points at that same file. The `deployer-credentials`
document is added to `docs/api/` as an operation document.

Revision (2026-11-08): applied the MasterPlan 33 review findings to the interfaces, acceptance and ownership described above.
