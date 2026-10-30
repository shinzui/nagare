---
id: 230
slug: push-signed-nix-closures-to-the-context-cache-with-one-nagarectl-command
title: "Push signed Nix closures to the context cache with one nagarectl command"
kind: exec-plan
created_at: 2026-10-30T17:45:48Z
intention: "intention_01kx3qz212e989078m6ssetr2b"
master_plan: "docs/masterplans/18-platform-prerequisites-for-the-agent-content-plane-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-30T17:45:48Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-30T21:04:32Z
      mode: "implement"
      note: "M1 and M2 implemented: nix-cache token, forward and push with fake-driven tests"
---

# Push signed Nix closures to the context cache with one nagarectl command

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). It is a child of the MasterPlan named in frontmatter and completes the producer
half of its EP-3 acceptance.


## Purpose / Big Picture

An operator who has built a Nix store path on their workstation can publish it to the active
context's Attic cache with one command: `nagarectl nix-cache push /nix/store/...`. The command
mints a short-lived write token inside the cluster, opens the private port-forward, pushes the
closure through the packaged Attic client, and removes every credential it created, whether it
succeeds, fails or is interrupted. Nothing secret appears in an argument, an environment variable,
a log line or a trace. Today the same work is a hand-typed sequence in
`docs/user/nix-binary-cache.md`: a `kubectl exec` that mints a token, a port-forward, a
hand-written client configuration and a push, with cleanup left to the operator.

Two smaller commands expose the primitives for other producers. `nagarectl nix-cache token`
writes a scoped, expiring token to a private file that a tool such as Kotei can name as its
`token-file`. `nagarectl nix-cache forward` opens the port-forward, prints the loopback endpoint,
cache name and public signing key, and stays open until interrupted. A `push` can also target any
Attic reachable by URL with `--endpoint` and `--token-file`, which is how the local round trip is
proved without a cluster and how a self-run Attic is served.

After this plan an opted-in Job in the cluster substitutes a path the operator pushed, which is
the laptop-push and cluster-substitution half of MasterPlan 18 EP-3's open acceptance. Restart
durability and key rotation remain that MasterPlan's work.


## Progress

- [x] M1: `nix-cache token` and `nix-cache forward` exist, bound to the command's admitted cluster session; fakes prove the token never leaves its 0600 file, the forward uses port 18080 and reports readiness only after Attic answers, and every child process is gone on success, failure and interruption. (2026-10-30: `cli/nagarectl/test/Nagare/Test/NixCacheProducer.hs`, 24 tests green under `-p /NixCacheProducer/`; with the child stop and private-directory removal disabled, 10 of them fail. `nix-cache-endpoint` sample and schema in `docs/api/`.)
- [x] M2: `nix-cache push` composes the primitives for the context cache and accepts an external endpoint; fakes prove path validation precedes any cluster contact, the private token is removed on every exit, and the result document is versioned. (2026-10-30: same module; mint, forward and push recorded in that order, no cluster call in external mode or on a refused path, scratch directory empty after success, failed push and interruption. `nix-cache-push-result` sample and schema in `docs/api/`.)
- [x] M3: A disposable local Attic drill pushes a path through the real command and reads it back with signature verification, with no cluster involved. (2026-10-30, deterministic, on the disposable `nagare-mp23` daemon with `nix build git+file://…?rev=c97054f7#nagare` = `/nix/store/2hjwx25j3sy2f34sc41vm2m34m8qgg3w-nagare-0.12.1`: `scripts/nix-cache-producer-drill.sh` pushed `/nix/store/md7bn6g57nyz18c5zzxsw9jbgf2scq8i-nagare-attic-drill` through `nagarectl nix-cache push --endpoint … --contract 1` (`outcome: pushed`); the narinfo carries `Sig: nagare-cache:vBhj…`; `nix copy` accepted it under the cache's key and refused it under a generated `nagare-cache` key with "lacks a signature by a trusted key"; the token appears in none of the push output, stderr or trace.)
- [ ] M4: On an operator-selected cloud context with the cache enabled, a push of the smoke path is substituted by the positive smoke Pod; the runbook and reference describe the commands; MasterPlan 18's EP-3 progress records the evidence. (2026-10-30: runbook and reference written; the native push and smoke Pod wait for the operator's context and go-ahead.)


