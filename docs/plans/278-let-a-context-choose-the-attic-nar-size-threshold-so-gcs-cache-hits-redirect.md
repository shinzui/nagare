---
id: 278
slug: let-a-context-choose-the-attic-nar-size-threshold-so-gcs-cache-hits-redirect
title: "Let a context choose the Attic NAR size threshold so GCS cache hits redirect"
kind: exec-plan
created_at: 2026-11-23T05:03:41Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-23T05:03:41Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-23T05:45:07Z
      mode: "implement"
      note: "M1 implemented; M2 docs and reseed rehearsal"
---

# Let a context choose the Attic NAR size threshold so GCS cache hits redirect

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

This plan fixes BUG-11,
[Forced Attic chunking makes GCS-backed cache hits slow](../bug-reports/forced-attic-chunking-slows-gcs-cache-hits.md).
Nagare's managed Attic cache always splits NARs larger than 64 KiB into chunks. When a client asks
for a chunked NAR, Attic downloads every chunk from GCS and streams the reassembled archive through
the cache Pod. On Labs this made a Bun NAR take 19 to 24 seconds. The same NAR stored as one
object took 0.44 seconds because Attic answered with an HTTP 307 redirect to a presigned GCS URL. A
fresh Kotei UI image build took 102 seconds with the managed cache preferred and 67 seconds with
the public cache alone.

After this change an operator can set `NAGARE_NIX_CACHE_NAR_SIZE_THRESHOLD=0` in a cloud context.
Bootstrap and platform upgrades then render that value into the Attic server configuration. Newly
pushed NARs are stored whole, and a cache hit becomes a redirect to GCS. A documented reseed moves
the NARs that are already chunked onto the new layout. The signing key and consumer trust do not
change. Contexts that do not set the variable keep today's threshold of 65536 bytes. For them the
server ConfigMap is byte-identical, so an upgrade does not roll the cache out.

To see it working, run `curl -s -o /dev/null -w '%{http_code}\n'` against a repushed NAR's URL from
an opted-in Pod. It prints `307`, and the fresh Kotei UI build with Attic preferred is no slower than
the build that uses the public substituter alone.


## Progress

- [x] M1 (2026-11-22): A context can choose the threshold. `NAGARE_NIX_CACHE_NAR_SIZE_THRESHOLD` (bytes; default
  `65536`; `0` disables chunking) is parsed and validated, stored in context files, pinned to the
  stored context like `NAGARE_NIX_CACHE_BUCKET`, and rendered into `server.toml`. Unit tests show
  four things. The default renders a server config byte-identical to v0.27.0's. Zero renders
  `nar-size-threshold = 0` with a different revision. Malformed values are refused. An environment
  override cannot change a named context's value. `just gate-commit` is green.
  Evidence: `default NAR size threshold renders the v0.27.0 server config`, `zero NAR size
  threshold disables chunking under a new revision`, `the Attic NAR size threshold is plain decimal
  bytes (BUG-11)` and the extended pinned-profile and Init round-trip tests pass; `just
  gate-commit` green (nagarectl suite, 121 s). The parser lives in `Nagare.Target.Kinds` and the
  context-map lookups moved to `Nagare.Target.ContextFile`, because the architecture audit refuses
  modules over 1000 lines.
- [x] M2 (2026-11-22): Documentation and reseed procedure. `docs/user/reference.md`,
  `docs/user/nix-binary-cache.md`, `cluster/bootstrap/nix-cache/README.md` and an ADR 21 amendment
  describe the choice and its trade-off. The user guide gains a reseed procedure that preserves the
  signing key and has a rollback at each step. The procedure has been rehearsed once against a
  disposable Attic, PostgreSQL and S3-compatible store in local Apple containers. In that rehearsal a
  NAR that was chunked before returned 307 after the reseed, and `nix store verify --sigs-needed 1`
  passed.
  Evidence (Apple containers: pinned Attic amd64 binaries, PostgreSQL 18, MinIO): at `65536` a
  9.3 MB NAR was stored as 136 chunks and served `200`; a repush at `0` without the reseed still
  served `200`. The side-table delete gave `404` and its rollback `200`. One collection took the
  bucket from 137 objects to 1 and the chunked count to `0`. After the repush the NAR returned `307`
  (and a single-chunk control path `307`), the public key `nagare-cache:det4T+…` was unchanged, a
  60-path closure copied into a fresh store with `require-sigs`, `--max-jobs 0` and `fallback false`,
  `nix store verify --sigs-needed 1 -r` passed, and a wrong key was refused as untrusted. The pinned
  image would not start under Apple containers as published ([FRIC-20](../friction-log/20-apple-containers-cannot-start-the-pinned-attic-image.md)).
