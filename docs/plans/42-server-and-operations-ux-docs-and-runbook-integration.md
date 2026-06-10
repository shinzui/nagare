---
id: 42
slug: server-and-operations-ux-docs-and-runbook-integration
title: "Server and operations UX docs and runbook integration"
kind: exec-plan
created_at: 2026-06-10T04:34:52Z
intention: "intention_01ktqwqc61e519h77zqdf3ngs3"
master_plan: "docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md"
---

# Server and operations UX docs and runbook integration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the final child of the MasterPlan at
`docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md`. It documents the
operator-facing commands delivered by its four sibling plans and folds them into the
existing runbooks. It **soft-depends** on all four:
`docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md`
(`nagarectl server status`),
`docs/plans/39-nagarectl-doctor-health-checks-with-remediation-hints.md`
(`nagarectl doctor`),
`docs/plans/40-nagarectl-domains-list-with-dns-and-certificate-readiness.md`
(`nagarectl domains list`), and
`docs/plans/41-nagarectl-cleanup-for-images-previews-and-releases.md`
(`nagarectl cleanup`). A docs plan describes commands that actually work, so it can be
drafted incrementally as each command lands and finalized once all four have merged. If a
command has not yet landed when its section is written, document the intended surface from
the sibling plan and mark that section with a short "lands with EP-NN" note, then verify it
against the real `--help` once the command merges.


## Purpose / Big Picture

Today an operator who wants to know "is my platform healthy, and what do I do when it is
not?" has to remember which of `gcloud`, `pulumi`, `kubectl`, `gsutil`, Grafana, and a
handful of runbook steps answers each question. The four sibling plans collapse that into
four `nagarectl` commands. But a command nobody can find — or whose runbook still tells you
to do the manual thing — is a command that does not help. This plan writes the
operator-facing documentation for those commands and rewrites the existing runbooks so the
docs and the tooling agree.

After this plan three things are true. First, a single new guide,
`docs/runbooks/server-operations.md`, walks an operator through day-2 platform operations
using `nagarectl server status` (is it healthy?), `nagarectl doctor` (what is wrong and how
do I fix it?), `nagarectl domains list` (what is my DNS/TLS state?), and `nagarectl cleanup`
(reclaim disk, prune previews and releases). Second, `docs/runbooks/cluster-access.md` keeps
its IAP-SSH access mechanics but now points "is the platform healthy?" at `server status` /
`doctor` instead of a hand-run `kubectl get nodes`. Third,
`docs/runbooks/disaster-recovery.md` keeps its full rebuild sequence, but each step's
"Observe:" assertions note that `nagarectl doctor` now checks many of them automatically,
and the backup-inventory section references `nagarectl server status` for freshness.

**You can see it working** by following the new guide's day-2 scenario top to bottom against
the real platform: the VM is `TERMINATED`; you start it with the documented `gcloud`
command; `nagarectl server status` prints a partial report with the still-cold facets as
`Unknown`/down; `nagarectl doctor` lists the `FAIL` lines, each carrying a remediation hint
and the exact command (re-apply the metadata route / MASQUERADE / coredns workarounds,
re-bootstrap, etc.); you copy-paste each fix; you re-run `nagarectl doctor` until every line
is `OK`; and `nagarectl domains list` shows the base domain and per-app DomainMappings
resolving. A newcomer recovers a dead platform to green using only the documented commands.
The guide is the acceptance test.


## Progress

- [ ] M1: `docs/runbooks/server-operations.md` written — one section per command (`server
  status`, `doctor`, `domains list`, `cleanup`) with real `--help`-matched transcripts, plus
  the end-to-end day-2 "TERMINATED → green" recovery scenario.
- [ ] M2: `docs/runbooks/cluster-access.md` and `docs/runbooks/disaster-recovery.md` updated
  in place to reference the new commands (health-check pointer in cluster-access; per-step
  "doctor checks this" notes + backup-freshness pointer in disaster-recovery), cross-linked
  to the new guide.