## Surprises & Discoveries

2026-10-30: The loopback port is not free to choose. The server configuration template
`cluster/bootstrap/nix-cache/server.toml.tmpl` admits only named hosts and advertises one API
endpoint:

```toml
allowed-hosts = [
  "nix-cache.nagare-system.svc.cluster.local",
  "nix-cache.nagare-system.svc.cluster.local:80",
  "nix-cache-internal.nagare-system.svc.cluster.local:8080",
  "127.0.0.1:18080",
]
api-endpoint = "http://127.0.0.1:18080/"
```

A port-forward on a random local port would be refused by the server's host check, so the
producer commands forward to 127.0.0.1:18080 and refuse when that port is busy (Decision Log).


## Decision Log

2026-10-30: This plan is a child of MasterPlan 18 and covers the workstation producer path only:
minting a token, reaching the private server, pushing, and proving substitution. Delivering a
token to an in-cluster producer Job, and Kotei's own Attic cache flavor, stay outside it. Kotei's
plan for that flavor (`mori://shinzui/kotei/plans/68-publish-signed-closures-to-a-platform-owned-attic-cache`)
consumes exactly an endpoint URL, a cache name and a token-file path, so these commands hand it
those three values and nothing Nagare-specific.

2026-10-30: The commands are Haskell inside `nagarectl`, not `just` recipes around the existing
bash transport. `scripts/inventory-cache-transport.sh` stays the reviewed transport for creating
and configuring the named cache; the producer path is an operator command with typed errors,
fakes and a contract document, as ADR 24 requires for tooling.

2026-10-30: A token is a file, never a value. `nix-cache token` writes only to a new file it
creates with mode 0600 and refuses an existing path. `nix-cache push` mints its own token with a
15-minute validity into a private temporary directory that is removed on every exit. No command
prints a token, passes one in argv, or exports one into a child's environment; the Attic client
reads it through `token-file` in a private configuration.

2026-10-30: The forward binds 127.0.0.1:18080, the only loopback host the server admits. When the
port is busy the command refuses and names the port and the two other users of it,
`nagare nix-cache-status` and the reviewed cache transport. It does not pick another port, since
the server would reject the request anyway.

2026-10-30: kubectl runs through the command's admitted cluster session (EP-226): the session
flattens the selected kubeconfig into a private file and refuses a cluster whose sole server node
is not the context's host. A local context refuses up front, as `cluster guard` does, because the
cache is cloud-only. The commands add no gcloud call.

2026-10-30: `push --endpoint URL --token-file FILE` skips the cluster entirely and pushes to any
Attic. This serves a self-run Attic, matches Kotei's "endpoint is opaque" rule, and is the mode
the local drill uses, so the real command is exercised end to end before any cloud run (ADR 25).

2026-10-30: The option records live in `cli/nagarectl/app/Nagare/Cli/Options/NixCache.hs`, beside
`Options/Site.hs`, so `Options.hs` gains one constructor line; `Dispatch.hs` stays under its
200-line limit by collapsing the `Host` import. The local-context refusal is
`requireCloudContext` in the library so the test suite can reach it. The forward passes
`--address 127.0.0.1` so kubectl binds only the loopback host the server admits.

2026-10-30: The drill runs `atticd --mode monolithic`, not `api-server`: a fresh SQLite
database needs the migrations monolithic mode runs (prototype on the pinned image, which accepts
SQLite and local storage, so no PostgreSQL container is needed). It pushes a derivation output,
not a `nix store add-file` path: Nix accepts a content-addressed path without any signature, so
only an input-addressed path makes the wrong-key copy fail. `nix copy` targets a chroot local
store under the drill root, which enforces `require-sigs`.

