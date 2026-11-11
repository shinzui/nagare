# EP-251 D1: conditional writes on the pinned local object store

Date: 2026-11-10. Script: [`ep251-s3-conditional-writes.sh`](ep251-s3-conditional-writes.sh), run in an Apple
container on arm64 with the digest-checked MinIO server release the local bootstrap packages
(`scripts/publish-local-minio-images.sh`). RustFS is not tested: its improvement request is still
`proposed`.

Verdict: keep the S3 transport. `If-None-Match: *` refuses an existing key and `If-Match: <etag>`
refuses a changed object, with the object untouched, and under two racing writers exactly one wins
in every one of 25 rounds for both create and replace. A conditional replace of a missing key is
answered `404 NoSuchKey`, not `412`; the transport classifies both as a refused condition.

```text
server: 200 ready, RELEASE.2025-09-07T16-13-09Z
ok   create bucket (200)
ok   create head if absent (200)
ok   second create if absent is refused (412)
ok   refused create left the object (one)
ok   replace if the ETag matches (200)
ok   replace with a stale ETag is refused (412)
ok   refused replace left the object (two)
ok   replace on a missing key is refused (404) (404)
ok   the refused replace created nothing (404)
ok   racing create: exactly one writer wins and its body stays, in 25 rounds (25)
ok   racing replace: exactly one writer wins and its body stays, in 25 rounds (25)
result: conditional create and replace hold
```