- [ ] M3: every documented command and flag verified against the real `nagarectl ... --help`;
  transcripts captured from the binary (degraded/partial form labelled as such if no cluster
  is reachable); newcomer read-through; no bare ``` fences; links resolve.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Ship the operator documentation as a separate, final ExecPlan (EP-42) rather than
  folding doc edits into EP-38..EP-41.
  Rationale: this matches the sibling MasterPlans' established pattern of a dedicated closing
  docs plan (e.g. EP-32 for MasterPlan 6's app lifecycle, EP-37 for MasterPlan 7). A docs plan
  can be drafted incrementally as commands land and finalized once all four merge, and it lets
  each implementation plan stay focused on a single command surface.
  Date: 2026-06-09

- Decision: Update the existing runbooks (`cluster-access.md`, `disaster-recovery.md`) in
  place rather than duplicating their content into the new guide.
  Rationale: the runbooks are the authoritative access and rebuild procedures; the MasterPlan's
  in-scope item is to "fold these commands into" them, "replacing manual procedures with
  command invocations where the command now covers them." Duplicating would create two
  divergent sources of truth. The new guide is the day-2 operations narrative; the runbooks
  keep their distinct jobs (how to reach the cluster, how to rebuild it) and gain pointers to
  the commands.
  Date: 2026-06-09

- Decision: Document every command and flag from its real `nagarectl ... --help` output, and
  capture transcripts from the built binary, rather than transcribing the sibling plans' spec
  prose.
  Rationale: the sibling plans' final `--help` and output formats are the source of truth; flag
  names and wording can drift during implementation. A docs initiative whose acceptance is
  "every command and transcript matches actual behavior" must read the shipped CLI, not the
  plan that proposed it.
  Date: 2026-06-09

- Decision: Place the new guide at `docs/runbooks/server-operations.md` (under `runbooks/`),
  not under a `docs/cli/` directory.
  Rationale: there is no `docs/cli/` directory in this repo — the EP-32 CLI guides landed in
  `docs/user/` and the operator procedures live in `docs/runbooks/` (`cluster-access.md`,
  `disaster-recovery.md`). This guide is an operator runbook (day-2 platform operations,
  recovery scenario) and belongs beside the two runbooks it cross-links, which the MasterPlan
  names as the integration targets.
  Date: 2026-06-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This plan edits Markdown only, under `docs/runbooks/`. No Haskell changes, no new code, no
new dependency. It documents the four commands the sibling plans add to the `nagarectl` CLI.

**Where docs live.** Operator procedures live under `docs/runbooks/`: today exactly two files,
`docs/runbooks/cluster-access.md` and `docs/runbooks/disaster-recovery.md`. User-facing CLI
and app guides live under `docs/user/` (`getting-started.md`, `deploying-apps.md`,
`app-lifecycle.md`, `config-reference.md`, `accessing-the-host.md`,
`backups-and-disaster-recovery.md`, `README.md` index, and others). There is **no**
`docs/cli/` directory — the EP-32 CLI documentation landed in `docs/user/`. This plan adds one
new runbook, `docs/runbooks/server-operations.md`, and edits the two existing runbooks in
place.

**The existing runbooks.** `docs/runbooks/cluster-access.md` is the "how to reach the cluster"
procedure: start the VM with `gcloud compute instances start nagare-01 --zone=us-west1-a`,
SSH over the IAP tunnel as the `deploy` user
(`SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 scripts/iap-ssh.sh ssh nagare-01 -- '...'`),
retrieve the k3s kubeconfig from `/etc/rancher/k3s/k3s.yaml` over a port-6443 tunnel, and the
pitfall that the workstation's default `kubectl` context points at an unrelated GKE cluster
(`tan-cluster`/`sennari`) so nagare commands must use `sudo k3s kubectl` on the VM or an
explicit tunneled `--kubeconfig`. `docs/runbooks/disaster-recovery.md` is the richest runbook:
a backup-inventory table (around lines 21–37), an eight-step rebuild sequence whose per-step
"Observe:" assertions *are* the platform health checks (cert-manager / knative-serving /
kourier-system pods `Running`; the `letsencrypt-dns` ClusterIssuer `READY=True`; the `hello`
ksvc `READY=True`; PVCs `Bound`; the Kourier `EXTERNAL-IP`), and a power-management section
noting the post-reboot host workarounds (the `169.254.169.254` metadata route, the
`MASQUERADE` POSTROUTING rule, and a `coredns` rollout restart) that do **not** survive a
plain `start`.

**The command surfaces to document** (from the four sibling plans; their final `--help` is the
source of truth):

- `nagarectl server status` (EP-38) — a one-screen, aligned inventory of the whole platform:
  VM power state, k3s node `Ready`, the Knative Serving / Kourier / cert-manager control-plane
  rollouts, the live base domain (Pulumi `baseDomain` output cross-checked against the
  in-cluster `config-domain` ConfigMap), the Kourier ingress `EXTERNAL-IP` vs the reserved
  `publicIp`, boot- and data-disk usage, Artifact Registry push-auth, and the age of the newest
  object in each `gs://tan-nb-exp-nagare-backups/` backup prefix. Degrades gracefully: an
  unreachable source yields an `Unknown` line, never a crash.
