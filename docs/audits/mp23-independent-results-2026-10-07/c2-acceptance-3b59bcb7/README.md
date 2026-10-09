# C2 on the final candidate `3b59bcb7`

nagare-verify ran this on 2026-10-09 on cp3. It used a fresh k3d context bootstrapped from the
candidate's own payload (`platform-root.json`: `nagare-0.4.0-3b59bcb7612d`), with the driver set that
passed on `3b78d905`.

The run passed on its first attempt. It finalized 16 of 16 assertions (`local-health.json`), and the
assembler accepted it (`inventory-evidence.json`). The candidate gate (C1) proof is `c1-proof.json`.
The console log is `chain.log`.

The five platform images are seeded from the cp3 Docker image store, as on `3b78d905` (see
`../c2-acceptance-3b78d905/README.md`), and `images.env` pins them. These are the 2026-09-16 builds of
en, shomei and nagare-access, and the `scripts/publish-local-minio-images.sh` builds of MinIO
`release-2025-09-07` and its client `release-2025-08-13`.
