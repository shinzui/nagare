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
---

# Publish release images for the auth plane and admin API

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current.


## Purpose / Big Picture

Implement [IR-39](../improvement-requests/publish-release-images-for-the-auth-plane-and-admin-api.md). Each Nagare release builds En (authorization), Shōmei (authentication), nagare-access (the request gateway) and nagare-admin-api (the read-only admin service) once with Nix. An upgrade moves a context's workloads to those images with no Cloud Build run and no hand-edited image digest. `platform status` shows which image each workload actually runs.

**Nothing is published to GitHub.** Clusters pull from their own GCP Artifact Registry, as they do today. An image digest is the SHA-256 identity of a container manifest; because it is computed from content, the same image keeps the same digest in the Nix cache and in every registry.


## Progress

Master carries none of this code: `c4e162d6` removed it for the v0.14.2 kernel release. The earlier evidence is for the GHCR design; each item below is unticked until it passes on restored code.

- [ ] D1: The EP-237 code is restored on master without any GHCR path, and master can still cut a release while no release has adopted it.
- [ ] D2: The four images build on the builder with the digests `release.json` names; a clean Mac fetches each from `shinzui.cachix.org` by store path with no build and no evaluation of the Linux derivations. **Do this first: the design depends on it and it has never been run.**
- [ ] D3: The candidate pushes the four images to the cache and reads them back. It makes no registry call and needs no GitHub credential.
- [ ] D4: Bootstrap and transitions publish the images into the context registry by digest and roll each migration Job and server onto them. Interpreter tests cover a lost acknowledgement, a resume after a partly applied image change, a cache miss and a digest mismatch.
- [ ] D5: `platform status` classifies each workload by digest, whatever registry it was pulled from.
- [ ] D6: The candidate refuses before any intranet mutation if the operator shell still exports an image override.
- [ ] D7: A disposable local context moves from a pinned release to a release with images. Its seeded row reads back unchanged, it passes login, and a re-added pin returns it to the old images.
- [ ] D8: The intranet adopts the release: verified backups, pins removed from `images.env`, candidate run, login and portal checked, and `images.env` and the per-upgrade rebuild step retired from the operator runbook.
- [ ] D9: The docs describe the shipped route, ADR 7 records the registry decision, and IR-39's acceptance criteria have evidence.


## Surprises & Discoveries

2026-11-01: The v0.15.0 candidate stopped because the GHCR packages it had just created were private. Reading the code then showed the release could not have finished anyway: the intranet's `images.env` pins would be reported as `image-skew`, and the release's intranet step refuses anything but `exact`, after the transition has applied. Both led to this redesign, and the second to D6. Evidence: `~/.local/state/nagare/releases/v0.15.0/20261101T230730Z/`.


## Decision Log

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

The removed code is in history and comes back in D1. `nix/release-images.nix` builds the images; `cli/nagare-harness/src/Nagare/Harness/Release/Images.hs` and `Candidate.hs` publish and verify them in the candidate; `cli/nagarectl/src/Nagare/Platform/ReleaseImages.hs`, `ImageStatus.hs` and `Transition.hs` select and classify them.

The precedent for D4 is on master: `cli/nagarectl/src/Nagare/Inventory/Components/ControllerImage.hs` declares a reviewed artifact, binds its digest with `skopeo` before any registry mutation, and publishes the patched net-certmanager controller into the context registry. It reads a `docker-archive:` from the payload; these four read an `oci:` layout from the Nix store, because four Haskell closures would multiply the payload's size. Clusters already pull privately from the context registry, so no new pull credential is needed.

The intranet's images are pinned in `mori://tan/tan-ng-labs` at `operator/intranet/images.env` (artifact-level URI pending), which that repository's `.envrc` loads. The release's intranet step runs in that shell through `direnv exec`, so those pins apply to every release. The same repository's `docs/runbooks/operations.md` step 7 rebuilds these images on Cloud Build, the step this plan retires.

Consulted ADRs: [ADR 1](../adr/0001-auth-plane-images-mirror-upstream-dependency-plans.md) (images share the reviewed upstream pins), [ADR 2](../adr/0002-auth-service-images-own-and-apply-their-database-schemas.md) (a server and its migration share an image; migration succeeds before rollout), [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) (immutable tags, no replacement), [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md) (release logic in tested Haskell), [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) (native runs only confirm).


## Plan of Work

**D1, D2.** Cherry-pick the four commits. Remove `repository`, the anonymous checks, the tag step and the GHCR text in the same change; add `storePath`. Master must not require images before D4 exists, so `release images prepare` and the candidate's image step stay out of the release path until then. Build on the builder, push one image to the cache, and fetch it on the Mac as in Concrete Steps. If this fails, stop and bring the failure to the operator, because the design changes.