- `nagarectl doctor` (EP-39) — the same probes re-presented as an ordered `OK` / `WARN` /
  `FAIL` checklist; each non-OK line names the problem in plain language and prints the exact
  remediation command (for example, "VM is TERMINATED → run `gcloud compute instances start
  nagare-01 --zone=us-west1-a`"). Returns a non-zero exit code on any `FAIL`, so it is
  scriptable.
- `nagarectl domains list` (EP-40) — the base domain plus every Knative `DomainMapping`, each
  with its owning Service, its DNS expectation (wildcard `A` → `publicIp`), and its certificate
  readiness. TLS may be disabled today (v1 is HTTP-first; Let's Encrypt wildcard TLS is opt-in
  via `just cluster-enable-tls`); document that state honestly.
- `nagarectl cleanup [--confirm] [--images] [--previews] [--releases]` (EP-41) — reclaims
  reclaimable container images on the node, stale static previews past their TTL, and
  release-history entries beyond a retention count. Defaults to a **dry-run** showing what
  *would* be removed; `--confirm` is required to act; the per-target flags scope the run.

**The docs precedent.** `docs/plans/32-application-lifecycle-docs-and-end-to-end-examples.md`
is the closing docs plan for MasterPlan 6 and the template for this one. It established the
house style for this repo's docs: an H1 title, a short status box using a colored-circle emoji
and plain-English status (e.g. "🟡 Works, but live testing pending"), a "Commands at a glance"
fenced `text` block, one section per command with a real transcript, and a "How it works"
callout. Its output (`docs/user/app-lifecycle.md`) shows the exact formatting conventions and
the deferred-cluster pattern (mark transcripts captured by dry-run / partial run when
`nagare-01` is down). Read both that plan and `docs/user/app-lifecycle.md` before writing, to
match voice and structure.

**Project isolation.** Per `CLAUDE.md`, every `gcloud`/`gsutil`/`pulumi` command shown in these
docs targets project `tan-nb-exp`, region `us-west1`, zone `us-west1-a`. The `gcloud compute
instances start nagare-01 --zone=us-west1-a` and the `gs://tan-nb-exp-nagare-backups/` bucket
in the existing runbooks already reflect this; keep new commands consistent.


## Plan of Work

The work is three milestones: write the new guide (M1), integrate the two existing runbooks
(M2), and verify everything against the real CLI and capture transcripts (M3). Each is
independently verifiable. Because the plan soft-depends on all four commands, a section may be
drafted against the sibling plan's spec before its command lands and then reconciled against
the real `--help` in M3.

### Milestone 1 — The server-operations guide

**Scope:** create `docs/runbooks/server-operations.md`, the day-2 operations runbook, in the
EP-32 house style. This is the bulk of the plan.

Create `docs/runbooks/server-operations.md` with:

1. H1 title (`# Nagare server-operations runbook`), a one-line status box (e.g. "🟡 Commands
   shipped; live transcripts captured in partial form while `nagare-01` is down — see status
   notes"), and a one-paragraph intro naming the audience ("for the **operator**") and the
   promise: "Run the whole platform's day-2 operations from `nagarectl` — check health,
   diagnose and fix problems, inspect domains, and reclaim disk — without remembering which of
   `gcloud`/`kubectl`/`gsutil` answers which question." Note the project-isolation invariant
   (`tan-nb-exp` / `us-west1` / `us-west1-a`) and link to `cluster-access.md` for the SSH /
   kubeconfig prerequisites the commands assume.
2. A "Commands at a glance" fenced `text` block listing the four commands and their one-line
   jobs (mirroring the MasterPlan's Vision block).
3. One section per command, each with a real transcript and an "Expected output shape" framing:
   - **Is it healthy? — `nagarectl server status`.** Show the aligned inventory table and call
     out the graceful-degradation behavior (`Unknown` lines when the VM is off or a source is
     unreachable). Note it is read-only.
   - **What is wrong and how do I fix it? — `nagarectl doctor`.** Show the `OK`/`WARN`/`FAIL`
     checklist with remediation hints, and document the non-zero exit code on `FAIL` (so it can
     gate a script). Show at least one `FAIL` line with its remediation command verbatim.
   - **What is my DNS/TLS state? — `nagarectl domains list`.** Show the base domain +
     per-app DomainMapping table with DNS expectation and certificate readiness; document the
     TLS-disabled (HTTP-first) state and how `just cluster-enable-tls` changes it.
   - **Reclaim disk — `nagarectl cleanup`.** Show a `--dry-run` (default) transcript first, then
     the `--confirm` form; document `--images` / `--previews` / `--releases` scoping and that
     dry-run is the default safety.
4. A **day-2 recovery scenario** section — the end-to-end narrative that is this plan's
   acceptance test. Walk: VM `TERMINATED` → `gcloud compute instances start nagare-01
   --zone=us-west1-a` → `nagarectl server status` shows a partial report → `nagarectl doctor`
   lists the `FAIL` lines (metadata route / MASQUERADE / coredns workarounds from
   disaster-recovery.md, plus any rollout/backup failures) each with its fix command → apply the
   fixes → re-run `nagarectl doctor` until every line is `OK` → `nagarectl domains list`
   confirms domains resolve. Cross-link the workarounds to `disaster-recovery.md`'s power-
   management section so the guide does not duplicate them.
5. A short "How it works / what it reads" callout: the commands shell out to the same local
   tooling (`gcloud`, `pulumi`, `gsutil`, `kubectl`, IAP-SSH) an operator would run by hand;
   `doctor` re-grades the same probes `server status` gathers; nothing here is a daemon. Link to
   the MasterPlan and to `cluster-access.md`.

**Acceptance:** `docs/runbooks/server-operations.md` exists; every command and flag shown
matches the real `nagarectl ... --help` (verified in M3); every fenced block has a language tag;
and a reader can follow the day-2 scenario end to end. For any command not yet landed, the
section carries a "lands with EP-NN" note and is reconciled in M3.

### Milestone 2 — Integrate the existing runbooks

**Scope:** edit `docs/runbooks/cluster-access.md` and `docs/runbooks/disaster-recovery.md` in
place so they point at the new commands where a command now covers a manual step, without losing
the access mechanics or the rebuild sequence.

In `docs/runbooks/cluster-access.md`:

- In "The cluster" section, after the `gcloud compute instances start` step, add that the fast
  way to answer "is the platform healthy after it boots?" is now `nagarectl server status` (one
  report) or `nagarectl doctor` (graded checklist with fixes), instead of eyeballing
  `kubectl get nodes`. Keep the existing `kubectl get nodes` confirmation as the low-level check.
- Keep the SSH / `deploy`-user / kubeconfig / wrong-default-context sections unchanged — those
  are the access mechanics the new commands depend on. Add a one-line pointer near the top to
  `server-operations.md` for day-2 operations once access is established.

In `docs/runbooks/disaster-recovery.md`:

- In each rebuild step whose "Observe:" assertion is a health check (steps 4 "Bootstrap the
  cluster platform" — cert-manager/knative/kourier `Running`, `letsencrypt-dns` `READY=True`,
  `hello` ksvc `READY=True`; step 5 "Install observability" — PVCs `Bound`; and the Kourier
  `EXTERNAL-IP`), add a short note that `nagarectl doctor` now checks these automatically, so
  after a step the operator can run `nagarectl doctor` to confirm the same assertions in one
  command instead of by hand. Do **not** remove the manual `kubectl`/`curl` assertions — they
  remain the ground-truth fallback when the CLI is unavailable mid-rebuild.
- In the "Backup inventory" section (around lines 21–37), add a line that
  `nagarectl server status` reports the freshness (newest-object age) of each
  `gs://tan-nb-exp-nagare-backups/` prefix, so an operator can confirm backups are current
  without a manual `gsutil ls -l`.
- In the "Power management" section, where the post-reboot workarounds (metadata route /
  MASQUERADE / coredns) are listed, add that `nagarectl doctor` will flag the resulting failures
  (e.g. in-cluster ADC / image pulls failing) with these exact remediation commands, and
  cross-link to the day-2 scenario in `server-operations.md`.
- Add a cross-link from the top of disaster-recovery.md to `server-operations.md` for routine
  (non-rebuild) health checks.

**Acceptance:** both runbooks reference the relevant command where it now covers a manual step,
the access mechanics and rebuild sequence are intact, every edited fenced block keeps its
language tag, and the three runbooks cross-link each other coherently.

### Milestone 3 — Verify against the real CLI and capture transcripts

**Scope:** make the docs truthful. For every command and flag documented in M1/M2, confirm it
against the real `nagarectl ... --help`, replace any placeholder/spec transcripts with output
captured from the built binary, and do a newcomer read-through.

Steps:

- Build the CLI and capture `--help` for each command (`server`, `server status`, `doctor`,
  `domains`, `domains list`, `cleanup`). Diff every flag and option name shown in the docs
  against the real help; fix any drift. Remove any "lands with EP-NN" note whose command has
  merged.
- Capture real transcripts. If a live cluster (`nagare-01`) is reachable, run each command and
  paste the real output. If it is not reachable, capture the inventory/doctor transcripts in
  their **degraded/partial** form (VM off / no kubeconfig → `Unknown`/down lines) and label them
  as such in the doc; this is the honest, documentation-true state and matches how EP-32's
  guide handled the powered-down box.
- Newcomer read-through of `server-operations.md`: confirm the day-2 scenario can be followed
  start to finish with only the documented commands and the cross-linked workarounds.
- Lint: no bare ``` fences (every block has a language tag) in the new and edited files; all
  intra-doc links resolve.

**Acceptance:** every documented command/flag matches the real `--help`; transcripts are from
the binary (degraded form labelled if no cluster); read-through passes; lints and links pass.


## Concrete Steps

All paths are absolute or relative to the repo root `/Users/shinzui/Keikaku/bokuno/nagare`.
There is no doc build; docs are read as Markdown in the repo. The "test" is that every command
shown runs and matches its captured output.

**M1/M2 — author the Markdown.** Write `docs/runbooks/server-operations.md` and edit
`docs/runbooks/cluster-access.md` and `docs/runbooks/disaster-recovery.md` per the Plan of Work.

**M3 — verify against the real CLI.** Build and query help from the CLI package:

```bash
cd cli/nagarectl
cabal build
cabal run nagarectl -- server status --help
cabal run nagarectl -- doctor --help
cabal run nagarectl -- domains list --help
cabal run nagarectl -- cleanup --help
```

Expected output shape (each is a standard `optparse-applicative` usage block; flag names are the
contract to match in the docs):

```text
Usage: nagarectl cleanup [--confirm] [--images] [--previews] [--releases]
  Reclaim disk: prune container images, stale previews, and old releases (dry-run by default)

Available options:
  --confirm     Actually delete (default is a dry run)
  --images      Limit to reclaimable container images
  --previews    Limit to stale static previews
  --releases    Limit to old release-history entries
  -h,--help     Show this help text
```

(The exact wording is whatever the shipped binary prints; copy it verbatim.)

**Capture command transcripts.** With the platform reachable (start the VM first per
`cluster-access.md`):

```bash
cd cli/nagarectl
cabal run nagarectl -- server status
cabal run nagarectl -- doctor
cabal run nagarectl -- domains list
cabal run nagarectl -- cleanup            # dry-run; safe, mutates nothing
```

Expected output shape — `server status` is an aligned inventory; if `nagare-01` is `TERMINATED`
or no kubeconfig is present, the cluster-dependent rows degrade to `Unknown` and the doc
transcript is labelled "captured with the VM off (partial)":

```text
VM nagare-01 ............... RUNNING
k3s node .................. Ready
Knative Serving ........... rolled out
Kourier ingress ........... EXTERNAL-IP 34.x.x.x = publicIp
cert-manager .............. rolled out
base domain ............... apps.example.com (matches config-domain)
boot disk ................. 38% of 100G
data disk (/var/lib/nagare) 12% of 50G
Artifact Registry auth .... configured
backups (sqlite) .......... newest 6h ago
backups (postgres) ........ newest 6h ago
```

`doctor` re-presents the same probes as a graded checklist with remediation hints and exits
non-zero on any `FAIL`:

```text
[OK]   VM nagare-01 is RUNNING
[FAIL] in-cluster metadata route missing
       fix: ip route replace 169.254.169.254/32 via "$GW" dev eth0
[FAIL] coredns not resolving upstream
       fix: kubectl -n kube-system rollout restart deploy/coredns
[OK]   backups (sqlite) newest 6h ago
```

**Lint for bare fences and check links:**

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
rg -n '^```$' docs/runbooks/server-operations.md docs/runbooks/cluster-access.md docs/runbooks/disaster-recovery.md \
  && echo "FOUND bare fences — add a language tag" || echo "all fences tagged"
```

This section is updated as work proceeds with the actual captured transcripts.


## Validation and Acceptance

1. `docs/runbooks/server-operations.md` exists, covers all four commands (`server status`,
   `doctor`, `domains list`, `cleanup`) with their flags, and contains a day-2 "TERMINATED →
   green" recovery scenario a newcomer can follow end to end using only documented commands and
   cross-linked workarounds.
2. Every documented command and flag matches the real `nagarectl ... --help` output (verified by
   running each `--help` in M3 and diffing flag names and usage against the docs). Any drift is
   fixed; any "lands with EP-NN" note for a merged command is removed.
3. `docs/runbooks/cluster-access.md` points "is the platform healthy?" at `nagarectl server
   status` / `nagarectl doctor` while keeping the SSH / kubeconfig / wrong-default-context access
   mechanics intact.
4. `docs/runbooks/disaster-recovery.md` notes, on each health-check "Observe:" step, that
   `nagarectl doctor` checks it automatically; references `nagarectl server status` for backup
   freshness; cross-links the post-reboot workarounds to the day-2 scenario; and keeps its full
   rebuild sequence and manual fallbacks.
5. A newcomer read-through of `server-operations.md` succeeds (the scenario is followable).
6. No bare ``` fences in any new or edited doc (every block carries a language tag); all
   intra-doc links resolve.

Command transcripts are captured from the real binary; if no cluster is reachable, the
inventory/doctor transcripts are captured in their degraded/partial form and labelled as such.


## Idempotence and Recovery

This plan edits and adds Markdown only; there is no state to corrupt and every step is safe to
redo. Re-running the `--help` and transcript-capture commands is read-only (and `nagarectl
cleanup` defaults to a dry-run, so even capturing its transcript mutates nothing — only the
`--confirm` form acts, which the doc does not need to run live). Re-running the fence/link lints
is read-only. Edits can be reapplied freely; if a section drifts from the real CLI, re-capture
the `--help` and overwrite the block. Recover from a bad edit with `git checkout`.


## Interfaces and Dependencies

This plan adds **no code and no dependency**. It is pure documentation. Its only "interface" is
that the documented commands, flags, and output formats match what the sibling plans shipped —
re-read each plan's final Interfaces / Concrete Steps section before writing, in case a flag name
or output line changed during implementation.

The command surfaces documented here are delivered by the four sibling plans, which are the
source of truth:

- `docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md` — the
  `Nagare.Ops` probe layer and `nagarectl server status` (the inventory report and its
  graceful-degradation `Unknown` lines).
- `docs/plans/39-nagarectl-doctor-health-checks-with-remediation-hints.md` — `nagarectl doctor`
  (the `OK`/`WARN`/`FAIL` checklist, remediation hints, and non-zero exit code on `FAIL`).
- `docs/plans/40-nagarectl-domains-list-with-dns-and-certificate-readiness.md` — `nagarectl
  domains list` (base domain + per-app DomainMappings with DNS expectation and certificate
  readiness).
- `docs/plans/41-nagarectl-cleanup-for-images-previews-and-releases.md` — `nagarectl cleanup`
  (the `--confirm` / `--images` / `--previews` / `--releases` flags and the dry-run default).

The `nagarectl` binary is the Haskell CLI at `cli/nagarectl/`; its `--help` output is the
authority for the documented flags. Build and query it from `cli/nagarectl` with `cabal build`
then `cabal run nagarectl -- <args>`. The docs it produces live under `docs/runbooks/` alongside
`cluster-access.md` and `disaster-recovery.md`.
