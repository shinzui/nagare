# Native verification harness (maintainers)

This runbook is for maintainers proving a release candidate natively, as in MasterPlan 23 Phase C. It
records the harness facts that earlier sessions had to rediscover: candidate builds, isolated operator
roots, the shared local cluster and its claim protocol, the candidate gate, object-store drills, the
fresh local acceptance run (C2), and fresh cloud context inputs. Operators running a real context use
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
binary. Never forward the caller's `NAGARE_PLATFORM_ROOT` into a wrapper. The repository's `.envrc` exports
it as the source checkout, and the packaged CLI only sets its own payload when the variable is unset, so a
forwarded value silently selects a source-development workspace instead of the payload. Either pin the
accepted payload workspace explicitly (gates on an existing context) or leave it unset (a fresh context
on a new candidate). A C1 gate pins it; a fresh C2 or C3 context must carry the candidate's own payload,
because an admitted context cannot change platform version (ADR 6). Before any direct `kubectl`, assert the kube server and node:

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

## 6. Fresh local acceptance (C2), step by step

C2 proves a candidate on a **fresh** local context bootstrapped from the candidate's own payload. It
yields two things that C5 combines:
- `evidence/c2-<rev>/local-health.json`, finalized with all 16 required scenario assertions;
- `evidence/c2-<rev>/inventory-evidence.json`, from `scripts/assemble-managed-resource-evidence.sh`.

Both live in the **same** evidence directory, which the runner creates. The procedure is this
section: the rules, inputs and step table below.

The shell drivers that ran the passing `7d486457` acceptance are archived as a frozen record in
[`c2-drivers/`](../audits/mp23-implementer-results-2026-10-03/c2-drivers/README.md). They are
evidence of what ran, not tooling. The tested replacement is
[EP-168](../plans/168-script-the-local-acceptance-run-as-one-command.md), in Haskell per
[ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md).
Until it lands, follow the step table, and use the archived drivers only as a reference for exact
commands.

### Hard rules

Rules 1–3 have each cost a full rerun, and rule 6 cost a resume.

1. **The runner runs last, and its phases run back to back.**
   - Run the scenario, every check, the source-unavailable drill and preview cleanup first.
   - Then run `rehearse-local-inventory-release.sh --phase plan`, `--phase apply` and `--phase verify`, in that order, with no store mutation between them.
   - The assembler requires `final-observation.accepted == review.desiredRevisions`. Any scope accepted between the runner's plan and its verify makes the run unassemblable ("final observation is incomplete or diverged"). This is what happened to the first `7d486457` run.
   - The final-marker interruption (kill the verify before its marker, then re-run it) happens on that same verify. It is read-only.
2. **Checks write evidence into a staging directory; their records are deferred.**
   - The runner's plan refuses an evidence directory that already exists, and `scenario-assertions.py record` needs the plan-time `local-health.json` that the plan writes.
   - So the scenario drivers write to `evidence/c2-<rev>-staging/checks/` and queue each `record` call (`defer-record.sh`).
   - After the runner's apply, `phase3-final-b.sh` copies `checks/` into the runner's directory and replays the queue.
   - Three records depend on the runner's verify output and are recorded directly after it: `interrupted-recovery`, `convergence-noop-removal` and `secret-read-refusal`.
3. **The runner probe can be used once per context.**
   - The runner's initial review needs at least one real operation. Generic `inventory plan` cannot plan app or Helm scopes, so the candidate adds one packaged scope: `scripts/unchanged-inventory-candidate.py … --add-packaged-scope runner-probe=cluster/examples/hello-knative-service/service.yaml --payload-root <workspace>`. This is one `CreateResource` of `personal/hello`.
   - The helper declares the member with lifecycle `Retain`. Once accepted it can be retired but never collected (`invalid-collection`), and it cannot be re-added (`retained-reactivation`).
   - If the runner has to be redone, the context has to be rebuilt.
