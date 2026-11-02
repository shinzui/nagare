---
id: 237
slug: publish-release-images-for-the-auth-plane-and-admin-api
title: "Publish release images for the auth plane and admin API"
kind: exec-plan
created_at: 2026-10-31T18:23:43Z
intention: "intention_01m69k6ss1e5797qfn2w8ytnyc"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-31T18:23:43Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-31T18:42:17Z
      verdict: "changes-requested"
      note: "Manifest-as-Nix-output makes the Darwin payload depend on x86_64-linux Haskell builds; existing controller-image route, candidate ordering, local mode and the per-commit gates are not oriented"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-31T18:44:53Z
      mode: "update"
      note: "Manifest becomes a committed release.json source input; oriented on the controller-image route, candidate ordering, local mode, cache push and per-commit gates"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-31T19:58:41Z
      mode: "implement"
      note: "M3 and M4 implemented with tests; M2 harness and candidate step implemented with fake-transport tests; M1 Nix images written, Linux build in progress"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-02T00:22:48Z
      mode: "update"
      note: "Redesigned without GitHub: images go through the Nix cache into each context's GCP Artifact Registry; progress reset after the c4e162d6 revert"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-02T02:49:18Z
      mode: "implement"
      note: "D2 proved against the cache; D1 restored on master without any registry name"
---

# Publish release images for the auth plane and admin API

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current.


## Purpose / Big Picture

Implement [IR-39](../improvement-requests/publish-release-images-for-the-auth-plane-and-admin-api.md). Each Nagare release builds En (authorization), Shōmei (authentication), nagare-access (the request gateway) and nagare-admin-api (the read-only admin service) once with Nix. An upgrade moves a context's workloads to those images with no Cloud Build run and no hand-edited image digest. `platform status` shows which image each workload actually runs.

**Nothing is published to GitHub.** Clusters pull from their own GCP Artifact Registry, as they do today. An image digest is the SHA-256 identity of a container manifest; because it is computed from content, the same image keeps the same digest in the Nix cache and in every registry.


## Progress

- [x] D1: The EP-237 code is restored on master without any GHCR path, and master can still cut a release while no release has adopted it. Evidence: `2632fda5` with its import fix `fa316911`, whose full gate is green on both systems. `release.json` has no `releaseImages`, the candidate and `release-publish.sh` are unchanged, bootstrap keeps its explicit images, and `ImageStatusSpec` proves a payload without images keeps an `exact` aggregate. `git grep ghcr.io/shinzui -- cli nix scripts justfile` finds nothing.
- [x] D2: The four images build on the builder with the digests `release.json` names; a clean Mac fetches each from `shinzui.cachix.org` by store path with no build and no evaluation of the Linux derivations. Evidence, run on this plan's Nix image definitions just before D1 landed, against `release-images-manifest`, because `release.json` carries no images until a release does: after `nix store delete`, `nix copy --from` took 2–3 s per image with no build and no `.drv` in its log, and `skopeo inspect oci:` printed the manifest's digest for all four. A second fetch into an empty store gave the same digests: en `sha256:2dd89ccc…`, shomei `sha256:39214222…`, nagare-access `sha256:a6cfa4f0…`, admin API `sha256:5f1a0261…`. Each closure is one path of 27–43 MiB. A scan of every layer found no secret; its one hit is the PEM marker string in `libssh2`, with no key after it.
- [ ] D3: The candidate pushes the four images to the cache and reads them back. It makes no registry call and needs no GitHub credential. Code and interpreter tests landed in `929b1a58`; the native confirmation comes from D7's candidate rehearsal.
- [ ] D4: Bootstrap and transitions publish the images into the context registry by digest and roll each migration Job and server onto them. Interpreter tests cover a lost acknowledgement, a resume after a partly applied image change, a cache miss and a digest mismatch. Code and interpreter tests landed in `aa564953`, full gate green; the native confirmation comes from D7.
- [ ] D5: `platform status` classifies each workload by digest, whatever registry it was pulled from.
- [x] D6: The candidate refuses before any intranet mutation if the operator shell still exports an image override. Evidence: `929b1a58`, whose candidate tests refuse in preflight, naming the variables, before any worktree exists; a release without images never reads the shell. The same script through the real `mori://tan/tan-ng-labs` shell names all four pins, so a release with images refuses there until D8 removes them.
- [ ] D7: A disposable local context moves from a pinned release to a release with images. Its seeded row reads back unchanged, it passes login, and a re-added pin returns `nagare-access` to its old image while one on En or Shōmei refuses at planning.
- [ ] D8: The intranet adopts the release: verified backups, pins removed from `images.env`, candidate run, login and portal checked, and `images.env` and the per-upgrade rebuild step retired from the operator runbook.
- [ ] D9: The docs describe the shipped route, ADR 7 records the registry decision, and IR-39's acceptance criteria have evidence.


