# EP-222 static publication: native evidence

Evidence for [EP-222](../plans/222-package-and-publish-static-site-updates-through-a-fast-repeatable-workflow.md),
2026-10-30. Environment: Colima profile `nagare-mp23` (aarch64, 6 CPU, 12 GiB), k3d cluster `nagare-local` reset
and re-bootstrapped for this run, context `site-access` (`mode=local`, `linux/arm64`), auth-plane images
`mp27-df54e94e`. Bootstrap used the packaged `nagarectl` 0.12.1 at `b718293b`; the publish scenario used the
packaged build of `f05a7a87` (code identical to the later `site publish` tree except the empty-release-directory
cleanup noted below). Raw trace documents: `evidence/static-publish/*.trace.json` under the drill root
`/private/tmp/claude-501/drill/root` (not retained in the repository).

## What ran

| Check | Command | Result |
| --- | --- | --- |
| Reset and bootstrap | `site-access-drill.sh` with `NAGARE_DRILL_RESET=1 NAGARE_DRILL_BOOTSTRAP_ONLY=1` | converged in 4 stages |
| AC-2: protected-site drill with `site package` in step 6 | `site-access-drill.sh` with `NAGARE_DRILL_SKIP_BOOTSTRAP=1` | `site access drill OK`: archive from `site package` passed unchanged to `app image-plan`, published, deployed, preview, login, grants, revoke, second release and rollback with protection intact |
| Publish loop | `scripts/static-publish-drill.sh` | passed after one defect (below) |

The publish loop, reading `index.html` from the running pod at each step: first publish serves the example; an
edit plus `site publish` gives a new tag and image, the same URL, and the edited bytes; a third `site publish`
prints `unchanged: release … already serves these files at …` with zero Docker runs; `--new-release` publishes
anyway; `site rollback` to the first release (reviewed, with its accepted image) restores byte-identical content.

## Defect found by the native run

The first `site publish` failed at the image save: `docker: createProcess: invalid argument (Bad file
descriptor)`. `UseHandle` closes the handle in the parent after the first spawn, so one `build.log` handle could
not serve the build and the save. Fixed in `f05a7a87` (log opened per run; library `runLogged`), covered by the
test "one build log serves two consecutive runs". The unchanged run also left an empty release directory;
it is now removed when nothing is released.

## Timings (EP-224 trace; medians of three warm samples)

Final run at `d0b61693` (packaged `nagarectl`), same cluster. Raw traces are under the drill root.

| Command | n | Wall | `publish.config` | `package.build` | `docker` runs |
| --- | --- | --- | --- | --- | --- |
| first publish (`--new-release`) | 1 | 9.68 s | – | – | 2 |
| edit + publish (`warm-update`) | 3 | median 10.15 s, range 9.98-10.24 s | median 1.36 s | median 0.70 s | 2 |
| publish with no change (`warm-unchanged`) | 3 | median 1.64 s, range 1.61-1.69 s | median 1.39 s | – | **0** |
| `--contract 1` unchanged | 1 | 1.66 s | 1.40 s | – | 0 |
| resume after interruption | 1 | 4.96 s | 1.38 s | – | **0** |
| rollback review + apply | 1 | 2.64 s + 2.47 s | – | – | 0 |

An earlier run at `f05a7a87` showed a 5.5-6.4 s config load on the first command and on one unchanged run;
every command in the final run loaded the config in 1.3-1.5 s, so the slow loads were a cold `runghc`
compile, not a property of the path.

Cache evidence from `build.log`: with unchanged files the nginx-config and site `COPY` steps are `CACHED`;
after an edit only `COPY site/` rebuilds.

Registry upload evidence: Skopeo's non-terminal output prints `Copying blob` whether a blob uploads or is
skipped, and the transport discards it, so the registry's own log was counted instead. The same
`skopeo copy --preserve-digests` into a fresh repository uploaded all 11 blobs for the first release (22
upload log lines) and 3 blobs for the edited release (6 lines): the site layer, the image config and one
more blob; the base layers were already present.

## Other observations

- Platform workspace preparation appears as the `runtime setup` span, twice per publish (image publication
  and site deployment), 0.02 s together. It is not worth collapsing.
- Cluster time (apply and readiness) is about 2-3 s on this warm local node and is not owned by this plan.
- The config load (1.4 s) is 85 % of an unchanged publish; reducing it belongs to EP-219.
- `site publish --contract 1`: the changed release and the unchanged case each printed exactly one
  `site-publish-result` document, validated by the drill (stage `deployed` with url, image resource,
  release directory and content digest; stage `unchanged`).
- Resume: the drill interrupted a publish with `SIGTERM` at stage `image-published` (receipt proved it),
  ran `site publish --resume --release-dir DIR`, and the release reached `deployed` with zero Docker runs and
  the interrupted edit served.
- Manual review path from the guide (package, `app image-plan --contract 1`, apply, `site deploy
  --save-plan`, apply) deployed an arm64 release; an amd64 archive went through `image-plan` and apply and
  the registry reports `amd64` for it. The node is arm64, so amd64 was published, not run.
- The extended `nagarectl-external-config` nix check passes at `d0b61693`.

## Not measured

- Per-blob transport timing: the registry log gives upload counts, not durations.
- A linux/amd64 release served by an amd64 node.
- A failure of the deploy stage (rather than an interruption) in the native run; both reach the same
  receipt stage and are covered by the coordinator tests.
