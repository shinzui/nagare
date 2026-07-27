# Secrets architecture assessment for Kikan, Kotei, and Nagare

Date: 2026-07-26
Status: Revised research and recommendation; not an implementation plan

## Question

Should Nagare add first-class OpenBao support to give Kikan agents credentials that can be
rotated, expired, revoked, and audited?

## Revised recommendation

Not yet. OpenBao is a capable general-purpose secrets system, but it should not be the
first-class Nagare abstraction or the primary way Kikan agents obtain CI/CD credentials.

Reviewing Kotei changes the ownership boundary. Kotei is Kikan's CI/CD platform, and it already
models credentials as logical `SecretRef` values resolved by a `SecretsProvider` at execution
time. A Kikan agent should receive narrowly scoped permission to request a Kotei pipeline or
action. Kotei, not the agent, should resolve and deliver the credentials needed by that run.

The preferred architecture is:

```text
Kikan agent or run identity
  -> authorization to invoke a specific Kotei pipeline or action
  -> Kotei resolves each declared logical SecretRef just in time
  -> provider-native workload identity or a Kotei SecretsProvider
  -> ephemeral delivery to the step that needs it
  -> correlated Kikan, Kotei, and provider audit records
```

Nagare still has an important role, but it is the execution substrate: workload identity,
ServiceAccounts, projected tokens, NetworkPolicy, memory-backed volumes, Pod isolation, and
cleanup. It should not know how to mint every provider credential.

OpenBao remains a reasonable future `SecretsProvider` or direct workload-delivery backend for
Kotei. Add it when there is evidence that several of its dynamic engines are needed, such as
database credentials, PKI certificates, SSH credentials, or cloud-independent operation. Do not
operate an additional security-critical control plane merely to put a few static API keys in KV.

## What changed from the initial assessment

The initial recommendation over-weighted Nagare's pending GitHub App token plan and treated
GitHub credential distribution as representative of Kikan agent access. That was the wrong
boundary for two reasons:

1. Kotei owns CI/CD execution. Kikan agents should invoke Kotei capabilities instead of receiving
   build, registry, deployment, or release credentials themselves.
2. GitHub is, at most, a source-forge adapter at Kotei's edge. Even when repositories are hosted
   there, GitHub credentials belong to Kotei rather than individual Kikan agents. If source is not
   hosted on GitHub, that integration is irrelevant to the secrets architecture.

This revision preserves the useful OpenBao findings while changing the system recommendation.

## Research method

Nagare, Kikan, Kotei, and Baikai were located through Mori before their source and documentation
were inspected:

```console
mori registry list
mori registry search kikan
mori registry show shinzui/kikan --full
mori registry docs shinzui/kikan
mori registry show shinzui/nagare --full
mori registry search kotei
mori registry show shinzui/kotei --full
mori registry show shinzui/kotei-docs --full
mori registry docs shinzui/kotei-docs
mori registry show shinzui/baikai --full
mori registry docs shinzui/baikai
mori registry search openbao
```

Mori has no registered OpenBao project. OpenBao behavior was therefore verified against official
OpenBao documentation and upstream Git tags. On the research date, the latest stable tags
observed upstream were OpenBao `v2.6.1` and Helm chart `openbao-0.28.6`. An implementation should
recheck upstream releases, then pin chart, image, plugin versions, and image digests rather than
following `latest`.

## Current system boundaries

### Nagare

Nagare currently has two secret paths:

- Host secrets are encrypted in Git and decrypted by `sops-nix` during NixOS activation.
- Application secrets are written to per-application, per-scope Kubernetes `Secret` objects by
  `nagarectl secret` and injected through `envFrom` or `secretKeyRef`.

This is documented in [`docs/user/secrets.md`](../user/secrets.md) and
[`docs/user/env-and-secrets.md`](../user/env-and-secrets.md). The implementation explicitly notes
that the Kubernetes wire value is base64 encoding, not encryption, and leaves encryption at rest
and RBAC outside the store's scope in
[`Nagare.Env.Store`](../../cli/nagarectl/src/Nagare/Env/Store.hs).

The model is useful static storage and injection, but it is not a credential lifecycle:

| Concern | Current behavior |
|---|---|
| Rotation | An operator replaces a value, or a provider-specific process republishes it. |
| Expiration | No generic expiry metadata or enforcement exists. |
| Revocation | Deleting a Kubernetes Secret does not revoke a credential already copied by a Pod. |
| Audit | Nagare does not record which workload fetched which secret. |
| Workload identity | Access is mediated through Kubernetes Secret visibility rather than per-workload provider policy. |
| Runtime refresh | Environment variables are fixed when the container starts. |

