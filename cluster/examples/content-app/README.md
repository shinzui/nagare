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

See [Object storage](../../../docs/user/object-storage.md).
