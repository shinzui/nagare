# Delegating deployments

A context's operator can let a CI/CD program, such as Kotei, deploy apps and sites inside a bounded part
of the context without a per-deploy operator review. The operator reviews one **delegation**; the
deployer then plans and applies inside it, and every change it makes is attributed to it.

The deployer is software the operator runs and trusts. What it deploys (an engineer's repository, its
configuration and images) is not trusted, so Nagare checks every deployer proposal against the
delegation before anything is published and again when the change is admitted
([ADR 35](../adr/0035-a-delegated-deployer-is-trusted-and-repository-content-is-not.md)).

## Create a delegation

```bash
nagarectl delegation create kotei \
  --namespace team-a \
  --host-suffix -docs \
  --kinds web-app --kinds static-site \
  --image-repository REGISTRY/PROJECT/nagare/team-a \
  --team engineering \
  --build-namespace team-a-build \
  --save-plan /tmp/delegation-kotei
nagarectl inventory apply /tmp/delegation-kotei --yes
```

The review creates scope `platform:delegation-kotei`. It owns each delegated namespace (labelled
`nagare.dev/delegation=kotei`), one ResourceQuota and one LimitRange per namespace (`--quota-cpu`,
`--quota-memory` and `--quota-pods`, default 4 CPUs, 8Gi and 50 pods), the optional build namespace, and
the record ConfigMap `nagare-delegation-kotei` in `nagare-system`. Every member is retained: revoking or
narrowing a delegation never deletes a namespace or what runs in it. A namespace the platform foundation
or another delegation owns, `nagare-system`, `personal`, `default` and `kube-*` are refused.

App, worker, task, site, storage and env commands accept a delegated namespace exactly as they accept
`personal`, for the operator and the deployer alike.

The same scope holds the deployer's identities. ServiceAccount `nagare-deployer-kotei` in `nagare-system`
gets a Role in each delegated namespace with exactly what the delegated kinds' compilers write: Knative
Services, ConfigMaps, Deployments, CronJobs and Jobs, as the kinds need. Its Role in `nagare-system` covers
the access backend map `nagare-access-backends` (get, update, patch) and protected DomainMappings. A
read-only ClusterRole covers nodes, DomainMappings and ClusterDomainClaims, which the cluster guard and the
hostname preflight read. It grants no Secret, no RBAC, no Namespace and nothing in `personal`. With
`--build-namespace`, ServiceAccount `nagare-builder-kotei` in that namespace may create, watch and delete
ServiceAccounts, NetworkPolicies and Jobs there and read Pods and their logs: exactly what a
[one-shot Job](one-shot-jobs.md) renders and what watching it needs. It holds no deploy rights, and the
deployer holds no build rights. Kubernetes cannot bound a route's hostname or the hosts written into the
backend map; the delegation's bounds below do.

On a local context whose inventory is in the in-cluster object store, the scope also reviews MinIO user
`nagare-deployer-kotei`. Its policy can read, conditionally write and delete objects beneath the context's
inventory prefix and list only that prefix, so it reaches no backups, no other prefix and no bucket
administration. A Job using the store's own client image writes the user and the policy. A context whose
store is a directory on the operator's machine has nothing a hosted deployer can reach; move it first with
`nagarectl inventory store migrate --to object`.

## Issue the deployer's credentials

```bash
nagarectl delegation credentials kotei --out ~/deployers/kotei [--duration 720h]
```

writes a private directory (mode 0700, files 0600) that is the deployer's whole configuration:

| File | Holds |
| --- | --- |
| `.config/nagare/contexts/CONTEXT.env` | the operator's context with `NAGARE_DEPLOYER=kotei`; nothing secret |
| `.config/nagare/kubeconfigs/CONTEXT.yaml` | an in-cluster kubeconfig (`https://kubernetes.default.svc`) whose one user is a bound token for `nagare-deployer-kotei` |
| `.config/nagare/credentials/CONTEXT-s3.json` | on an object-store context, the deployer's store key, `{"accessKeyId", "secretAccessKey"}` |
| `builder/kubeconfig.yaml` | with a build namespace, a bound token for `nagare-builder-kotei` |