The checked-in k3s configuration also does not currently enable `--secrets-encryption` and sets
the kubeconfig mode to `0644`; see
[`nixos/hosts/nagare-01/k3s.nix`](../../nixos/hosts/nagare-01/k3s.nix). ExecPlan 103 proposes
closing both gaps, but that work is not present in the current configuration. This hardening is
worth completing independently of whether OpenBao is ever deployed.

Nagare's `Job` renderer creates a distinct ServiceAccount, disables generic token automounting,
and applies default-deny networking; see
[`Nagare.Dsl.Job.Render`](../../cli/nagare-dsl/src/Nagare/Dsl/Job/Render.hs). Those are the right
foundations. Credentialed workloads should opt into an audience-bound projected token and narrow
egress rather than weakening the default for every Job.

### Kikan

Kikan defines stable identities such as `service:shinzui/shikigami` and `agent:<name>`, plus
on-behalf-of attribution through Shomei. See
[`trust-grants.md`](../../../kikan/docs/architecture/evolution/trust-grants.md).

Kikan and Kikan-En should answer who the actor is, on whose behalf it acts, and which capability
it may request. For CI/CD, that capability should look like "invoke this Kotei pipeline/action for
this project and environment," not "read the deployment token." Revoking the capability prevents
new runs without requiring the agent to know which provider credentials were behind it.

### Kotei

Kotei owns workflow execution, build and deployment orchestration, application reconciliation,
artifact tracking, and pipeline visibility. It deliberately treats source hosting and Kubernetes
scheduling as external boundaries; see Kotei's
[`current-boundaries.mdx`](../../../kotei-docs/content/docs/kotei/explanation/current-boundaries.mdx).

Its source already contains the correct logical seam:

- `StepSpec` and `ActionSpec` declare `[SecretRef]` values.
- `SecretsProvider` resolves a logical reference at execution time.
- Environment, file, and in-memory providers currently exist.
- The local backend resolves declared secrets, injects them into the child process, and redacts
  their values from streamed and persisted logs.
- Action runs and workflow runs already provide identities to which credential events can be
  correlated.

See [`Kotei.Secrets`](../../../kotei/kotei-core/src/Kotei/Secrets.hs),
[`Kotei.Engine.Local`](../../../kotei/kotei-core/src/Kotei/Engine/Local.hs), and the
[`Actions and Forge` reference](../../../kotei-docs/content/docs/kotei/reference/actions-and-forge.mdx).

The seam is not production-complete. The current Kubernetes backend does not resolve or inject
`StepSpec.secrets`, so local and cluster behavior diverge. Kotei's pending secret-isolation work
also identifies risks from inherited process environments, unsafe secret reference paths, inline
Kubernetes values, and values leaking into durable records. See
[`Kotei.Engine.Kubernetes`](../../../kotei/kotei-core/src/Kotei/Engine/Kubernetes.hs) and
[`plan 48`](../../../kotei/docs/plans/48-isolate-and-redact-secrets-across-execution-paths.md).

This is the first implementation gap to close. Adding OpenBao to Nagare without completing
Kotei's execution contract would leave the actual CI/CD secret boundary inconsistent.

### External providers

Whenever possible, an external provider should issue short-lived credentials directly from
workload identity:

- GCP access should use Workload Identity Federation or service-account impersonation rather
  than exported service-account keys.
- Internal services should accept scoped Shomei/Kikan service tokens rather than shared API keys.
- Model-provider keys should stay behind a Baikai service boundary if Baikai is deployed as a
  gateway, rather than being distributed to every agent process.
- Database access should eventually use an identity-aware database proxy or a dynamic credential
  engine if unique leased users are operationally justified.

Provider-native identity usually gives stronger expiry and revocation semantics than copying a
static value out of any vault. Provider audit logs remain necessary because a secret manager can
record issuance or retrieval but cannot observe every later use of a copied credential.

## Proposed ownership model

| Concern | Owner |
|---|---|
| Agent, user, and on-behalf-of identity | Kikan and Shomei |
| Permission to invoke a pipeline, action, project, or environment | Kikan-En and the Kotei API boundary |
| Logical credential declarations | Kotei `SecretRef` contract |
| Just-in-time resolution, delivery, redaction, and run correlation | Kotei execution backends |
| ServiceAccounts, projected tokens, isolation, egress, tmpfs, and cleanup | Nagare and Kubernetes |
| Credential issuance, expiry, revocation, and usage audit | Provider-native identity/API where possible |
| Encrypted storage for unavoidable static roots | A managed secret store or OpenBao KV |
| Host bootstrap and disaster recovery | `sops-nix` with separately protected recovery material |

