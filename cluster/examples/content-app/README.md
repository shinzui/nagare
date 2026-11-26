# content-app

An app that stores user files in an app object bucket (MasterPlan 39).

- `nagare/Buckets.hs` declares the private bucket `publications`: objects under `staging/` expire
  after one day, the web service `content-app` reads and writes, and the worker `content-gateway`
  only reads.
- `nagare/Config.hs` declares the application. Both workloads bind the bucket by name.

```bash
nagarectl bucket plan --file cluster/examples/content-app/nagare/Buckets.hs --save-plan DIR
nagarectl inventory apply DIR --yes
nagarectl app deploy -f cluster/examples/content-app/nagare/Config.hs
```

On a cloud context the same declarations give each workload a keyless Google identity for the
bucket (see [Object storage](../../../docs/user/object-storage.md#on-a-cloud-context)): plan the
bucket, run the cloud review (`nagarectl platform bootstrap plan`), then deploy. `probe/` is a small
server built on Google's storage client that stands in for whoami there: `/put-and-sign` writes an
object and returns a V4 signed PUT URL, `/try-put` reads and tries a write, `/keyset` lists the key
set's files, and `/` echoes the `Host` header.

```bash
docker build --platform linux/amd64 -t content-probe:v1 cluster/examples/content-app/probe
CONTENT_APP_IMAGE=REGISTRY/content-probe CONTENT_APP_TAG=v1 \
  nagarectl app deploy -f cluster/examples/content-app/nagare/Config.hs --tag v1 --image-resource RESOURCE
```

See [Object storage](../../../docs/user/object-storage.md).
