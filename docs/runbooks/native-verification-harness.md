# Native verification harness (maintainers)

This runbook is for maintainers proving a release candidate natively, as in MasterPlan 23 Phase C. It
records the harness facts that earlier sessions had to rediscover: candidate builds, isolated operator
roots, the shared local cluster and its claim protocol, the candidate gate, object-store drills, and
fresh cloud context inputs. Operators running a real context use
[Operate and recover a reviewed inventory](inventory-operations.md) instead.

The project rules in `CLAUDE.md` apply throughout. Use only the active context's project, stop when a
guard refuses, and batch cloud mutations into one rehearsed, operator-approved sequence.

## 1. Build the candidate at an exact revision

The CLI embeds its git revision, and release evidence binds that revision. Build from a worktree
pinned to the candidate, never from a tree that has moved on:

```bash
git worktree add /private/tmp/nagare-c3-src <full-revision>
(cd /private/tmp/nagare-c3-src && nix build .#nagarectl --out-link "$PWD/../result-<rev>")   # CLI only
(cd /private/tmp/nagare-c3-src && nix build .#nagare    --out-link "$PWD/../result-<rev>-nagare")  # CLI + platform payload
result-<rev>/bin/nagarectl version --json   # "revision" must be the candidate
```

`.#nagarectl` is enough for a gate on an existing context, which keeps its accepted payload. A fresh
context needs `.#nagare`, the package with the platform payload. The candidate is frozen once announced;
any later code change is a new candidate and must re-pass C1. Docs, plans and harness-only scripts may
still change.

## 2. Isolated operator roots and wrappers

Never run live work from your own `~/.config/nagare` or a direnv shell; stale exported values leak in.
Each native target has an operator root holding `config/`, `state/` and `cache/`, plus a wrapper that
pins everything with `env -i`:

```bash
#!/usr/bin/env bash
set -euo pipefail
root=/tmp/nagare-mp23-cp3.1EQ78L
exec env -i PATH="$PATH" HOME="$HOME" \
  DOCKER_HOST=unix://$HOME/.colima/nagare-mp23-cp3/docker.sock \
  XDG_CONFIG_HOME="$root/config" XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache" \
  NAGARE_PLATFORM_ROOT="$root/state/nagare/local/platform/<accepted-payload-workspace>" \
  SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" \
  NAGARE_CLUSTER_SECRETS_DIR="$root/recovered-cluster-secrets-20261002" \
  KUBECONFIG="$root/config/nagare/kubeconfigs/local.yaml" \
  /path/to/result-<rev>/bin/nagarectl --context local "$@"
```

Earlier wrappers sit beside each root as `runctl-<rev>*.sh`. Copy the newest and change only the
binary. Before any direct `kubectl`, assert the kube server and node:

```bash
KUBECONFIG=$root/config/nagare/kubeconfigs/local.yaml kubectl get nodes -o name   # node/k3d-nagare-local-server-0
```

## 3. The shared local cluster (cp3) and its claim protocol

All local MP-23 checks use one Colima profile, `nagare-mp23-cp3` (6 CPU, 12 GiB). Never start another
profile. Its k3d cluster `nagare-local` uses fixed host ports and the fixed registry
`k3d-registry.localhost:5000`, so a second k3d cluster cannot coexist; a fresh local context requires
deliberately retiring the current one after exporting its history (`inventory export`) and copying its
images out by digest (`skopeo`, never `docker push`).

The retained root before C2 was `/private/tmp/nagare-mp23-cp3.1EQ78L`, context `local`. If it moves, find
it by searching `/private/tmp` for `state/nagare/local/inventory/head.json`. The default
`~/.config/nagare/contexts/local.env` is a different, empty context.

Several sessions may share cp3. Before any cp3 mutation (inventory apply, resume or recover, `kubectl`
or object-store writes, cluster or context create/delete), take the claim atomically:

```bash
C=<root>/.cp3-claim
mkdir "$C" && echo <session-name> > "$C/owner" && date -u +%FT%TZ > "$C/since" && echo "<purpose>" > "$C/purpose"
# ... bounded mutation sequence ...
# release only when the store has no active transaction:
python3 -c "import json;assert json.load(open('<root>/state/nagare/local/inventory/head.json')).get('activeTransaction') is None"
rm "$C"/owner "$C"/since "$C"/purpose && rmdir "$C"
```

If the claim exists, wait. Never break a claim whose owner is gone; report it to the operator instead.
Read-only commands need no claim: `server status`, `db backup-receipts`, `inventory status`, `kubectl
get`, and `--save-plan` planning.

