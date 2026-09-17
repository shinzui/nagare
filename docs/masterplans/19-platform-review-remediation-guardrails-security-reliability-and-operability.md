---
id: 19
slug: platform-review-remediation-guardrails-security-reliability-and-operability
title: "Platform review remediation: guardrails, security, reliability, and operability"
kind: master-plan
created_at: 2026-07-16T04:24:57Z
intention: intention_01kzakvy1qeasagg3rpbn44749
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T04:46:25Z
      mode: "update"
      note: "Reconcile child progress, live evidence, secret ownership, and remaining operator gates"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-16T17:57:59Z
      mode: "implement"
      note: "Record EP-3 labs preflight and vault access dependency under the private-operator boundary"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-16T19:41:12Z
      mode: "implement"
      note: "Record EP-4 resource correction rehearsal, operator ownership, ADR 23, and remaining live gates"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T21:22:32Z
      mode: "implement"
      note: "Record EP-4 guarded live-audit refusal and recovery boundary"
---

# Platform review remediation: guardrails, security, reliability, and operability

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

In July 2026 a full five-track review of nagare (Haskell CLI packages, Pulumi and
NixOS infrastructure, cluster manifests, shell tooling, and cross-cutting
architecture/operations) surfaced roughly forty-five findings. A handful of them
undermine guarantees the repository explicitly promises: the GCP project-isolation
guardrail in `scripts/lib/target.sh` is a tautology that can never fail, `nagared`
will execute a fork pull request's `nagare/Config.hs` as arbitrary code, nothing
protects the data disk or backup bucket from deletion, host secrets are encrypted to
a single age key that lives only on the VM, and there is no alerting at all on a
single-node platform where one full disk takes everything down.

The repository implementation is now substantially complete. The project guardrail genuinely fails closed and
the local-mode loopback assertion cannot be spoofed; the auth plane (nagared,
nagare-access) is safe against fork-PR code execution, open redirects, timing
oracles, and outage-amplifying denial caching; stateful GCP resources are protected,
versioned, and snapshotted; the auth manifests carry resource bounds and applicable
probes/security contexts, and the log/trace stores have disk caps. The live audit
found unbounded chart-default monitoring containers; the
2026-09-16 resource rollout now bounds those containers, while startup OOMs
remain under investigation before claiming clean-start reliability. vmalert is
configured for the five failure
modes that actually kill a personal PaaS (disk, backups, certificates, node, crash
loops) and backup-freshness monitoring watches the prefixes backups actually land
in; nagarectl's deploy and database paths fail cleanly instead of throwing or
generating unparsable connection URLs; and the host is tuned for its 2-vCPU/8 GB
reality with a written, rehearsable upgrade story and a disaster-recovery runbook
that matches the tree.

Three live acceptance bundles remain before the initiative is complete.
EP-3 completed labs recovery enrollment on 2026-09-16: operator-confirmed vault
custody, independent decryption, guarded live activation, and updated recovery text.
Its private recovery backups are now published with verified remote heads. EP-4's
observability rollout and datasource/storage checks passed on labs; it must still
finish cloud auth bootstrap, startup-memory follow-up, and longer-term sizing
evidence. Local auth resource/probe/migration-rerun acceptance now passes. The
monitoring resource correction is deployed and passed its 628-second stability
observation. The new Grafana ciphertext backup is
published privately and its remote commit is verified. EP-5 must replace
the temporary blackhole notifier with an operator-owned Pushover configuration and
prove both phone delivery and the live metric/status paths. EP-7 must activate its
tested kubeconfig parent-directory correction and prove a private image can be pulled more than
45 minutes after k3s starts without restarting it. Everything else in the registry is
complete or repository-complete with its remaining live proof named explicitly below.

Out of scope: new product features (workload kinds, brokers, the agent content
plane), multi-node or high-availability work, replacing any major component
(Victoria stack, Kourier, k3s), and the full end-to-end disaster-recovery drill
itself — the drill becomes practical once EP-3 and EP-7 land, and should be run as
its own follow-up exercise against a scratch context.


## Decomposition Strategy

The forty-five findings were grouped by functional concern — the subsystem an
implementer must hold in their head — rather than by severity, so each child plan
stays independently implementable and verifiable with one toolchain (bash +
shellcheck, Haskell + cabal, TypeScript + pulumi preview, YAML + helm/kubectl,
Nix + nixos-rebuild). Severity is handled by phasing instead: the three plans that
close promise-breaking holes (guardrail, auth-plane RCE, unprotected state) form
Phase 1, the two that keep the box alive day-to-day (workload bounds, alerting)
form Phase 2, and the two hygiene plans (CLI correctness, host tuning/docs) form
Phase 3.

An alternative decomposition by severity ("critical fixes", "high", "medium") was
rejected because it would force every plan to touch every subsystem, maximizing
cross-plan coupling and merge conflicts on shared files. A second alternative —
one MasterPlan per review track (five plans mirroring the five review agents) —
was rejected because the review tracks overlap on artifacts (the architecture
track's alerting finding lands in the same Helm values file as the cluster track's
Grafana finding); the chosen split gives each shared artifact exactly one owning
plan (see Integration Points).

Eight plans exceed the preferred two-to-seven, so they are grouped into three phases
that act as implementation waves. All eight are mutually independent at the compile
level; the only ordering pressure is the soft dependency of EP-5 on EP-4 (shared
Helm values file and the sops-secret pattern), the soft dependency of EP-8 on EP-4
(both edit the auth-plane manifests under `cluster/bootstrap/`), and the
shared-file ownership rules in Integration Points.

EP-8 was added on 2026-08-25 and completed on 2026-08-28. It remediated the same auth-plane surfaces
EP-4 began: an authorization service that runs without any caller authentication,
health probes pointing at URLs the upstream service no longer serves, and Git pins
120 and 155 commits stale. Its post-completion M8 refresh moved Shomei to the official
0.2.0.0 release and recorded the explicit disposable-database reset required by that
release's checksum-breaking migration correction. It remains grouped into Phase 3
(hygiene).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Fail-closed target guardrail and shell tooling hardening | docs/plans/97-fail-closed-target-guardrail-and-shell-tooling-hardening.md | None | None | Complete |
| 2 | Auth-plane application security fixes for nagared and nagare-access | docs/plans/98-auth-plane-application-security-fixes-for-nagared-and-nagare-access.md | None | None | Complete |
| 3 | Protect stateful infrastructure and make secrets and state recoverable | docs/plans/99-protect-stateful-infrastructure-and-make-secrets-and-state-recoverable.md | None | None | Complete |
| 4 | Bound and harden cluster workloads | docs/plans/100-bound-and-harden-cluster-workloads.md | None | None | In Progress |
| 5 | Alerting and backup freshness monitoring | docs/plans/101-alerting-and-backup-freshness-monitoring.md | None | EP-4 | In Progress |
| 6 | nagarectl correctness and robustness fixes | docs/plans/102-nagarectl-correctness-and-robustness-fixes.md | None | EP-2 | Complete |
| 7 | Host tuning, upgrade story, and documentation reality sync | docs/plans/103-host-tuning-upgrade-story-and-documentation-reality-sync.md | None | EP-3 | In Progress |
| 8 | Upgrade nagare to the latest shomei and en | docs/plans/104-upgrade-nagare-to-the-latest-shomei-and-en.md | None | EP-4 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).

