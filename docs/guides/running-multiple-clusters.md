# Running multiple Nagare clusters

> **Supported topology:** one named Nagare context per cluster, one GCP project
> per cloud cluster, and a distinct base domain for every cluster. Local k3d is
> a separate `mode=local` context.

Nagare can operate several independent single-node clusters from the same
repository. A typical setup has a durable production cluster, a disposable
cloud lab for infrastructure and integration testing, and a local cluster for
fast development:

| Context | Purpose                                    | Project     | Base domain          | Pulumi state           |
| ------- | ------------------------------------------ | ----------- | -------------------- | ---------------------- |
| `prod`  | Durable applications and data              | `acme-prod` | `apps.example.com`   | Remote GCS recommended |
| `labs`  | Risky upgrades and cloud integration tests | `acme-labs` | `labs.example.com`   | Remote GCS or local    |
| `local` | Laptop development and offline smoke tests | none        | `127-0-0-1.sslip.io` | Local                  |

The context name is the operator-facing identity of a cluster. It selects the
GCP project, region, registry, buckets, domain, VM, build target, and Pulumi
stack. It also owns the platform release pin, immutable payload workspaces, and
upgrade transaction history. It does **not** select a Kubernetes API endpoint;
pair it with the right `KUBECONFIG` before any live cluster operation.

## Decide whether you need another cluster

Use another cluster when the workload needs a different:

- failure or deletion blast radius;
- GCP project, billing boundary, or operator IAM policy;
- base domain and public DNS zone;
- backup and disaster-recovery lifecycle;
- infrastructure change cadence; or
- trust boundary, such as experimental or externally supplied workloads that
  should not share the production node.

Keep workloads on one cluster when they can share those boundaries. Nagare
already separates applications through Kubernetes namespaces and named
resources; another app or namespace is cheaper than another VM and operational
perimeter.

Nagare clusters are independent single-node platforms, not members of one
federated control plane. There is no cross-cluster scheduler, service discovery,
replication, or failover. Promote an application by deploying the same source
configuration to another context; move state with the application-specific
backup and restore commands.

## Why cloud clusters use separate GCP projects

A context isolates local configuration and Pulumi state, but its name is not
automatically added to every physical GCP resource. The infrastructure still
has project-scoped identities and defaults such as:

- service account id `nagare-node`;
- Artifact Registry repository `nagare`;
- VM name `nagare-01`;
- `<project>-nagare-images` and `<project>-nagare-backups` buckets; and
- project service/API declarations.

Some names can be overridden in a context, but the node service-account id is
currently fixed. Two Nagare Pulumi stacks in one GCP project can therefore
collide or attempt to manage shared resources. **Multiple cloud clusters in one
project are not a supported topology.** Use a separate project for each cloud
cluster until the infrastructure namespaces every physical resource by
context.

Separate projects also make the fail-closed project guard useful: a command
whose ambient GCP project disagrees with its selected context is rejected before
it changes cloud resources.

## Plan the clusters

Choose all of these before provisioning:

| Decision               | Rule                                                                                         |
| ---------------------- | -------------------------------------------------------------------------------------------- |
| Context name           | Short purpose name such as `prod`, `labs`, or `local`.                                       |
| GCP project            | Unique project for each cloud context.                                                       |
| Base domain            | Unique, non-overlapping delegated zone for each cloud cluster.                               |
| Region and zone        | May match other clusters; they are isolated by project.                                      |
| Pulumi backend         | Prefer GCS for durable or multi-operator cloud clusters.                                     |
| Backups                | Keep each cluster's default project-specific bucket.                                         |
| Kubernetes credentials | Store a separate, uncommitted kubeconfig per cluster.                                        |
| Host credentials       | Decide whether operators, age recipients, and Tailscale enrollment are intentionally shared. |

`apps.example.com` and `labs.example.com` are a clean pair. Delegate each
subdomain to the Cloud DNS zone created by its own Pulumi stack. Do not point
two clusters at the same base domain.

Contexts contain target configuration, not credentials. GCP authentication,
the host age key, SSH keys, Tailscale enrollment, and Kubernetes credentials
still need their own lifecycle. The tracked NixOS host configuration is shared
by default, so separate operator or host-secret trust domains require explicit
NixOS configuration variants rather than another context alone.

## Create the contexts

