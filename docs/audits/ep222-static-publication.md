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

## Timings (one sample each; wall from the EP-224 trace)

| Command | Wall | `publish.config` | `package.build` | `docker` runs | `kubectl` runs |
| --- | --- | --- | --- | --- | --- |
| first publish | 16.97 s | 6.41 s | 1.28 s | 2 | 16 |
| update (one file edited) | 9.99 s | 1.50 s | 0.85 s | 2 | 16 |
| unchanged | 5.74 s | 5.45 s | – | **0** | 0 |
| `--new-release` | 11.06 s | 1.45 s | 1.12 s | 2 | 16 |
| rollback review + apply | 2.79 s + 2.09 s | – | – | 0 | 5 + 12 |

Cache evidence from `build.log`: the nginx config and site `COPY` steps were `CACHED` when the files were
unchanged (first and `--new-release` releases) and only `COPY site/` rebuilt for the edited update.

## Reading

- The unchanged republish costs only the config load (`runghc`) plus a file copy and hash; it builds nothing and
  writes nothing.
- The config load is the largest part of every release (1.5 s warm; 5.5–6.4 s when it recompiles) and is paid
  exactly once per command. Reducing it belongs to EP-219.
- Cluster time (apply and Knative readiness) is 2–3 s here on a warm local node; it is not owned by this plan.

## Not measured, and why

- Three warm samples per case: one run each, not medians.
- Which blobs `skopeo copy` skipped (only the changed site layer should upload): the transport is not traced.
- Platform workspace preparation: image publication and site deployment each prepare it; no span separates it.
- A linux/amd64 end-to-end release: this cluster is arm64. Both architectures were built and inspected as
  archives (`skopeo inspect docker-archive:` reports `arm64` and `amd64`).
- The extended `nagarectl-external-config` nix check was not run through nix.
- `site publish --resume` was covered by fake-operation tests only; no native interruption was induced.
- No `--contract 1` result exists for `site publish`.
