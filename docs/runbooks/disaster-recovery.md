# Nagare disaster-recovery runbook

Rebuild the entire Nagare platform from this Git repository plus the backup
bucket. The goal is **boring and reproducible**: every step is a command plus the
observation that confirms it worked. Run everything from the repo root
`/Users/shinzui/Keikaku/bokuno/nagare` inside the dev shell (`nix develop` or
`direnv allow`), which provides `pulumi`, `kubectl`, `helm`, `gcloud`/`gsutil`,
`sops`, `age`, `jq`, and `just`. All cloud work targets the active context; the
historic default context is project **`tan-nb-exp`**, region **`us-west1`**, zone
**`us-west1-a`**.

> For routine (non-rebuild) health checks and day-2 operations, use `nagarectl
> server status` / `nagarectl doctor` — see
> [`server-operations.md`](server-operations.md). This runbook is the full
> rebuild-from-scratch sequence; `doctor` automates many of its per-step
> "Observe:" assertions, noted inline below.

> **`nagarectl` is a disaster-recovery prerequisite.** The restore steps below
> call `nagarectl` verbs (`db restore`, `storage restore`) directly; the former
> hand-rolled `scripts/restore-*` / `scripts/backup-postgres` helper scripts have
> been removed (MasterPlan 13, EP-1) so that all control-plane logic lives in the
> typed CLI. Build it once with `cabal build exe:nagarectl` in `cli/nagarectl/`
> (inside `nix develop`), or have it on `PATH`, before starting a restore.

## The keys that are NOT in Git or the bucket

Three separate age identities serve different purposes. The **host identity** lives
at the context's configured `ageKeyFile` (normally `/var/lib/sops-nix/age-key.txt`)
and lets sops-nix render that host's secrets. The **workstation identity**, normally
`~/.config/sops/age/keys.txt`, lets the operator edit encrypted files. The **offline
recovery identity** belongs in the operator's password manager, separately from both
machines; remove temporary local copies after verification. All private identities
stay out of Git, Pulumi state, platform payloads, and VM images. Public recipients
and the vault-item reference belong in the private operator repository.

Recovery coverage is explicit per context and ciphertext. A shared recovery identity
can cover several clusters only after their private policies and every encrypted
document have been updated and independently verified. A policy entry alone is not
proof, and an existing host-key backup is not an independent recovery identity.
Consult the selected context's private recovery inventory rather than assuming all
clusters use the same recipients.