- [ ] M3: Labs rollout, which needs the operator's go-ahead. A release containing M1 is upgraded onto
  Labs. Labs sets the threshold to `0` and bootstraps, and the reseed runs. From a fresh Job, the
  Bun 1.4.2 and Caddy 2.11.7 NARs return 307 and download in under 1 second, and signed pulls pass
  with builders and fallback disabled. A fresh Kotei UI console-image build of
  `c8d465d16d00fac0a69d6d1ec23c721caceba56f` with Attic preferred is timed and compared against the
  67-second public-only baseline. BUG-11 records the fixed version.


## Surprises & Discoveries

- `nagarectl db restore` restores only into a new scratch database
  (`docs/user/backups-and-disaster-recovery.md`), so the planned `db backup` could not roll the
  reseed's delete back in place. This changed the reseed's rollback; see the Decision Log.
- Attic's collector prints only its banner at the default log level, so the procedure checks
  `SELECT count(*) FROM nar WHERE num_chunks > 1` instead of a `Deleted N orphan NARs` line.


## Decision Log

- Decision: The default stays `65536`. Zero is an opt-in for each context.
  Rationale: Nagare serves installations other than Labs, and the operator rule is not to change
  their behaviour silently. Because the default is unchanged, the rendered ConfigMap and
  `serverConfigDigest` stay identical, and an upgrade does not restart Attic or rerun its migration
  Job. Whole-NAR storage gives up Attic's cross-NAR chunk deduplication, so GCS usage grows. Each
  operator should take that trade-off knowingly.
  Date: 2026-11-22

- Decision: The reseed deletes the `nagare-cache` objects whose NAR has more than one chunk, runs
  Attic's garbage collector once, and then repushes. It does not destroy and recreate the cache,
  and it does not use a new metadata database.
  Rationale: Attic stores the NAR signing keypair on the cache row. Destroying the cache would
  change the public key in `nagare-nix-cache-client` and break consumer trust. A new database
  would lose the signing identity as well. Attic deduplicates an upload by NAR hash
  (`server/src/api/v1/upload_path.rs`, `find_and_lock_nar`), so a repush reuses the chunked NAR
  while its row exists. The garbage collector deletes a NAR only once no object references it
  (`server/src/gc.rs`, `run_reap_orphan_nars`). Collection must therefore run between the delete
  and the repush. Only NARs with `num_chunks > 1` are affected. A single-chunk NAR already
  redirects (`server/src/api/binary_cache.rs`, `chunks.len() == 1`).
  Date: 2026-11-22

- Decision: The reseed is a documented operator procedure, not a new `nagarectl` command.
  Rationale: Each existing context runs it once, after it opts in. The cache is rebuildable
  transport (ADR 21), and the signing key is never touched. The operator rule is to prefer fewer
  steps and fewer tools.
  Date: 2026-11-22


- Decision: The reseed copies the `object` rows it removes into a side table,
  `nagare_reseed_object`, in the same transaction, instead of taking a `nagarectl db backup` first.
  Rollback before collection is `INSERT INTO object SELECT * FROM nagare_reseed_object`.
  Rationale: `db restore` restores only into a scratch database, so it could not undo the delete.
  Nothing references `object`, and `chunkref` cascades only on NAR deletion
  (`server/src/database/migration/` in the pinned Attic), so the copy restores the cache exactly
  while every chunk is still in GCS. It is one SQL statement rather than a reviewed backup flow,
  and the cache row with the signing key is never touched, so the daily
  `nagare-dbbackup-nix-cache` backup remains the signing-identity boundary.
  Date: 2026-11-22

## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

**Attic** is the Nix binary cache server that Nagare runs in `nagare-system` when a cloud context
sets `NAGARE_NIX_CACHE_ENABLED=1`. Its pinned source is `github:zhaofengli/attic` at
`12cbeca141f46e1ade76728bce8adc447f2166c6`; see `flake.nix` and `nix/attic.nix`. Read that
source with `gh api "repos/zhaofengli/attic/contents/<path>?ref=12cbeca141f46e1ade76728bce8adc447f2166c6" -H "Accept: application/vnd.github.raw"`;
the user's rules forbid browsing `/nix/store`. A **NAR** is the archive of one Nix store path. A
**chunk** is a piece of a NAR that Attic stores as its own GCS object. Attic's
`[chunking] nar-size-threshold` decides the layout of each new upload (`server/src/config.rs` and
`upload_path.rs`). A value of `0` means never chunk. A NAR smaller than a non-zero threshold is
stored whole. Any other NAR is cut into content-defined chunks of `min-size`, `avg-size` and
`max-size` bytes. When a client downloads a single-chunk NAR, the S3 backend answers with a
presigned GCS redirect. A multi-chunk NAR is reassembled in the server and streamed. Chunk sizes
have no effect when the threshold is `0`.

