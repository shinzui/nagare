---
id: 97
slug: fail-closed-target-guardrail-and-shell-tooling-hardening
title: "Fail-closed target guardrail and shell tooling hardening"
kind: exec-plan
created_at: 2026-07-16T04:25:03Z
intention: intention_01kzakvy1qeasagg3rpbn44749
master_plan: "docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md"
---

# Fail-closed target guardrail and shell tooling hardening

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


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
- [ ] M2 (deferred, credential-gated): run the live M2-d probe — `scripts/migrate-pulumi-backend.sh --url gs://<existing-foreign-bucket>/nagare/x` must print the `refusing: gs://… is owned by project number …` message and run no `buckets update`. Requires credentials for the real target project and a known foreign bucket name; not runnable in this session.
- [x] M3: guard `scripts/live-smoke.sh` cleanup on a harness-ready flag and fix the `pkill` pattern to use the instance name. (2026-08-05)
- [x] M3: guard `scripts/local-smoke.sh` cleanup on a harness-ready flag and split the SC2155 `export KUBECONFIG` line. (2026-08-05)
- [x] M3: quote the remote path in `scripts/iap-ssh.sh` `recv-file` with `printf '%q'`. (2026-08-05)
- [x] M3: replace the fixed `/tmp/nagare-nix-build.err` in `scripts/upload-images.sh` with `mktemp`. (2026-08-05)
- [x] M3: run shellcheck (error severity over all scripts; default severity over touched scripts). (2026-08-05 — error severity clean; `SC2155` count in local-smoke is 0)
- [x] M3 (split from the shellcheck item): run the hermetic `shellcheck-scripts` flake check. (2026-08-05 — `nix build .#checks.aarch64-darwin.shellcheck-scripts` PASSES)
- [ ] M3 (split, blocked, NOT this plan's fault): a full `nix flake check` cannot complete in this environment — `nagare-access-build-test` fails cloning a cabal `source-repository-package` from GitHub inside the Nix sandbox (`fatal: could not read Username for 'https://github.com'`), which cancels the remaining checks. No file under `cli/` was touched by this plan. Re-run once the sandbox has GitHub credentials.
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

**What remains.** Three items, all recorded as unchecked Progress entries and
none of them code changes: the live foreign-bucket probe for `ensure_bucket`
(needs credentials for the real target project plus a known foreign bucket
name); a full `nix flake check` (blocked on an unrelated
`nagare-access-build-test` GitHub-clone failure inside the Nix sandbox — the
hermetic `shellcheck-scripts` check was built on its own and passes); and the
positive end-to-end `just local-smoke` run (would stand up a fresh `nagare-local`
k3d cluster; the specific local-mode risk this plan introduces was instead
proven directly, by showing the shipped local profile passes the tightened
whitelist).

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


## Context and Orientation

Work happens at the repository root, `/Users/shinzui/Keikaku/bokuno/nagare` (referred
to below by relative paths). You need the Nix dev shell (`nix develop`, or direnv
after `direnv allow`) for `shellcheck`, `just`, `gcloud`, and `pulumi`; the shell
edits themselves need nothing special.

**The target-context model.** A *target context* is a named flat file of
`export VAR=value` lines under `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`
declaring which GCP project (or local substitute) nagare acts on. Selection
precedence is: `NAGARE_CONTEXT` env var > the *current-context pointer* (a one-line
file `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/current-context` holding a context
name) > the git-ignored in-repo profiles `nagare.target.env` / `nagare.local.env`
(schemas documented in the tracked `nagare.target.env.example` and
`nagare.local.env.example`) > built-in defaults reproducing the historic `tan-nb-exp`
setup. Per *field*, precedence is environment > context file > default. A context
with `NAGARE_MODE=local` points everything at loopback substitutes (k3d cluster,
local registry, MinIO) and the GCP guardrail steps aside — but only after asserting
the target is genuinely loopback.

**The single file that owns all of this** is `scripts/lib/target.sh`. Every cloud
script sources it and then calls `_require_target_project`. `.envrc` sources it too,
so direnv-loaded shells carry the resolved `CLOUDSDK_*` / `NAGARE_*` exports. The
resolver, `_nagare_resolve_context`, works like this today (line numbers verified
against the current tree):

- Lines 95–106: if no `NAGARE_CONTEXT` was requested, read the current-context
  pointer file. **Bug (finding 3):** a non-empty pointer that fails
  `_nagare_context_name_valid` simply falls through — `if [ -n "${ptr}" ] &&
  _nagare_context_name_valid "${ptr}"; then … fi` has no else — so a corrupted
  pointer silently selects the in-repo profile or the built-in `tan-nb-exp`
  defaults, whereas a *valid but missing* pointer errors (lines 98–100).
- Lines 131–142: snapshot every context variable that is already set in the
  environment (`_snap`), source the context file and overlay, then re-apply the
  snapshot so "environment wins per-field".
- Line 144: `export CLOUDSDK_CORE_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"` —
  after this line the variable is *always* set, whatever its provenance.
- Line 229: `TARGET_PROJECT="${CLOUDSDK_CORE_PROJECT:-tan-nb-exp}"` — derived from
  the final value.
- Lines 254–263, the cloud branch of `_require_target_project`:

  ```bash
  local active
  active="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
  if [ "${active}" != "${TARGET_PROJECT}" ]; then
  ```

  **Bug (finding 1, CRITICAL):** `CLOUDSDK_CORE_PROJECT` is always set (line 144), so
  the `$(gcloud …)` arm is dead code, `active` always equals
  `CLOUDSDK_CORE_PROJECT`, and `TARGET_PROJECT` *is* `CLOUDSDK_CORE_PROJECT` (line
  229). The comparison is `x != x` — it can never fail. Meanwhile the snapshot
  restore (lines 139–142) means a stale `export CLOUDSDK_CORE_PROJECT=other-project`
  in the shell overrides the context file and flows into every derived name
  (`NAGARE_IMAGE_BUCKET`/`NAGARE_BACKUP_BUCKET` at lines 149–150,
  `NAGARE_REGISTRY_PREFIX` at line 173, `TARGET_PROJECT` at 229) — silently.
- Lines 239–251, the local branch of `_require_target_project`:

  ```bash
  case "${NAGARE_BASE_DOMAIN:-}" in
    *sslip.io|*nip.io|*127.0.0.1*|*127-0-0-1*) : ;;
  ```

  **Bug (finding 2, CRITICAL):** sslip.io and nip.io resolve *any* IP encoded in the
  label — `34-120-1-1.sslip.io` resolves to 34.120.1.1, a public address — yet
  `*sslip.io` accepts it. The registry check below it only blacklists
  `*.pkg.dev`, so `mode=local` with `NAGARE_REGISTRY_HOST=registry.evil.example:5000`
  passes. Since local mode *disarms* the GCP guardrail, this branch must be a strict
  loopback whitelist.
- Line 203, in `_nagare_export_pulumi_env` (which runs on **every** source of
  `target.sh`): `: > "${root}/home/passphrase"` — **Bug (finding 4):** this truncates
  the Pulumi passphrase file unconditionally. `.envrc` currently exports an empty
  `PULUMI_CONFIG_PASSPHRASE`, but an operator who has set a *real* passphrase into
  that file (the file is `PULUMI_CONFIG_PASSPHRASE_FILE`, line 206) loses it — and
  with it access to stack secrets — the next time any script sources `target.sh`.

**The `justfile`** (repo root) is a `just` command runner file; each recipe line runs
under `sh -cu` (nounset, **no** `-e`). Two hazards:

- Lines 36 and 45: `vm-stop` / `vm-start` run raw
  `gcloud compute instances stop|start "${NAGARE_INSTANCE_NAME:-nagare-01}"
  --zone="${CLOUDSDK_COMPUTE_ZONE:-us-west1-a}"` with **no `--project` flag and no
  guardrail** (finding 5). With soft `:-` fallbacks, a shell with no direnv context
  acts on whatever project gcloud defaults to.
- Lines 107–109, inside `cluster-bootstrap`:

  ```bash
  BASE_DOMAIN="$(pulumi -C infra/pulumi stack output baseDomain)"; \
    kubectl -n knative-serving patch configmap config-domain --type merge --patch "{\"data\":{\"$BASE_DOMAIN\":\"\"}}"; \
  ```

  **Bug (finding 6):** if the pulumi command fails (no stack, no output), command
  substitution yields `BASE_DOMAIN=""` and — because `sh -cu` has no `-e` — the
  recipe happily patches `{"data":{"":""}}` into Knative's `config-domain`
  ConfigMap, breaking app domains cluster-wide. The local twin at line 207 already
  uses the hard-fail idiom `"${NAGARE_BASE_DOMAIN:?…}"`.

**The smoke tests.** `scripts/live-smoke.sh` (cloud) and `scripts/local-smoke.sh`
(k3d) both install a `trap cleanup EXIT` *before* they establish their own
kubeconfig. `live-smoke.sh` lines 44–57: `cleanup` runs `nagarectl app delete …`
unconditionally (no KUBECONFIG guard at all on that line) and only guards the
`kubectl delete pvc` on `[ -n "${KUBECONFIG:-}" ]` — which is also satisfied by an
*ambient* KUBECONFIG inherited from the operator's shell. `local-smoke.sh` lines
68–79 are the same shape (`nagarectl app delete` unguarded). If the script dies in
step 1 (say, `gcloud` fails, or k3d is not installed), the trap fires against
whatever cluster the shell points at — for this operator, a real GKE context
(finding 7). Two adjacent bugs: `live-smoke.sh` line 54 does
`pkill -f 'start-iap-tunnel '"${SMOKE_APP:-nagare-01}"` — but `SMOKE_APP` is
`uploads-volume` and tunnels are opened by `scripts/iap-ssh.sh` as
`start-iap-tunnel nagare-01 22 …`, so the pattern never matches and stray tunnels
survive (finding 8); and `local-smoke.sh` line 89 does
`export KUBECONFIG="$(k3d kubeconfig write nagare-local)"` — the `export` masks the
command's exit status (shellcheck SC2155), so a failed `k3d kubeconfig write` leaves
`KUBECONFIG` empty-but-exported and the script marches on against the ambient
context.

**The Pulumi backend migration.** `scripts/migrate-pulumi-backend.sh` moves a
context's Pulumi state between the per-context local file backend and a remote GCS
(Google Cloud Storage) backend. Its `ensure_bucket` (lines 98–119) does
`gcloud storage buckets describe gs://<bucket>` and, whether or not the bucket
already existed, runs `gcloud storage buckets update … --versioning …` and
optionally `add-iam-policy-binding`. **Bug (finding 9):** GCS bucket *names are
global* across all of Google Cloud — a same-named bucket may already exist in a
foreign project, and describe/update/IAM would then mutate (or fail confusingly
against) someone else's bucket. The owning project must be asserted before any
mutation. Same script, line 83: `sed "s|^export ${key}=.*$|export ${key}=${value}|"`
interpolates `${value}` (a `gs://…` URL) into a sed replacement unescaped — `&`,
`\`, or a `|` in the value corrupts the operator's context file. Line 183 repeats
the passphrase truncation bug from `target.sh:203`.

**Small quoting/tempfile items (finding 10).** `scripts/iap-ssh.sh` line 319 builds a
remote command as `"sudo cat ${remote_path}"` — an unquoted interpolation into the
remote shell; the repo's established idiom for this is `printf '%q'` (see
`scripts/upload-images.sh` lines 51, 66, 111). `scripts/upload-images.sh` line 46
redirects nix build errors to the fixed path `/tmp/nagare-nix-build.err` (also read
at lines 50 and 56) — a predictable, world-shared path; use `mktemp`.

**Shellcheck gate.** `flake.nix` (lines 117–123) has a `shellcheck-scripts` check
running `shellcheck --severity=error scripts/*.sh scripts/lib/*.sh` as part of
`nix flake check`. All edits must keep it green; the SC2155 fix is below error
severity but is verified explicitly.

**Ownership and integration notes (record-keeping for sibling plans).**
`scripts/lib/target.sh` is owned by THIS plan for the duration of MasterPlan 19:
`docs/plans/99-protect-stateful-infrastructure-and-make-secrets-and-state-recoverable.md`
may later flip the *default Pulumi backend* for cloud contexts but must not edit the
guardrail logic (`_require_target_project`, `_nagare_resolve_context`'s
`_NAGARE_CTX_PROJECT` capture, or the loopback whitelist). The `justfile` is also
touched by `docs/plans/103-host-tuning-upgrade-story-and-documentation-reality-sync.md`
(pin bumps) in unrelated recipes — keep this plan's `justfile` edits confined to
`vm-stop`, `vm-start`, and the `cluster-bootstrap` BASE_DOMAIN line to avoid
conflicts.

**Git conventions.** Conventional Commits; commit directly to the current branch;
stage files by explicit path (never `git add -A` — a concurrent actor commits
mid-session in this repo). Every commit carries both trailers:

```text
MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
ExecPlan: docs/plans/97-fail-closed-target-guardrail-and-shell-tooling-hardening.md
```


## Plan of Work

The work is three milestones. M1 makes the guardrail itself real (the two CRITICAL
findings plus the two resolver-adjacent bugs, all in `scripts/lib/target.sh`). M2
routes the bypassing `justfile` recipes and the backend-migration script through the
now-real guardrail and closes the foreign-bucket hazard. M3 makes the smoke-test
cleanup traps safe and fixes the quoting/temp-file hygiene items, finishing with the
repo-wide shellcheck gate. Each milestone is independently verifiable and committed
separately.


### Milestone 1 — a guardrail that can actually fail (scripts/lib/target.sh)

Scope: `scripts/lib/target.sh` only. At the end of this milestone, the file exports a
new resolver-computed fact — the project the context/profile *itself declared* — and
`_require_target_project` asserts against it; the local-mode branch is a loopback
whitelist; a malformed current-context pointer errors; and the passphrase file is
created only if absent. Acceptance: the negative probes in Validation exit non-zero
with the documented messages, the positive probes exit zero, and
`shellcheck --severity=error scripts/lib/target.sh` is clean.

**Edit 1a — capture the declared project.** In `_nagare_resolve_context`, the
snapshot/source/restore block currently reads (lines 131–142):

```bash
  local _snap=() v
  for v in "${_NAGARE_CONTEXT_VARS[@]}"; do
    [ -n "${!v+x}" ] && _snap+=("${v}=${!v}")
  done

  _nagare_source_if_present "${file}"
  _nagare_source_if_present "${overlay}"

  local kv
  for kv in "${_snap[@]+"${_snap[@]}"}"; do
    export "${kv?}"
  done
```

Change it so that, after the snapshot is taken, every context variable is *unset*
before sourcing; then, after sourcing the file and overlay but **before** re-applying
the snapshot, capture the project value that the files themselves set:

```bash
  local _snap=() v
  for v in "${_NAGARE_CONTEXT_VARS[@]}"; do
    [ -n "${!v+x}" ] && _snap+=("${v}=${!v}")
  done

  # Clear the slate so that after sourcing, a set variable can ONLY have come
  # from the context/profile files. The snapshot restore below reinstates every
  # ambient value, so the final per-field precedence (env > context > default)
  # is unchanged.
  for v in "${_NAGARE_CONTEXT_VARS[@]}"; do
    unset "${v}"
  done

  _nagare_source_if_present "${file}"
  _nagare_source_if_present "${overlay}"

  # The project the active context/profile DECLARES (empty when no file declares
  # one). Captured before the env snapshot is re-applied, so an ambient
  # CLOUDSDK_CORE_PROJECT cannot masquerade as the context's project.
  # _require_target_project asserts against this. Not exported: it is
  # recomputed on every source of this file, and consumers always source it.
  _NAGARE_CTX_PROJECT="${CLOUDSDK_CORE_PROJECT:-}"

  local kv
  for kv in "${_snap[@]+"${_snap[@]}"}"; do
    export "${kv?}"
  done
```

Why the final values are unchanged: today, sourcing overwrites ambient values and the
snapshot restore puts them back; with the unset added, sourcing *sets* values on a
clean slate and the same restore puts the ambient ones back. Only the mid-flight
capture differs. The existing unset loop at lines 124–129 (which clears variables
when the *resolved context changed* within one shell) stays as-is — it runs before
the snapshot and prevents a previous context's values from being snapshotted as
"ambient".

**Edit 1b — the non-tautological cloud check.** Replace the cloud branch of
`_require_target_project` (currently lines 254–263, the `local active …` block)
with:

```bash
  # Cloud context: fail closed on ANY disagreement about the target project.
  #
  # TARGET_PROJECT is derived from the FINAL CLOUDSDK_CORE_PROJECT, where an
  # ambient environment value wins over the context file (per-field precedence).
  # For the project field that precedence must never silently retarget a guarded
  # script, so:
  #   - when the active context/profile declares a project (_NAGARE_CTX_PROJECT
  #     is non-empty), the effective project must equal it;
  #   - when nothing declares one, the effective project came from ambient env
  #     or the built-in default, so cross-check gcloud's CONFIGURED project,
  #     read with CLOUDSDK_CORE_PROJECT stripped from the environment (gcloud
  #     lets that env var shadow its configuration, which would re-create the
  #     tautology this replaces).
  if [ -n "${_NAGARE_CTX_PROJECT:-}" ]; then
    if [ "${TARGET_PROJECT}" != "${_NAGARE_CTX_PROJECT}" ]; then
      echo "refusing to run: effective project '${TARGET_PROJECT}' does not match the active context's declared project '${_NAGARE_CTX_PROJECT}' (context: ${NAGARE_CONTEXT:-default})." >&2
      echo "fix: unset the ambient CLOUDSDK_CORE_PROJECT override, or select the context that declares '${TARGET_PROJECT}' (NAGARE_CONTEXT=<name> or 'nagarectl context use <name>')." >&2
      return 1
    fi
  else
    local configured
    configured="$(env -u CLOUDSDK_CORE_PROJECT gcloud config get-value project 2>/dev/null || true)"
    if [ -z "${configured}" ] || [ "${configured}" != "${TARGET_PROJECT}" ]; then
      echo "refusing to run: gcloud's configured project is '${configured:-<unset>}', expected '${TARGET_PROJECT}' (active context: ${NAGARE_CONTEXT:-default})." >&2
      echo "fix: select a context that declares the project ('nagarectl context use <name>')," >&2
      echo "     or run 'gcloud config set project ${TARGET_PROJECT}'." >&2
      return 1
    fi
  fi
```

Note the properties this restores: with a declared project, the check is instant and
offline (no gcloud subprocess) and *can fail* — exactly when an ambient override
disagrees. Without one (legacy bare-defaults setup), the check regains its original
EP-60 meaning against a genuinely independent source. `env -u` is POSIX and works on
both Darwin and Linux.

**Edit 1c — loopback whitelist.** Replace the two `case` blocks in the local branch
(lines 240–250) with:

```bash
    # Whitelist, not blacklist. sslip.io / nip.io resolve the LAST IP encoded in
    # their labels (dashed or dotted), so 34-120-1-1.sslip.io is a PUBLIC
    # address; accept those providers only when the encoded address starts with
    # 127. Also accept localhost and *.localhost (loopback per RFC 6761).
    local _d="${NAGARE_BASE_DOMAIN:-}"
    if ! { [ "${_d}" = "localhost" ] \
        || [[ "${_d}" =~ \.localhost$ ]] \
        || [[ "${_d}" =~ (^|[.-])127([.-][0-9]{1,3}){3}\.(sslip|nip)\.io$ ]]; }; then
      echo "refusing local run: active context is mode=local but NAGARE_BASE_DOMAIN='${_d:-<unset>}' is not provably loopback (allowed: localhost, *.localhost, 127.x.x.x-encoded sslip.io/nip.io)." >&2
      return 1
    fi
    local _r="${NAGARE_REGISTRY_HOST:-}"
    if ! { [[ "${_r}" =~ ^localhost(:[0-9]+)?$ ]] \
        || [[ "${_r}" =~ \.localhost(:[0-9]+)?$ ]] \
        || [[ "${_r}" =~ ^127(\.[0-9]{1,3}){3}(:[0-9]+)?$ ]]; }; then
      echo "refusing local run: active context is mode=local but NAGARE_REGISTRY_HOST='${_r:-<unset>}' is not a loopback registry (allowed: localhost[:port], *.localhost[:port], 127.x.x.x[:port])." >&2
      return 1
    fi
    return 0
```

The base-domain regex requires the *final* dashed/dotted quad before
`.sslip.io`/`.nip.io` to begin with `127` — which matches how those providers parse
(right-to-left), so `evil-127-0-0-1.sslip.io` (which genuinely resolves to
127.0.0.1) is accepted while `127-0-0-1-34-120-1-1.sslip.io` (resolves to
34.120.1.1) and `1-1-1-127.sslip.io` (1.1.1.127) are rejected. The worked example
`127-0-0-1.sslip.io` (from `nagare.local.env.example` line 45) and the registry
`k3d-registry.localhost:5000` (line 41) both pass, so `just local-smoke` is
unaffected. Note `NAGARE_REGISTRY_HOST` is never empty after resolution (line 147
defaults it to `<region>-docker.pkg.dev`), and that default is correctly rejected
here — same outcome as the old `*.pkg.dev` blacklist.

**Edit 1d — fail-closed pointer.** Rewrite the pointer block (lines 95–106) so the
invalid-name path errors exactly like the not-found path:

```bash
  if [ -z "${selkey}" ] && [ -f "${ptrfile}" ]; then
    ptr="$(tr -d '[:space:]' < "${ptrfile}")"
    if [ -n "${ptr}" ]; then
      if ! _nagare_context_name_valid "${ptr}"; then
        echo "nagare: current-context pointer '${ptr}' is not a valid context name (from ${ptrfile})" >&2
        return 1
      fi
      if [ ! -f "${ctxdir}/${ptr}.env" ]; then
        echo "nagare: current-context '${ptr}' not found (expected ${ctxdir}/${ptr}.env)" >&2
        return 1
      fi
      name="${ptr}"
      file="${ctxdir}/${ptr}.env"
      selkey="ctx:${ptr}"
    fi
  fi
```

An *empty* pointer file still falls through (see Decision Log). Because
`target.sh`'s top-level `if ! _nagare_resolve_context; then return 1 … exit 1; fi`
(lines 182–184) already propagates resolver failures, no other change is needed —
scripts sourcing the file under `set -e` will abort.

**Edit 1e — passphrase guard.** Change line 203 from `: > "${root}/home/passphrase"`
to:

```bash
  [ -f "${root}/home/passphrase" ] || : > "${root}/home/passphrase"
```


### Milestone 2 — route the bypassing tooling through the guardrail

Scope: a new script `scripts/vm-power.sh`, two `justfile` recipe bodies, one
`justfile` recipe line, and three fixes in `scripts/migrate-pulumi-backend.sh`. At
the end, no recipe or script issues a project-touching gcloud call without
`_require_target_project` and an explicit `--project="${TARGET_PROJECT}"`, and the
migration script can neither mutate a foreign bucket nor corrupt a context file.
Acceptance: the Validation probes for M2 pass; `just --list` still renders; shellcheck
stays clean.

**Edit 2a — `scripts/vm-power.sh` (new file, mode 0755):**

```bash
#!/usr/bin/env bash
# scripts/vm-power.sh (EP-97) — start/stop the target VM THROUGH the guardrail.
#
# `just vm-stop` / `just vm-start` used to run raw gcloud with no --project and
# no preflight, silently acting on whatever project gcloud defaulted to. This
# wrapper sources the shared resolver, runs the fail-closed preflight, and pins
# --project/--zone to the active context's values.
set -euo pipefail

if [ "$#" -ne 1 ] || { [ "$1" != "start" ] && [ "$1" != "stop" ]; }; then
  echo "usage: scripts/vm-power.sh <start|stop>" >&2
  exit 2
fi

# shellcheck source=scripts/lib/target.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/target.sh"
_require_target_project

exec gcloud --project="${TARGET_PROJECT}" compute instances "$1" \
  "${NAGARE_INSTANCE_NAME:-nagare-01}" --zone="${TARGET_ZONE}"
```

Run `chmod +x scripts/vm-power.sh` after writing it.

**Edit 2b — `justfile` recipes.** Replace the bodies of `vm-stop` (line 36) and
`vm-start` (line 45) — keeping every comment line above them intact:

```text
vm-stop:
    scripts/vm-power.sh stop
```

```text
vm-start:
    scripts/vm-power.sh start
```

**Edit 2c — hard-fail BASE_DOMAIN.** In the `cluster-bootstrap` recipe, change line
107 (the start of the three-line continued command) to insert a `:?` guard between
the command substitution and the patch, mirroring the local twin at line 207:

```text
    BASE_DOMAIN="$(pulumi -C infra/pulumi stack output baseDomain)"; \
      : "${BASE_DOMAIN:?empty baseDomain — run 'pulumi -C infra/pulumi up' (or 'pulumi config set baseDomain …') before cluster-bootstrap}"; \
      kubectl -n knative-serving patch configmap config-domain --type merge --patch "{\"data\":{\"$BASE_DOMAIN\":\"\"}}"; \
      kubectl -n knative-serving patch configmap config-domain --type=json -p '[{"op":"remove","path":"/data/svc.cluster.local"}]' || true
```

In POSIX `sh`, a failed `${VAR:?}` expansion aborts the (non-interactive) shell with
a non-zero status, so the recipe stops before touching the ConfigMap even though
`just` runs it with `sh -cu` and no `-e`.

**Edit 2d — bucket ownership assertion.** In `scripts/migrate-pulumi-backend.sh`,
inside `ensure_bucket`, after the create-if-missing block (lines 105–112) and
**before** the unconditional `gcloud storage buckets update` (line 113), insert:

```bash
  # GCS bucket names are GLOBAL: a same-named bucket may exist in a FOREIGN
  # project, and describe/update/IAM would mutate someone else's bucket. Assert
  # the bucket's owning project number equals the target project's before any
  # update, IAM change, or state import.
  local bucket_pn target_pn
  bucket_pn="$(gcloud storage buckets describe "gs://${bucket}" --format='value(projectNumber)' 2>/dev/null || true)"
  target_pn="$(gcloud projects describe "${CLOUDSDK_CORE_PROJECT}" --format='value(projectNumber)' 2>/dev/null || true)"
  if [ -z "${bucket_pn}" ] || [ -z "${target_pn}" ] || [ "${bucket_pn}" != "${target_pn}" ]; then
    echo "refusing: gs://${bucket} is owned by project number '${bucket_pn:-<unknown>}', not the target project '${CLOUDSDK_CORE_PROJECT}' (number '${target_pn:-<unknown>}')." >&2
    echo "  GCS bucket names are global; pick a different state bucket with --url gs://<unique-name>/nagare/${CTX}." >&2
    return 1
  fi
```

Because `do_forward` calls `ensure_bucket` before `pulumi stack init/import` against
the GCS URL, this also gates the import. (`_require_target_project` is already the
first line of `do_forward`, so M1's fix protects the project identity here too.)

**Edit 2e — safe context-file rewrite.** Replace the body of `set_context_var`
(lines 75–89) so no operator-controlled value is ever interpolated into a sed
program:

```bash
set_context_var() {
  local key="$1" value="$2" file="${NAGARE_ACTIVE_CONTEXT_FILE:-}"
  if [ -z "${file}" ] || [ ! -f "${file}" ]; then
    log "no context file to update (NAGARE_ACTIVE_CONTEXT_FILE unset); set ${key}=${value} manually."
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  # Drop any existing line for the key, then append the fresh one. printf
  # emits the value verbatim — no sed replacement-string metacharacters
  # (&, \, delimiter) can corrupt the operator's context file. The updated
  # key moves to the end of the file; context files are flat export bundles,
  # so position carries no meaning.
  grep -v "^export ${key}=" "${file}" > "${tmp}" || true
  printf 'export %s=%s\n' "${key}" "${value}" >> "${tmp}"
  mv "${tmp}" "${file}"
}
```

(`grep -v` exits 1 when it emits no lines, hence `|| true`. `${key}` is one of the
two literal caller-supplied names, never operator data.)

**Edit 2f — rollback passphrase guard.** Change line 183 from
`: > "${LOCAL_HOME}/passphrase"` to:

```bash
  [ -f "${LOCAL_HOME}/passphrase" ] || : > "${LOCAL_HOME}/passphrase"
```


### Milestone 3 — trap safety and hygiene, then the lint gate

Scope: `scripts/live-smoke.sh`, `scripts/local-smoke.sh`, `scripts/iap-ssh.sh`,
`scripts/upload-images.sh`, then shellcheck over everything. At the end, a smoke test
that dies before its harness exists performs no cluster operations in its EXIT trap;
stray IAP tunnels are actually reaped; the `recv-file` remote path is shell-safe; and
the image builder uses a private temp file. Acceptance: the early-death teardown
probe prints the skip message and touches no cluster; `shellcheck` results as
specified in Validation.

**Edit 3a — `scripts/live-smoke.sh`.** Next to the existing state initialisers
(lines 41–42, `TUN_PIDS=""` / `SNAPSHOT_URL=""`), add:

```bash
HARNESS_READY=0
```

Replace the `cleanup` function (lines 44–56) with:

```bash
cleanup() {
  echo "== teardown =="
  # Cluster-facing cleanup ONLY once our own harness (tunnel + kubeconfig) was
  # verified — otherwise these commands would fire against whatever ambient
  # kubectl context / gcloud project the operator's shell happened to hold.
  if [ "${HARNESS_READY}" = "1" ]; then
    nagarectl app delete "${SMOKE_APP}" --yes >/dev/null 2>&1 || true
    # Best-effort: remove the smoke snapshot object and any restore-scratch PVC.
    [ -n "${SNAPSHOT_URL}" ] && gsutil rm "${SNAPSHOT_URL}" >/dev/null 2>&1 || true
    kubectl -n "${SMOKE_NS}" delete pvc -l nagare.dev/restore-scratch=true >/dev/null 2>&1 || true
  else
    echo "== teardown: harness never became ready; skipping cluster cleanup =="
  fi
  # Our own child tunnels are reaped unconditionally: identified by PID, and by
  # the INSTANCE name in the start-iap-tunnel argv (NOT the app name — tunnels
  # are opened as 'start-iap-tunnel nagare-01 22 …').
  # shellcheck disable=SC2086
  [ -n "${TUN_PIDS}" ] && kill ${TUN_PIDS} 2>/dev/null || true
  pkill -f "start-iap-tunnel ${NAGARE_INSTANCE_NAME:-nagare-01} " 2>/dev/null || true
  echo "== teardown done =="
}
```

Then set the flag at the moment the harness is proven: immediately after the existing
`kubectl get nodes >/dev/null` in step 2 (line 76), add:

```bash
HARNESS_READY=1
```

Note the `pkill` pattern uses `NAGARE_INSTANCE_NAME` (exported by `target.sh`) with a
trailing space so it anchors the full instance argument, and no longer references
`SMOKE_APP` (finding 8).

**Edit 3b — `scripts/local-smoke.sh`.** Next to the initialisers (lines 50–51,
`SNAPSHOT_URL=""` / `PF_PID=""`), add `HARNESS_READY=0`. Replace `cleanup` (lines
68–79) with:

```bash
cleanup() {
  echo "== teardown =="
  # Cluster-facing cleanup ONLY once the k3d kubeconfig was written and
  # verified — otherwise these commands would fire against whatever ambient
  # kubectl context the shell holds (see MEMORY: never the GKE default).
  if [ "${HARNESS_READY}" = "1" ]; then
    # `app delete NAME -n NS` deletes the Knative Service + DomainMappings +
    # history (no --yes flag, no prompt); it resolves domains from the cluster
    # when the config file is absent, so it is safe to run from the repo root.
    nagarectl app delete "${SMOKE_APP}" -n "${SMOKE_NS}" >/dev/null 2>&1 || true
    # Best-effort: drop the local MinIO snapshot object + any restore-scratch PVC.
    [ -n "${SNAPSHOT_URL}" ] && minio_rm "${SNAPSHOT_URL}"
    kubectl -n "${SMOKE_NS}" delete pvc -l nagare.dev/restore-scratch=true >/dev/null 2>&1 || true
  else
    echo "== teardown: harness never became ready; skipping cluster cleanup =="
  fi
  [ -n "${PF_PID}" ] && kill "${PF_PID}" 2>/dev/null || true
  echo "== teardown done =="
}
```

Fix line 89 (SC2155 — `export` masks the substitution's exit status) by splitting:

```bash
KUBECONFIG="$(k3d kubeconfig write nagare-local)"
export KUBECONFIG
```

and immediately after the following `kubectl get nodes >/dev/null` (line 90), add
`HARNESS_READY=1`.

**Edit 3c — `scripts/iap-ssh.sh` recv-file quoting.** In `_do_recv_file_inner`,
change line 319 from

```bash
    "${SSH_USER}@localhost" "sudo cat ${remote_path}" > "${out_path}"
```

to the repo's `printf '%q'` idiom (as used in `scripts/upload-images.sh` lines 51,
66, 111), declaring the helper variable alongside the function's other locals:

```bash
  local q_remote; q_remote="$(printf '%q' "${remote_path}")"
  # …
    "${SSH_USER}@localhost" "sudo cat ${q_remote}" > "${out_path}"
```

`%q` shell-escapes the path so spaces or metacharacters in a remote filename can
neither break the remote command nor smuggle extra words into `sudo`.

**Edit 3d — `scripts/upload-images.sh` temp file.** Near the top (after the `log()`
definition on line 27), add:

```bash
NIX_BUILD_ERR="$(mktemp -t nagare-nix-build.XXXXXX)"
```

and replace all three occurrences of `/tmp/nagare-nix-build.err` (lines 46, 50, 56)
with `"${NIX_BUILD_ERR}"`.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/nagare`,
inside the dev shell (`nix develop` or a direnv-loaded shell).

1. **M1.** Apply Edits 1a–1e to `scripts/lib/target.sh` as specified in Plan of
   Work. Then run the M1 probes from Validation and Acceptance (they need no GCP
   credentials — every probe uses a throwaway `XDG_CONFIG_HOME`). Lint:

   ```bash
   shellcheck --severity=error scripts/lib/target.sh
   ```

   Expected: no output, exit 0. Commit:

   ```bash
   git add scripts/lib/target.sh docs/plans/97-fail-closed-target-guardrail-and-shell-tooling-hardening.md
   git commit -m "fix(target)!: make the project guardrail non-tautological and whitelist local loopback

   Capture the context-declared project before the env snapshot is
   re-applied and assert against it in _require_target_project (an ambient
   CLOUDSDK_CORE_PROJECT override now fails closed instead of silently
   retargeting); replace the sslip/nip blacklist with a 127.* loopback
   whitelist; error on a malformed current-context pointer; stop
   truncating the Pulumi passphrase file on every source.

   MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
   ExecPlan: docs/plans/97-fail-closed-target-guardrail-and-shell-tooling-hardening.md" 
   ```

   (The `!` marks the narrowed env-override precedence for guarded scripts as a
   deliberate behavior change.)

2. **M2.** Create `scripts/vm-power.sh` (Edit 2a), `chmod +x scripts/vm-power.sh`,
   apply Edits 2b–2c to `justfile` and 2d–2f to
   `scripts/migrate-pulumi-backend.sh`. Verify `just` still parses:

   ```bash
   just --list
   ```

   Expected: the recipe list renders, including `vm-stop` and `vm-start`. Run the M2
   probes from Validation. Lint:

   ```bash
   shellcheck --severity=error scripts/vm-power.sh scripts/migrate-pulumi-backend.sh
   ```

   Commit:

   ```bash
   git add scripts/vm-power.sh justfile scripts/migrate-pulumi-backend.sh docs/plans/97-fail-closed-target-guardrail-and-shell-tooling-hardening.md
   git commit -m "fix(tooling): route vm power and pulumi-backend migration through the guardrail

   just vm-stop/vm-start now call scripts/vm-power.sh (preflight +
   explicit --project/--zone); cluster-bootstrap hard-fails on an empty
   pulumi baseDomain instead of patching {\"\":\"\"} into config-domain;
   migrate-pulumi-backend asserts the state bucket's owning project
   number before update/IAM/import, rewrites context files without sed
   interpolation, and no longer truncates an existing passphrase file.

   MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
   ExecPlan: docs/plans/97-fail-closed-target-guardrail-and-shell-tooling-hardening.md"
   ```

3. **M3.** Apply Edits 3a–3d. Run the M3 probes from Validation, then the full lint
   gate:

   ```bash
   shellcheck --severity=error scripts/*.sh scripts/lib/*.sh
   shellcheck scripts/local-smoke.sh | grep SC2155 || echo "SC2155 gone"
   nix flake check
   ```

   Expected: the first command exits 0 with no output; the second prints
   `SC2155 gone`; `nix flake check` passes (its `shellcheck-scripts` check covers the
   same error-severity run hermetically). Commit:

   ```bash
   git add scripts/live-smoke.sh scripts/local-smoke.sh scripts/iap-ssh.sh scripts/upload-images.sh docs/plans/97-fail-closed-target-guardrail-and-shell-tooling-hardening.md
   git commit -m "fix(scripts): guard smoke-test teardown traps and clean up quoting/tempfiles

   Smoke-test EXIT traps skip all cluster-facing cleanup until the
   script's own kubeconfig is verified (never the ambient context); the
   stray-tunnel pkill matches the instance name actually present in the
   start-iap-tunnel argv; local-smoke splits the SC2155 KUBECONFIG
   export; iap-ssh recv-file %q-quotes the remote path; upload-images
   uses mktemp instead of a fixed /tmp path.

   MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
   ExecPlan: docs/plans/97-fail-closed-target-guardrail-and-shell-tooling-hardening.md"
   ```

4. Update this plan's Progress checkboxes, Surprises & Discoveries, and (at the end)
   Outcomes & Retrospective at every stopping point; include the plan file in the
   milestone commits (as shown above). Stage by explicit path only.


## Validation and Acceptance

All probes are runnable without GCP credentials unless noted. Each M1/M2 probe builds
a disposable context under `mktemp -d` so the operator's real
`~/.config/nagare` is never read or written; `XDG_STATE_HOME` is also pointed at the
sandbox so the resolver's Pulumi bookkeeping cannot touch real state.

**Setup used by several probes** (run once per shell; from the repo root):

```bash
SBX="$(mktemp -d)"
mkdir -p "${SBX}/cfg/nagare/contexts" "${SBX}/state"
cat > "${SBX}/cfg/nagare/contexts/probe.env" <<'EOF'
export CLOUDSDK_CORE_PROJECT=probe-project
export NAGARE_MODE=cloud
EOF
probe() {  # probe [EXTRA_ENV...] -- runs the guardrail under the sandbox
  env -i HOME="${HOME}" PATH="${PATH}" \
    XDG_CONFIG_HOME="${SBX}/cfg" XDG_STATE_HOME="${SBX}/state" \
    NAGARE_CONTEXT=probe "$@" \
    bash -c 'source scripts/lib/target.sh && _require_target_project'
}
```

**M1-a (the tautology is dead — negative).** With a stale ambient project exported,
the guardrail must refuse:

```bash
probe CLOUDSDK_CORE_PROJECT=wrong-project; echo "exit=$?"
```

Expected output (stderr) and status:

```text
refusing to run: effective project 'wrong-project' does not match the active context's declared project 'probe-project' (context: probe).
fix: unset the ambient CLOUDSDK_CORE_PROJECT override, or select the context that declares 'wrong-project' (NAGARE_CONTEXT=<name> or 'nagarectl context use <name>').
exit=1
```

Before this plan, the same probe printed nothing and exited 0 — that contrast is the
proof the tautology is gone.

**M1-b (agreement still passes — positive).** `probe; echo "exit=$?"` (no override)
prints `exit=0`. Also `probe CLOUDSDK_CORE_PROJECT=probe-project` prints `exit=0`
(an ambient value that *agrees* is not an error). Neither invocation may shell out
to gcloud (verify: probes pass even with `PATH` lacking gcloud, e.g. inside
`env -i … PATH=/usr/bin:/bin` if your bash lives there).

**M1-c (local bypass closed — negative and positive).** Append local contexts to the
sandbox and probe each:

```bash
for dom in 34-120-1-1.sslip.io 127-0-0-1-34-120-1-1.sslip.io 1-1-1-127.nip.io; do
  printf 'export NAGARE_MODE=local\nexport NAGARE_BASE_DOMAIN=%s\nexport NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000\n' "$dom" \
    > "${SBX}/cfg/nagare/contexts/loc.env"
  env -i HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="${SBX}/cfg" XDG_STATE_HOME="${SBX}/state" NAGARE_CONTEXT=loc \
    bash -c 'source scripts/lib/target.sh && _require_target_project'; echo "$dom -> exit=$?"
done
```

Expected: every line ends `exit=1`, each preceded by the
`refusing local run: … not provably loopback …` message. Repeat with
`NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io` (and again with `127.0.0.1.nip.io`,
`apps.localhost`) — expected `exit=0`. Then hold the domain loopback and vary the
registry: `us-west1-docker.pkg.dev`, `registry.evil.example:5000` → `exit=1` with the
`not a loopback registry` message; `k3d-registry.localhost:5000`, `localhost:5000`,
`127.0.0.1:5000` → `exit=0`.

**M1-d (invalid pointer fails closed).** With no `NAGARE_CONTEXT`:

```bash
printf 'bad/name\n' > "${SBX}/cfg/nagare/current-context"
env -i HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="${SBX}/cfg" XDG_STATE_HOME="${SBX}/state" \
  bash -c 'source scripts/lib/target.sh'; echo "exit=$?"
```

Expected: `nagare: current-context pointer 'bad/name' is not a valid context name …`
and `exit=1`. An empty pointer file (`: > …/current-context`) must still exit 0.

**M1-e (passphrase survives).**

```bash
printf 'real-secret\n' > "${SBX}/state/nagare/probe/home/passphrase" 2>/dev/null || { mkdir -p "${SBX}/state/nagare/probe/home"; printf 'real-secret\n' > "${SBX}/state/nagare/probe/home/passphrase"; }
probe >/dev/null 2>&1 || true
cat "${SBX}/state/nagare/probe/home/passphrase"
```

Expected: `real-secret` (before the fix: empty output — the file was truncated).

**M2-a (vm recipes are guarded — negative; needs gcloud on PATH but no credentials).**
In a shell where the active context declares `probe-project` and the ambient
environment says otherwise:

```bash
env XDG_CONFIG_HOME="${SBX}/cfg" XDG_STATE_HOME="${SBX}/state" NAGARE_CONTEXT=probe \
  CLOUDSDK_CORE_PROJECT=wrong-project just vm-stop; echo "exit=$?"
```

Expected: the M1-a refusal message, non-zero exit, and **no** gcloud API call.
`bash scripts/vm-power.sh` with a missing/invalid argument prints
`usage: scripts/vm-power.sh <start|stop>` and exits 2. A live positive check (only
if the operator wants one and the VM is already stopped/running appropriately):
`just vm-start` then `just vm-stop` behaves exactly as before, with
`--project` pinned.

**M2-b (empty baseDomain aborts).** Reproduce the recipe line under the same shell
`just` uses, with a command that fails the way an absent stack output does:

```bash
sh -cu 'BASE_DOMAIN="$(false)"; : "${BASE_DOMAIN:?empty baseDomain — run pulumi up first}"; echo "would patch: $BASE_DOMAIN"'; echo "exit=$?"
```

Expected: `BASE_DOMAIN: empty baseDomain — run pulumi up first` on stderr, no
`would patch:` line, non-zero exit. (Before the fix the analogous line printed
`would patch:` with an empty value.) A full `just cluster-bootstrap` against a
context whose Pulumi stack has no `baseDomain` output must now stop at that line
without touching `config-domain`.

**M2-c (context-file rewrite is byte-safe).**

```bash
CTX_FILE="${SBX}/cfg/nagare/contexts/probe.env"
env XDG_CONFIG_HOME="${SBX}/cfg" XDG_STATE_HOME="${SBX}/state" NAGARE_CONTEXT=probe \
  bash -c 'source scripts/lib/target.sh
           source /dev/stdin <<<"$(sed -n "/^set_context_var()/,/^}/p" scripts/migrate-pulumi-backend.sh)"
           log(){ :; }
           set_context_var NAGARE_PULUMI_BACKEND_URL "gs://bucket/a&b|c\\d"'
grep -F 'export NAGARE_PULUMI_BACKEND_URL=gs://bucket/a&b|c\d' "${CTX_FILE}" && echo "REWRITE OK"
```

Expected: `REWRITE OK`, and the file still contains its other `export` lines exactly
once. (Before the fix, `&` and `|` in the value corrupted the written line.)

**M2-d (bucket ownership — logic check offline, full check live-only).** Offline:
re-read `ensure_bucket` and confirm the assertion sits before *every* `update`,
`add-iam-policy-binding`, and before `do_forward`'s `stack init/import` call chain.
Live (optional, requires credentials for the real target project): running
`scripts/migrate-pulumi-backend.sh --url gs://<some-existing-foreign-bucket>/nagare/x`
must print `refusing: gs://… is owned by project number …` and exit non-zero without
running any `buckets update`.

**M3-a (early-death trap is inert).** Force the live smoke to die before its harness
exists, with a deliberately bogus ambient KUBECONFIG standing in for "the operator's
real cluster":

```bash
KUBECONFIG=/nonexistent PATH="/usr/bin:/bin" bash scripts/live-smoke.sh; echo "exit=$?"
```

(The stripped PATH makes step 0/1 fail fast — cabal/gcloud missing.) Expected: the
run fails, and the teardown block prints:

```text
== teardown ==
== teardown: harness never became ready; skipping cluster cleanup ==
== teardown done ==
```

with **no** `nagarectl`, `kubectl`, or `gsutil` invocation attempted in the trap
(before the fix, `nagarectl app delete` ran unconditionally). Same probe for
`bash scripts/local-smoke.sh`. A full positive `just local-smoke` (needs Docker) must
still pass end-to-end and print `local smoke: OK`, proving the guarded cleanup still
runs when the harness *was* ready.

**M3-b (pkill pattern).** Static check plus behavioral spot-check:

```bash
grep -n 'pkill -f' scripts/live-smoke.sh
```

Expected: the pattern interpolates `NAGARE_INSTANCE_NAME` (not `SMOKE_APP`), e.g.
`pkill -f "start-iap-tunnel ${NAGARE_INSTANCE_NAME:-nagare-01} "`. Optionally verify
matching against a synthetic argv:
`(sleep 300 &); pgrep -f "start-iap-tunnel nagare-01 "` returns nothing, then a mock
`bash -c 'exec -a "gcloud compute start-iap-tunnel nagare-01 22" sleep 300 &'`-style
check on Linux; on macOS rely on the grep plus a live smoke run leaving no
`start-iap-tunnel` processes behind (`pgrep -fl start-iap-tunnel` empty after
`just smoke`).

**M3-c (lint gate).**

```bash
shellcheck --severity=error scripts/*.sh scripts/lib/*.sh   # exit 0, no output
shellcheck scripts/local-smoke.sh | grep -c SC2155          # prints 0
nix flake check                                             # passes shellcheck-scripts
```

**Overall acceptance.** All probes above behave as documented; `just local-smoke`
still passes (proving the tightened local whitelist accepts the shipped local
profile); and the three commits exist with Conventional Commit subjects and both git
trailers.


## Idempotence and Recovery

Every edit in this plan is a plain text change to tracked files plus one new tracked
script; re-applying an already-applied edit is a no-op (the Edit instructions specify
exact before/after text, so a second pass finds nothing to change). All validation
probes are read-only with respect to the real environment: they run inside a
disposable `mktemp -d` sandbox (`XDG_CONFIG_HOME`/`XDG_STATE_HOME` overridden), so
they can be re-run any number of times; delete the sandbox with `rm -rf "${SBX}"`
when done.

The one behavioral risk is M1's precedence narrowing: a workflow that *relied* on
`export CLOUDSDK_CORE_PROJECT=<other>` silently overriding the active context will
now fail closed with an explanatory message. That is the intended fix, and the
message names both remedies (unset the override, or select the matching context). If
a milestone must be rolled back, `git revert <commit>` of that milestone's single
commit restores the previous behavior; no state migration is involved anywhere in
this plan. The passphrase-file change is strictly protective (it only *skips* a
truncation); if a passphrase file was already truncated by the old code before this
plan lands, that loss predates the fix and is out of scope here — note it in
Surprises & Discoveries if encountered.

If a smoke-test probe is interrupted mid-run, its own (now-guarded) EXIT trap is the
recovery path; nothing else needs cleanup. If `nix flake check` fails on an
unrelated check, run the targeted
`shellcheck --severity=error scripts/*.sh scripts/lib/*.sh` to isolate whether this
plan's edits are at fault.


## Interfaces and Dependencies

No new external dependencies. Tools used — `bash` (>= 4 for `[[ =~ ]]` and arrays;
already required by every script here), `gcloud`, `pulumi`, `just`, `k3d`,
`kubectl`, `shellcheck`, `nix` — all come from the flake dev shell.

Shell-level interfaces that must exist at the end (all in-repo, full paths):

- `scripts/lib/target.sh` continues to export, on source: `CLOUDSDK_CORE_PROJECT`,
  `CLOUDSDK_COMPUTE_REGION`, `CLOUDSDK_COMPUTE_ZONE`, the `NAGARE_*` contract
  variables, `TARGET_PROJECT`/`TARGET_REGION`/`TARGET_ZONE`/`TARGET_PLATFORM`, and
  the functions `_nagare_resolve_context`, `_nagare_select_pulumi_stack`,
  `_nagare_export_pulumi_env`, `_require_target_project` — signatures unchanged. New
  non-exported global: `_NAGARE_CTX_PROJECT` (string; empty when no context/profile
  declared a project). `_require_target_project` keeps its contract — no arguments,
  returns 0 to proceed and 1 (with stderr diagnostics) to refuse — callers
  (`scripts/iap-ssh.sh:45`, `scripts/live-smoke.sh:21`, `scripts/local-smoke.sh:32`,
  `scripts/upload-images.sh:15`, `scripts/migrate-pulumi-backend.sh:126`, and the
  new `scripts/vm-power.sh`) need no changes beyond those specified.
- `scripts/vm-power.sh <start|stop>` (new, executable): sources
  `scripts/lib/target.sh`, calls `_require_target_project`, execs
  `gcloud --project="${TARGET_PROJECT}" compute instances <verb>
  "${NAGARE_INSTANCE_NAME:-nagare-01}" --zone="${TARGET_ZONE}"`. Exit 2 on usage
  error; otherwise gcloud's exit status.
- `justfile` recipes `vm-stop` / `vm-start` delegate to `scripts/vm-power.sh`;
  `cluster-bootstrap` aborts (via `${BASE_DOMAIN:?…}`) when the Pulumi `baseDomain`
  output is empty.
- `scripts/migrate-pulumi-backend.sh` gains no new flags; `ensure_bucket` refuses
  buckets whose `projectNumber` differs from the target project's;
  `set_context_var` preserves its signature `set_context_var KEY VALUE` (the
  written line may move to the end of the context file).

Plan-ownership boundaries (repeated from Context so they survive excerpting):
`scripts/lib/target.sh` guardrail logic is owned by this plan;
`docs/plans/99-protect-stateful-infrastructure-and-make-secrets-and-state-recoverable.md`
may later change the default `NAGARE_PULUMI_BACKEND` for cloud contexts but must not
modify `_require_target_project` or the resolver's capture/whitelist code;
`docs/plans/103-host-tuning-upgrade-story-and-documentation-reality-sync.md` touches
other `justfile` recipes (version pins) — this plan's `justfile` footprint is
exactly `vm-stop`, `vm-start`, and the `cluster-bootstrap` BASE_DOMAIN line.
