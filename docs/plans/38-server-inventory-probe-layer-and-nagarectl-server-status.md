---
id: 38
slug: server-inventory-probe-layer-and-nagarectl-server-status
title: "Server inventory probe layer and nagarectl server status"
kind: exec-plan
created_at: 2026-06-10T04:34:52Z
intention: "intention_01ktqwqc61e519h77zqdf3ngs3"
master_plan: "docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md"
---

# Server inventory probe layer and nagarectl server status

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [38-server-inventory-probe-layer-and-nagarectl-server-status.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today an operator who wants to know whether the Nagare platform is healthy has to stitch the
answer together by hand: run `gcloud compute instances describe nagare-01` to see if the VM is
even powered on, open an IAP-tunnelled SSH session to run `df -h`, run `kubectl rollout status`
in four namespaces, compare the Kourier `EXTERNAL-IP` against the Pulumi `publicIp` output by
eye, and run `gsutil ls -l` to see when the last backup landed. Nothing ties these together and
nothing tells a newcomer what a bad result means. This plan replaces that scavenger hunt with a
single command that prints a one-screen, aligned health report of the whole platform:

```text
nagarectl server status
```

After this plan, that command prints — in one aligned table — the power state of the VM
`nagare-01` (RUNNING / TERMINATED), whether the k3s node is `Ready`, whether the Knative
Serving / Kourier / cert-manager / net-certmanager control-plane deployments are rolled out, the
live base domain (read from the Pulumi `baseDomain` stack output and cross-checked against the
in-cluster `config-domain` ConfigMap), the Kourier ingress `EXTERNAL-IP` and whether it equals
the reserved `publicIp`, the boot-disk and `/var/lib/nagare` data-disk usage, whether Artifact
Registry push auth is configured, and the age of the most recent object in each backup prefix of
`gs://tan-nb-exp-nagare-backups/`. Every line is tagged `OK` / `WARN` / `UNKNOWN` / `FAIL`, and a
probe whose data source is unreachable (the VM is off, no kubeconfig, `gsutil`/`pulumi` not on
PATH) degrades to an `UNKNOWN`/`WARN` line with a short hint rather than crashing the command — so
the report is always printed, partial-but-clear, never a stack trace.

Underneath the command, this plan builds a reusable, typed probe layer under
`cli/nagarectl/src/Nagare/Ops/` (modules `Nagare.Ops.Probe`, `Nagare.Ops.Pulumi`,
`Nagare.Ops.Status`) whose pure parsers and formatters are unit-tested without a live cluster.
That layer is the foundation that the sibling plans build on: `nagarectl doctor`
(`docs/plans/39-nagarectl-doctor-health-checks-with-remediation-hints.md`) re-grades the same
`Probe` values into remediation checks, and `nagarectl domains list`
(`docs/plans/40-nagarectl-domains-list-with-dns-and-certificate-readiness.md`) and
`nagarectl cleanup` (`docs/plans/41-nagarectl-cleanup-for-images-previews-and-releases.md`) reuse
its base-domain resolver and table formatting.

You can see it working end-to-end: with your `kubectl` context pointing at the k3s cluster and
`gcloud`/`pulumi`/`gsutil` on PATH, run `nagarectl server status`. It prints a table whose first
line is the VM power state and whose remaining lines walk down the platform — node, control
planes, ingress IP match, base domain match, disk usage, registry auth, backup ages — each marked
`OK`/`WARN`/`UNKNOWN`/`FAIL`. Power the VM off (`gcloud compute instances stop nagare-01
--zone=us-west1-a`) and re-run: the VM line reads `FAIL TERMINATED`, the k3s/control-plane/disk
lines that depend on the VM degrade to `UNKNOWN` with a hint, and the command still exits cleanly
having printed the whole report.

## Progress

- [x] M1 (2026-06-10): `Nagare.Ops.Probe` (the `ProbeStatus`/`Probe` types, `InventoryOpts`, the external-tool wrappers `captureTool`/`runMaybe`, and the pure parsers/formatters) plus `Nagare.Ops.Pulumi.stackOutput`; both added to the cabal library; `testGroup "Nagare.Ops"` (16 cases) covering the pure helpers — all green.
- [x] M2 (2026-06-10): `gatherInventory` in `Nagare.Ops.Status` wiring every probe (VM, k3s node, Knative controller/webhook, Kourier gateway, cert-manager + webhook + cainjector, net-certmanager, ClusterIssuer, Kourier IP vs publicIp, base domain, external-domain-tls info, registry auth, backup freshness ×3, boot+data disk) with graceful degradation; compiles, typechecks.
- [x] M3 (2026-06-10): `server status` command registered in `cli/nagarectl/app/Main.hs` (a `server` group whose first subcommand is `status`); the `runServerStatus` handler renders the report via `renderInventory` and always exits 0.
- [x] M4 (2026-06-10): `nagarectl-test` green (134 tests) + `server --help`/`server status --help` transcripts captured below; graceful-degradation demo captured (empty-PATH run → all `UNKNOWN`, exit 0); live cluster run deferred (GCP isolation + VM commonly `TERMINATED`).

## Surprises & Discoveries

- 2026-06-10 (M2): The `Nagare.Dsl.Prelude` re-exports `Control.Lens`, so the
  `&` operator used by `cradle` (`cmd … & addArgs …`) and the lens `&` coexist
  without ambiguity — confirmed by the existing `Nagare.App`/`Nagare.Image`
  modules, which do exactly this. The new `Nagare.Ops.*` modules follow the same
  `import Nagare.Dsl.Prelude` + explicit-qualified-imports style.
- 2026-06-10 (M2): Added a `cert-manager-cainjector` Deployment probe and an
  informational `external-domain-tls` line beyond the sketch in the plan body,
  because the real cluster-bootstrap deploys the cainjector and the
  `config-network-tls` ConfigMap; both fit the same `probeDeploy`/`runMaybe`
  shape and degrade gracefully.
- 2026-06-10 (M3): The longest probe name, `cert-manager-cainjector` (23 chars),
  overflowed the initial 22-wide CHECK column and was truncated. Widened the
  `renderInventory` CHECK column to 25 (and updated the formatter unit test
  accordingly) so every probe name renders in full.
- 2026-06-10 (M4): Graceful degradation was demonstrated without any live GCP /
  cluster calls by running the built binary with `PATH=/var/empty`: every probe
  reported `UNKNOWN` (or `FAIL` for the VM, when `gcloud` is reachable but the VM
  is `TERMINATED`), the full report printed, and the command exited 0 — proving
  the IP4 convention with zero external side effects and no risk to the GCP
  project-isolation rule.

## Decision Log

- Decision: Bundle the reusable probe layer with `nagarectl server status` in this one plan rather
  than shipping a behavior-less "foundations" plan. The probe types (`ProbeStatus`/`Probe`), the
  external-tool wrappers, and the pure parsers/formatters live in `cli/nagarectl/src/Nagare/Ops/`
  and are exercised by `server status` as their first real consumer.
  Rationale: A foundation plan with no user-visible behavior would violate the MasterPlan
  requirement that every work stream produce a demonstrable outcome; folding `server status` in
  gives the foundation a runnable proof while still leaving the types as the dependency root EP-39
  consumes.
  Date: 2026-06-09

- Decision: The access model is: `kubectl` runs against the operator's *ambient* context exactly as
  every existing `nagarectl` command assumes (no kubeconfig management, no `--context` flag);
  `gcloud`/`pulumi`/`gsutil` run locally and default to project `tan-nb-exp` (region `us-west1`,
  zone `us-west1-a`) per the repo's `.envrc`, with explicit flags where reasonable; the VM disk
  probe is best-effort over `scripts/iap-ssh.sh` invoked as `SSH_USER=deploy
  SSH_KEY=~/.ssh/id_ed25519`.
  Rationale: Matches the assumption of every existing command and the project-isolation rule in
  `CLAUDE.md`. The workstation's *default* kubectl context points at an unrelated GKE cluster
  (`tan-cluster`), so the report documents that pitfall but does not try to fix the operator's
  context for them.
  Date: 2026-06-09

- Decision: Backup freshness is defined purely as the age of the *newest* object in each GCS backup
  prefix (`gs://tan-nb-exp-nagare-backups/{postgres,litestream,volumes}/`), read via `gsutil ls -l`.
  Rationale: No host-level backup systemd timer exists yet — backups are manual scripts under
  `scripts/` (e.g. `scripts/backup-postgres.sh`) — so there is no schedule to compare against;
  "freshness" can only mean "how long since the last object landed". Building a scheduler is out of
  scope (it belongs to a future databases/backups initiative).
  Date: 2026-06-09

- Decision: The base-domain probe reads the authoritative value from Pulumi (`pulumi -C
  infra/pulumi stack output baseDomain`) via a new `Nagare.Ops.Pulumi.stackOutput` helper and
  cross-checks it against the in-cluster `config-domain` ConfigMap; the existing `resolveBaseDomain`
  in `cli/nagarectl/app/Main.hs` (which reads only a flag/env/literal fallback) is left untouched
  for the deploy path.
  Rationale: `resolveBaseDomain` deliberately does not read Pulumi and must keep its
  flag/env/literal behavior for offline deploys; the *probe* needs the authoritative Pulumi value to
  meaningfully report drift. EP-40 (`domains list`) reuses `Nagare.Ops.Pulumi.stackOutput` rather
  than re-implementing it.
  Date: 2026-06-09

## Outcomes & Retrospective

Delivered the reusable `Nagare.Ops.*` probe layer and the first consumer,
`nagarectl server status`. Three new library modules
(`cli/nagarectl/src/Nagare/Ops/Probe.hs`, `…/Pulumi.hs`, `…/Status.hs`) are
exposed from `nagarectl.cabal`; the `server status` command is registered in
`cli/nagarectl/app/Main.hs` (new `ServerStatus ServerStatusOpts` constructor,
`serverStatusOptsParser` with `--skip-vm`, a `server` command group, a
`runServerStatus` handler, and a `main` dispatch arm). All 134 tests pass,
including the new 16-case `testGroup "Nagare.Ops"` over the pure parsers and the
formatter.

Captured transcripts (2026-06-10):

```text
$ nagarectl server --help
Usage: nagarectl server COMMAND

  Server and platform inventory

Available options:
  -h,--help                Show this help text

Available commands:
  status                   One-screen platform health report

$ nagarectl server status --help
Usage: nagarectl server status [--skip-vm]

  One-screen platform health report

Available options:
  --skip-vm                Skip the IAP-SSH disk probe (no SSH setup needed)
  -h,--help                Show this help text
```

Graceful-degradation demo (built binary, `PATH=/var/empty` so no external tool
is reachable — every probe degrades and the command exits 0):

```text
$ PATH=/var/empty nagarectl server status
  STATUS   CHECK                    DETAIL
  UNKNOWN  VM                       gcloud unavailable or no access
  UNKNOWN  k3s node                 no kubeconfig / not reachable
  UNKNOWN  Knative controller       no kubeconfig / not reachable
  UNKNOWN  Knative webhook          no kubeconfig / not reachable
  UNKNOWN  Kourier gateway          no kubeconfig / not reachable
  UNKNOWN  cert-manager             no kubeconfig / not reachable
  UNKNOWN  cert-manager-webhook     no kubeconfig / not reachable
  UNKNOWN  cert-manager-cainjector  no kubeconfig / not reachable
  UNKNOWN  net-certmanager          no kubeconfig / not reachable
  UNKNOWN  ClusterIssuer            letsencrypt-dns not reachable
  UNKNOWN  Kourier ingress          no kubeconfig / not reachable
  UNKNOWN  base domain              config-domain not reachable
  UNKNOWN  external-domain-tls      config-network-tls not reachable
  UNKNOWN  Artifact Registry        gcloud unavailable or no access
  UNKNOWN  backup postgres          gsutil unavailable or prefix empty
  UNKNOWN  backup litestream        gsutil unavailable or prefix empty
  UNKNOWN  backup volumes           gsutil unavailable or prefix empty
  UNKNOWN  disk                     iap-ssh unavailable (VM off? key not set?)
$ echo $?
0
```

What changed from the plan: (1) the CHECK column is 25 wide, not 22, so the
longest probe name fits; (2) `gatherInventory` includes a
`cert-manager-cainjector` Deployment probe and an informational
`external-domain-tls` line in addition to the plan's sketch. Neither affects the
IP1 types EP-39 reads back. The live cluster run is deferred (per the plan's M4
convention and the GCP project-isolation rule); the parser/formatter behavior is
covered by unit tests and the degradation demo above.

Integration handoff: IP1 (`ProbeStatus`/`Probe`/`InventoryOpts`), IP2
(`Nagare.Ops.Pulumi.stackOutput`), IP3 (the `server` command-group pattern in
`Main.hs`), and IP4 (`captureTool`/`runMaybe` + degradation convention) are all
in place and stable for EP-39/40/41 to consume.

