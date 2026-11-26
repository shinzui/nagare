---
type: Guide
title: "Storing user files in an app object bucket"
description: "Declare a private object bucket with expiry rules, grant each workload its own read-write or read-only credential, and retire access through review."
docId: DOC-48
tags: [buckets, object-storage, minio, workers, secrets]
generated:
  by: process:claude-code
  at: 2026-11-26T03:40:00Z
---

# Storing user files in an app object bucket

An app object bucket is a private bucket that Nagare creates for an application, with expiry rules
for prefixes and one credential per workload it grants. On a local context the bucket lives in the
packaged MinIO store. (A GCS backend for cloud contexts is MasterPlan 39's EP-284; until it lands a
cloud context refuses with `bucket-backend-unsupported`.)

## Declare the bucket

A bucket is its own document, like an app database, because its objects outlive the applications
that use it. `cluster/examples/content-app/nagare/Buckets.hs` is a complete example:

```haskell
publications = do
  bucket <- mkBucketName "publications"
  ns <- mkNamespace "personal"
  api <- mkServiceName "content-app"
  gateway <- mkServiceName "content-gateway"
  staging <- mkObjectPrefix "staging/"
  oneDay <- mkPositiveDays 1
  validateObjectBucket
    ObjectBucket
      { name = bucket, logicalKey = Nothing
      , expire = [ExpireRule {prefix = staging, afterDays = oneDay}]
      , grants =
          [ BucketGrant {namespace = ns, workload = api, access = ReadWrite, signUrls = True}
          , BucketGrant {namespace = ns, workload = gateway, access = ReadOnly, signUrls = False}
          ]
      }

main = either (ioError . userError . Text.unpack) (emitObjectBuckets . pure) publications
```

Each grant names one workload by namespace and name. `ReadWrite` may get, put and delete objects
and list the bucket; `ReadOnly` may only get objects. Review and apply it:

```bash
nagarectl bucket plan --file nagare/Buckets.hs --save-plan ./bucket-review
nagarectl inventory apply ./bucket-review --yes
```

The review makes the store bucket `nagare-app-NAME`, sets exactly the declared expiry rules, and for
each grant creates a store user with its own key and policy. Each workload's copy of its key is a
Secret in its own namespace. No review holds a key.

## Bind it from a workload

```haskell
api & #buckets .~ [BucketBinding publications]
```

A standalone service, worker or task, or an Application's service and workers, can bind a bucket
that grants it. The binding is refused with `bucket-grant-missing` when the accepted bucket does not
grant that workload. A bound workload receives:

| Variable | Value |
| --- | --- |
| `NAGARE_BUCKET_NAME_BACKEND` | `s3` |
| `NAGARE_BUCKET_NAME_NAME` | the store bucket, `nagare-app-NAME` |
| `NAGARE_BUCKET_NAME_ENDPOINT` | the in-cluster store URL |
| `NAGARE_BUCKET_NAME_ACCESS_KEY_ID` | from the workload's own Secret |
| `NAGARE_BUCKET_NAME_SECRET_ACCESS_KEY` | from the workload's own Secret |

(`NAME` is the bucket name upper-cased, `-` as `_`.) The workload starts only after the Job that
created its store user, so it never starts with a key the store does not know.

## Change access

Edit the grants and plan again. A dropped grant's store user is removed by a revoke Job in the same
review, and the review lists what is lost:

```text
This review removes:
  workload content-gateway in personal loses read-only access to bucket publications
```

## Retire a bucket

Remove every binding and deploy first; `bucket retire` refuses `bucket-still-bound` while any
workload binds the bucket. Then:

```bash
nagarectl bucket retire publications --save-plan ./bucket-retire
nagarectl inventory apply ./bucket-retire --yes
```

Every workload loses access; the bucket and its objects are kept. Nagare never deletes a bucket.

```bash
nagarectl bucket status
```

lists each accepted bucket with its backend, store bucket and grants.