The relevant Nagare code:

- `cluster/bootstrap/nix-cache/server.toml.tmpl` is the packaged server configuration. Today it
  hard-codes `nar-size-threshold = 65536`, and its only placeholder is `${NAGARE_NIX_CACHE_BUCKET}`.
- `cli/nagarectl/src/Nagare/Inventory/Cache.hs`, `compileCacheNative`, reads that template and
  requires exactly one bucket placeholder. It substitutes `renderBucket` and builds ConfigMap
  `nagare-nix-cache-server`. It hashes the rendered text into `serverConfigDigest`. The revision
  digest, made from the image and `serverConfigDigest`, names the config-check and migration Jobs
  and drives the Deployment rollout. `validateInputs` checks the image and the bucket. The input
  record is `CacheRenderInput`.
- `cli/nagarectl/src/Nagare/Inventory/Components/PackagedCache.hs`, `compilePackagedCache` and
  `compilePackagedCacheWithVerifiedImage`, builds `CacheRenderInput` from positional arguments. It
  receives the cache bucket last.
- `cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs` (around line 255) calls
  `compilePackagedCache` with `profile ^. #nixCacheBucket` when `nixCacheEnabled` is set. Normal
  `cluster-bootstrap` and platform upgrade both reach this path.
- `cli/nagarectl/src/Nagare/Target.hs` holds `TargetProfile`, the resolved context. It parses
  context files in two places: `profileFromContextMap` (pure; used for the stored profile) and
  `resolveProfileFrom` (IO; environment over context over default). It renders them back in
  `renderContextShellEnv`. In `resolveActiveTarget`, around line 905, it pins fields such as
  `nixCacheBucket` to the stored context so that a stale shell variable cannot change them.
  `validateNixCacheMode` refuses the cache for local contexts.
- `cli/nagarectl/src/Nagare/Init.hs` provides `renderTargetEnv` (writes context files),
  `initFlagPairs` and the init summary. `cli/nagarectl/app/Nagare/Cli/Runtime/Context.hs`
  provides `contextEnvPairs` for `nagarectl context create`.
  `cli/nagarectl/app/Nagare/Cli/Parser/Context.hs` (lines 54 and 95) and
  `cli/nagarectl/app/Nagare/Cli/Options.hs` declare the `--nix-cache-bucket` flags for init and
  context create. `cli/nagarectl/app/Nagare/Cli/Commands/Init.hs` (around line 295) applies them.
- `cli/nagarectl/app/Nagare/Cli/Platform/Upgrade.hs`, `bootstrapEnvironment`, forwards only the
  enable flags and sets `NAGARE_RESOLVED_CONTEXT=upgrade-transaction`, which makes bootstrap
  re-source the persisted context. A pinned profile field therefore reaches the upgrade path with
  no forwarding.
- `scripts/lib/target.sh` lists the contract variables it clears from stale shells (line 37) and
  exports defaults (around line 240).
- Tests: `cli/nagarectl/test/InventoryCacheSpec.hs` (group `cache inventory adapter`, fixture
  `renderInput`), `cli/nagarectl/test/Nagare/Test/Context.hs` (the pinned-profile test near line
  395), `cli/nagarectl/test/Nagare/Test/Init.hs`, `cli/nagarectl/test/Nagare/Test/Support/Profiles.hs`
  and `cli/nagarectl/test/HostSpec.hs` (both build a full `TargetProfile` literal), and
  `cli/nagarectl/test/InventoryObservabilitySpec.hs` (calls `compilePackagedCacheWithVerifiedImage`).
- `cli/nagarectl/test/fixtures/transition-0.4.0/payload/` is a digest-bound copy of an old payload.
  Do not edit it.

ADRs: [ADR 21](../adr/0021-nagare-owns-an-optional-context-local-nix-cache-provider.md) makes
Nagare the owner of one optional Attic per cloud context. It keeps the NAR signing key in
PostgreSQL, so a database backup is the boundary for recovering the signing identity. It treats the
cache as rebuildable transport and allows client HTTPS egress because Attic redirects to presigned
GCS URLs. This plan stays within that decision. It changes a configuration value and adds an
amendment saying the chunking layout is chosen per context.
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
puts the real Labs context file in the operator's private repository. Labs therefore opts in
there, not in this repository. No other ADR is relevant.