2026-10-30: Live confirmation needs a cloud context whose cache is enabled. No current context has
one: the intranet sets `NAGARE_NIX_CACHE_ENABLED='0'` and the others leave the default off.
Enabling it adds a protected bucket, an HMAC key, a managed PostgreSQL database and cluster
workloads through a reviewed Pulumi change and bootstrap, and is the operator's call. M1 to M3
complete without it; M4 waits for the operator to select the context and give the go-ahead.


2026-10-30: The operator chose to wait on M4. No cloud context gets the cache for now; the
commands ship in v0.13.0 and `push --endpoint` serves any Attic, as M3 proved. M4 resumes when
the operator names a context (the intranet if Kotei is the next consumer) and gives the go-ahead
for the reviewed enablement, bootstrap, push and smoke Pods.

## Outcomes & Retrospective


## Context and Orientation

Attic is the Nix binary cache server Nagare runs as an optional, cloud-only platform component
(ADR 21). A closure is a store path plus everything it depends on. A NAR is Nix's archive of one
store path; Attic stores NARs in chunks in a GCS bucket and signs each path with a key that lives
in its PostgreSQL database. A token is a signed JWT that Attic's `atticadm make-token` mints from
the server's RS256 key; it authorizes pull, push or cache configuration for named caches for a
bounded validity. The cache in every Nagare context is named `nagare-cache` and is public for
reads, so pulling needs no token and pushing needs one.

The server is a private ClusterIP Service `nix-cache` in namespace `nagare-system` (template
`cluster/bootstrap/nix-cache/workloads.yaml.tmpl`), whose container runs
`atticd -f /config/server.toml --mode api-server` with the RS256 key from Secret
`nagare-nix-cache-token-key`. The same image carries `atticadm`. The manual producer path in
`docs/user/nix-binary-cache.md` ("Push a closure") is the specification this plan automates:

```bash
kubectl -n nagare-system exec deployment/nix-cache -- \
  atticadm -f /config/server.toml make-token \
    --sub operator-push --validity 1h --pull nagare-cache --push nagare-cache > token
kubectl -n nagare-system port-forward service/nix-cache 18080:80
XDG_CONFIG_HOME="$private_dir/attic" attic push nagare:nagare-cache "$store_path"
```

with a client configuration at `$private_dir/attic/attic/config.toml` naming
`default-server = "nagare"`, `endpoint = "http://127.0.0.1:18080/"` and `token-file`.
`scripts/inventory-cache-transport.sh` already does the same three things in bash for the reviewed
cache creation: it targets `kubectl --context CTX --request-timeout=10s`, forwards 18080:80,
polls `http://127.0.0.1:18080/` with header `Host: 127.0.0.1:18080` until the body contains
`Attic Binary Cache`, mints a five-minute bootstrap token with `--create-cache`,
`--configure-cache` and `--configure-cache-retention`, writes the client configuration with mode
0600, and runs `attic cache create` and `attic cache configure`. The cache's public configuration,
including the public signing key, is at `/_api/v1/cache-config/nagare-cache`, which
`cluster/bootstrap/nix-cache/status.sh` reads the same way. These are the exact argument vectors
the new module reproduces.

The packaged Attic client is on the operator wrapper's PATH: `nix/haskell-packages.nix` appends
`operatorTools`, which includes `atticClient`, to `operatorNagarectl`, and the `nagare` output
also exposes `attic` directly. A `cabal` development build has no `attic` on PATH, which is why
the Haskell tests use fakes and the drill uses the packaged build.