Plan and apply back to back. An object that appears at a reviewed create address after admission stops
the transaction ([F35](../audits/mp23-findings.md#f35)); end it with `abandon-refused-operation` rather
than deleting someone else's object.

## 4. Candidate gate (C1)

```bash
scripts/run-local-candidate-gate.py --operator-root <root> --wrapper <root>/runctl-<rev>.sh \
  --revision <rev> --payload nagare-0.4.0-<accepted-payload>
```

Take the claim first. The gate passes only when the public platform bootstrap review is
`VerifyResource`-only, accepted digests and the idle head are unchanged, and it writes
`<root>/candidate-<rev>-c1/proof.json`. Copy that proof into the dated results directory. This is a CLI
gate on the retained accepted payload, not a fresh-payload bootstrap.

Two things make the gate fail for reasons unrelated to the candidate:

- **An unpinned payload workspace.** Without `NAGARE_PLATFORM_ROOT`, a new candidate CLI installs its own
  payload workspace beside the accepted one (`state/nagare/<ctx>/platform/nagare-<version>-<rev>-…`).
  Planning then refuses with `accepted local substrate differs from the selected specification`, because
  the accepted substrate scope binds the absolute path of the accepted workspace's
  `cluster/bootstrap/local-substrate.json`. Pin `NAGARE_PLATFORM_ROOT` to the accepted workspace in the
  wrapper. Platform upgrades are out of scope for MP-23.
- **A stale bootstrap stamp.** The `nagare-platform-version` ConfigMap records a digest over every platform
  scope's generation and content. An `operator-cli` review that re-accepts a platform scope (even with zero
  operations) advances its generation. Every later bootstrap plan then proposes one `UpdateResource` on the
  stamp, and the gate's verification-only assertion fails. Confirm the proposal is state-induced by planning
  with the previous accepted CLI on the same state (planning is read-only), apply that one-operation review
  under the claim, and re-run the gate into a new `--evidence-dir`. This is what C1 for `44ff0fd7` did.

## 5. Object-store drills (local MinIO)

Use a throwaway pod with the platform's pinned MinIO client image. Credentials come in through `envFrom`,
so they never appear in argv:

```yaml
apiVersion: v1
kind: Pod
metadata: {name: drill-mc, namespace: nagare-system, labels: {nagare.dev/drill: <session>}}
spec:
  restartPolicy: Never
  containers:
  - name: mc
    image: k3d-registry.localhost:5000/nagare-mc@sha256:<pinned digest from the wrapper's NAGARE_LOCAL_MC_IMAGE>
    command: ["sh", "-c", "sleep 3600"]
    envFrom: [{secretRef: {name: nagare-minio-credentials}}]
```

```bash
kubectl -n nagare-system exec drill-mc -- sh -c 'mc alias set d http://minio:9000 "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" >/dev/null && mc ls --versions d/nagare-backups/<key>'
# add a version: mc cp FILE d/nagare-backups/<key>; remove exactly it: mc rm --version-id <vid> d/nagare-backups/<key>
```

Revert every drill change by exact version ID and delete the pod. A tampered accepted backup must be
refused at planning. Pinned reviews saved earlier keep downloading the pinned versions, which is correct.

## 6. Fresh cloud context (C3)

The disposable target is a checked-in fixture (for example
[`fixtures/inventory-release/gcp/c3-target.json`](../../fixtures/inventory-release/gcp/c3-target.json)).
Its project is reached through a named gcloud configuration (`labs` for `tan-ng-labs`), never the
ambient one. `scripts/rehearse-gcp-inventory-release.sh` refuses unless the selected context's profile
matches the fixture exactly. That covers project, region, zone, domain, instance, service account,
registry id and buckets, plus `NAGARE_PULUMI_BACKEND_URL=gs://<stateBucket>/pulumi` and
`NAGARE_INVENTORY_STORE_URL=gs://<stateBucket>/inventory`. Create the context with `nagarectl context
create` and the matching flags, inside the isolated root.

A fresh host also needs these inputs, as the retained F15 root shows:

- A host age identity (`age-keygen`, mode 0600) kept in the operator root. Only its public `age1…`
  recipient goes into the sops creation rule.
- A sops-encrypted host secrets file with a non-empty `tailscale/authkey`. Host age-key placement
  requires that path to be non-empty. Mint a one-time, ephemeral, pre-approved Tailscale auth key with a
  1-day expiry in the Tailscale admin console; the CLI cannot mint keys. Write it to a mode-0600 file
  without echoing it, and encrypt it with sops from stdin.
- `nagarectl host init --context <ctx> --ssh-public-key-file <key.pub> --sops-file <secrets.yaml>`
  installs the context-owned host flake under `config/nagare/hosts/<ctx>`.
- Wrapper variables:
  - `CLOUDSDK_ACTIVE_CONFIG_NAME=labs`, `CLOUDSDK_CORE_PROJECT`, `CLOUDSDK_CORE_DISABLE_PROMPTS=true`
  - `SSH_KEY=$HOME/.ssh/google_compute_engine`
  - `NAGARE_HOST_AGE_KEY_FILE` and `SOPS_AGE_KEY_FILE` pointing at the host age key
  - `NAGARE_PLATFORM_ROOT` set to the context's installed payload workspace
  - `NAGARE_BUILDER_PROJECT/ZONE/INSTANCE` set to the reused builder
  - `NAGARE_AUTH_{SHOMEI,EN,ACCESS}_IMAGE` set to immutable `…@sha256:` references, which already
    exist in `us-west1-docker.pkg.dev/tan-ng-labs/nagare/`
- A builder SSH key the operator can read. The workstation's `/etc/nix/builder_ed25519` is root-only,
  so generate a key in the operator root (`ssh-keygen -t ed25519 -N '' -f <root>/builder_ed25519`) and
  append its public half to `/home/builder/.ssh/authorized_keys` on the builder. `gcloud compute ssh`
  to the builder fails in its ProxyCommand, so open the tunnel yourself
  (`gcloud compute start-iap-tunnel <builder> 22 --local-host-port=localhost:28222 --zone <zone>`) and
  `ssh -p 28222 <you>@localhost`. Then set `NIX_BUILDER_SSH_KEY=<root>/builder_ed25519` and
  `NIX_BUILDER_HOST_KEY_B64` (the builder's pinned host key, base64 on **one** line; a wrapped value
  breaks the context env file) in the context env.
- A sops-encrypted `grafana-admin.yaml` Secret (`monitoring/grafana-admin`, `stringData` keys
  `admin-user` and `admin-password`) at `<root>/config/nagare/cluster-secrets/<ctx>/`. The cluster
  stage refuses without it (`required encrypted observability Secret is missing`). Generate the
  password in a shell variable, pipe the manifest into
  `sops --config <root>/sops-encrypt.yaml --encrypt --encrypted-regex '^(data|stringData)$' --input-type yaml --output-type yaml /dev/stdin`,
  and check it decrypts with `SOPS_AGE_KEY_FILE=<root>/age-key.txt`. Add `alertmanager-config.yaml`
  too when the context enables Alertmanager.
- Stages: each `platform bootstrap plan --out <new evidence dir>/review`, then
  `platform bootstrap apply <dir>/review --yes`, advances exactly one stage. A fresh `tan-ng-labs`
  context on candidate `db808a74` took these, in order (plan / apply seconds):

  | Stage | Review | Plan | Apply |
  | --- | --- | --- | --- |
  | foundation (state bucket, registry) | 2 creates | 22 | 46 |
  | perimeter | 1 create | 61 | 76 |
  | host image build (remote builder) | 1 create | 107 | 563 |
  | GCE image | 1 create | 132 | 202 |
  | stack config | 1 update | 31 | 30 |
  | VM | 1 create | 41 | 47 |
  | host activation | 1 create, 1 declared op | 152 | 1838, exit 1, then `inventory resume` converged |
  | kubeconfig | 1 create | 40 | 15 |
  | cluster (charts, auth, net-certmanager image) | 207 creates, 3 declared ops | 326 | see below |

  Filter each review before applying: no operation may name a standing project resource. Strip hex
  runs from summaries before matching names, since digests contain short strings like `f15`.
  After the first boot, run `nagarectl host place-age-key`. Release scenario evidence then uses the
  runner with `--candidate`.
- Host activation and Tailscale SSH. The host transport proves a fresh login over the tailnet
  (ADR 11). If the tailnet's SSH policy uses `check` mode, the first connection waits for a browser
  re-authentication, so the activation step can time out and report an ambiguous outcome. Do not
  re-run activation. Read `inventory status --json`, then `inventory resume`, which re-observes the
  host and converges when activation in fact succeeded (as it did here). Use an `accept` rule for the
  tag the ephemeral auth key grants. Keys and SSH checks can only be managed in the admin console or
  through the Tailscale API with an API token; the `tailscale` CLI cannot do either.

Before any cloud stage, check credentials and standing inputs read-only:

```bash
CLOUDSDK_ACTIVE_CONFIG_NAME=labs gcloud auth print-access-token >/dev/null && gcloud auth application-default print-access-token >/dev/null
CLOUDSDK_ACTIVE_CONFIG_NAME=labs gcloud compute instances describe nix-builder-ep150 --zone us-west1-a --format='value(status)'
```

If Google asks for re-authentication mid-run, stop at a safe boundary and ask the operator.

## 7. Shared working tree hygiene

Several sessions may commit in the same checkout and stage their own files. Always stage and commit by
explicit pathspec: `git add -- <paths> && git commit -F - -- <paths>`. A bare `git commit` would sweep a
peer's staged files into your commit. In zsh, split a path list with `${=VAR}`. Never use `git stash`,
`git checkout <rev> --` or other tree-wide commands in a shared checkout.

Before committing Haskell, run `just haskell-style-check` **and** `python3
scripts/check-haskell-architecture.py`. The latter enforces per-module line caps, which only ratchet
down, and the style check does not run it. Fix an overage by separating modules, not by raising the
allowance.