The user-facing contract is
[Use Case 002](../use-cases/002-deliver-prebuilt-nix-closures-to-nagare-jobs.md): fresh Jobs reuse
signed closures. The Labs measurements come from
`mori://tan/tan-ng-labs/plans/23-enable-the-shared-attic-cache-on-labs`.


## Plan of Work

### M1: the context field and the renderer

Add `nixCacheNarSizeThreshold :: !Word64` to `TargetProfile`, after `nixCacheBucket`, with a
haddock line naming `NAGARE_NIX_CACHE_NAR_SIZE_THRESHOLD`, its default `65536`, and the meaning of
`0`. Add a pure parser to `Nagare.Target`,
`parseNixCacheNarSizeThreshold :: Maybe Text -> Either Text Word64`. Missing or empty input yields
`65536`. Any other input must be ASCII decimal digits that fit a `Word64`. Signs, spaces and
suffixes such as `64K` are refused with a message that names the variable. Use it in
`profileFromContextMap` the way `parseIngressMode` is used there (`error` on a malformed value) and
in `resolveProfileFrom` (`ioError`). Pin the field to the stored profile in `resolveActiveTarget`
next to `nixCacheBucket`. Render it in `renderContextShellEnv` and `renderTargetEnv`. Add an
optional `--nix-cache-nar-size-threshold BYTES` flag next to `--nix-cache-bucket` for both
`nagarectl init` and `nagarectl context create`, and route it through `initFlagPairs`,
`contextEnvPairs` and `Commands/Init.hs`. Add one line to the init summary. Fill the two test
profile literals. In `scripts/lib/target.sh`, add the variable to the clear list and export a
default of `65536`. No shell code reads it.

In `server.toml.tmpl`, replace `nar-size-threshold = 65536` with
`nar-size-threshold = ${NAGARE_NIX_CACHE_NAR_SIZE_THRESHOLD}`. In `Nagare.Inventory.Cache`, add
`renderNarSizeThreshold :: !Word64` to `CacheRenderInput`. Require exactly one occurrence of the new
placeholder, as the bucket check does, and substitute the decimal text before hashing. The digest
and every downstream name follow automatically. Thread the value through `compilePackagedCache` and
`compilePackagedCacheWithVerifiedImage`, then through `Bootstrap/Platform.hs`
(`profile ^. #nixCacheNarSizeThreshold`) and the three test call sites.

Tests:

- In `InventoryCacheSpec`, add a golden check. Render `renderInput` with `65536` and assert that the
  ConfigMap's `server.toml` equals the v0.27.0 template text with the bucket substituted. Paste
  that expected text as a literal in the test, so that a later template edit cannot pass
  unnoticed. Render with `0` and assert that the text contains `nar-size-threshold = 0\n` and
  that the revision suffix in the migration Job name differs from the default's.
- In `Nagare.Test.Context`, add a test for the parser. Missing gives `65536`, and `"0"` gives `0`.
  `"-1"`, `"64K"`, `" 0"` and `"18446744073709551616"` are refused.
- Extend the pinned-profile test so that setting the environment variable to `0` leaves a named
  context's stored `65536`.
- Add an Init or Context round-trip. Rendering a profile with `0` and parsing it back yields `0`.

### M2: documentation, ADR amendment and reseed rehearsal

Update `docs/user/reference.md` (one table row) and `cluster/bootstrap/nix-cache/README.md`
(the redirect paragraph now names the threshold). Give `docs/user/nix-binary-cache.md` a short
"Choose the chunking threshold" section covering the redirect speed-up, the loss of chunk
deduplication, the fact that only new uploads follow the setting, and the opt-in line for a
context file. Follow it with "Move existing NARs to whole-object storage", which holds the
procedure in Concrete Steps. Append a dated amendment paragraph to ADR 21's Consequences.

Rehearse the reseed in local Apple containers. Run the pinned Attic image with PostgreSQL and an
S3-compatible store such as MinIO, using threshold `65536`. Push a NAR larger than 256 KiB and
confirm that its download is not a redirect. Switch the threshold to `0`, restart, and run the
procedure. Then confirm that the same NAR URL returns 307 and that a client with only that
substituter and its public key passes `nix store verify --sigs-needed 1`. MinIO's presigned URL
stands in for GCS here. The rehearsal checks the SQL, the order of steps and the preservation of
the key; it does not measure GCS speed. If Apple containers cannot host the stack, record why and
rehearse on a remote Linux builder.

### M3: Labs rollout