The first-class contract should therefore be a logical Kotei credential reference with explicit
delivery and lifetime requirements. `openbao://...`, `gcp-secret-manager://...`, Kubernetes Secret
names, and provider-specific paths should remain backend configuration rather than appearing in
pipeline code or Kikan agent prompts.

The existing `SecretsProvider` returns raw `SecretValue` bytes to the Kotei process. That is enough
for the local backend but too narrow for the final Kubernetes design. A production contract should
also represent workload identity and delivery plans so that a Kubernetes Job can authenticate
directly and receive an ephemeral file without routing plaintext through the Kotei control plane
or persisting it in the Job manifest.

## Where GitHub fits

Kotei is the CI/CD platform, but source control remains a separate forge. Its neutral `Forge`
adapter verifies webhooks, normalizes push or change-request events, reads repository metadata,
and posts statuses. GitHub is currently the MVP adapter, not the core execution model; see
[`forge-integration.mdx`](../../../kotei-docs/content/docs/kotei/explanation/forge-integration.mdx).

If GitHub remains the source host, Kotei may need a webhook secret and a narrowly scoped forge
credential for checkout, repository inspection, or status updates. Those are Kotei service/run
credentials. They should not be issued to Kikan agents and should not determine the overall
secrets architecture.

The unimplemented Nagare
[`GitHub credential plan`](../plans/94-rotating-github-app-installation-token-credentials-for-runtime-pods.md)
should therefore be reassessed rather than used as evidence for OpenBao. Its timer-based
publication into stable Kubernetes Secrets has real refresh, revocation, and audit limitations,
but the more fundamental question is whether any consumer outside Kotei needs the credential. If
not, the plan should move to Kotei's forge or execution boundary. If GitHub is not used for source
hosting, the plan may be unnecessary.

## What OpenBao would still add

OpenBao remains strong in several areas:

### Workload authentication and policy

Kubernetes workloads can authenticate with audience-bound ServiceAccount identity. OpenBao roles
can bind ServiceAccount names and namespaces to narrow policies, avoiding a shared bootstrap token
in each Pod.

### Leases and dynamic credentials

Dynamic secret engines and service-type OpenBao tokens carry leases that can be renewed, expired,
or revoked. The database secrets engine can create unique leased users, and PKI can issue
short-lived certificates.

This does not apply to arbitrary values stored in KV. Putting a static API key in OpenBao improves
storage policy and retrieval auditing but does not make the external key renewable, expiring, or
revocable.

### Retrieval auditing

OpenBao audit devices record nearly all API requests and responses, with sensitive strings HMACed
by default. This can prove that a workload requested a credential. It cannot prove or govern every
subsequent use at an LLM provider, source forge, or database, so provider-side audit remains part of
the design.

### Ephemeral Kubernetes delivery

OpenBao Agent and the CSI provider can deliver values through ephemeral in-memory files without
creating a second Kubernetes Secret. Agent templates can renew and refresh leased credentials.
Applications must reread the file; copying it into a process environment recreates the immutable
environment-variable problem.

### Operational independence

OpenBao provides a portable, open-source control plane when cloud independence or offline
self-hosting is a hard requirement. That benefit comes with responsibility for TLS,
initialization, seal recovery, persistent storage, snapshots, audit retention, monitoring,
upgrades, and incident response.

On Nagare's single node it would not provide high availability or defend against total host
compromise. Running OpenBao beside all of its clients and its only data replica creates a larger
operational burden without creating a new failure domain.

## Alternatives and their roles

| Option | Best use | Limitation |
|---|---|---|
| Provider-native workload identity | Default for cloud and internal service access | Not every provider supports it. |
| Kotei `SecretsProvider` plus ephemeral delivery | CI/CD steps and actions | Production Kubernetes implementation is incomplete. |
| GCP Secret Manager | Managed storage and audit for unavoidable static roots | Rotation schedules notify a rotator; they do not rotate an external credential by themselves. |
| OpenBao | Multiple dynamic engines, PKI, leased database users, or cloud-independent operation | Adds a security-critical stateful service and KV does not add lifecycle to external static keys. |
| Kubernetes Secrets | Compatibility for ordinary static application configuration | Weak refresh, revocation, and consumption-attribution semantics. |
| `sops-nix` and SOPS | Bootstrap, recovery, and low-change configuration | No runtime issuance, lease, or retrieval audit. |
| External Secrets-style synchronization | Copying values from a store into Kubernetes | Distribution mechanism, not credential lifecycle; usually leaves another Kubernetes Secret copy. |

No one product supplies identity, authorization, dynamic issuance, secure delivery, and downstream
usage audit for every provider. The architecture should combine these concerns deliberately rather
than treating a vault as the universal answer.

## Suggested delivery sequence

1. Inventory the exact capabilities Kikan agents require and classify each as Kotei CI/CD,
   internal service access, cloud access, or unavoidable direct third-party credential use.
