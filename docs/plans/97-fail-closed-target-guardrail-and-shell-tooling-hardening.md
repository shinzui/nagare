---
id: 97
slug: fail-closed-target-guardrail-and-shell-tooling-hardening
title: "Fail-closed target guardrail and shell tooling hardening"
kind: exec-plan
created_at: 2026-07-16T04:25:03Z
intention: intention_01kzakvy1qeasagg3rpbn44749
master_plan: "docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T13:31:15Z
      mode: "update"
      note: "Reconcile deferred validation against tan-ng-labs and later plan evidence"
---

# Fail-closed target guardrail and shell tooling hardening

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [97-fail-closed-target-guardrail-and-shell-tooling-hardening.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/97-fail-closed-target-guardrail-and-shell-tooling-hardening.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

nagare is a personal single-node PaaS: Pulumi provisions GCP infrastructure, NixOS +
k3s run the node, Knative serves the apps, a Haskell CLI (`nagarectl`) and a set of
bash scripts operate it. The repository's central operating rule (see `CLAUDE.md` at
the repo root, section "GCP project isolation") is that every cloud action targets
exactly one GCP project — the one declared by the *active target context* — and that
the guardrail enforcing this is **fail-closed**: a script must refuse to run rather
than act on the wrong project.

A platform review found that this guardrail is currently a **tautology**: the check in
`scripts/lib/target.sh` compares a value against itself, so it can never fail, and a
stale `CLOUDSDK_CORE_PROJECT` exported in the operator's shell silently retargets
every derived name (buckets, registry, instance) at a different project while the
"guardrail" waves it through. The review also found that the local-mode loopback
assertion can be bypassed by any `sslip.io`/`nip.io` domain (they encode *arbitrary*
IPs, not just loopback), that an invalid current-context pointer silently falls back
to defaults instead of erroring, that sourcing `target.sh` truncates the Pulumi
passphrase file on every load, and a series of smaller but real hazards: `justfile`
recipes that bypass the guardrail entirely, smoke-test cleanup traps that can fire
against an *ambient* kubectl context (for this operator, a real GKE cluster), a
`pkill` pattern that never matches, a Pulumi-backend migration script that can mutate
a same-named GCS bucket owned by a *foreign* project, and unquoted/unsafe temp-file
idioms.

After this plan is implemented, every one of those holes is closed and each closure is
demonstrable: exporting `CLOUDSDK_CORE_PROJECT=wrong-project` and calling the guardrail
exits non-zero with an actionable message; a `mode=local` context whose base domain is
`34-120-1-1.sslip.io` is rejected; `just vm-stop` refuses to run when gcloud disagrees
with the context; a smoke test that dies before its harness is ready prints
"skipping cluster cleanup" instead of deleting apps from whatever cluster the shell
happened to point at; and `shellcheck --severity=error` stays clean over all scripts.

## Progress

