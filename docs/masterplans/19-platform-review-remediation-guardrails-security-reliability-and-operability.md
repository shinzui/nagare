---
id: 19
slug: platform-review-remediation-guardrails-security-reliability-and-operability
title: "Platform review remediation: guardrails, security, reliability, and operability"
kind: master-plan
created_at: 2026-07-16T04:24:57Z
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

When this initiative is complete: the project guardrail genuinely fails closed and
the local-mode loopback assertion cannot be spoofed; the auth plane (nagared,
nagare-access) is safe against fork-PR code execution, open redirects, timing
oracles, and outage-amplifying denial caching; stateful GCP resources are protected,
versioned, and snapshotted, and every sops-encrypted secret can be recovered with an
operator-held key even if the VM is lost; every always-on cluster workload carries
resource bounds, probes, and a hardened security context, and the log/trace stores
cannot fill the shared data disk; vmalert pushes notifications for the five failure
modes that actually kill a personal PaaS (disk, backups, certificates, node, crash
loops) and backup-freshness monitoring watches the prefixes backups actually land
in; nagarectl's deploy and database paths fail cleanly instead of throwing or
generating unparsable connection URLs; and the host is tuned for its 2-vCPU/8 GB
reality with a written, rehearsable upgrade story and a disaster-recovery runbook
that matches the tree.

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

Seven plans slightly exceeds the preferred two-to-five, so they are grouped into
three phases that act as implementation waves. All seven are mutually independent
at the compile level; the only ordering pressure is the soft dependency of EP-5 on
EP-4 (shared Helm values file and the sops-secret pattern) and the shared-file
ownership rules in Integration Points.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Fail-closed target guardrail and shell tooling hardening | docs/plans/97-fail-closed-target-guardrail-and-shell-tooling-hardening.md | None | None | Not Started |
| 2 | Auth-plane application security fixes for nagared and nagare-access | docs/plans/98-auth-plane-application-security-fixes-for-nagared-and-nagare-access.md | None | None | Not Started |
| 3 | Protect stateful infrastructure and make secrets and state recoverable | docs/plans/99-protect-stateful-infrastructure-and-make-secrets-and-state-recoverable.md | None | None | Not Started |
| 4 | Bound and harden cluster workloads | docs/plans/100-bound-and-harden-cluster-workloads.md | None | None | Not Started |
| 5 | Alerting and backup freshness monitoring | docs/plans/101-alerting-and-backup-freshness-monitoring.md | None | EP-4 | Not Started |
| 6 | nagarectl correctness and robustness fixes | docs/plans/102-nagarectl-correctness-and-robustness-fixes.md | None | EP-2 | Not Started |
| 7 | Host tuning, upgrade story, and documentation reality sync | docs/plans/103-host-tuning-upgrade-story-and-documentation-reality-sync.md | None | EP-3 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).

Phases: Phase 1 (promise-breaking holes) = EP-1, EP-2, EP-3. Phase 2 (keep the box
alive) = EP-4, EP-5. Phase 3 (hygiene) = EP-6, EP-7.


## Dependency Graph

There are no hard dependencies: every plan compiles and verifies on its own, so all
seven could in principle proceed in parallel. Three soft dependencies shape the
sensible order.

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

Within Phase 1 the three plans are fully parallel: EP-1 is pure bash/justfile, EP-2
is pure Haskell, EP-3 is Pulumi TypeScript plus sops configuration.


## Integration Points

`cluster/observability/victoria-metrics/values.yaml` — shared by EP-4 and EP-5.
EP-4 owns the `grafana` block (admin `existingSecret`, plugin pinning, datasource
deduplication) and defines the repository's sops-managed-Secret pattern for cluster
credentials. EP-5 owns the `vmalert` and `alertmanager` blocks and consumes the
sops pattern for the push-channel credential. Neither plan edits the other's block.

The sops-managed-Secret pattern (`cluster/secrets/*.yaml` encrypted via the root
`.sops.yaml`, applied with `sops -d | kubectl apply -f -`) — established today by
`cluster/secrets/notes-db-url.yaml`, extended by EP-4 (Grafana admin), reused by
EP-5 (alert channel), and formalized in docs by EP-7 (secrets.md status change).
EP-3 changes the age recipients in both `.sops.yaml` files; whichever of EP-3/EP-4/
EP-5 lands last must run `sops updatekeys` on any secret files created in the
meantime.

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
`cli/nagarectl/src/Nagare/Ops/Status.hs` (backup-freshness probing). No module
appears in two plans.

`docs/runbooks/disaster-recovery.md` — EP-3 owns the age-key/root-of-trust section;
EP-7 owns every other section (stale paths, contradictory power-management text,
hardcoded image and bucket names, backup prefixes).

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

- [ ] EP-1 M1: A guardrail that can actually fail (scripts/lib/target.sh) — fail-closed project assertion, loopback whitelist, fail-closed context pointer, passphrase-file guard
- [ ] EP-1 M2: Route the bypassing tooling through the guardrail — vm-power.sh, hard-fail cluster-bootstrap, migrate-pulumi-backend ownership assertion
- [ ] EP-1 M3: Trap safety and hygiene, then the lint gate
- [ ] EP-2 M1: nagared — fork-PR gating and a runghc timeout
- [ ] EP-2 M2: nagare-access — cookie MAC, return destination, Host header
- [ ] EP-2 M3: nagare-access — unavailable-vs-denied and cache eviction
- [ ] EP-3 M1: Pulumi — deletion protection, bucket hardening, snapshots, scoped IAM, instance fixes
- [ ] EP-3 M2: sops — an offline recovery recipient for every secret
- [ ] EP-3 M3: Pulumi state — off the laptop, onto versioned GCS
- [ ] EP-4 M1: Resource bounds, probes, and securityContext for the auth plane
- [ ] EP-4 M2: Grafana secret, datasource single-sourcing, and disk-capped log/trace stores
- [ ] EP-4 M3: Idempotent migrations, immutable-by-default image tags, pinned MinIO
- [ ] EP-5 M1: vmalert + Alertmanager with a Pushover channel
- [ ] EP-5 M2: Five real alert rules, and a truthful freshness probe
- [ ] EP-5 M3: Prove backups restore, on a schedule
- [ ] EP-6 M1: URL-safe database credentials and total secret decoding
- [ ] EP-6 M2: Clean phase failures and verified label stamping
- [ ] EP-6 M3: House-style sweep and final validation
- [ ] EP-7 M1: Host tuning and k3s hardening flags
- [ ] EP-7 M2: Registry credentials without k3s restarts
- [ ] EP-7 M3: Upgrade story and documentation reality sync


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


## Decision Log

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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