## Surprises & Discoveries

2026-11-01: The v0.15.0 candidate stopped because the GHCR packages it had just created were private. Reading the code then showed the release could not have finished anyway: the intranet's `images.env` pins would be reported as `image-skew`, and the release's intranet step refuses anything but `exact`, after the transition has applied. Both led to this redesign, and the second to D6. Evidence: `~/.local/state/nagare/releases/v0.15.0/20261101T230730Z/`.

2026-11-01: The images could not start on any k3s node: `buildLayeredImage` leaves `/etc/passwd` as a symlink into the store, and containerd refuses it (`openat etc/passwd: path escapes from parent`). The earlier start checks ran under Docker, which follows the link. `25f9ef7b` writes real files; all four then started as Pods on containerd 2.2.2 on an arm64 node through qemu.

2026-11-01: A return to an earlier En or Shōmei image refuses at planning with `retained-reactivation`, because its migration Job is named after the image and history retains it. This changed the rollback rule; see the Decision Log. Evidence: `InventoryContributionRetirementSpec`.

2026-11-01: Each layout's closure first held 10 paths, not 1: `buildLayeredImage` names store paths in the config's history comments and Nix kept nine of them (the glibc closure) as references, so a fetch would have pulled Linux store paths to the Mac. See the Decision Log entry on references. Evidence: `nix path-info -r` before and after.

2026-11-01: `nix copy --from` into the daemon store fails on a machine that does not trust the cache's key: `lacks a signature by a trusted key`, reproduced with only `cache.nixos.org` trusted. `nix copy --no-check-sigs --to DIR` into a private store works with no trust setup. This changes how D4 fetches.


## Decision Log

2026-11-01 (operator): En and Shōmei only move forward. A bad adoption is fixed forward with a new image or restored from the recovery point; re-adding an old pin for either refuses at planning, before any change, and that refusal stays. A failed migration Job stops before its server rolls, and a server that never becomes ready leaves the old pod serving, so the case for going back is a bug that passes readiness on an unmoved schema, which a new image also fixes. `nagare-access` and the admin API have no migrations, so their old pins still apply.

2026-11-01: Each image keeps one artifact identity and its digest moves: `requiresMigration` allows exactly this for `platform:release-images`. The first design gave each digest its own retained member, which grew history per release and refused any return to an earlier digest.

2026-11-01: D4 fetches into a private store under nagarectl's state directory with `nix copy --no-check-sigs --from … --to DIR` and reads `oci:DIR/nix/store/…`, not the daemon store. An operator then needs no trusted key, no trusted-user setting and no cache configuration. Integrity comes from the digest in the reviewed `release.json`, so D4 must prove that the copy refuses a tampered blob, not only a wrong manifest.

2026-11-01: Image layouts drop the config's history comments and set `allowedReferences = [ ]`, so a layout's closure is that one path and the build fails if a reference returns.

2026-11-01: Images carry no release version: the `io.nagare.release-version` label, the archive tag and the index annotations are gone. An image whose inputs did not change now keeps its store path and digest across releases, which is what lets an upgrade skip it. nagare-access and the admin API still move when their Nagare sources do.

2026-11-01: D1 restores no candidate or publish step, so D3 adds the push to the candidate and skips it while `release.json` has no `releaseImages`. D1 keeps only the status text from `db83be4e`'s docs; the release, upgrade, access and bootstrap text describes a route that exists after D4, so its GCP version comes with D9.