Resolve the actual host file with `nagarectl host path --context <context>` and the
cluster-secret directory with `NAGARE_CLUSTER_SECRETS_DIR` or
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/`. Reconcile their
versioned private backups; regular XDG files do not follow later Git edits as symlinks
do. The public `example.yaml` has a deliberately discarded private key and is not a
recovery source.

Retrieve the recovery identity from the vault into a private temporary file on the
recovery machine. With only that identity available, prove decryption of every
inventoried operational file, including every document in multi-document YAML, while
discarding plaintext output. Repeat with only the workstation identity and check
that an invocation with no identities fails. Preserve the host recipient when
re-keying. Restore the appropriate host identity through
`nagarectl host place-age-key` before activating a replacement host; the offline
recovery private key must not become the running VM's identity. Then use the guarded
`nagare host-switch` path and verify sops-nix renders the expected `/run/secrets`
entries. Keep old ciphertext until these checks succeed. If no inventoried identity
can decrypt an operational file, stop recovery and locate its matching vault backup.

## Backup inventory — what is backed up, where, and how it is restored

```text
NixOS config .............. Git (nixos/)                              -> git clone
Pulumi infra (TypeScript) . Git (infra/pulumi/src/)                  -> git clone
Pulumi state .............. GCS backend named in the context (gs://<project>-nagare-pulumi-state/nagare/<context>,
                            versioned) or the local file backend
                            ${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/state -> restore active context state
Context, host flake,
cluster secrets ........... operator's private repository, linked into ${XDG_CONFIG_HOME:-$HOME/.config}/nagare/ -> git clone + symlink
Kubernetes manifests ...... Git (cluster/)                           -> git clone
Secrets ................... sops-encrypted in the operator's private repo
                            (cluster-secrets/<context>/,
                            hosts/<context>/secrets.yaml)             -> sops -d | kubectl apply
SQLite app data ........... Litestream replica in
                            gcs://<backupBucket>/litestream/          -> litestream restore (scratch)
App volume data ........... tar.gz snapshots in
                            gcs://<backupBucket>/volumes/<app>/<volume>/ -> reviewed restore pending after inventory admission
Managed database data ..... pg_dump/.rdb/.native logical dumps in
                            gcs://<backupBucket>/manual-databases/<ns>/<name>/ -> reviewed PostgreSQL scratch restore from accepted receipt
Grafana dashboards ........ Git (cluster/observability/grafana/
                            dashboards/)                              -> provisioned by EP-5 sidecar
Victoria metrics/logs/traces  NOT backed up (non-critical;
                            re-derived from live workloads)           -> nothing to restore
age PRIVATE key ........... NOT in Git, NOT in the bucket; offline    -> restore from your vault
```

Resolve the active context's backup bucket with:

```bash
pulumi -C infra/pulumi stack output backupBucket
```

`nagarectl server status` and `nagarectl doctor` grade each accepted managed
database's recovery point from verified receipts and exit nonzero on a breach
(`db backup-receipts NAME --check-freshness` for one database).

## Total cluster loss

The procedure for recovering the data after total cluster loss, and for drilling
it, is [Total cluster loss: recover the data](../user/backups-and-disaster-recovery.md#total-cluster-loss-recover-the-data)
in the backups guide. It reads only the backup bucket and the private operator
material (escrowed signing keys, the age key, the context), restores each
database's newest verified backup into a disposable engine, compares the content
and records the recovery time.

This release has no reviewed rebuild of the same context with the databases
restored into service: planning refuses to recreate an accepted durable member,
and a backup restores only into the incarnation it was taken from (ADR 27). That
is the next MasterPlan's scope. Recreating the host itself follows
[Rebuilding the host](../user/backups-and-disaster-recovery.md#rebuilding-the-host).

## Power management (stop / start / full teardown)

Nagare is designed to be disposable, so there are three "off" levels:

**Stop the VM (cheapest reversible — halts compute only).**

```bash
just vm-stop --operation-id stop-20261002 --save-plan ./stop-review
nagarectl inventory apply ./stop-review --yes
just vm-start --operation-id start-20261002 --save-plan ./start-review
nagarectl inventory apply ./start-review --yes
```

Stopping halts compute charges; the boot + data disks and the reserved static IP
still incur small storage/reservation costs. `start` boots the *existing* boot
disk and current NixOS generation, not the latest registered image. Generations
that include `nixos/hosts/nagare-01/networking.nix` already declare the public
resolvers, metadata `/32` route, and pod MASQUERADE, so no runtime re-application
is needed. Verify after startup:

```bash
scripts/iap-ssh.sh ssh nagare-01 -- \
  'ip route get 169.254.169.254; cat /etc/resolv.conf'
nagarectl doctor
```

The route must use `dev eth0`, the resolver list must include `8.8.8.8`, and
`nagarectl doctor` should return the platform to green.

If you intentionally boot a pre-fix generation, use these temporary recovery
commands only long enough to rebuild or switch to the declarative generation:

```bash
GW=$(ip route show default | awk 'NR == 1 { print $3 }')
sudo ip route replace 169.254.169.254/32 via "$GW" dev eth0
sudo iptables -t nat -C POSTROUTING -d 169.254.169.254/32 -j MASQUERADE || \
  sudo iptables -t nat -A POSTROUTING -d 169.254.169.254/32 -j MASQUERADE
kubectl -n kube-system rollout restart deploy/coredns
```

**Replace the VM onto the fixed image (clean boot, recommended).** The image is
the one recorded in the active context's Pulumi config key
`nagareImageSelfLink`:

```bash
pulumi -C infra/pulumi config get nagareImageSelfLink
```

A `pulumi up` that recreates the instance boots that image, then the platform is
re-bootstrapped with steps 4–8 above. The ordinary reviewed-plan path refuses an instance
replacement, so follow the three-bundle
[deliberate VM rebuild procedure](../user/provisioning-with-pulumi.md#review-replacements-and-protected-resources).

**Full teardown (stop all charges).**

```bash
nagare infra-destroy --yes
```

This reruns the platform, ADC, and selected-project guards immediately before Pulumi. Protected
resources and GCE deletion protection refuse until you deliberately remove those protections; the
command never infers teardown from a failed apply. Rebuild from scratch with this runbook from step
1. The age private key, Git, and any deliberately retained backup objects are what make that rebuild
possible.

## Notes on idempotence

Every step is safe to re-run: `pulumi up` reconciles; `just cluster-bootstrap`
and `just observability` use declarative apply / `helm upgrade --install`;
`sops -d | kubectl apply` is idempotent; restores write to scratch first and
never clobber a live database.