4. **Every provider must be observable in all three runner phases.**
   - Port-forward `svc/en` and export `NAGARE_EN_URL` and `NAGARE_EN_API_KEY` (the read-write key from `nagare-system/nagare-en-api-keys`, in the environment only).
   - Run the runner through a wrapper that forwards them (`nagarectl-bare-access.sh`).
   - Without en, `inventory status` reports `missingProviders: ["AccessExecutor"]` and the assembler refuses.
5. **The CLI must run against its own payload.**
   - F41 compiles the MinIO manifest digest into the CLI, so a candidate CLI on an older workspace refuses with `pinned MinIO manifest digest changed`.
   - Bootstrap a fresh context instead of reusing the previous candidate's.
6. **Let the cluster settle after any node restart before a reviewed collection.**
   - A collection review binds the namespaced API discovery it saw.
   - Right after the source-unavailable drill restarts the node, metrics-server's APIService is not yet back. A collection planned then gets refused at apply ("collection graph, protected objects, or API discovery changed since review"; 74 → 75 types) with no effect, and must be closed with `abandon-refused-operation`.
   - Wait until every APIService is Available and `kubectl api-resources --namespaced=true` is identical across two reads 15 s apart.
7. **Confirm the context runs the candidate's payload before the runner's plan.** Save `nagarectl --context <ctx> platform root --json` in the run root and check that its `revision` equals the candidate's. The assembler does not check this yet ([F48](../audits/mp23-findings.md#f48)), so a mixed run would assemble under the wrong payload.
8. **Before the live run, rehearse the evidence pipeline.** Run the assembler and the record replay against the planned layout, using a scratch copy and real prior data. Cluster steps that pass prove nothing about whether the evidence will assemble.

### Inputs

- The candidate package, CLI plus payload (`result-<rev>-nagare`), built from a pinned clean worktree.
- The release manifest from `scripts/check-release.sh --version <v> --output-dir …` in that worktree.
- A coverage result from `scripts/audit-managed-commands.py`, run in that worktree. It must report `complete: true` and `dirty: false`.
- The cp3 claim and the operator's teardown approval. A peer session's agreement is not approval.
- Five pinned images in `images.env`: en, shomei, nagare-access, the MinIO server and the MinIO client. Copy them into the k3d registry by digest with `skopeo --preserve-digests` from `<cp3 root>/exports/registry-pre-c2`.
  Every `platform bootstrap` plan, including the one inside the C1 gate, needs them in its environment: the wrapper forwards `NAGARE_AUTH_*` and `NAGARE_LOCAL_*` only when they are set. Source `images.env` in the same process. Without it the plan refuses with `bootstrap requires NAGARE_AUTH_EN_IMAGE as an immutable image reference`, which is harmless but stops the run.

### Steps