2026-11-01: Publication pins each image with `cachix pin … --keep-forever`, because the cache's garbage collection could otherwise evict a released image and turn a later upgrade into a cache miss.

2026-11-01 (operator): Never use GitHub for packages. This supersedes the 2026-10-31 entries that use public GHCR, and the review entry that rejects the context registry. The first upload, anonymous-pull check, `ghcr.io` login and release-version image tags all go away with it.

2026-11-01 (operator): Images move through the Nix binary cache into each context's GCP Artifact Registry. The cache `shinzui.cachix.org` is public, so these images are publicly downloadable; D2 checks that they hold no secrets. Their En, Shōmei and Nagare sources are already public.

2026-11-01: `release.json` also names each image's OCI layout store path, so a Mac fetches it with `nix copy --from` and never evaluates a Linux derivation. The earlier objection to this route was that Haskell closures cannot be cross-built on Darwin; fetching needs no build. A cache miss refuses with a message and never compiles.

2026-11-01: Image references are derived per context from the digest, and nothing in the release names a registry. Status compares digests alone.

2026-11-01: Images are published into the registry prefix the patched net-certmanager controller already uses (the context's own Artifact Registry). The intranet's current pins live in the separate `nagare` repository; they stay until D8 and are not moved.

2026-11-01: Restore the code by cherry-picking `6c4bfe0b`, `cd241dad`, `2be948e1` and `db83be4e`. Reverting `c4e162d6` would also bring back the v0.15.0 version bump and its GHCR digests.

2026-10-31 (still applies): `releaseImages` is a source input in root `release.json`, written by the `chore(release): prepare vX.Y.Z` commit, so the aarch64-darwin payload never depends on Linux builds. Because `nagare-api-server` links the `nagarectl` library, the admin digest moves with almost every Haskell commit, so a `source-development` payload has no usable `releaseImages` and keeps the explicit-image path.

2026-10-31 (still applies): Explicit immutable overrides stay. Intent is saved in reviewed state and never inferred from the live image. An override that differs from the release is visible and non-exact, and skew never blocks the reviewed transition that repairs it.

2026-10-31 (still applies): The auth package set pins every Hackage package whose nixpkgs version differs from the cabal solve of `cli/nagare-access/cabal.project` (`nix/release-images/hackage-pins.json`) and builds them jailbroken, without tests or Haddock. Each image is an OCI layout compressed with `gzip -n`, so its manifest digest is stable through `skopeo copy --preserve-digests`. The test-fixture `release.json` drops `releaseImages` at evaluation, so writing a digest does not change the admin digest. The selection is recorded on the workload's own metadata (`nagare.dev/image-source`, `nagare.dev/release-image`), so recording intent never rolls a workload.


## Outcomes & Retrospective


## Context and Orientation

`nix/release-images.nix` builds the images; `cli/nagare-harness/src/Nagare/Harness/Release/Images.hs` prepares them and pushes them to the cache, and D3 calls it from `Candidate.hs`; `cli/nagarectl/src/Nagare/Platform/ReleaseImages.hs`, `ImageStatus.hs` and `Transition.hs` select and classify them.

The precedent for D4 is on master: `cli/nagarectl/src/Nagare/Inventory/Components/ControllerImage.hs` declares a reviewed artifact, binds its digest with `skopeo` before any registry mutation, and publishes the patched net-certmanager controller into the context registry. It reads a `docker-archive:` from the payload; these four read an `oci:` layout from the Nix store, because four Haskell closures would multiply the payload's size. Clusters already pull privately from the context registry, so no new pull credential is needed.

The intranet's images are pinned in `mori://tan/tan-ng-labs` at `operator/intranet/images.env` (artifact-level URI pending), which that repository's `.envrc` loads. The release's intranet step runs in that shell through `direnv exec`, so those pins apply to every release. The same repository's `docs/runbooks/operations.md` step 7 rebuilds these images on Cloud Build, the step this plan retires.

Consulted ADRs: [ADR 1](../adr/0001-auth-plane-images-mirror-upstream-dependency-plans.md) (images share the reviewed upstream pins), [ADR 2](../adr/0002-auth-service-images-own-and-apply-their-database-schemas.md) (a server and its migration share an image; migration succeeds before rollout), [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) (immutable tags, no replacement), [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md) (release logic in tested Haskell), [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) (native runs only confirm).


## Plan of Work

**D3.** The candidate's image step becomes: build, compare digests with `release.json`, push the closures with `cachix push`, read them back. It runs before the rehearsal, which needs them.

**D4.** Add one reviewed artifact per image, modelled on `ControllerImage.hs`. Before any registry mutation: fetch the store path into a private store as the Decision Log says, then check the layout's manifest digest with `skopeo` against `release.json`. Publish with `skopeo copy --preserve-digests`. Each workload's reference is `<context registry>/<name>@sha256:<digest>`, and a server rolls only after its migration Job succeeds. An unchanged digest does no fetch and no copy, so an upgrade that leaves an image alone pays nothing for it. Local mode uses the same route into its k3d registry.

**D5.** Restore the classifications `release`, `override`, `other-release`, `drift`, `unknown` and `not-enabled`, comparing digests only. Status adds no registry call and needs no image variables.

**D6.** Extend the candidate's preflight: read the four image variables from the operator shell and refuse if any is set, naming it. This moves an existing late refusal to the start of the run and adds no step for a context without pins.

**D7.** Run `just release-candidate X.Y.Z --rehearsal`, whose transition drill goes from a pinned release to one with images. Then re-add a pin and confirm the workload returns to the old image.

**D8.** Complete `docs/runbooks/before-a-native-run.md` and get the operator's go-ahead. Confirm hourly recovery points are healthy, remove the four lines from `images.env`, then run the normal candidate and publish. Check login, the portal and `/v1/sites`. After a release has run this way, remove the rebuild step and `images.env` from the operator repository.

**D9.** Update `docs/runbooks/releases.md`, `docs/user/cluster-bootstrap.md`, `docs/user/upgrades.md` and `docs/runbooks/admin-api-reader.md`. Amend ADR 7.


## Concrete Steps

Per Haskell commit run `just haskell-style-check`, then `just gate-fast`; land with `just land`.


## Validation and Acceptance

- AC-1 (IR-39's "release registry" is the binary cache): the four images are fetchable from the cache at the digests the payload records, and a clean rebuild from the tag reproduces those digests.
- AC-2: a transition with no image variables moves all four workloads; migration Jobs and servers agree; each serves its release.
- AC-3: status names a stale workload as non-exact, including mixed replicas and failed reads, and is exact again only after ready replicas agree.
- AC-4: a reviewed admin override runs and stays reported as an override, with no environment inputs, while the other three stay `release`.
- AC-5: a measured cloud transition shows no compilation and no Cloud Build run.
- Performance: an upgrade that changes no image digest makes no cache fetch and no registry copy; record the added time of an upgrade that changes all four.
- Rule: `git grep ghcr.io/shinzui` finds no reference outside the history in this plan's log and old release evidence.


## Idempotence and Recovery

Fetching and publishing are by content, so a retry repeats safely: a lost acknowledgement resumes the existing transaction and checks the registry before accepting anything. A digest mismatch or cache miss refuses before any mutation. En and Shōmei only move forward: fix a bad adoption with a new image, or restore from the recovery point taken first. To go back on `nagare-access` or the admin API, add the old pin to `images.env` and plan again. Published tags are never moved.


## Interfaces and Dependencies

`releaseImages` in root `release.json` holds `schemaVersion` and exactly four entries keyed `en`, `shomei`, `nagare-access` and `nagare-admin-api`. Each has `platform` (`linux/amd64`), `digest`, `storePath` and the upstream source revisions. The resolver returns the expected digest, the selected reference and the source (`release` or `override`), or a typed error.

Dependencies are the flake-locked package set, `skopeo`, the `shinzui.cachix.org` cache and a `CACHIX_AUTH_TOKEN` for release pushes only; operators need no cache credential to fetch. Sources come from `mori://shinzui/en` and `mori://shinzui/shomei`, pinned in `cli/nagare-access/cabal.project`. No new dependency version is chosen.
