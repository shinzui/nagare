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
`mori://shinzui/kotei/plans/136-run-forge-builds-in-credential-free-kubernetes-jobs` uses the builder kubeconfig.


## Progress

Interpreter and fake-adapter evidence comes first; native runs only confirm
([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)).

- [ ] D1, rules derived from the compiler: a pure function maps a delegation's allowed kinds to the Kubernetes rules a
  deployer needs, derived from the provider addresses that compiled delegated scopes produce (Knative Services and
  DomainMappings, ConfigMaps for release history, Secrets for runtime environment references, CronJobs and Jobs for
  tasks and hooks, Deployments for workers, as the compilers actually emit). Evidence: a property test compiles one
  fixture scope per allowed kind and fails if any generated member address, including protected routes in nagare-system, is not covered by the derived
  rules, and fails if a rule grants a resource no fixture produces.
- [ ] D2, the deployer identity in the delegation scope: the delegation scope (EP-247) gains, when a credential is
  issued, a ServiceAccount `nagare-deployer-NAME` in `nagare-system`; a Role and RoleBinding in each delegated
  namespace with D1's rules; a Role and RoleBinding in `nagare-system` granting `get, update, patch` on exactly the
  ConfigMap `nagare-access-backends` by `resourceNames`, and `get` on
  `nagare-delegation-NAME` and `nagare-shomei-settings`; a Role and binding in `nagare-system` for
  `get, list, watch, create, update, patch, delete` on `domainmappings.serving.knative.dev`. The latter covers
  generated protected routes; hostname suffixes and the enforcer target are enforced by EP-247, not RBAC.
  This wider resource-kind authority is an explicit trusted-deployer exception, never authority over other system kinds; a ClusterRole and binding for `get, list` on nodes (the cluster session guard) and on
  `domainmappings` and `clusterdomainclaims` (the hostname preflight, as `cluster/bootstrap/nagared/rbac.yaml` already
  grants `nagared`). All are reviewed members, `Retain` until revoked. Evidence: compiler tests of the members and their
  bytes, and a review fixture showing them in a `delegation create … --issue-deployer` review.
- [ ] D3, the builder identity: when the delegation has a build namespace, the scope gains ServiceAccount
  `nagare-builder-NAME` in that namespace and a Role and RoleBinding granting `create, get, list, watch, delete` on
  `serviceaccounts`, `networkpolicies.networking.k8s.io` and `jobs.batch`, and `get, list, watch` on `pods` and
  `pods/log`, which is exactly what `renderJob` in `cli/nagare-dsl/src/Nagare/Dsl/Job.hs` creates and what watching it
  needs. It has no `secrets`, no `pods/exec` and nothing outside the build namespace. Evidence: a test that renders a
  `oneShotJob` and proves every rendered object kind is covered, and that no other verb is granted.