Initialize each cloud project as its own named context. Supplying the context
name is important; omitting it creates the legacy in-repository profile instead.

```bash
nagarectl init prod \
  --project acme-prod \
  --region us-west1 \
  --zone us-west1-a \
  --base-domain apps.example.com \
  --pulumi-backend gcs

nagarectl init labs \
  --project acme-labs \
  --region us-west1 \
  --zone us-west1-a \
  --base-domain labs.example.com \
  --pulumi-backend gcs
```

Create the laptop context separately:

```bash
nagarectl context create local --mode local \
  --registry-host k3d-registry.localhost:5000 \
  --base-domain 127-0-0-1.sslip.io \
  --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups
```

Check the inventory before provisioning anything:

```bash
nagarectl context list
nagarectl context show prod
nagarectl context show labs
nagarectl context show local
```

The cloud initializers seed separate `prod` and `labs` Pulumi stacks and config
projections. With the default local backend, their state directories are also
separate. With `--pulumi-backend gcs`, each project gets its own versioned state
bucket and context path.

## Provision one cloud cluster at a time

Complete the full [bring-your-own-project onboarding](../user/onboarding-bring-your-own-project.md)
for one context before starting the next. The condensed loop is:

1. Select the context and reload the shell so scripts and Pulumi inherit it.
2. Verify the project, stack, buckets, domain, and VM name.
3. Preview and apply the cloud perimeter.
4. Delegate that context's base domain.
5. Build and register a host image for that project, then apply again to create
   the VM.
6. Connect the correct kubeconfig and bootstrap that cluster.
7. Verify backups, observability, and one smoke deployment.

For example, start with production:

```bash
nagarectl context use prod
direnv reload

nagarectl context show
pulumi -C infra/pulumi stack
just infra-preview
just infra-up

# Complete DNS delegation and host-secret prerequisites first, then generate
# prod's host flake with its own public key and encrypted sops file.
nagarectl host init --context prod \
  --ssh-public-key-file "$HOME/.ssh/id_ed25519.pub" \
  --sops-file /secure/path/prod-host-secrets.yaml
just host-image
just infra-preview
just infra-up
```

Then repeat with `labs`:

```bash
nagarectl context use labs
direnv reload

nagarectl context show
pulumi -C infra/pulumi stack
just infra-preview
```

Stop if the preview mentions resources from the other project or base domain.
The host image self-link is project-specific and must be built and registered
for each cloud context; never copy `nagare:nagareImageSelfLink` between stacks.

Context-driven rendering also writes checkout-local generated files, including
the NixOS registry host override. Do not build two cloud host images
concurrently from one checkout.

## Pair context selection with Kubernetes selection

This is the most important day-2 rule:

```text
Nagare context  -> cloud project, registry, buckets, domain, Pulumi stack
KUBECONFIG      -> Kubernetes cluster changed by kubectl and live nagarectl verbs
```

`nagarectl --context labs ...` does not switch `kubectl`. A deploy can therefore
build for one context while applying to the cluster named by an unrelated
kubeconfig if the operator pairs them incorrectly.

Keep a separate uncommitted kubeconfig for each cluster, for example:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/nagare/kubeconfigs/
  prod.yaml
  labs.yaml
  local.yaml
```

Use one shell per active cluster and select both identities before operating:

```bash
# Production shell
export NAGARE_CONTEXT=prod
export KUBECONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/nagare/kubeconfigs/prod.yaml"
direnv reload

nagarectl context show
just context-show
kubectl get nodes
```

```bash
# Labs shell
export NAGARE_CONTEXT=labs
export KUBECONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/nagare/kubeconfigs/labs.yaml"
direnv reload

nagarectl context show
just context-show
kubectl get nodes
```

The user-level `current-context` pointer is shared by all shells. For parallel
operator sessions, prefer a shell-local `NAGARE_CONTEXT` as above instead of
changing that pointer with `nagarectl context use`.

The default `just live-test` helper also uses shared local ports and
`.live-test/kubeconfig.yaml`. Run only one default live-test tunnel at a time.
For simultaneous cloud-cluster access, use separate worktrees with distinct
`LIVE_TEST_PORT` and `LIVE_TEST_SSH_PORT` values, or prepare stable per-cluster
kubeconfigs using the access procedure in the user manual.

## Run different platform releases safely

Contexts may intentionally remain on different Nagare platform releases. The
payload workspace, generated host flake, Pulumi projection, and transaction
history are stored below that context's XDG state/config roots; upgrading
`labs` does not advance `prod`.

Inspect each context with its own kubeconfig before planning:

```bash
NAGARE_CONTEXT=labs \
KUBECONFIG="$HOME/.config/nagare/kubeconfigs/labs.yaml" \
nagarectl platform status --json

