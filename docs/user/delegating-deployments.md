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
revocation. The namespaces and everything deployed in them stay; the operator can still change them.

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