- [ ] D4, the bundle: `nagarectl deployer credentials NAME --out DIR [--duration D]`, run by the operator, refuses unless
  the delegation and its identities are accepted and converged, then writes, mode 0600 under a 0700 `DIR`:
  `DIR/.config/nagare/contexts/CONTEXT.env` (the operator's context with `NAGARE_DEPLOYER=NAME` added and nothing
  secret), `DIR/.config/nagare/kubeconfigs/CONTEXT.yaml` (a kubeconfig whose only user is a bound token for
  `nagare-deployer-NAME` from the Kubernetes TokenRequest API with the chosen duration), on a cloud context
  `DIR/.config/gcloud/` (a gcloud configuration whose `auth/credential_file_override` names a key for the delegation's
  cloud principal and whose `core/project` is the context's project), and `DIR/builder/kubeconfig.yaml` when a build
  namespace exists. It prints a `deployer-credentials` contract document naming the paths, the token expiry and the
  key id, never a secret. It refuses an existing non-empty `DIR`, a symlinked `DIR` and a `DIR` inside the repository.
  Evidence: fake-command tests for each refusal and for the file modes; a golden sample. For local object-store contexts, write a private
  `DIR/.config/nagare/credentials/CONTEXT-s3.json` containing only the scoped access key and secret key. Set
  `NAGARE_INVENTORY_STORE_CREDENTIALS_FILE` to its bundle-local path and use the in-cluster Service endpoint in the
  context. EP-251 reads that file without sourcing it as shell. Never copy the object-store administrator credential.
- [ ] D5, the guard and the store with a scoped identity: with `HOME=DIR` and `XDG_CONFIG_HOME=DIR/.config` and nothing
  else, `nagarectl --context CONTEXT inventory status` passes the cluster session guard
  (`cli/nagarectl/src/Nagare/Inventory/ClusterSession.hs`) and reads the store; `app image-plan`, `app deploy
  --save-plan` and `inventory apply` succeed for a delegated fixture site. Evidence: a local-context run (D8).
- [ ] D6, the cloud principal (cloud contexts only, proved without a cloud run; a native IAM refusal check is the
  operator's to run on a disposable cloud context, as EP-198 did for the reader): a Pulumi component
  `NagareDelegatedDeployer`, built once per accepted, unrevoked delegation listed in a derived Pulumi config key
  `nagare:delegatedDeployers`, declares a service account, an Artifact Registry Docker repository for the delegation's
  image repository with that account as a repository-level writer (the node account keeps its project-level access, so
  pulls are unchanged), and a custom role on the inventory store's bucket with `storage.objects.get, create, delete,
  list` and `storage.buckets.get`, under an IAM condition limiting object access to the context's inventory prefix.
  `deployer credentials` creates the key with the operator's session, through the same project assertion as every
  cloud-mutating path (ADR 9). Evidence: `infra/pulumi/test/delegatedDeployerResources.test.ts` (added to the `test` script in
  `infra/pulumi/package.json`) checks exactly those resources, the condition text and that nothing grants project-level roles; `resourceProgramParity.test.ts` gains a
  variant with one delegation; a fake-command test of key creation and of the project assertion's refusal.
- [ ] D7, revoke and rotate: `nagarectl deployer revoke NAME --save-plan DIR` reviews removing every RoleBinding,
  ClusterRoleBinding and the cloud principal's bindings and keys for NAME, which makes every issued token and key stop
  working at apply; `deployer rotate NAME` issues a new bundle, then reviews deleting the old key. EP-247's `delegation
  revoke` includes the deployer revocation. Evidence: a test that the revocation review contains every binding D2, D3
  and D6 created and every local S3 identity from D10, and the local-context run in D8 showing a 403 after revocation. Rotation replaces local S3 credentials too;
  the old identity is disabled after the new bundle is verified, and resume completes a partially applied revocation.
- [ ] D8, the local confirmation: on a local context, with only the bundle, the deployer publishes and deploys a
  protected fixture site into its delegation; the same bundle gets `Forbidden` creating a ConfigMap in `personal`,
  reading a Secret in `nagare-system`, patching `nagare-shomei-settings` and creating a Namespace; the builder kubeconfig
  runs a `oneShotJob` to completion in the build namespace and gets `Forbidden` creating a Deployment there and anything
  in a delegated namespace; after `deployer revoke`, the deploy bundle gets `Unauthorized` or `Forbidden`. Evidence: an
  audit file under `docs/audits/`.
- [ ] D9, docs and decisions: `docs/user/` gains the credential steps in the "Delegating deployments" guide (EP-247) and
  reference rows; ADR 9 is amended to say a deployer bundle is a cloud-mutating path confined to the context's project
  by the same assertion. Evidence: the linked pages.

- [ ] D10, scoped local object-store identity: for an object-store context, issue a distinct deployer identity and
  policy granting read, conditional write and delete only beneath the inventory prefix and listing only that prefix.
  This plan owns policy creation, key issuance, rotation, revocation and private bundle delivery; EP-251 owns transport
  and credential loading. No access to backups, other prefixes, bucket administration or root credentials is granted.
  Policy and identity lifecycle changes use reviewed resources with adapter recovery; key material stays private.
  Evidence: fake-adapter tests cover partial issuance, retry, rotation and revocation; on a disposable local context,
  a Pod with only the bundle applies a protected-site change, the operator sees that same head, outside-prefix reads,
  writes and lists fail, and old credentials fail after rotation and revocation. This gate also exercises creation,
  update and retirement of the generated protected DomainMapping with D2's actual credentials.


## Surprises & Discoveries

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

(To be filled at completion.)


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