Phases: Phase 1 (promise-breaking holes) = EP-1, EP-2, EP-3. Phase 2 (keep the box
alive) = EP-4, EP-5. Phase 3 (hygiene) = EP-6, EP-7, EP-8.


## Dependency Graph

There are no hard dependencies: every plan compiles and verifies on its own. The
original four soft dependencies shaped implementation order; EP-2, EP-4's repository
work, EP-6, and EP-8 have now landed, so the remaining work is operational and can
proceed in parallel when its required credentials, secrets, or live workload are
available.

EP-5 (alerting) benefits from EP-4 (cluster workloads) landing first because both
edit `cluster/observability/victoria-metrics/values.yaml` and EP-4 establishes the
sops-managed-Secret pattern (for the Grafana admin password) that EP-5 reuses for
the alert notification channel credential. EP-5 remains implementable standalone —
its plan states what to create if EP-4 has not landed — but doing EP-4 first avoids
a merge conflict in one Helm values file and a duplicated pattern.

EP-6 (nagarectl correctness) soft-depends on EP-2 (auth-plane security) only in the
sense that both touch the `cli/` tree and it is easier to review them serially;
they own disjoint module sets (see Integration Points), so parallel work is safe if
desired.

EP-7 (host tuning and docs) soft-depends on EP-3 (infra protection) because EP-3
rewrites the age-key section of `docs/runbooks/disaster-recovery.md` while EP-7
fixes the rest of that runbook; landing EP-3's key-model change first means EP-7
documents the final two-recipient reality rather than the current fragile one.

EP-8 (upgrade shomei and en) soft-depended on EP-4 (cluster workloads) because both
edit the four auth-plane manifests under `cluster/bootstrap/` and the shared image
build script `cluster/bootstrap/auth-images/build-local-image.sh`. EP-4 established
the resource bounds, `securityContext` blocks and the migration-Job-per-service
shape those files now carry; EP-8 changes the probe paths, adds en's API-key
environment and adds a second migration Job on top of that shape. Landing EP-4
first avoided conflicting edits to the same five files. EP-8 also touched
`cli/nagare-access/` and `cli/nagarectl/src/Nagare/Access/Grants.hs`, which EP-2
and EP-6 own respectively — see Integration Points. EP-8 is complete; EP-4's remaining
rollout must deploy the current combined manifests rather than reconstruct its older
pre-EP-8 probe or migration shape.

Within Phase 1 the three plans are fully parallel: EP-1 is pure bash/justfile, EP-2
is pure Haskell, EP-3 is Pulumi TypeScript plus sops configuration.


## Integration Points

`cluster/observability/victoria-metrics/values.yaml` — shared by EP-4 and EP-5.
EP-4 owns the `grafana` block (admin `existingSecret`, plugin pinning, datasource
deduplication), exporter/controller resource blocks, and global operator reloader
resource defaults and defines the repository's sops-managed-Secret pattern for cluster
credentials. EP-5 owns the `vmalert` and `alertmanager` blocks and consumes the
sops pattern for the push-channel credential. Neither plan edits the other's block.

The sops-managed-Secret pattern is now context-owned operator configuration, as
defined by [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md),
[ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md), and
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md).
Cluster secrets live under
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/` (or
`NAGARE_CLUSTER_SECRETS_DIR`); host secrets live in the generated context host flake.
A source checkout's resolver retains `cluster/secrets/` compatibility, but ADR 13
removed this operator's ciphertext and recipients from the public repository. Its
current example policies and discarded-key fixture are excluded from recovery-key
work. Released payloads/workspaces exclude cluster secrets. EP-4 established the Grafana Secret consumer,
EP-5's installer now resolves the context-owned directory fail-closed, and EP-3 owns
adding the recovery recipient and re-keying every actual context-owned ciphertext.

`scripts/lib/target.sh` and the guardrail-adjacent `justfile` recipes (`vm-stop`,
`vm-start`, `cluster-bootstrap`) — owned exclusively by EP-1. EP-3 may change which
Pulumi backend cloud contexts default to, and EP-7 edits the justfile header
comment and component version pins, but neither touches guardrail logic or those
three recipes.

The `cli/` Haskell tree — split by module ownership. EP-2 owns
`cli/nagarectl/nagared/Main.hs`, `cli/nagarectl/src/Nagare/Static/Webhook.hs`, the
`runghc` timeout in `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, and everything under
`cli/nagare-access/`. EP-6 owns `cli/nagarectl/src/Nagare/Deploy.hs`,
`App/Deploy.hs`, `Database/Create.hs`, `Database/Secret.hs`, `Env/Store.hs`, and
any `Dsl/Render.hs` change needed for structural label stamping. EP-5 owns
`cli/nagarectl/src/Nagare/Ops/Status.hs` (backup-freshness probing). EP-8 owns
`cli/nagare-access/cabal.project` and the three shomei/en adapter modules
(`Nagare/Access/Shomei.hs`, `ShomeiClient.hs`, `En.hs`), plus
`cli/nagarectl/src/Nagare/Access/Grants.hs`. That last file is the one genuine
overlap: EP-2 owns everything under `cli/nagare-access/` for its security fixes,
and EP-8 rewrites those same adapters for upstream compatibility. EP-2's three
milestones are complete as of 2026-08-05, so EP-8 rebases on them rather than
racing them; EP-8 must preserve EP-2's unavailable-vs-denied distinction, which is
exactly the invariant its `EnResult` mapping restates.

`cluster/bootstrap/` auth-plane manifests and
`cluster/bootstrap/auth-images/build-local-image.sh` — shared by EP-4 and EP-8.
EP-4 owns the resource bounds, `securityContext` blocks, and the pattern of running
each service's migrations from its own release image. EP-8 owns the probe paths,
en's API-key Secret and environment, the new shomei migration Job, and the
generated cabal-project tails. Both repository changes have landed. EP-4's remaining
live validation consumes the resulting combined manifests, including EP-8's current
health endpoints and both dependency-owned migration Jobs.

`docs/runbooks/disaster-recovery.md` — EP-3 owns the age-key/root-of-trust
section and completed it with labs re-keying on 2026-09-16. EP-7's
reality-sync work for every other section is complete; EP-5 also corrected the managed
database backup prefixes.

`scripts/local-smoke.sh` — EP-1 owns the cleanup-trap safety changes; EP-5 appends
the managed-DB backup/restore round-trip steps. Appending test steps does not
conflict with trap hardening, but EP-5 should rebase on EP-1's version if both are
in flight.

Image and registry handling — EP-4 pins auth-plane image tags
(`NAGARE_AUTH_TAG` defaulting to a git SHA), while EP-7 replaces the k3s-restart
registry-credential hack in `nixos/hosts/nagare-01/registries.nix`. These touch
different layers (manifest tags vs pull credentials) and interact only in docs.