Cut a release with the nagare-release skill. Then ask the operator once for this bounded sequence:
upgrade Labs to the release, add `export NAGARE_NIX_CACHE_NAR_SIZE_THRESHOLD=0` to the Labs
context in the operator repository, run bootstrap, and run the reseed. Measure again as the bug
report's reproduction does. Record the numbers in Progress and set BUG-11's fixed version in its
frontmatter, as commit `4f2831a3` did for BUG-10. Labs' substituter priorities live in the
operator repository, and the operator decides whether to prefer Attic again.


## Concrete Steps

M1 checks, from the repository root:

```bash
just haskell-style-check
just gate-commit
```

The test patterns that focus the work while iterating (run from `cli/nagarectl`):

```bash
cabal test nagarectl-test --test-option=-p --test-option='/cache inventory adapter/'
cabal test nagarectl-test --test-option=-p --test-option='/context/'
```

The reseed procedure, for M2 and M3, is the section "Move existing NARs to whole-object storage"
in `docs/user/nix-binary-cache.md`. Run it against the active cloud context after bootstrap has
rolled out the zero threshold. In order:

1. Note the public key from `nagare nix-cache-status` and suspend CronJob `nix-cache-gc`.
2. In `nix-cache-db-0`, inspect `SELECT name FROM cache` and the count of `nar` rows with
   `num_chunks > 1`.
3. In one transaction, copy the `nagare-cache` `object` rows whose NAR has `num_chunks > 1` into
   `nagare_reseed_object`, then delete them from `object`.
4. Run `nix-cache-gc` once as a Job and confirm `SELECT count(*) FROM nar WHERE num_chunks > 1`
   returns `0`.
5. Repush the producer closures, drop `nagare_reseed_object`, resume the CronJob, and compare
   the public key.

Do not push anything else and do not bootstrap during the procedure: an early push can reattach
a path to a chunked NAR, and bootstrap clears the CronJob suspension. The local rehearsal ran
the same SQL with `container exec -i ep278-pg` in place of `kubectl exec` and
`atticd --mode garbage-collector-once` in place of the CronJob.


## Validation and Acceptance

M1 is accepted when `just gate-commit` passes with the new tests and the default golden render
matches v0.27.0's `server.toml` exactly. That match is the evidence that contexts which do not opt
in see no rollout on upgrade.

M2 is accepted when the rehearsal shows the following in one transcript, recorded concisely in
Progress. Before the reseed the large NAR returns `200` and is streamed. After it, the same URL
returns `307`. The public key served at `nix-cache-info` and in the client configuration is the
same before and after. A substitution with `--max-jobs 0 --option fallback false` and
`nix store verify --sigs-needed 1` succeeds.

M3 is accepted when the Labs measurements show four things. Bun and Caddy return 307. Each
download takes under 1 second. The signed pull with builders and fallback disabled succeeds. The
Kotei UI build with Attic preferred has a recorded time next to the 67-second baseline. If it is
still slower, record that in Surprises & Discoveries with the substitution log, because the
remaining cost then lies outside NAR transfer.


## Idempotence and Recovery

M1 and M2 change only code and documents. Setting the threshold back to `65536` and bootstrapping
restores the old configuration. NARs stored whole under `0` keep working, because Attic serves any
single-chunk NAR the same way.

The reseed's rollback depends on how far it got:

- Before step 3, resume the CronJob. Nothing has changed.
- After step 3 and before step 4, every chunk is still in GCS. Run
  `INSERT INTO object SELECT * FROM nagare_reseed_object`, drop the table and resume the CronJob.
  The cache serves exactly what it served before, under the same signing key.
- After step 4, the chunks of the removed NARs are gone. Repush instead. The cache is transport
  (ADR 21), and every closure is reproducible from its producer.

Steps 3 to 5 are safe to repeat. A second delete finds no rows (append to the side table rather
than recreate it), a second collection finds no orphans, and Attic skips paths the cache already
holds.


## Interfaces and Dependencies

- `Nagare.Target.TargetProfile` gains `nixCacheNarSizeThreshold :: !Word64`. `Nagare.Target`
  exports `parseNixCacheNarSizeThreshold :: Maybe Text -> Either Text Word64`.
- `Nagare.Inventory.Cache.CacheRenderInput` gains `renderNarSizeThreshold :: !Word64`.
  `compilePackagedCache` and `compilePackagedCacheWithVerifiedImage` take the threshold after the
  cache bucket.
- The context variable is `NAGARE_NIX_CACHE_NAR_SIZE_THRESHOLD`, and the template placeholder is
  `${NAGARE_NIX_CACHE_NAR_SIZE_THRESHOLD}`.
- Attic `12cbeca141f46e1ade76728bce8adc447f2166c6` treats `nar-size-threshold = 0` as "never chunk".
  A pin bump must recheck that behaviour, the single-chunk redirect, and the reseed's table names.