`cli/nagarectl/src/Nagare/Inventory/ClusterSession.hs` (EP-226) is the guard. `commandClusterSession`
takes `SessionOps`, the context name and the expected host node and returns the command's admitted
session; `kubectlConnectionArguments` returns the `--kubeconfig PRIVATE --context CTX` arguments
every kubectl call must carry. `Nagare.Host.Config.readContextHostName` gives the expected node, as
`runCluster` in `cli/nagarectl/app/Nagare/Cli/Commands/Host.hs` shows for `cluster guard`,
including its refusal for a local context. `Nagare.Cli.Dispatch.dispatchTraced` already wraps
every command in `withCommandScope`, so sessions and traces need no extra setup.

`cli/nagare-dsl/src/Nagare/Dsl/Load/Process.hs` (`runConfigUntil`) is the house pattern for a
child process that must not outlive the command: it runs the child in its own process group and
kills the group with SIGKILL on expiry, because a child can ignore SIGTERM and anything it spawned
keeps the pipes open. The port-forward child follows it. The threaded RTS is required for
`waitForProcess`, which the executable already uses.

The CLI boundary is `cli/nagarectl/app/Nagare/Cli/Options.hs` (command and option types; 952 of
its 1000-line allowance are used, so additions must stay small or the architecture check
refuses), a parser per group under `cli/nagarectl/app/Nagare/Cli/Parser/`, a command module per
group under `cli/nagarectl/app/Nagare/Cli/Commands/`, and `cli/nagarectl/app/Nagare/Cli/Dispatch.hs`,
which wraps contract-bearing commands with `withContract`. `scripts/audit-managed-commands.py`
keeps the exhaustive constructor registry in `ROUTES`; a group constructor goes in the `Command`
table's `group` list and its own table names each subcommand's category, where `bounded` means a
specifically constrained transport. `docs/architecture/managed-resource-coverage.md` carries the
catalogue between its registry markers, and `scripts/test-managed-command-audit.sh` fails on an
unregistered constructor. Contract documents live in `cli/nagare-contract` (`Nagare.Contract.V1`,
`Nagare.Contract.Project`) with samples under `docs/api/samples/`; `Nagare.Contract.Sink` emits
them. Tests register in `cli/nagarectl/test/Nagare/Test/Suite.hs`, which is at its 300-line
limit, so a new module's tests join the existing `Nagare.Ops` group line.

`cluster/bootstrap/nix-cache/smoke/flake.nix` builds the deterministic path
`/nix/store/1rp5453vmy2839v1frykkx9wa578gsam-nagare-attic-smoke` for x86_64-linux from every
operator system, which on this aarch64-darwin workstation means the configured remote builder.
`cluster/bootstrap/nix-cache/smoke-pod.yaml` is the consumer proof: its positive Pod realises
that path with `--option max-jobs 0 --option fallback false`, so it either substitutes from the
context cache or fails, and its negative Pod must be refused by a wrong public key.
`nix/attic.nix` pins the server image (`serverImage`, a Docker archive) that the local drill loads.