Run the deployer with `HOME` and `XDG_CONFIG_HOME` at the directory and its `.config`. A deployer context
uses the bundle's kubeconfig and store key unless `KUBECONFIG` or a store credential variable says
otherwise. The directory must be new or empty, not a symbolic link, and outside any Git repository: it is
operator material ([ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)).
`--contract 1` prints a `deployer-credentials` document naming the files, the token expiry and the key id,
never a secret.

Each token is bound to a handle Secret created for that run, and each key is a new key of the deployer's
store user. **Running the command again rotates.** It proves the new key, writes the new directory, and only
then deletes every earlier handle (so every earlier token is refused) and every earlier key. If a run fails,
the previous directory keeps working; run it again.

## What a deployer may do

A context whose file sets `NAGARE_DEPLOYER=kotei` is a deployer context. It reviews as `deployer:kotei`
and runs only `app image-plan|check|deploy|delete`, `worker deploy`, `task run|delete`,
`site deploy|rollback|preview …`, `inventory apply|resume|status|publications|history`,
`delegation show` and `version`; any other command is refused before it reads the store. A context
never sets both `NAGARE_DEPLOYER` and `NAGARE_OPERATOR`.

A deployer proposal is refused, naming the delegation, the bound and the member, when it:

- writes a scope other than a web app, worker, task, static or server site the delegation allows, or an
  app image;
- places a member outside the delegated namespaces, except the generated protected route for one of its
  own hosts in `nagare-system`, targeting the access enforcer;
- declares a hostname that is neither `NAME.NAMESPACE.BASE` (or `NAME-NAMESPACE.BASE` behind a tunnel)
  for a delegated namespace nor one label under the base domain ending in an allowed suffix (a site
  preview may also use the context's preview hostname shape);
- declares a public host: every delegated host requires `access = requireLogin`;
- contains a managed database, app database, broker, volume, CDN resource, supplied TLS, public route,
  namespace request, RBAC object or collection;
- publishes an image outside the delegation's image repository;
- touches a scope another actor last wrote.

## Revoke a delegation

```bash
nagarectl delegation revoke kotei --save-plan /tmp/revoke-kotei
nagarectl inventory apply /tmp/revoke-kotei --yes
```

Every later deployer review is refused with `delegation-revoked`, including one saved before the
revocation. The same review empties every deployer and builder Role, so every issued token is refused by
Kubernetes as soon as the change applies, and on an object-store context a Job removes the store user
with every key it holds. The namespaces and everything deployed in them stay; the operator can still
change them.

On a cloud context, then run `nagarectl platform bootstrap plan --out DIR` and apply it. That stage disables
the deployer's service account, which refuses every key it holds. Do it before the next platform transition:
a transition started while the foundation still holds the active account stops at the foundation stage. An
access token minted before a key was deleted, by rotation or revocation, stays valid until it expires
(up to an hour).

## Who applied each change

Every review records its actor: `deployer:NAME`, `operator`, or `operator:NAME` when the operator's
context sets `NAGARE_OPERATOR=NAME`. A deploy may also record where its change came from with
`--source-repository URL`, `--source REF` (or `--source-revision REF` where the command has no
`--source`) and `--source-run URL`. These are part of the review digest, so the transaction that applied
it is bound to them.

```bash
nagarectl inventory history --limit 10
nagarectl inventory history --contract 1
```

lists transactions newest first with their final state, scopes, actor and source. The actor is what the
applying client's context asserted, not a proved identity.

## Retrying a stale review

Admission takes one change at a time. When another change lands first, a saved review is refused with
the problem `review_stale` (`retryable: true`); plan again and apply the new review. Every other refusal,
including `delegation-revoked` and `delegation-bounds`, is `admission_refused`.

## Related

- [Resource inventory](resource-inventory.md)
- [Identity-aware access](access.md)
- [Reference](reference.md#nagarectl-delegation)