**D3.** The candidate's image step becomes: build, compare digests with `release.json`, push the closures with `cachix push`, read them back. It runs before the rehearsal, which needs them.

**D4.** Add one reviewed artifact per image, modelled on `ControllerImage.hs`. Before any registry mutation: `nix copy --from` the store path, then check the layout's manifest digest with `skopeo` against `release.json`. Publish with `skopeo copy --preserve-digests`. Each workload's reference is `<context registry>/<name>@sha256:<digest>`, and a server rolls only after its migration Job succeeds. An unchanged digest does no fetch and no copy, so an upgrade that leaves an image alone pays nothing for it. Local mode uses the same route into its k3d registry.

**D5.** Restore the classifications `release`, `override`, `other-release`, `drift`, `unknown` and `not-enabled`, comparing digests only. Status adds no registry call and needs no image variables.

**D6.** Extend the candidate's preflight: read the four image variables from the operator shell and refuse if any is set, naming it. This moves an existing late refusal to the start of the run and adds no step for a context without pins.

**D7.** Run `just release-candidate X.Y.Z --rehearsal`, whose transition drill goes from a pinned release to one with images. Then re-add a pin and confirm the workload returns to the old image.

**D8.** Complete `docs/runbooks/before-a-native-run.md` and get the operator's go-ahead. Confirm hourly recovery points are healthy, remove the four lines from `images.env`, then run the normal candidate and publish. Check login, the portal and `/v1/sites`. After a release has run this way, remove the rebuild step and `images.env` from the operator repository.

**D9.** Update `docs/runbooks/releases.md`, `docs/user/cluster-bootstrap.md`, `docs/user/upgrades.md` and `docs/runbooks/admin-api-reader.md`. Amend ADR 7.


## Concrete Steps

The D2 proof, run from the repository root on the Mac, where `$PATH_FROM_RELEASE_JSON` is an image's `storePath`:

```bash
nix build --no-link --print-out-paths --max-jobs 0 .#packages.x86_64-linux.release-image-admin-api
cachix push shinzui "$PATH_FROM_RELEASE_JSON"
nix store delete "$PATH_FROM_RELEASE_JSON"
nix copy --from https://shinzui.cachix.org "$PATH_FROM_RELEASE_JSON"
skopeo inspect --format '{{.Digest}}' "oci:$PATH_FROM_RELEASE_JSON"
```

Pass: the last command prints the digest `release.json` names, and no derivation was built or evaluated by the `nix copy`. Per Haskell commit run `just haskell-style-check`, then `just gate-fast`; land with `just land`.


## Validation and Acceptance

- AC-1 (IR-39's "release registry" is the binary cache): the four images are fetchable from the cache at the digests the payload records, and a clean rebuild from the tag reproduces those digests.
- AC-2: a transition with no image variables moves all four workloads; migration Jobs and servers agree; each serves its release.
- AC-3: status names a stale workload as non-exact, including mixed replicas and failed reads, and is exact again only after ready replicas agree.
- AC-4: a reviewed admin override runs and stays reported as an override, with no environment inputs, while the other three stay `release`.
- AC-5: a measured cloud transition shows no compilation and no Cloud Build run.
- Performance: an upgrade that changes no image digest makes no cache fetch and no registry copy; record the added time of an upgrade that changes all four.
- Rule: `git grep ghcr.io/shinzui` finds no reference outside the history in this plan's log and old release evidence.


## Idempotence and Recovery

Fetching and publishing are by content, so a retry repeats safely: a lost acknowledgement resumes the existing transaction and checks the registry before accepting anything. A digest mismatch or cache miss refuses before any mutation. To go back on a context, add the old pin to `images.env` and plan again; D7 proves this. An older image does not undo a database migration, so a failed adoption whose schema moved restores from the recovery point taken first. Published tags are never moved.


## Interfaces and Dependencies

`releaseImages` in root `release.json` holds `schemaVersion` and exactly four entries keyed `en`, `shomei`, `nagare-access` and `nagare-admin-api`. Each has `platform` (`linux/amd64`), `digest`, `storePath` and the upstream source revisions. The resolver returns the expected digest, the selected reference and the source (`release` or `override`), or a typed error.

Dependencies are the flake-locked package set, `skopeo`, the `shinzui.cachix.org` cache and a `CACHIX_AUTH_TOKEN` for release pushes only; operators need no cache credential to fetch. Sources come from `mori://shinzui/en` and `mori://shinzui/shomei`, pinned in `cli/nagare-access/cabal.project`. No new dependency version is chosen.