Relevant decisions: [ADR 21](../adr/0021-nagare-owns-an-optional-context-local-nix-cache-provider.md)
makes Nagare the single cache provider per context with per-context trust and leaves producer
policy to consumers; [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
requires every cloud-mutating path to be bound to the active context, which the cluster session
supplies here; [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
keeps the JWT key in operator-owned sops material, so tokens are minted inside the cluster and
never derived locally; [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md)
puts the tooling in Haskell; [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
orders fakes, then the local drill, then one native confirmation. Kotei's consumer-side decision
is its ADR-9 at `mori://shinzui/kotei`, project-relative
`docs/adr/0009-kotei-consumes-a-platform-owned-nix-binary-cache.md` (artifact-level URI pending; the
registry does not yet index that bundle). ADRs here use the filesystem convention.


## Plan of Work

### M1 — Token and forward primitives


Add `cli/nagarectl/src/Nagare/Ops/NixCacheProducer.hs`, registered in `cli/nagarectl/nagarectl.cabal`.
It owns pure argument builders (`makeTokenArguments`, `portForwardArguments`, `pushArguments`,
`cacheConfigUrl`), the client configuration renderer, a `ProducerOps` record of injectable
effects (run kubectl capturing stdout, start a long-lived child in its own process group and kill
it, probe an HTTP URL with a Host header, run the Attic client with a given `XDG_CONFIG_HOME`,
write a private file, sleep), `defaultProducerOps` for the real programs, typed errors with
one-line renderers, and the three operations. Token minting runs
`kubectl <session args> --request-timeout=10s -n nagare-system exec deployment/nix-cache --
atticadm -f /config/server.toml make-token --sub SUBJECT --validity VALIDITY --pull nagare-cache
--push nagare-cache` and writes stdout, trimmed, to the destination file created with mode 0600.
Subject defaults to `operator-push` and must match `^[A-Za-z0-9._-]+$`; validity defaults to `1h`,
accepts Attic's duration syntax and refuses more than `24h`. The forward starts
`kubectl <session args> -n nagare-system port-forward service/nix-cache 18080:80`, refuses first
if 127.0.0.1:18080 is already bound, then probes `http://127.0.0.1:18080/` with
`Host: 127.0.0.1:18080` until the body contains `Attic Binary Cache`, at most 30 times one second
apart, and reads `/_api/v1/cache-config/nagare-cache` for the public key. A forward that dies or
never answers is an error that names the port-forward's last stderr line.

Add `NixCacheCommand` with `NixCacheToken`, `NixCacheForward` and `NixCachePush` constructors and
their option records to `Options.hs`, `cli/nagarectl/app/Nagare/Cli/Parser/NixCache.hs`,
`cli/nagarectl/app/Nagare/Cli/Commands/NixCache.hs`, a `NixCache` arm in `Dispatch.hs`, the audit
`ROUTES` entries (`NixCache` in the `Command` group list; a `NixCacheCommand` table with all three
as `bounded`) and a catalogue row. The command module resolves the active target as
`runCluster` does, refuses local mode with "the Nix cache is a cloud-only component and is
unavailable for local contexts", obtains the admitted session and its kubectl arguments, and
hands `ProducerOps` to the library. `forward` prints, on readiness, one human line
`forwarding nagare-cache at http://127.0.0.1:18080/ (public key nagare-cache-1:...)` or, with
`--contract 1`, one `nix-cache-endpoint` document with `endpoint`, `cache` and `publicKey`, then
blocks until SIGINT, SIGTERM or the child's exit, and exits non-zero only when the child died.

Tests in `cli/nagarectl/test/Nagare/Test/NixCacheProducer.hs`, joined to the `Nagare.Ops` group:
exact argument vectors; the token file exists with mode 0600, holds the fake's stdout trimmed,
and an existing destination is refused untouched; the token bytes appear in no recorded argv,
no child environment, no stdout, no stderr and no trace document; subject and validity
validation; the forward refuses a bound port before starting kubectl; readiness waits for the
probe and gives up after the bound; the child is killed on success, on probe failure and when the
calling thread receives an asynchronous exception; the local-mode refusal; and the contract
document round-trips through its sample.

### M2 — One-command push


Add the push operation: validate every argument is an absolute `/nix/store/` path present in the
local store (`nix path-info PATH` through the injected runner) before any cluster contact, then in
context mode mint a 15-minute token with subject `operator-push` into a private directory
(`mktemp`-style under the system temporary directory, mode 0700), write the client configuration
there with `token-file` pointing at it, open the forward, run `attic push nagare:nagare-cache
PATH...` with `XDG_CONFIG_HOME` set to that directory and the Attic client's stdout and stderr
passed through to stderr, and remove the directory and kill the forward on every exit. In
external mode (`--endpoint URL --token-file FILE`, both required together, `--cache NAME`
defaulting to `nagare-cache`) skip the session, the token minting and the forward; the
configuration points at the given endpoint and file, and the file is read only by the client.
The result is a `nix-cache-push-result` contract document with `endpoint`, `cache`, `paths`
and `outcome`, emitted under `--contract 1`; the human line is
`pushed N paths to nagare-cache at ENDPOINT`. Exit code follows the Attic client.

Tests: path validation refuses a relative path, a missing path and a non-store path with no
kubectl call recorded; context mode records exactly one token mint, one forward and one push in
that order; external mode records no kubectl call; the private directory is absent after
success, after a failed push and after an interruption during the push; the push argument vector
and the configuration bytes; and the result document sample.

### M3 — Local Attic round trip without a cluster


Add `scripts/nix-cache-producer-drill.sh`, in the shape of the existing drills: it requires a
disposable `DOCKER_HOST` and refuses the shared cp3 socket, requires `NAGARE_DRILL_NAGARE` (the
`nix build .#nagare` output, whose `bin` has both `nagarectl` and `attic`), creates a private root,
loads the pinned server image from `nix build .#attic-server-image` (add that flake output from
`nagarePackages.attic.serverImage` if it is not already exposed), writes a drill `server.toml`
with SQLite at `/data/attic.db`, `storage.type = "local"`, `allowed-hosts = ["127.0.0.1:18080"]`,
`api-endpoint = "http://127.0.0.1:18080/"` and an RS256 key generated as
`cluster/bootstrap/nix-cache/create-secret.sh` generates it, and runs `atticd --mode api-server`
with port 18080 published on loopback. It mints an admin token inside the container exactly as
the reviewed transport does, creates `nagare-cache` public with `attic cache create`, mints a
push-only token to a 0600 file, builds a small local path with
`nix build --impure --expr 'with import <nixpkgs> {}; writeText "nagare-attic-drill" "v1"'`, runs
`nagarectl nix-cache push --endpoint http://127.0.0.1:18080/ --token-file FILE PATH --contract 1`,
and proves the result two ways: the narinfo at `http://127.0.0.1:18080/nagare-cache/HASH.narinfo`
carries a `Sig: nagare-cache:` line, and `nix copy --from http://127.0.0.1:18080/nagare-cache
--to file://$ROOT/store PATH --option trusted-public-keys KEY` succeeds while the same copy with a
wrong key fails. It records both outputs under the drill root and stops at the first refusal.

The one assumption to settle first, as a bounded prototype: that the pinned image's `atticd`
accepts SQLite and local storage. If it does not, run a PostgreSQL container beside it in the
drill; the acceptance does not change.

### M4 — Native confirmation, documentation and the parent's evidence


On the cloud context the operator selects, with the cache enabled and bootstrapped, run
`nagarectl nix-cache push "$(nix build cluster/bootstrap/nix-cache/smoke --print-out-paths)"`,
then apply `cluster/bootstrap/nix-cache/smoke-pod.yaml` and wait for the positive Pod to log
`substituted /nix/store/1rp5...-nagare-attic-smoke from http://nix-cache-internal...` and the
negative Pod to log `wrong key rejected as expected`. Record the candidate revision, context,
token subject, elapsed times and both Pod logs under `docs/audits/ep230-nix-cache-producer.md`,
never a token.

Replace the manual block in `docs/user/nix-binary-cache.md` "Push a closure" with the three
commands and one paragraph on what `push` does, keeping its OKF frontmatter valid, and add the
commands to `docs/user/reference.md` beside the `nagare nix-cache-*` rows. Tick the laptop-push
and cluster-substitution halves of MasterPlan 18 EP-3's last Progress line with the audit link,
leaving restart durability and key rotation open.


## Concrete Steps


Run from the repository root. Contributor checks after each Haskell change:

```bash
just haskell-style-check
python3 scripts/check-haskell-architecture.py
bash scripts/test-managed-command-audit.sh
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p /Nagare.Ops/' --test-show-details=direct
```

After each meaningful commit, `just gate-fast <sha>`; before the native run, the full gate on
the exact candidate and `docs/runbooks/before-a-native-run.md`.

The commands this plan delivers, from an operator shell whose active context is a cloud context
with the cache enabled:

```bash
nagarectl nix-cache token --out "$private/token"          # writes a 1h pull+push token, mode 0600
nagarectl nix-cache forward                               # prints the endpoint and stays open
nagarectl nix-cache push "$(nix build .#closure --print-out-paths)"
nagarectl nix-cache push --endpoint https://cache.example.com/ --token-file "$private/token" --cache team /nix/store/...
```

Expected human output of a context push:

```text
pushed 1 paths to nagare-cache at http://127.0.0.1:18080/
```

The local drill, on a disposable Docker daemon:

```bash
DOCKER_HOST=unix:///path/to/disposable/docker.sock \
NAGARE_DRILL_NAGARE="$(nix build .#nagare --no-link --print-out-paths)" \
bash scripts/nix-cache-producer-drill.sh
```

Its last lines name the pushed path, the narinfo signature line and the two `nix copy`
outcomes. For the native run, the push and the smoke Pod commands above, recorded in the audit
file.


## Validation and Acceptance


M1 and M2 are accepted by the fake-driven tests listed in their milestones, with the
no-token-leak test reading every recorded argv, environment, stdout, stderr and the trace
document written with `NAGARE_TRACE_FILE`. M3 is accepted when the drill ends with a signed
narinfo and a successful `nix copy` under the right key and a refused one under the wrong key,
through the real `nagarectl nix-cache push`. M4 is accepted only by the positive smoke Pod's
`substituted` line on a cloud context after a push by the command; a saved review, a green gate
or a successful push alone is not acceptance. The evidence must say which checks were
deterministic and which were native.


## Idempotence and Recovery

Minting a token creates nothing durable; an expired or unused token needs no cleanup. Pushing the
same path twice is a no-op at the server, which already holds the NAR. A push interrupted midway
leaves at most partial chunks that Attic's garbage collection reclaims under the 30-day retention;
rerunning the command completes the path. The forward and the private directory are owned by the
command and removed on every exit; if a previous forward was left by another tool, the command
refuses port 18080 and names it rather than killing it. The drill is self-contained under its
root and can be rerun after removing that root and the drill container.


## Interfaces and Dependencies

`Nagare.Ops.NixCacheProducer` exposes `ProducerOps`, `defaultProducerOps`, `mintToken`,
`withForward`, `pushPaths`, the pure builders and `renderProducerError`. `Nagare.Inventory.ClusterSession`
supplies `commandClusterSession` and `kubectlConnectionArguments`; `Nagare.Host.Config.readContextHostName`
the expected node; `Nagare.Contract.V1` gains `NixCacheEndpoint` and `NixCachePushResult`
with samples `docs/api/samples/nix-cache-endpoint.json` and `docs/api/samples/nix-cache-push-result.json`.
Programs invoked: `kubectl`, `attic` (packaged), `nix` (`path-info`, and `copy` in the drill),
`atticadm` inside the server image. No new Haskell dependency; process handling uses the
`process` package as `Nagare.Dsl.Load.Process` does.

Prerequisites from the parent: MasterPlan 18 EP-3's provisioning and bootstrap deliverables are
accepted (2026-10-17, `5bd7d7e2`), and the reviewed cache transport creates and configures the
named cache. The native run additionally needs a cloud context with `NAGARE_NIX_CACHE_ENABLED=1`
through the reviewed enablement in `docs/user/nix-binary-cache.md`, which is the operator's
decision. Commits carry this plan's ExecPlan trailer and the frontmatter intention's Intention
trailer. At completion, distill the producer-path contract (token as file, fixed loopback host,
session-bound kubectl) into ADR 21 as an amendment rather than a new ADR.
