# C2 on candidate `3b78d905`

nagare-verify ran this on 2026-10-08 on cp3, with a fresh k3d context bootstrapped from the
candidate's own payload (`platform-root.json` shows `3b78d905a7dbcdead997348eaba3db2499f487ac`). It
used the same driver set that passed on `3ae20f8c`.

The run finalized 16 of 16 assertions (`local-health.json`), and the assembler accepted it
(`inventory-evidence.json`). The candidate gate (C1) proof is `c1-proof.json`, and the console log
is `chain.log`.

**Deviation: images seeded from the cp3 image store.** The pinned OCI export the drivers copy from,
`<cp3 root>/exports/registry-pre-c2`, had been purged by macOS temporary-file cleanup. Two attempts
stopped in phase 1, before any review and with no context mutation beyond bootstrap stages 1–2.
The five platform images were therefore pushed from the cp3 Docker image store, with each digest
checked after the push, and `images.env` pins them:
- en, shomei and nagare-access: the 2026-09-16 builds in the store. These are other builds than the
  previously pinned digests, whose source is gone.
- MinIO server and client: the `scripts/publish-local-minio-images.sh` builds of the same upstream
  releases (`release-2025-09-07`, `release-2025-08-13`).

C2 tests the candidate's inventory and recovery behaviour, not the versions of these components.
Every assertion passed with them, including the access and authentication paths.