- [x] M1: capture the context-declared project (`_NAGARE_CTX_PROJECT`) in `_nagare_resolve_context` before the env snapshot is re-applied. (2026-08-05)
- [x] M1: rewrite the cloud branch of `_require_target_project` so it is no longer a tautology (declared-project assertion + gcloud cross-check fallback). (2026-08-05)
- [x] M1: replace the local-mode base-domain blacklist with a loopback whitelist (127.* encoded sslip.io/nip.io, localhost, *.localhost). (2026-08-05)
- [x] M1: replace the local-mode registry-host blacklist with a loopback whitelist (localhost[:port], *.localhost[:port], 127.*[:port]). (2026-08-05)
- [x] M1: make an invalid (non-empty, malformed) current-context pointer fail closed like the not-found branch. (2026-08-05)
- [x] M1: stop truncating the Pulumi passphrase file on every `target.sh` source (guard with `[ -f ]`). (2026-08-05)
- [x] M1: run the M1 negative/positive guardrail probes and record transcripts. (2026-08-05 — all of M1-a…M1-e behaved as documented; transcripts in Surprises & Discoveries)
- [x] M1: commit M1 with Conventional Commit message + MasterPlan/ExecPlan trailers. (2026-08-05)
- [x] M1 (added): update the file header comment in `scripts/lib/target.sh` so its description of `_require_target_project` matches the new two-branch behavior. (2026-08-05)
- [x] M2: create `scripts/vm-power.sh` (guardrail-routed VM start/stop) and make it executable. (2026-08-05)
- [x] M2: point `justfile` `vm-stop` / `vm-start` at `scripts/vm-power.sh`. (2026-08-05)
- [x] M2: hard-fail `justfile` `cluster-bootstrap` when `pulumi stack output baseDomain` is empty. (2026-08-05)
- [x] M2: assert GCS bucket ownership (project number) in `scripts/migrate-pulumi-backend.sh` before any update/IAM/import. (2026-08-05)
- [x] M2: replace the unescaped `sed` interpolation in `set_context_var` with a `grep -v` + `printf` rewrite. (2026-08-05)
- [x] M2: guard the rollback-path passphrase truncation in `scripts/migrate-pulumi-backend.sh` (same bug class as target.sh). (2026-08-05)
- [x] M2: run M2 validation and record transcripts. (2026-08-05 — M2-a/b/c pass; M2-d verified statically, the live foreign-bucket check remains credential-gated)
- [x] M2: commit M2 with Conventional Commit message + trailers. (2026-08-05)
- [x] M2 live M2-d probe: EP-116's first real backend-migration run exposed a gcloud output-format
  incompatibility, fixed it with `--raw`, then verified that the ownership guard accepts the target
  bucket and refuses a foreign bucket before re-running the approved migration. (Reconciled
  2026-09-15 from EP-116's 2026-09-12 live transcript.)
- [x] M3: guard `scripts/live-smoke.sh` cleanup on a harness-ready flag and fix the `pkill` pattern to use the instance name. (2026-08-05)
- [x] M3: guard `scripts/local-smoke.sh` cleanup on a harness-ready flag and split the SC2155 `export KUBECONFIG` line. (2026-08-05)
- [x] M3: quote the remote path in `scripts/iap-ssh.sh` `recv-file` with `printf '%q'`. (2026-08-05)
- [x] M3: replace the fixed `/tmp/nagare-nix-build.err` in `scripts/upload-images.sh` with `mktemp`. (2026-08-05)
- [x] M3: run shellcheck (error severity over all scripts; default severity over touched scripts). (2026-08-05 — error severity clean; `SC2155` count in local-smoke is 0)
- [x] M3 (split from the shellcheck item): run the hermetic `shellcheck-scripts` flake check. (2026-08-05 — `nix build .#checks.aarch64-darwin.shellcheck-scripts` PASSES)
- [x] M3 full flake gate: the dependency-authentication blocker was subsequently removed. The
  released v0.3.0 candidate at current HEAD passed the full flake gates, including all 29 buildable
  native root-flake checks; the shell hardening remains in that released tree. (Reconciled
  2026-09-15 from EP-139 and `docs/releases/v0.3.0.md`.)
- [x] M3: commit M3 with Conventional Commit message + trailers; fill in Outcomes & Retrospective. (2026-08-05)
- [ ] M3 (deferred, operator-run): the positive `just local-smoke` end-to-end run printing `local smoke: OK`. Docker is up on this machine but no `nagare-local` k3d cluster exists, so the run would stand up a fresh cluster; the specific risk this plan introduces to local mode (the tightened loopback whitelist) was instead proven directly — see Surprises & Discoveries.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**`shellcheck` is not in the dev shell.** The plan's lint commands assume
`shellcheck` is on `PATH` inside `nix develop`. It is not — `flake.nix` only
pulls `pkgs.shellcheck` into the hermetic `shellcheck-scripts` check derivation
(lines 117–123). Run it ad hoc instead:

```bash
nix shell nixpkgs#shellcheck --command shellcheck --severity=error scripts/lib/target.sh
```

This is what every lint step in this plan was actually executed with.

**The guardrail's reach depends on whether the resolved context *changed*.** The
pre-existing unset loop in `_nagare_resolve_context` (the
`NAGARE_RESOLVED_CONTEXT != selkey` branch) clears every context variable before
the ambient snapshot is taken. So a stale `CLOUDSDK_CORE_PROJECT` is discarded
outright when the operator switches contexts inside one shell, and is caught by
the new assertion when the context is unchanged. Both paths are safe — either
the context's project wins or the run is refused — but only the second produces
the refusal message. Evidence:

```text
=== stale override, resolved context CHANGES (:inrepo: -> ctx:probe) ===
target=probe-project declared=probe-project
exit=0
=== stale override, resolved context UNCHANGED (ctx:probe) ===
target=wrong-project declared=probe-project
refusing to run: effective project 'wrong-project' does not match the active context's declared project 'probe-project' (context: probe).
exit=1
```

**M1 probe transcripts.** The tautology is demonstrably dead (M1-a), agreement
still passes offline with no gcloud on `PATH` (M1-b):

```text
--- M1-a: stale ambient project (expect exit=1) ---
refusing to run: effective project 'wrong-project' does not match the active context's declared project 'probe-project' (context: probe).
fix: unset the ambient CLOUDSDK_CORE_PROJECT override, or select the context that declares 'wrong-project' (NAGARE_CONTEXT=<name> or 'nagarectl context use <name>').
exit=1
--- M1-b: no override (expect exit=0) ---
exit=0
--- M1-b: agreeing override (expect exit=0) ---
exit=0
--- M1-b: no gcloud on PATH (expect exit=0) ---
exit=0
```

The loopback whitelist (M1-c) rejects every public-IP encoding and accepts every
loopback form, including the one this repository actually ships:

```text
  34-120-1-1.sslip.io           -> exit=1
  127-0-0-1-34-120-1-1.sslip.io -> exit=1
  1-1-1-127.nip.io              -> exit=1
  evil.example.com              -> exit=1
  127-0-0-1.sslip.io            -> exit=0
  127.0.0.1.nip.io              -> exit=0
  apps.localhost                -> exit=0
  localhost                     -> exit=0
  evil-127-0-0-1.sslip.io       -> exit=0
  us-west1-docker.pkg.dev       -> exit=1   (registry)
  registry.evil.example:5000    -> exit=1   (registry)
  k3d-registry.localhost:5000   -> exit=0   (registry)
  localhost:5000                -> exit=0   (registry)
  127.0.0.1:5000                -> exit=0   (registry)
```

The pointer (M1-d) and passphrase (M1-e) fixes behave as specified:

```text
=== M1-d: malformed pointer ===
nagare: current-context pointer 'bad/name' is not a valid context name (from .../cfg/nagare/current-context)
exit=1
=== M1-d: valid-but-missing pointer ===
nagare: current-context 'nosuch' not found (expected .../cfg/nagare/contexts/nosuch.env)
exit=1
=== M1-d: empty pointer ===
exit=0
=== M1-e: passphrase survives ===
passphrase content: real-secret
```

**M2-b aborts with status 127, not 1.** A failed `${VAR:?message}` expansion in a
non-interactive shell exits with 127 (bash's "expansion error" status), not 1.
The plan's acceptance — "no `would patch:` line, non-zero exit" — holds:

```text
sh: line 1: BASE_DOMAIN: empty baseDomain — run pulumi up first
exit=127
```

**M2-a transcript (the recipe path is genuinely guarded).** Both the script and
the `just` recipe refuse before any gcloud API call:

```text
=== through 'just vm-stop' ===
scripts/vm-power.sh stop
refusing to run: effective project 'wrong-project' does not match the active context's declared project 'probe-project' (context: probe).
fix: unset the ambient CLOUDSDK_CORE_PROJECT override, or select the context that declares 'wrong-project' (NAGARE_CONTEXT=<name> or 'nagarectl context use <name>').
error: recipe `vm-stop` failed on line 36 with exit code 1
exit=1
```

**M2-c transcript (byte-exact rewrite).** `&`, `|` and `\` all survive verbatim
and every unrelated line is preserved exactly once:

```text
export CLOUDSDK_CORE_PROJECT=probe-project
export NAGARE_MODE=cloud
export NAGARE_INSTANCE_NAME=nagare-01
export NAGARE_PULUMI_BACKEND_URL=gs://bucket/a&b|c\d
REWRITE OK
backend-url lines: 1 | project lines: 1 | instance lines: 1
```

**The bucket-ownership assertion sits after `buckets create`, and that residual
window is still fail-closed.** `ensure_bucket` creates the bucket when its
existence probe fails, and only then asserts ownership. If a foreign bucket
exists but is *undescribable* to us, the existence probe fails, the `create`
runs and GCS rejects it (the name is globally taken), and `set -e` aborts the
script — a gcloud-worded failure rather than our message, but no mutation of the
foreign bucket. Every describable case reaches the assertion with its intended
message. Static ordering evidence:

```text
108:    gcloud storage buckets create …
119:  bucket_pn="$(gcloud storage buckets describe … projectNumber …)"
122:    echo "refusing: gs://${bucket} is owned by project number …"
127:  gcloud storage buckets update …
130:    gcloud storage buckets add-iam-policy-binding …
161:  ensure_bucket "${url}"
166:    pulumi … stack init …
169:    pulumi … stack import …
```

**Later live evidence closes M2-d.** EP-116 recorded that the first migration attempt was
refused when gcloud 570 hid `projectNumber`; commit `ed238ba` switched the probe to raw output,
after which the guard accepted the owned bucket and refused a foreign bucket. Only then did the
operator-approved migration proceed. This is stronger evidence than the originally requested
standalone probe because it exercised the same ordering immediately before a real state migration.

**The unrelated full-flake blocker is gone.** EP-139 and `docs/releases/v0.3.0.md` record the
released candidate passing full flake checks and all 29 buildable native root-flake checks. The
shell guard changes from this plan are present in that candidate, so the stale environment-specific
failure no longer represents unfinished acceptance work.

**The M3-a probe as written never reaches the trap.** The plan's probe
(`PATH="/usr/bin:/bin" bash scripts/live-smoke.sh`) makes the script die at the
`cabal build` line — which runs *before* `trap cleanup EXIT` is installed — so
nothing is proven: the run prints `cabal: command not found` and no teardown at
all. A faithful probe needs the script to die *after* the trap is installed but
*before* `HARNESS_READY=1`. Both smoke tests were re-probed with a stub `PATH`
(a `cabal` that succeeds, plus stub `gcloud`/`k3d`/`kubectl`/`nagarectl`/`gsutil`
that announce themselves on stderr) so the failure lands in step 1:

```text
=== live-smoke: dies starting the VM ===
== step 1: ensure nagare-01 is RUNNING ==
  VM is UNKNOWN; starting it…
STUB gcloud CALLED: --project=tan-nb-exp compute instances start nagare-01 --zone=us-west1-a
== teardown ==
== teardown: harness never became ready; skipping cluster cleanup ==
== teardown done ==

=== local-smoke: dies writing the k3d kubeconfig ===
== step 1: ensure the local k3d cluster + registry + MinIO are up ==
STUB k3d kubeconfig write FAILED
== teardown ==
== teardown: harness never became ready; skipping cluster cleanup ==
== teardown done ==
```

The proof is the *absence* of `STUB nagarectl CALLED`, `STUB kubectl CALLED`, and
`STUB gsutil CALLED` lines after `== teardown ==`. Before this milestone,
`nagarectl app delete` ran unconditionally there against the ambient context.

**The SC2155 split is load-bearing, not cosmetic.** In `local-smoke.sh` the old
`export KUBECONFIG="$(k3d kubeconfig write …)"` masked the substitution's exit
status, so under `set -e` a failed kubeconfig write did not abort the script — it
continued to `kubectl get nodes` against the *ambient* context. The split form
aborts. That is also why the local-smoke probe above dies where it does:

```text
sh -c 'set -e; export X="$(false)"; echo "OLD FORM continued, X=[$X]"'
OLD FORM continued, X=[]
old exit=0
sh -c 'set -e; X="$(false)"; export X; echo "NEW FORM continued"'
new exit=1
```

**`nix flake check` cannot complete in this environment, for reasons unrelated
to this plan.** The `nagare-access-build-test` derivation fails cloning a cabal
`source-repository-package` inside the Nix sandbox
(`fatal: could not read Username for 'https://github.com': Device not
configured`), which cancels `shellcheck-scripts` and the other checks. This plan
touched no file under `cli/`. The lint gate was therefore verified two ways —
directly, and by building the hermetic check on its own:

```text
shellcheck --severity=error scripts/*.sh scripts/lib/*.sh   -> exit 0, no output
shellcheck scripts/local-smoke.sh | grep -c SC2155          -> 0
nix build .#checks.aarch64-darwin.shellcheck-scripts        -> shellcheck-scripts: PASS
```

**This operator's live environment is a local-mode in-repo profile, and it
passes the tightened whitelist unchanged.** Sourcing `target.sh` with the real
config resolves `ctx=default mode=local` from `nagare.local.env`
(`NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io`,
`NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000`) and
`_require_target_project` returns 0 — so `just local-smoke` is unaffected by the
whitelist, as the plan predicted. Note the cloud-branch assertion is therefore
never exercised by this machine's default shell; the sandbox probes are the only
coverage.

## Decision Log

- Decision: Under the guardrail, an ambient `CLOUDSDK_CORE_PROJECT` that disagrees
  with the active context's declared project is a **hard failure**, not a silent
  override. The repository's documented per-field precedence (environment > context >
  default) is deliberately narrowed for the *project* field in guarded scripts.
  Rationale: the guardrail's entire purpose (CLAUDE.md, "GCP project isolation") is
  that no script may act on a project other than the active context's; a precedence
  rule that lets a stale exported variable retarget everything defeats it. Unguarded
  consumers (interactive `gcloud`, direnv exports) keep the documented precedence
  unchanged — only `_require_target_project` call sites gain the assertion.
  Date: 2026-07-16
- Decision: When no context/profile declares a project at all (bare built-in
  defaults), the guardrail falls back to cross-checking gcloud's *configured* project
  (read with the `CLOUDSDK_CORE_PROJECT` env var stripped, because gcloud lets that
  variable shadow its configuration). Rationale: this restores the original,
  pre-context meaning of the check ("gcloud's active project equals the target")
  for the legacy no-context setup, with a genuinely independent second source.
  Date: 2026-07-16
- Decision: The local-mode loopback assertion becomes a **whitelist** (127.*-encoded
  sslip.io/nip.io, `localhost`, `*.localhost`; registry `localhost[:port]`,
  `*.localhost[:port]`, `127.*[:port]`), not a longer blacklist. Rationale:
  sslip.io/nip.io encode arbitrary IPs; only an allow-list of provably-loopback forms
  is fail-closed.
  Date: 2026-07-16
- Decision: An **empty** current-context pointer file still falls through to the
  in-repo profile / defaults; only a *non-empty, malformed* pointer becomes an error.
  Rationale: a blank file plausibly means "no context selected" (same as no file); a
  garbled name means the operator's selection is being ignored, which must not be
  silent.
  Date: 2026-07-16
- Decision: `set_context_var` in `scripts/migrate-pulumi-backend.sh` is rewritten
  with `grep -v` + `printf` (drop existing line, append fresh one) instead of
  escaping the value for `sed`. The updated key moves to the end of the context
  file. Rationale: appending via `printf` cannot misinterpret any byte of the value;
  the sed replacement-string metacharacters (`&`, `\`, the `|` delimiter) are a
  standing injection/corruption hazard. Context files are flat `export` bundles, so
  line position carries no meaning.
  Date: 2026-07-16
- Decision: In the smoke-test cleanup traps, tunnel/port-forward process kills stay
  *outside* the harness-ready guard; only cluster-facing operations (`nagarectl`,
  `kubectl`, `gsutil`, MinIO helper) go inside it. Rationale: the tunnels are our own
  child processes identified by PID (or by an instance-name pkill pattern) and must
  be reaped even on early death; the cluster operations are the ones that can hit an
  ambient foreign context.
  Date: 2026-07-16
- Decision: The rollback-path passphrase truncation in
  `scripts/migrate-pulumi-backend.sh` (line 183) is fixed alongside the reviewed
  `target.sh:203` instance. Rationale: identical bug class (unconditional `: >`
  clobbering a possibly-real passphrase); leaving one copy defeats the fix.
  Date: 2026-07-16
- Decision: The M3-a validation probe is replaced with a stub-`PATH` version that
  makes each smoke test die *inside step 1* (after `trap cleanup EXIT` is
  installed), and its acceptance is the *absence* of stub `nagarectl`/`kubectl`/
  `gsutil` invocations after `== teardown ==`. Rationale: as written, the probe's
  stripped `PATH` killed the script at the `cabal build` line, which precedes the
  trap installation — the probe could not distinguish a working guard from a
  script that never reached the trap. Recorded in Surprises & Discoveries with
  transcripts.
  Date: 2026-08-05

- Decision: accept later plan and release evidence for M2-d and the full-flake gate.
  Rationale: EP-116 exercised the exact shipped bucket-ownership path against owned and foreign
  buckets, and EP-139's v0.3.0 release gate exercised the integrated repository after the unrelated
  dependency-authentication failure was fixed. Repeating either older blocked command would be
  weaker than the evidence already retained.
  Date: 2026-09-15
- Decision: `nix flake check` is not treated as a blocking gate for this plan;
  the hermetic `shellcheck-scripts` check is built on its own instead
  (`nix build .#checks.aarch64-darwin.shellcheck-scripts`). Rationale: the full
  check fails in `nagare-access-build-test`, which clones a cabal
  `source-repository-package` from GitHub inside the Nix sandbox and has no
  credentials there; that failure cancels the remaining checks and is unrelated
  to this plan, which touched no file under `cli/`. The plan's own Idempotence
  and Recovery section prescribes exactly this isolation step.
  Date: 2026-08-05
- Decision: The positive `just local-smoke` acceptance run is deferred to the
  operator rather than run here. Rationale: no `nagare-local` k3d cluster exists
  on this machine, so the run would stand up fresh local infrastructure (cluster,
  registry, MinIO) that was not asked for; and the only way this plan can affect
  local mode is the tightened loopback whitelist, which was proven directly by
  showing that the shipped `nagare.local.env` profile
  (`127-0-0-1.sslip.io` + `k3d-registry.localhost:5000`) still passes
  `_require_target_project` with exit 0. Left unchecked in Progress so the gap is
  visible.
  Date: 2026-08-05

## Outcomes & Retrospective

All three milestones landed on 2026-08-05 as three commits on `master`
(`d9cf31b`, `4093ad9`, and the M3 commit), each carrying Conventional Commit
subjects and the `MasterPlan:` / `ExecPlan:` / `Intention:` trailers.

**What exists now that did not before.** The project-isolation guardrail can
actually fail: `scripts/lib/target.sh` captures the project the active
context/profile *declares* (`_NAGARE_CTX_PROJECT`) before the ambient-environment
snapshot is re-applied, and `_require_target_project` refuses to proceed when the
effective project disagrees with it — the old `x != x` comparison is gone. When
no context declares a project, the check falls back to gcloud's *configured*
project read with `CLOUDSDK_CORE_PROJECT` stripped, restoring the original
independent second source. Local mode is now a loopback *whitelist*, so an
sslip.io/nip.io label encoding a public address (`34-120-1-1.sslip.io`) is
rejected where it used to disarm the guardrail. A malformed current-context
pointer errors instead of silently falling back to defaults, and sourcing
`target.sh` no longer truncates the Pulumi passphrase file.

Nothing that touches a GCP project now bypasses that guardrail:
`just vm-stop` / `just vm-start` go through the new `scripts/vm-power.sh`, which
runs the preflight and pins `--project`/`--zone`; `just cluster-bootstrap` aborts
on an empty Pulumi `baseDomain` instead of patching `{"":""}` into Knative's
`config-domain`; and `scripts/migrate-pulumi-backend.sh` asserts a state bucket's
owning project number before any `update`, IAM binding, or stack import (GCS
bucket names are global), rewrites context files byte-exactly without a `sed`
program, and no longer clobbers an existing passphrase.

Both smoke tests' EXIT traps skip every cluster-facing operation until their own
kubeconfig is verified, so an early death performs no `nagarectl`/`kubectl`/
`gsutil` calls against whatever cluster the operator's shell happened to point
at; the stray-tunnel `pkill` matches the instance name actually present in the
`start-iap-tunnel` argv; `iap-ssh.sh recv-file` `%q`-quotes the remote path; and
`upload-images.sh` uses a private `mktemp` scratch file.

**What remains after the 2026-09-15 reconciliation.** One operator check, not a code change:
the positive end-to-end `just local-smoke` run, which would stand up a fresh
`nagare-local` k3d cluster. EP-116 later proved the foreign-bucket refusal in the real
migration path, and EP-139's released v0.3.0 candidate passed the full flake gate after
the unrelated dependency-authentication blocker was fixed. The specific local-mode risk
introduced here remains directly proven by the shipped local profile passing the tightened
whitelist, but the full local smoke is left visible rather than inferred from labs.

**Lessons.** Two of the plan's own validation probes were wrong in instructive
ways, and both errors were of the same kind — assuming a failure would land where
the plan wanted it. The M3-a probe stripped `PATH` to force an early death, but
the script died *before* the trap it was meant to exercise was even installed, so
the probe passed vacuously; only stubbing the tools so the failure landed inside
step 1 actually proved anything. The M2-b probe predicted a non-zero exit and got
127 rather than 1. A validation step that cannot distinguish "the fix works" from
"the code never ran" is not a validation step — when writing probes for
defensive code, assert on the *absence of the dangerous call*, not just on a
non-zero exit.

The second lesson is about lint infrastructure: `shellcheck` is referenced
throughout this plan as if it were in the dev shell, and it is not — it exists
only inside the `shellcheck-scripts` flake check. Any future plan that leans on a
tool should confirm the tool is reachable the way the plan says it is.