| # | Archived driver (reference) | What it does | Records |
| --- | --- | --- | --- |
| 0 | (manual) | Export the old store privately, delete the k3d cluster and registry, create a fresh `mktemp -d` root with wrappers pinned to the candidate, `context create local --mode local …` | — |
| 1 | `phase1.sh` | Bootstrap stages 1–2; seed the five images by digest; stage-3 platform review (≈218 ops). It goes ambiguous once at the same op every time, and one `inventory resume <tx>` converges it. | — |
| 2 | `run-local-candidate-gate.py` | C1 on the fresh payload: `VerifyResource` only, zero mutations, digests unchanged | C1 `proof.json` |
| 3 | `phase2.sh` | Databases, broker, images, secret; deploy A and B, each killed mid-apply and resumed; site, env, preview; seed known rows and files | (staged) |
| 4 | `phase2b.sh` | drift + `--take-over-fields` repair; collision refusal; rename killed at its copy Job and resumed; retained-data collection plus an isolated history restore | drift-classification, collision-refusal, retained-postgresql-rename, retained-data (deferred) |
| 5 | `phase3-restores.sh` | backup/restore for PostgreSQL, Redis, ClickHouse and a volume, including wrong-incarnation refusals | 4 × *-backup-restore (deferred) |
| 6 | `phase3-misc.sh` | adoption refusal, independent-scope preservation, access grant/revoke, F36 drill, freshness | adoption, independent-scope-preservation, access-grant-revoke, backup-freshness (deferred) |
| 7 | `phase3-su.sh` | F41: escrow the key, live-copy the MinIO volume, `docker stop` the node, verify offline (`--offline-object-store`), restore the exact archive into a disposable PostgreSQL, restart | source-unavailable-recovery (deferred) |
| 8 | `phase3-final-a.sh` | Wait for the cluster to settle (rule 6), then preview cleanup, repeated until no review remains (the last mutation) | (staged) |
| 9 | `phase3-final-b.sh` | Runner plan → apply (probe, en forwarded); copy checks and replay deferred records; verify killed before its marker, then re-run; interrupted-recovery evidence; secret scan; `finalize` | interrupted-recovery, convergence-noop-removal, secret-read-refusal; 16/16 |
| 10 | `chain.sh` (end) | `assemble-managed-resource-evidence.sh --release-manifest … --system aarch64-darwin --rehearsal-dir evidence/c2-<rev> --private-store-export evidence-private/final-export --coverage-result …` | `inventory-evidence.json` |

Stop at the first failure. When any guard
refuses, stop and report. Do not patch evidence, relax a check, or use a raw provider write.
Expected, designed refusals:
- the strict drift replan, closed with `abandon-refused-operation`;
- the PostgreSQL and Redis wrong-incarnation applies;
- the F36 restore, closed with `abandon-partial-database-restore`;
- the collision and adoption refusals;
- the retained PVC collection.

## 7. Fresh cloud context (C3)

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
  | cluster (charts, auth, net-certmanager image) | 207 creates, 3 declared ops | 326 | 241, exit 1 ambiguous ([F38](../audits/mp23-findings.md#f38)), then `inventory resume` converged in 872 |

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

Staged teardown on a full context, as natively proven on the `db808a74` checkpoint with the F39 and F40 fixes:
1. `infra destroy --save-plan` stage 1, the cloud policy review (verify-only).
2. `inventory retire --scope …` for every platform scope. Repeat `--scope` for scopes that consume each other: Serving, Kourier, net-certmanager, cert-manager and certificate-issuer go together, and so do the host and artifact scopes.
3. `infra destroy --save-plan` stage 2, which retires the cloud scope.

Exact collection of a full context's VM and data is not supported yet ([MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md)). Remove a disposable full context with operator-approved, bounded `gcloud` deletes, listing exact names from its own Pulumi stack export first. Export the inventory history before deleting the state bucket.

Before any cloud stage, check credentials and standing inputs read-only:

```bash
CLOUDSDK_ACTIVE_CONFIG_NAME=labs gcloud auth print-access-token >/dev/null && gcloud auth application-default print-access-token >/dev/null
CLOUDSDK_ACTIVE_CONFIG_NAME=labs gcloud compute instances describe nix-builder-ep150 --zone us-west1-a --format='value(status)'
```

If Google asks for re-authentication mid-run, stop at a safe boundary and ask the operator.

## 8. Shared working tree hygiene

Several sessions may commit in the same checkout and stage their own files. Always stage and commit by
explicit pathspec: `git add -- <paths> && git commit -F - -- <paths>`. A bare `git commit` would sweep a
peer's staged files into your commit. In zsh, split a path list with `${=VAR}`. Never use `git stash`,
`git checkout <rev> --` or other tree-wide commands in a shared checkout.

Before committing Haskell, run `just haskell-style-check` **and** `python3
scripts/check-haskell-architecture.py`. The latter enforces per-module line caps, which only ratchet
down, and the style check does not run it. Fix an overage by separating modules, not by raising the
allowance.