2. Define authorization from Kikan identity to a specific Kotei project, pipeline/action,
   environment, and maximum run lifetime. Do not expose backing credential names to the agent.
3. Make Kotei's logical secret contract safe and equivalent across local and Kubernetes execution.
   Resolve the isolation and persistence issues already captured in Kotei plan 48.
4. Give Kotei Jobs distinct ServiceAccounts, projected audience-bound tokens, narrow RBAC and
   NetworkPolicy, memory-backed delivery, and deterministic cleanup through Nagare/Kubernetes.
5. Use provider-native workload identity first, beginning with GCP Workload Identity Federation
   where applicable.
6. Put unavoidable static bootstrap material in a managed secret store; retain `sops-nix` for host
   bootstrap and disaster recovery.
7. Add Kotei audit events that correlate Kikan actor, on-behalf-of identity, Kotei run/action/step,
   logical secret reference, provider role or version, issuance result, and expiry without storing
   plaintext.
8. Prove rotation, expiry, revocation, denial, log redaction, cache exclusion, and cleanup with one
   low-blast-radius credential.
9. Reassess OpenBao when a second or third real dynamic-engine use case appears, or when
   cloud-independent self-hosting becomes a requirement.
10. If that threshold is met, pilot OpenBao behind the Kotei contract so callers do not change when
    the backend changes.

## Acceptance criteria for the first pilot

The first pilot should validate the architecture, not OpenBao specifically:

- a Kikan agent can invoke one authorized Kotei pipeline/action without receiving its provider
  credential;
- the same agent is denied for another project or environment;
- Kotei resolves only the logical references declared by the selected step or action;
- the credential is absent from Kikan messages, Kotei durable events, Job manifests, logs, traces,
  cache keys, and artifacts;
- local and Kubernetes execution enforce equivalent declaration and redaction rules;
- Kubernetes material is ephemeral and cleanup is verified after success, failure, timeout, and
  cancellation;
- a newly rotated value or newly issued credential is used by the next run without restarting the
  Kotei control plane;
- expiry or explicit revocation prevents a new run from using the old credential;
- an unavailable credential backend fails the affected step closed rather than using an
  indefinitely stale value; and
- audit records correlate the Kikan actor and delegation with the Kotei run, step/action, logical
  credential, provider issuance, expiry, and result without recording plaintext.

If OpenBao is later piloted, add separate acceptance criteria for seal recovery, Raft snapshot
restore, durable off-node audit retention, upgrades, revocation behavior of each selected engine,
and failure on loss of the single OpenBao node.

## Authoritative references

- [OpenBao Kubernetes integrations](https://openbao.org/docs/platform/k8s/)
- [Kubernetes authentication method](https://openbao.org/docs/auth/kubernetes/)
- [OpenBao Agent](https://openbao.org/docs/agent-and-proxy/agent/)
- [OpenBao Agent templates and renewal behavior](https://openbao.org/docs/agent-and-proxy/agent/template/)
- [Lease, renew, and revoke](https://openbao.org/docs/concepts/lease/)
- [Audit devices](https://openbao.org/docs/audit/)
- [Database secrets engine](https://openbao.org/docs/secrets/databases/)
- [Integrated storage](https://openbao.org/docs/internals/integrated-storage/)
- [Raft snapshot and restore API](https://openbao.org/api-docs/system/storage/raft/)
- [GCP Cloud KMS seal](https://openbao.org/docs/configuration/seal/gcpckms/)
- [OpenBao first-party external plugins](https://github.com/openbao/openbao-plugins)
- [Kubernetes Secret-backed environment variable update behavior](https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/)
- [GCP Workload Identity Federation with Kubernetes](https://cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes)
- [GCP Secret Manager rotation recommendations](https://cloud.google.com/secret-manager/docs/rotation-recommendations)
- [GCP Secret Manager audit logging](https://cloud.google.com/secret-manager/docs/audit-logging)
- [OpenBao `v2.6.1` upstream release](https://github.com/openbao/openbao/releases/tag/v2.6.1)
- [OpenBao Helm `openbao-0.28.6` upstream release](https://github.com/openbao/openbao-helm/releases/tag/openbao-0.28.6)

## Decision summary

Do not proceed with first-class OpenBao support in Nagare yet. Make Kotei's logical credential and
execution boundary first-class, authorize Kikan agents to invoke scoped Kotei capabilities, and use
provider-native workload identity whenever possible. Keep Nagare responsible for secure execution
and ephemeral delivery. Use a managed store for unavoidable roots, retain SOPS for bootstrap and
recovery, and introduce OpenBao behind Kotei only when concrete dynamic-engine or independence
requirements justify its operational cost.
