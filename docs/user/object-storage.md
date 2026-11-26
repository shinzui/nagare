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
packaged MinIO store. On a cloud context it is a Google Cloud Storage bucket, and each granted
workload reaches it through its own Google service account with no key at all (see
[On a cloud context](#on-a-cloud-context)).

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
and list the bucket; `ReadOnly` may only get objects on a local context, and get and list them on
a cloud context, where Google's Storage Object Viewer role includes listing. Review and apply it:

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

## On a cloud context

The declaration and the bindings are the same; what they create differs. A cloud context needs the
project's number in its context (`NAGARE_PROJECT_NUMBER`, from
`gcloud projects describe PROJECT --format 'value(projectNumber)'`).

Three reviews run in order:

1. **The bucket review** (`nagarectl bucket plan`) creates, in each granted workload's namespace, a
   Kubernetes ServiceAccount `nagare-wl-WORKLOAD` with no RBAC and no API token, and a ConfigMap
   `nagare-bucket-BUCKET-WORKLOAD` holding an `external_account` credential configuration. Neither
   holds a key.
2. **The cloud review** (`nagarectl platform bootstrap plan`, its cloud stage) creates the Google
   side from the accepted buckets: a workload identity pool for the context that trusts the
   cluster's service-account signing keys (uploaded, so the cluster needs no public issuer), the
   bucket `PROJECT-CONTEXT-NAME` with uniform access, enforced public access prevention and the
   declared expiry rules, and per grant one Google service account that holds exactly one role on
   that bucket (`roles/storage.objectUser` for `ReadWrite`, `roles/storage.objectViewer` for
   `ReadOnly`) and admits only that workload's Kubernetes account. A grant with `signUrls = True`
   may also sign as itself, for V4 signed URLs. Nothing is granted at project level.
3. **The application review** binds the bucket. It is refused with `bucket-cloud-identity-missing`
   until the cloud review has created that grant's identity, so a workload never starts with an
   identity Google would refuse.

A bound workload runs as `nagare-wl-WORKLOAD` and mounts `/var/run/nagare/identity/`: the credential
configuration and a short-lived token whose audience is the pool. It receives:

| Variable | Value |
| --- | --- |
| `NAGARE_BUCKET_NAME_BACKEND` | `gcs` |
| `NAGARE_BUCKET_NAME_NAME` | the Google bucket, `PROJECT-CONTEXT-NAME` |
| `NAGARE_BUCKET_NAME_ENDPOINT` | `https://storage.googleapis.com` |
| `NAGARE_BUCKET_NAME_SERVICE_ACCOUNT` | the grant's Google account, which signs URLs |
| `NAGARE_BUCKET_NAME_CREDENTIALS` | `/var/run/nagare/identity/credentials.json` |
| `GOOGLE_APPLICATION_CREDENTIALS` | the same file |

Google's client libraries read `GOOGLE_APPLICATION_CREDENTIALS` unchanged. To sign a URL, refresh
the default credentials and pass the account and its token to the library's V4 signer; the probe in
`cluster/examples/content-app/probe/server.py` shows both.

A workload runs as one account, so on a cloud context it binds at most one bucket, and it may not
also name its own `serviceAccount`; both are refused when the app is planned. A task cannot bind a
cloud bucket.

Changing access works as on a local context, followed by the cloud review: a dropped grant's Google
account is deleted. Retiring a bucket keeps the Google bucket, its objects and its accounts, and the
next cloud review **disables** those accounts, which refuses every credential at once:

```text
This review removes:
  workload content-gateway in personal loses read-only access to bucket publications; the next cloud review disables its Google account nagare-wl-…@PROJECT.iam.gserviceaccount.com
  no object: Google bucket PROJECT-CONTEXT-publications and its objects are kept; Nagare never deletes a bucket
```

After a cluster rebuild the cluster signs tokens with new keys: run the cloud review again before
workloads can reach their buckets (see [Backups and disaster recovery](backups-and-disaster-recovery.md)).