## Progress

Milestone-level view across all child plans. Check items as child-plan milestones
complete; the child plans hold the granular checklists.

- [x] EP-1 M1: A guardrail that can actually fail (scripts/lib/target.sh) — fail-closed project assertion, loopback whitelist, fail-closed context pointer, passphrase-file guard (2026-08-05)
- [x] EP-1 M2: Route the bypassing tooling through the guardrail — vm-power.sh, hard-fail cluster-bootstrap, migrate-pulumi-backend ownership assertion (2026-09-15 reconciliation — [ExecPlan 116](../plans/116-move-operator-private-deployment-material-into-a-private-development-repository.md) exercised the foreign-bucket refusal live after correcting gcloud's raw project-number output)
- [x] EP-1 M3: Trap safety and hygiene, then the lint gate (2026-09-15 reconciliation — shellcheck and the hermetic gate pass; the later dependency-authentication fix also removed the stale repo-wide flake-check blocker. The positive full local-smoke run remains a deferred operator exercise, not a completion blocker for the already-proven loopback guardrail.)
- [x] EP-2 M1: nagared — fork-PR gating and a runghc timeout (2026-08-05)
- [x] EP-2 M2: nagare-access — cookie MAC, return destination, Host header (2026-08-05)
- [x] EP-2 M3: nagare-access — unavailable-vs-denied and cache eviction (2026-08-05)
- [x] EP-3 M1: Pulumi — deletion protection, bucket hardening, snapshots, scoped IAM, instance fixes (2026-09-15 — the released program was applied to the fresh `tan-ng-labs` target and authoritative GCP/Kubernetes reads plus a 31-unchanged preview proved the intended protections)
- [x] EP-3 M2: sops recovery (2026-09-16) — operator confirmed vault storage;
  re-keyed the labs host and both nix-cache documents, proved independent recovery,
  workstation, and host decryption with unchanged plaintext, completed guarded host
  activation, updated the runbook and ADR 13, and removed temporary private material.
  Other contexts remain unenrolled; private recovery commits are now published.
- [x] EP-3 M2 preflight (2026-09-16): inventoried the selected labs host and
  nix-cache ciphertext and proved workstation decryption for both. Recovery-key
  custody was subsequently confirmed manually; no automated vault readback is claimed.
- [x] EP-3 M2 recovery-key generation (2026-09-16): generated a distinct identity
  at the operator's explicit request, staged outside repositories with directory
  mode 0700 and key mode 0600. Vault storage, re-keying, and staging cleanup are complete.
- [x] EP-3 final publication (2026-09-16): operator approved both private pushes,
  including the two disclosed pre-existing commits. Verified remote master equals
  local HEAD at `mori://shinzui/nagare-ops` (commit `f70d762`) and
  `mori://tan/tan-ng-labs` (commit `0a57197`). EP-3 is Complete.
- [x] EP-3 M3: Pulumi state — off the laptop, onto versioned GCS (2026-09-15 — [ExecPlan 116](../plans/116-move-operator-private-deployment-material-into-a-private-development-repository.md) migrated the active `tan-nb-exp` stack and verified matching outputs plus 31 unchanged)
- [x] EP-4 M1 local acceptance (2026-09-16): three auth services Ready, all five
  application/migration containers bounded and hardened; En survived a 62-second
  database outage with readiness failing/recovering, liveness 200 and zero restarts.
  Cloud auth bootstrap and the undeployed nagared scaffold remain separate.
- [x] EP-4 M2: Grafana secret, datasource single-sourcing, and disk-capped log/trace
  stores (2026-09-16 — all five releases deployed; encrypted login/default rejection,
  exactly one logs/traces datasource, real logs/synthetic traces, and live caps/PVCs
  verified; private ciphertext publication completed after separate approval)
- [x] EP-4 labs preflight/rehearsal (2026-09-16): five pinned observability charts
  render; auth services and both migration Jobs pass server-side dry run. No cloud
  mutation performed. Labs has no auth/observability installation or auth images;
  its 4-CPU node currently reserves 2 CPUs. Fresh bootstrap and bounded deployment
  approval are required, not merely an existing-workload update.
- [x] EP-4 first observability rollout and recovery (2026-09-16): operator approved the bounded
  sequence; recovery-encrypted Grafana credentials created/applied and committed
  privately (publication pending). Stopped at the metrics release when Grafana's
  plugin syntax caused startup failure; revision 1 is failed, resources retained.
  After separate recovery approval, the tested plugin syntax fix deployed,
  VMSingle passed a 306-second no-restart window, and all five releases completed.
  Datasource queries and live caps passed, with 1755m CPU unreserved. Auth bootstrap
  was not authorized by this approval.
- [x] EP-4 resource correction preparation (2026-09-16): added limits for six
  chart-created containers and operator defaults for two reloaders; all five pinned
  chart checks and labs server admission dry runs pass. Proposed additional requests
  are 115m CPU/576Mi memory; labs retains a projected 1640m unreserved CPU.
- [x] EP-4 resource rollout (2026-09-16): operator approved the rehearsed sequence;
  `vmks` revision 4 deployed and every observability container now has requests
  and a memory cap, including both 128Mi reloaders. Grafana metrics/logs queries
  and actual 2360m CPU/3674Mi memory reservations pass. Twenty-one samples over
  628 seconds kept all eleven observability and both cache pods Ready with unchanged
  UIDs/restart counts; end-of-window health, metrics and logs queries passed.
- [x] EP-4 private Grafana backup publication (2026-09-16): operator approved the
  exact ciphertext/README commit; pushed without force and verified remote master
  at `85826b1af8f04170a2308d2af44c67f4d1877d62` in `mori://shinzui/nagare-ops`.
  No cluster mutation was performed.
- [x] EP-4 read-only follow-up recovery (2026-09-16): the first continuation
  sourced the Bash target library from zsh, failed its operational-root guard,
  and produced no valid labs reads. The child plan's bounded Bash/project/context/
  node gates subsequently passed and the audit completed without mutation.
- [ ] EP-4 remaining resource reliability: investigate startup OOMs (three metrics,
  one logs) and record longer-term sizing. Repository correction now sets both
  store cache budgets to 40% under unchanged 512Mi caps and passes exact-chart
  checks. Its separately approved two-stage rollout/clean-start proof and seven
  days of history remain; current history covers only about 2.5 hours.
- [x] EP-4 M3 local acceptance (2026-09-16): both installer runs recreated and
  completed both Jobs; En verifies 2 applied migrations and Shomei 36, with zero
  pending/unknown. The rerun logs report `already_applied`. Immutable-tag renders
  and MinIO pins retain their earlier verification; cloud installer proof remains.
- [~] EP-5 M1: vmalert + Alertmanager with a Pushover channel (2026-08-26 — the packaged installer resolves context-owned secrets fail-closed; the Pushover account/token, encrypted Alertmanager config, chart enablement, and phone-delivery proof remain)
- [~] EP-5 M1 live audit (2026-09-16): labs has no Alertmanager ciphertext;
  Alertmanager remains disabled and vmalert's explicit blackhole notifier is live.
  No credential, chart, or phone-delivery mutation was attempted.
- [~] EP-5 M2: Seven rules covering five failure modes, and a truthful freshness
  probe (2026-09-16 — exact chart/render/code tests pass; every required metric
  family is live and all seven rules report healthy. `server status` proves the
  correct empty `databases` fallback and no legacy `postgres` line, but labs has
  no managed database or backup objects, so fresh `databases/<name>` age proof remains)
- [x] EP-5 M3: Prove backups restore, on a schedule (2026-08-26 — packaged local
  smoke repeatedly completed the database backup/restore round-trip and teardown;
  the monthly cloud workflow exists and intentionally fails at its still-unwired
  authentication step)
- [x] EP-6 M1: URL-safe database credentials and total secret decoding
  (2026-08-24 — hex generation, percent-encoded URL userinfo, total UTF-8
  decoding, and all 368 tests pass)
- [x] EP-6 M2: Clean phase failures and verified label stamping
  (2026-08-24 — clean `ExitCode` propagation, structural stamping verification,
  byte-identical dry-run output, and all 372 tests pass)
- [x] EP-6 M3: House-style sweep and final validation
  (2026-08-24 — all six owned sites use `fromMaybe`; final build and all 372
  tests pass)
- [~] EP-7 M1: Host tuning and k3s hardening flags
  (2026-09-16 — the released configuration is live on labs, the kubeconfig file is
  `640 root:wheel`, and datastore encryption is enabled; a read-only audit found its
  `700 root:root` parent blocked wheel traversal. The tested repository correction makes the
  directory `750 root:wheel`; activation/operator verification remains. First-start evidence
  proves encryption covered the datastore from birth; `Enabled` + stage `start` is normal before
  optional key rotation, so no reencryption is required. A guarded same-version platform-upgrade
  rehearsal passed host evaluation, replacement-free Pulumi preview, and no-op Kubernetes diff;
  its approved apply left all 37 Pulumi resources unchanged, then stopped before host activation on
  a macOS Bash 3.2 empty-array incompatibility. The tested portable rollback-client fix now awaits a
  replacement transaction whose staged closure, exact directory invariants, dry-run target, and
  packaged Bash 3.2 path all pass; apply remains operator-gated)
- [~] EP-7 M2: Registry credentials without k3s restarts
  (2026-09-16 — labs proves the replacement timer runs every 30 minutes, the old
  restart unit is absent, and k3s has been up for more than two days. An exact private Attic
  digest is available; its approved eviction and fresh canary pull remain)
- [x] EP-7 M3: Upgrade story and documentation reality sync (2026-08-24 —
  verified net-certmanager release assets and retained the live GCS pin; added
  the upgrade guide and IAP fallback; synchronized DR, secrets, kubeconfig, and
  active-context docs; parse, evaluation, stale-string, and path checks pass;
  optional k3d rehearsal skipped because Docker is unavailable)
- [x] EP-8 M0: Resolve the shomei/en pins and capture the baseline (2026-08-25)
- [x] EP-8 M1: Repin and make the nagare-access library compile (2026-08-25)
- [x] EP-8 M2: Make the nagare-access test suite compile and pass (2026-08-25)
- [x] EP-8 M3: Send en's mandatory API key from nagare-access (2026-08-25)
- [x] EP-8 M4: Fix nagarectl's hand-written en client (2026-08-25)
- [x] EP-8 M5: Cluster manifests and the image build script (2026-08-25)
- [x] EP-8 M6: Recreate the auth databases and prove access end to end (2026-08-25)
- [x] EP-8 M7: Documentation and ADR distillation (2026-08-25 — ADRs 1 and 2 record dependency-plan and schema ownership)
- [x] EP-8 M8: Refresh Shomei to the official 0.2.0.0 release (2026-08-28 — builds, 104 focused tests, native image build, migration reset proof, and native flake checks pass)


## Surprises & Discoveries

Discoveries made while researching and drafting the child plans (before any
implementation):

- The review's timing-oracle finding against the refresh-cookie MAC comparison in
  `cli/nagare-access/src/Nagare/Access/Cookie.hs` was a false positive: crypton's
  `Eq` instance for `HMAC` already compares via `constEq`. EP-2 keeps a small
  change that makes the constant-time comparison explicit rather than relying on
  an instance property, but there is no live vulnerability.
- nagared's builds do not run docker inside the pod — image builds run host-side;
  the pod's memory profile is dominated by `runghc` config loading. EP-4 sizes
  nagared's limit (1Gi) accordingly, and its securityContext hardening is deferred
  (recorded in EP-4's Decision Log).
- The review's `maybe x id` house-style sites attributed to nagarectl are mostly
  in `cli/nagare-access` (EP-2's territory); EP-6 scoped its style sweep to
  nagarectl-owned modules and recorded the boundary in its Decision Log.
- The `printf '%q'` quoting idiom the review said to copy from `iap-ssh.sh`
  actually lives in `scripts/upload-images.sh` (lines 51/66/111); EP-1's plan
  references the correct file.
- cert-manager's DNS-01 solver needs project-level `roles/dns.reader` for zone
  listing because the ClusterIssuer sets no `hostedZoneName`; EP-3's zone-scoped
  `dns.admin` grant is paired with that reader role rather than being fully
  project-free.

Discoveries from implementation:

- **EP-4's read-only continuation failed closed before reaching labs**
  (2026-09-16). `scripts/lib/target.sh` is a Bash source library; sourcing it from
  zsh left `BASH_SOURCE[0]` empty and derived `/Users/shinzui/Keikaku` as the
  operational root. The root check refused before the project guard was defined,
  and later ambient-kubeconfig errors are not labs evidence. The child now requires
  Bash, guarded context/project identity, and an explicit labs kubeconfig before
  any read-only audit resumes. The authoritative operator documentation at
  `mori://tan/tan-ng-labs/docs/readme` also corrected the identity gate:
  `nagare-01` is the GCE instance, while the sole Kubernetes node is
  `labs-nagare`.
- **EP-4's startup OOMs share a bounded-cache mechanism** (2026-09-16). Both
  stores detected the 512Mi cgroup correctly, then assigned the default 60%
  (307.2Mi) to caches and reached the cgroup ceiling during empty-store startup.
  The repository now renders 40% for both pinned charts, leaving 307.2Mi to
  non-cache work without raising the cap. Exact-chart and native checks pass;
  live clean-start and seven-day sizing evidence remain separate gates under
  [ADR 23](../adr/0023-observability-resource-bounds-cover-chart-and-operator-created-containers.md).
- **EP-5's live rule plane is healthy but has nothing to deliver or age yet**
  (2026-09-16). Both filesystem mountpoints and every other required metric family
  return series; the VMRule and scrapes are operational, and vmalert reports all
  seven rules healthy. Labs has no Alertmanager ciphertext, managed database, or
  objects under `databases/`, `litestream/`, or `volumes/`. Notification and fresh
  backup-age proof therefore remain genuine operator mutations, not code defects.
- **EP-7's kubeconfig file was hardened but unreachable by its intended group** (2026-09-16).
  Labs had `0640 root:wheel` on `k3s.yaml`, but `/etc/rancher/k3s` was `0700 root:root`
  because the registry bootstrap created it that way. Consequently `kubectl` as `deploy` failed
  despite the apparently correct file metadata. The repository now declares and tests
  `0750 root:wheel` on the directory while keeping `registries.yaml` root-only. Activation remains
  a separately approved host switch.
- **EP-7 activation requires an immutable-payload repin, not a direct source-tree switch**
  (2026-09-16). The first approved switch refused before mutation because the ambient CLI was
  0.2.2 against a 0.4.0 context/host. The checkout-built 0.4.0 operator passed the guard, then showed
  that the context-owned host flake correctly pins the prior immutable 0.4.0 payload. Its supported
  same-version upgrade rehearsal passed host evaluation and a no-replacement Pulumi preview; after
  fetching and explicitly selecting the labs kubeconfig, Kubernetes diff also passed with no
  migration. The persisted apply remains a separate operator boundary.
- **The self-reverting switch was safe but not portable to empty SSH options on macOS Bash 3.2**
  (2026-09-16). The approved transaction applied a no-change Pulumi plan, built and copied the host
  closure, then failed before arming or activation because nounset rejects expansion of an empty
  array on Bash 3.2. Live verification confirmed the old generation remained active. The client now
  branches before expansion; a native reproduction and the full commit/lockout/crash rollback VM
  test pass.
- **EP-4 restored local acceptance and found a bootstrap race** (2026-09-16).
  Colima can run the disposable test cluster again. A clean environment is required
  when creating an isolated local context beneath an ambient cloud shell. The first
  bootstrap then exposed cert-manager CA injection lagging webhook pod readiness;
  both bootstrap recipes now gate on bounded server-side admission dry runs, with
  retries restricted to known cert-manager startup errors. Local recovery passed;
  the cloud recipe was rendered/tested without mutation. Native synthetic store
  tests did not reproduce the labs startup OOMs, which remain open.

- **EP-4 has a rehearsed resource correction** (2026-09-16). Six direct chart
  containers and two operator-created reloaders lacked limits. Pinned-chart source
  and the running operator confirm the supported settings; a new five-chart check
  covers both forms. ADR 23 distinguishes render/admission evidence from live
  resource reconciliation and startup stability. The current labs sample has no
  new metrics/logs restarts; their initial OOM cause remains unresolved. Docker is
  unavailable locally, so auth acceptance cannot run there yet.

- **Labs recovery enrollment is now proven** (EP-3, 2026-09-16). The host document
  and both nix-cache documents decrypt independently with the new recovery identity;
  original identities still work, plaintext is unchanged, and no-key checks fail.
  Guarded activation committed and sops-nix, k3s, and Tailscale are healthy. Manual
  vault custody was confirmed by the operator; no automated vault retrieval is
  claimed. ADR 13 records why recovery enrollment is explicit per context.
- **EP-3's current files do not match its historical key assumptions** (2026-09-16).
  The selected labs host already accepts the workstation identity and has its own
  host recipient. Its operational host directory is a regular XDG directory, while
  cluster secrets point into a private repository. Re-keying a repository host copy
  alone can miss the deployed input. ADR 13's public fixture has a discarded key and
  is excluded from recovery acceptance; EP-3 now records the actual inventory and
  successful workstation decryption. Vault access remains unresolved.
- **`shellcheck` is not in the dev shell** (EP-1, 2026-08-05). Every plan in this
  MasterPlan that lints shell should note this: `flake.nix` pulls
  `pkgs.shellcheck` only into the hermetic `shellcheck-scripts` check
  derivation, so `nix develop` does not provide the binary. Run it ad hoc with
  `nix shell nixpkgs#shellcheck --command shellcheck …`, and verify the gate with
  `nix build .#checks.aarch64-darwin.shellcheck-scripts`.
- **`nix flake check` is currently red for a reason unrelated to any plan here**
  (EP-1, 2026-08-05). `nagare-access-build-test` fails cloning a cabal
  `source-repository-package` from GitHub inside the Nix sandbox
  (`fatal: could not read Username for 'https://github.com'`), and that cancels
  the remaining checks. Plans that name `nix flake check` as an acceptance gate —
  notably EP-2 and EP-6, which change Haskell under `cli/` — should expect this
  and validate with targeted per-check builds until the sandbox has credentials.
- **The guardrail's new refusal is reachable only when the resolved context does
  not change** (EP-1, 2026-08-05). `_nagare_resolve_context` already cleared
  every context variable when the resolved context *changed* within one shell, so
  a stale `CLOUDSDK_CORE_PROJECT` is discarded on a context switch and caught by
  the new assertion otherwise. Both outcomes are safe; sibling plans should not
  read a passing guardrail on a context switch as evidence the assertion is
  inert.
- **`_NAGARE_CTX_PROJECT` is a new non-exported global in `scripts/lib/target.sh`**
  (EP-1, 2026-08-05). It holds the project the active context/profile declares
  (empty when none does) and is recomputed on every source. EP-3 may change which
  Pulumi backend cloud contexts default to, but must not touch this capture, the
  loopback whitelist, or `_require_target_project` — the ownership boundary
  recorded in Integration Points still holds.
- **`AccessServices.authorizeUser` changed shape** (EP-2, 2026-08-05). It is now
  `AuthenticatedUser -> Text -> IO AuthorizationResult`, where
  `AuthorizationResult` (new, in `Nagare.Access.DecisionCache`) is either
  `AuthorizationDecision AccessDecision` or `AuthorizationUnavailable Text`.
  `cacheLookupOrLoad` operates on the same type and caches only real decisions.
  Any later plan constructing an `AccessServices` — including test stubs — must
  wrap decisions in `AuthorizationDecision`.
- **`Nagare.Dsl.Load` gained a bounded-execution surface** (EP-2, 2026-08-05):
  `ConfigTimeout`, `defaultConfigTimeout` (120 s), `runConfigWith`,
  `loadStaticSiteWith`, and a `LoadTimedOut` constructor on `LoadError`. Every
  existing `load*` function is unchanged in signature but now bounded by the
  default. EP-6 (`docs/plans/102-nagarectl-correctness-and-robustness-fixes.md`)
  touches `Nagare.Deploy` and `Nagare.Database.*`, which consume `LoadError` —
  any exhaustive match on it there needs the new constructor.
- **This machine's default shell resolves to a local-mode in-repo profile**
  (EP-1, 2026-08-05): `nagare.local.env` with `NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io`
  and `NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000`, and no
  `~/.config/nagare/contexts` at all. Any plan whose validation assumes a cloud
  context must select one explicitly; the cloud branch of the guardrail is never
  exercised by an ordinary shell here.
- **EP-3's live blocker persisted on 2026-08-24.** There is still no user-level
  Nagare context directory, and explicit read-only GCP resource queries for
  `tan-nb-exp` fail because gcloud requires interactive reauthentication. EP-3 remains
  In Progress; because this MasterPlan has no hard dependencies, EP-4 can proceed
  without weakening or concealing EP-3's operator-only acceptance gates.
- **EP-4's planned SQL bootstrap became unsafe as the dependency evolved**
  (2026-08-24). `mori://shinzui/en/packages/en-migrations` is now an accepted,
  append-only pg-migrate component with an `en-migrate` executable, datastore
  identity and GC-horizon schema, and a changed live uniqueness contract. The
  prior Nagare ConfigMap would have retained an obsolete schema even after adding
  `IF NOT EXISTS`. EP-4 now ships `en-server` and `en-migrate` in one tagged image
  and treats the dependency-owned manifest as the only schema authority. Downstream
  plans must not reintroduce copied en SQL. The controlling cross-repository ADR
  is in `mori://shinzui/en` at project-relative path
  `docs/adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md`; an
  artifact-level Mori URI is pending registry coverage.
- **EP-5's pinned interfaces differed from its authored assumptions**
  (2026-08-24). The cert-manager v1.20.2 Service port is
  `tcp-prometheus-servicemonitor`, chart 0.81.0 prefers
  `defaultRules.enabled`, and the chart requires vmalert to have a notifier.
  Also, kube-state-metrics can retain a failed-attempt count on an eventually
  successful Job. EP-5 uses the exact port/current value key, explicit blackhole
  mode until Pushover is configured, and excludes successful Jobs from the
  backup-failure alert.
- **Encrypted operational secrets moved out of immutable releases** (EP-3/EP-5,
  2026-08-26). MasterPlan 20 and ADRs 4, 5, and 13 made the active context's
  `cluster-secrets/<context>/` directory and generated host flake the operational
  source of truth. Released payloads deliberately exclude `cluster/secrets/`.
  Recovery and observability work must resolve those context-owned paths; re-keying
  only the checkout compatibility files would leave the real deployment unrecoverable.
- **Packaged local smoke now proves the managed-database restore path** (EP-5,
  2026-08-26). The clone-free run repeatedly reached `DB RESTORE OK`, cleaned up the
  deterministic backup CronJob, and exposed three integration defects that were fixed:
  inherited cloud context, PostgreSQL readiness/socket assumptions, and backup-CronJob
  leakage. M3 is complete rather than waiting on the formerly absent Docker daemon.
- **The dependency upgrade completed and then advanced again** (EP-8,
  2026-08-25 through 2026-08-28). Nagare now uses current En plus Shomei 0.2.0.0,
  authenticates both En clients with role-appropriate keys, runs dependency-owned
  migration Jobs, and passed a local grant → sign-in → allow → revoke → deny proof.
  [ADR 1](../adr/0001-auth-plane-images-mirror-upstream-dependency-plans.md)
  and [ADR 2](../adr/0002-auth-service-images-own-and-apply-their-database-schemas.md)
  preserve the durable dependency-plan and schema-ownership rules. Shomei 0.2.0.0's
  rewritten migration history requires an explicit reset only because Nagare's current
  auth data is disposable; that exception must not be generalized.
- **A fresh labs target and the original context now provide complementary live
  evidence** (EP-3/EP-7, 2026-09-15). `mori://tan/tan-ng-labs` proves the released
  infrastructure protections, host mode, fresh-start datastore encryption, and
  pull-secret timer. [ExecPlan 116](../plans/116-move-operator-private-deployment-material-into-a-private-development-repository.md)
  proves the active `tan-nb-exp` Pulumi stack's exact GCS
  migration. Neither substitutes for human custody of the recovery key or an expired-boot-token
  private pull. A later first-start audit closed the supposed reencryption gap: labs used its
  encryption provider from datastore creation, and stage `start` is normal while encryption is
  Enabled.


## Decision Log

- Decision: close EP-7 encryption-at-rest acceptance from first-start evidence; do not rotate
  labs keys solely to obtain stage `reencrypt_finished`.
  Rationale: upstream k3s documents `Enabled` + `start` as a normal state before optional key
  rotation. Labs created its datastore and encryption config within the same first-boot second,
  and its first API server loaded the encryption provider. No plaintext era exists to migrate, so
  rotation would add a datastore rewrite and restart without improving the stated guarantee.
  Date: 2026-09-16.

- Decision: use EP-7's successfully rehearsed same-version platform-upgrade transaction rather than
  bypassing the version guard or editing the context-owned host flake.
  Rationale: immutable payload pinning is the deployment contract. The transaction contains the
  replacement-free infrastructure plan, corrected host closure, explicit labs cluster gate, release
  stamp, and context-pin commit; applying only an ad hoc source tree would leave those identities
  inconsistent.
  Date: 2026-09-16.

- Decision: retain the self-reverting switch and fix its Bash 3.2 empty-options path instead of
  bypassing rollback protection for EP-7.
  Rationale: the refusal happened before activation and proved the safety boundary worked. An
  explicit non-empty/empty SSH helper preserves every safety flag and supports both configured
  `NIX_SSHOPTS` and ordinary SSH configuration.
  Date: 2026-09-16.

- Decision: accept the later `DiskUsageCritical` addition as EP-5's seventh
  curated rule while keeping the failure-mode count at five.
  Rationale: it adds critical escalation to the existing disk-pressure mode and
  evaluates cleanly live; deleting it to preserve the authored count would reduce
  operability. The chart's noisy multi-node defaults remain disabled.
  Date: 2026-09-16.

- Decision: retain EP-4's 512Mi store caps and prepare a 40% internal cache budget,
  with a separately approved one-store-at-a-time rollout before any clean-start
  claim.
  Rationale: read-only logs and kernel evidence connect all four startup OOMs to
  the default 60% cache reservation, while both stores later ran under the same
  hard cap. Reducing caches preserves node protection; raising limits is not yet
  justified. Cache misses/I/O and long-term sizing still require seven-day data.
  ADR 23 records the durable constraint.
  Date: 2026-09-16.

- Decision: recover EP-4's live read-only audit only through the child plan's
  Bash target guard and explicit labs kubeconfig gates; do not infer authorization
  for mutation from the audit.
  Rationale: the first zsh invocation failed the operational-root check before
  `_require_target_project` existed. The repository requires every cloud read to
  pass the same fail-closed project isolation as mutations, and EP-4's remaining
  Helm/auth operations still need a separate operator go-ahead.
  Date: 2026-09-16.

- Decision: EP-4 owns the shared chart operator/exporter resource blocks and global
  reloader defaults in addition to Grafana; EP-5 retains notification policy.
  Rationale: the live acceptance gap includes operator-created sidecars. Setting
  their global defaults avoids changing EP-5 notifier configuration. ADR 23 records
  the coverage boundary and separate proof requirements. Date: 2026-09-16.

- Decision: close EP-3 after publishing the verified recovery envelopes with the
  operator's explicit approval, including the disclosed pre-existing private commits.
  Rationale: both remote heads now match the tested local commits, closing the
  off-machine backup gap. The unrelated uncommitted Pulumi edit was preserved.
  Date: 2026-09-16

- Decision: treat EP-3's labs live implementation as complete but retain In Progress
  until the private recovery envelopes are published, with explicit scope limits.
  Rationale: labs is the active context the operator agreed to enroll. A shared
  recovery identity does not enroll other clusters. Existing unpublished commits in
  the private configuration repository are not published as an incidental mutation.
  Date: 2026-09-16
- Decision: resume EP-3 against the selected `labs` context and apply ADR 13's
  existing distinction between private operational ciphertext and public examples.
  Rationale: the current host is already workstation-decryptable, uses its own host
  recipient, and is a regular XDG directory; cluster secrets resolve into a separate
  private repository. EP-3 now inventories those actual files and their backups,
  excludes discarded-key fixtures, and requires isolated vault-retrieved recovery
  decryption. No recipient changes can proceed until recovery-key custody/access
  is established.
  Date: 2026-09-16

- Decision: Organize all review findings under one MasterPlan with seven themed
  child ExecPlans in three phases, rather than several MasterPlans or a
  severity-based split.
  Rationale: One initiative, one coordination document; functional-concern
  boundaries minimize shared-file coupling (each shared artifact gets exactly one
  owning plan) while phases carry the severity ordering. User confirmed this
  structure when asked.
  Date: 2026-07-16

- Decision: No hard dependencies between child plans; express ordering pressure as
  soft dependencies (EP-5→EP-4, EP-6→EP-2, EP-7→EP-3) plus explicit file-ownership
  rules in Integration Points.
  Rationale: Every plan is independently compilable and verifiable; hard
  dependencies would serialize work without protecting any real artifact. The two
  genuine contention points (the Victoria Helm values file and the DR runbook) are
  handled by block-level ownership instead.
  Date: 2026-07-16

- Decision: The full end-to-end disaster-recovery drill is out of scope for this
  MasterPlan and should run as a follow-up exercise once EP-3 (recoverable
  secrets/state) and EP-7 (accurate runbook) are complete.
  Rationale: Drilling against a runbook known to be wrong wastes the drill; the
  drill is an exercise, not a code change, and deserves its own session with a
  scratch context.
  Date: 2026-07-16

- Decision: Findings are remediated as reviewed; where a finding admits multiple
  fixes (e.g. registry-credential refresh via CronJob-managed imagePullSecrets vs
  the kubelet GCP credential provider, Pulumi GCS backend default vs documented
  migration), the child plan evaluates and records the choice in its own Decision
  Log rather than this one.
  Rationale: Those choices need implementation-level detail (chart capabilities,
  plan-93 status) that belongs with the implementer; the MasterPlan only fixes the
  scope.
  Date: 2026-07-16

- Decision: Leave EP-3 In Progress after its 2026-08-24 blocker re-audit and proceed
  to EP-4 instead of attempting an unverified cloud apply, creating recovery-key
  material outside the operator's vault, or stalling the independent work streams.
  Rationale: EP-3's remaining acceptance gates require interactive gcloud
  reauthentication, restoration of the live cloud context/state, and operator-owned
  password-manager handling. The registry intentionally declares no hard dependencies,
  so EP-4 can be implemented safely while those gates remain explicit and unchecked.
  Date: 2026-08-24

- Decision: EP-4 consumes en's released migration executable from the same tagged
  image as the server; Nagare does not own or mount a second SQL manifest.
  Rationale: en's pg-migrate component is the accepted schema boundary and carries
  ledger, checksum, advisory-lock, and forward-only behavior. Delegating to it
  prevents the drift discovered in Nagare's bootstrap SQL and keeps the runtime
  binary and schema plan version-locked. The dependency is
  `mori://shinzui/pg-migrate`, whose 1.1.0.0 release was verified against Hackage
  and upstream tag `v1.1.0.0` on 2026-08-24.
  Date: 2026-08-24

- Decision: Proceed with EP-5 M2/M3 repository work while M1 remains open on
  operator-owned Pushover credentials and phone-delivery proof; run vmalert with
  an explicit blackhole notifier in the interim.
  Rationale: scrape/rule validation, backup-prefix correctness, and restore smoke
  coverage do not require fabricating an external account secret. The temporary
  notifier state is explicit and chart-valid, and EP-5 records that M1 must remove
  it when enabling Alertmanager.
  Date: 2026-08-24

- Decision: Treat context-owned host and cluster secret directories as the only
  operational re-key targets; retain `cluster/secrets/` only as a source-checkout
  compatibility fallback.
  Rationale: ADRs 4, 5, and 13 moved mutable operator identity and ciphertext out of
  immutable release payloads. Re-keying or backing up only checkout fixtures would not
  make a packaged deployment recoverable, and shipping ciphertext in every release
  would violate the established payload boundary.
  Date: 2026-09-15

- Decision: Mark EP-8 Complete and preserve its M8 Shomei 0.2.0.0 refresh as part of
  the initiative rather than opening a ninth plan.
  Rationale: M8 is the final compatibility correction on the same auth-plane surface,
  passed its focused/native validation, and distilled its durable rules into ADRs 1 and
  2. A separate child would add coordination overhead without creating an independent
  remaining behavior.
  Date: 2026-09-15

- Decision: Use later authoritative cross-plan evidence to close stale child-plan
  acceptance items, but split broad live gates so evidence is never allowed to imply
  unobserved behavior.
  Rationale: labs directly proves the released Pulumi resources and fresh-host state;
  [ExecPlan 116](../plans/116-move-operator-private-deployment-material-into-a-private-development-repository.md)
  directly proves the original stack's GCS migration. The same evidence does not
  prove operator recovery-key custody, migration of pre-existing plaintext datastore
  rows, or a private pull after the boot token expires. Keeping those narrower checks
  open makes the remaining plan actionable and honest.
  Date: 2026-09-15

- Decision: Plan the remaining work as four parallel operator acceptance bundles —
  EP-3 recovery identity, EP-4 live rollout, EP-5 notification/live observability, and
  EP-7 host migration/pull proof — rather than by the original implementation phases.
  Rationale: all hard dependencies remain absent, the shared repository edits have
  landed, and each remaining bundle is gated by different live credentials or human
  custody. Serializing them by the old phases would hide available work without
  protecting a shared artifact.
  Date: 2026-09-15


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

As of 2026-09-16, five of eight child plans are complete: EP-1, EP-2, EP-3,
EP-6, and EP-8. EP-3 adds verified labs secret recovery to its previously
accepted infrastructure protections and GCS migration. The operator confirmed vault
storage of a distinct recovery identity; all three operational YAML documents pass
isolated decryption with unchanged plaintext, the guarded host switch committed,
and temporary recovery private material was removed. Other clusters remain
unenrolled. Both private configuration repositories were pushed with the operator's
approval, and independent remote-head checks matched the verified local commits.
No automated vault readback is claimed; manual custody and cryptographic verification
remain separate evidence.

EP-4's repository changes for resource bounds, probes, observability storage caps,
Grafana credentials, immutable auth tags, and dependency-owned migrations are complete.
Its local auth resource/probe/migration-rerun acceptance now passes. The
observability rollout/data paths/caps and current capacity are now verified;
chart-default memory bounds are now live and passed a 628-second stability window.
The read-only follow-up tied the four startup OOMs to the stores' default 60%
cache reservation inside unchanged 512Mi cgroups. A tested 40% repository
correction preserves the hard caps, but deployment and clean-start observation
remain operator-gated; only about 2.5 hours of the required seven-day history exist.
The additional local checks directly establish EP-4's pod and rerun behavior.
The 2026-09-16 labs preflight confirmed that this is a first installation. After
the operator's observability-only approval, Grafana ciphertext was created/applied,
but a plugin pin syntax error prevented Grafana startup. The installer was stopped
at failed `vmks` revision 1. A separately approved recovery applied the tested
syntax correction, passed login and five-minute metrics stability, and completed
all five releases (`vmks` revision 3, the others revision 1). Metrics/logs queries
and an OTel-to-Grafana trace round trip succeeded. Logs had one startup OOM but
recovered without changes. The subsequently approved revision 4 closes the live
observability-container bounds gap and passed its ten-minute stability gate.
Cloud auth coverage and clean-start reliability remain open. Private Grafana
ciphertext publication is complete and the remote commit verified. Cloud auth images/databases
remain absent and their bootstrap needs separate approval. The nagared manifest
remains a non-turnkey scaffold and must not be mistaken for an installed service.

EP-5 has validated alert rules, truthful backup-prefix probing, and repeated successful
packaged database restore smoke tests. Live metric/rule evidence now passes for seven
curated rules, and status proves the correct empty fallback. Pushover configuration,
phone delivery, and a fresh live `databases/<name>` age remain open because labs has
neither the ciphertext nor a managed database/backup. EP-7's host configuration is active on labs;
its tested kubeconfig directory correction still needs activation, followed by operator-access
verification and a private pull after the boot token expires. First-start evidence now closes
encryption-at-rest without an unnecessary key rotation. EP-3's successful secrets activation does
not prove the remaining behaviors.

The next child is EP-4. It and EP-5 can share a live cluster session, while
EP-7 can use the same host window for its correction and remaining checks. The full disaster-
recovery drill remains a separate scratch-context exercise. ADR 13 captures the
durable recovery decisions from EP-3; task-specific custody and test evidence stays
in the child plan.

Revision note (2026-09-15): reconciled all eight child plans, later live evidence,
MasterPlan 20's packaged-operator boundary, and current ADRs. Marked EP-8 complete,
closed EP-3 M1/M3 and EP-5 M3, narrowed EP-7 to its two unproven live behaviors, and
rewrote the remaining-work view around four independently runnable operator acceptance
bundles. Cascaded the current auth-probe, two-migration-Job, and context-owned
Grafana-secret assumptions into EP-4 so its remaining live rollout is executable. No
architecture decision changed in this refresh.

Revision note (2026-09-16): recorded EP-3's current labs inventory and successful
workstation decryption, corrected recovery scope to the existing ADR 13 boundary,
and retained the vault-access blocker. The child plan now accounts for differing
host/cluster ownership paths and excludes intentionally undecryptable public fixtures.

Revision note (2026-09-16, live completion): completed EP-3's live labs work after manual vault
confirmation, recipient-only re-keying, isolated cryptographic checks, guarded live
activation, and temporary-key cleanup. Updated the registry, remaining-work view,
runbook ownership, and retrospective; ADR 13 preserves the recovery decisions.
Other contexts remain unenrolled. EP-3 stays In Progress until private backup
publication is authorized and verified, including its pre-existing unpublished history.

Revision note (2026-09-16, EP-7 audit): recorded the live kubeconfig parent-directory
permission defect, the tested declarative correction, and the ready private-image candidate.
EP-7 now requires activation/operator-access verification and an uncached-pull proof. First-start
evidence plus current upstream k3s semantics closed the supposed reencryption gap without a risky
datastore rewrite; the read-only audit made no host or cluster mutation.

Revision note (2026-09-16, EP-7 activation rehearsal): recorded the stale-CLI refusal, immutable
payload boundary, explicit labs kubeconfig recovery, and successful same-version upgrade plan. No
cloud or host mutation occurred; transaction apply remains operator-gated.

Revision note (2026-09-16, EP-7 activation recovery): the approved transaction kept all Pulumi
resources unchanged and stopped before host activation on a Bash 3.2 compatibility bug. Recorded
the unchanged live generation and fully tested portable rollback-client correction. The replacement
transaction's staged closure and client now pass direct rehearsal; apply remains operator-gated.

Revision note (2026-09-16, publication): the operator approved both private pushes,
including the disclosed pre-existing commits. Verified exact remote heads and marked
EP-3 Complete; five of eight children are now complete. No unrelated Pulumi edit was
staged or published.

Revision note (2026-09-16, resource follow-up): EP-4 now has tested chart/helper
bounds and a rehearsed metrics-only rollout, pending operator go-ahead. Expanded
shared-file resource ownership and recorded ADR 23. Live acceptance, OOM root
cause, auth bootstrap, and longer-term sizing remain open.

Revision note (2026-09-16, approved resource rollout): applied the rehearsed
metrics-only update as Helm revision 4. All live observability containers are
bounded, Grafana queries work, and reservations match the projection. The
required ten-minute stability observation passed with 21 samples over 628 seconds;
auth and startup-memory acceptance remain separate.

Revision note (2026-09-16, local acceptance recovery): EP-4 restored the disposable
local test path and fixed the cert-manager admission readiness race encountered
before auth installation. The guardrail remains unchanged. The initial local store
probe did not reproduce the cloud OOMs and does not close startup acceptance.

Revision note (2026-09-16, local auth acceptance): EP-4 completed both current-image
installer runs, migration verification, actual container resource/security checks
and the En database-outage readiness/liveness proof. Read-only kernel diagnostics
confirm cgroup-limit OOMs but do not establish their allocation cause. The private
Grafana backup push passed rehearsal and awaits explicit publication approval.

Revision note (2026-09-16, Grafana backup publication): operator approved the
rehearsed private push; the exact ciphertext/README commit is now published and
remote master verified. EP-4 remains In Progress for its other live acceptance gates.

Revision note (2026-09-16, guarded EP-4 audit recovery): recorded the failed-closed
zsh preflight and added the child plan's bounded Bash/read-only recovery boundary.
Mori-resolved labs documentation corrected the node gate from the GCE instance
name to `labs-nagare`. No workload evidence, cloud mutation, or completion claim
resulted from the failed calls.

Revision note (2026-09-16, EP-4 startup-memory correction): the recovered
read-only audit identified the common default-cache mechanism, confirmed the
seven-day evidence window is not yet available, and produced a validated 40%
cache-budget correction plus a separately approved staged rollout gate. ADR 23
now records the durable cache-versus-cgroup rule.

Revision note (2026-09-16, EP-5 live audit): verified every required metrics
family and all seven live rules without mutation, reconciled the later critical
disk threshold, and proved the status command's correct empty-prefix behavior.
Pushover delivery and fresh managed-database backup age remain operator-gated.