NAGARE_CONTEXT=prod \
KUBECONFIG="$HOME/.config/nagare/kubeconfigs/prod.yaml" \
nagarectl platform status --json
```

Rehearse a release on `labs`, keep its transaction identifier, and apply that
same reviewed plan. Do not reuse the identifier for another context; the CLI
rejects cross-context transaction histories.

```bash
export NAGARE_CONTEXT=labs
export KUBECONFIG="$HOME/.config/nagare/kubeconfigs/labs.yaml"
nagarectl platform upgrade --to 0.2.0 --dry-run --json > labs-upgrade.json
labs_transaction="$(jq -r '.transactionId' labs-upgrade.json)"
nagarectl platform upgrade --apply --resume "$labs_transaction" --yes
nagarectl platform status
```

Leave `prod` selected at its old release until the labs verification is
complete. A shell-local `NAGARE_CONTEXT` and `KUBECONFIG` pair is safer than
changing the shared current-context pointer during parallel work. See
[Upgrades](../user/upgrades.md) for adoption, recovery, and rollback limits.

## Deploy the same application to two clusters

The typed application config stays the same; the selected context supplies the
registry prefix and base domain. Always bind the matching kubeconfig in the same
command environment:

```bash
NAGARE_CONTEXT=labs \
KUBECONFIG="$HOME/.config/nagare/kubeconfigs/labs.yaml" \
nagarectl deploy -f nagare/Config.hs
```

After validating the labs release, deploy the same source to production:

```bash
NAGARE_CONTEXT=prod \
KUBECONFIG="$HOME/.config/nagare/kubeconfigs/prod.yaml" \
nagarectl deploy -f nagare/Config.hs
```

These are two independent deployments. Environment values, Kubernetes Secrets,
databases, PVCs, release history, and backups are not copied automatically.
Recreate configuration explicitly and use the documented backup/restore paths
when data must move between clusters.

## Day-2 operating pattern

Before every mutating session:

1. Set `NAGARE_CONTEXT` and `KUBECONFIG` together.
2. Reload the dev shell after changing the Nagare context.
3. Run `nagarectl context show` and `just context-show`.
4. For infrastructure changes, run `just infra-preview` and confirm the GCP
   project, stack, base domain, and replacement plan.
5. For Kubernetes changes, confirm the intended cluster is reachable before
   invoking `nagarectl`, `kubectl`, or a `just` bootstrap recipe.

Operate backups and recovery independently. A healthy multi-cluster setup has:

- a recoverable Pulumi backend for every cloud context;
- a distinct versioned backup bucket for every cloud cluster;
- the age private key and repository available off each VM;
- a tested application/database restore path per cluster; and
- no assumption that the labs cluster is a failover replica of production.

## Removing a cluster

Deleting a context does not delete its cloud resources:

```bash
nagarectl context delete labs --yes
```

That command only removes the local context file. To retire a cloud cluster,
first select its context and follow the disaster-recovery runbook's deliberate
teardown procedure. Export or verify backups before destroying infrastructure,
and account for protected disks and buckets. Delete the context only after the
cloud resources and retained state have the intended final disposition.

## Related documentation

- [Target contexts](../user/contexts.md) — context schema, selection precedence,
  Pulumi state, and migration from profile files.
- [Bring-your-own-project onboarding](../user/onboarding-bring-your-own-project.md)
  — the complete zero-to-running sequence for each cloud cluster.
- [Provisioning with Pulumi](../user/provisioning-with-pulumi.md) — resources,
  protection settings, previews, and replacements.
- [Accessing the host](../user/accessing-the-host.md) — IAP/Tailscale access and
  kubeconfig preparation.
- [Local development](../user/local-development.md) — the local k3d cluster.
- [Backups and disaster recovery](../user/backups-and-disaster-recovery.md) —
  state ownership, restore paths, and recovery prerequisites.
- [Disaster-recovery runbook](../runbooks/disaster-recovery.md) — destructive
  recovery and teardown procedures.
