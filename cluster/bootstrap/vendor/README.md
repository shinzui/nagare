# Pinned bootstrap manifests

These are the exact upstream release assets used by cluster and local bootstrap.
`SHA256SUMS` pins their bytes. The inventory component will retain canonical
native members privately during review preparation. Refreshing a release
requires updating the version, asset, digest, and component fixture together.

| File | Release asset |
| --- | --- |
| `cert-manager-v1.20.2.yaml` | <https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml> |
| `serving-crds-v1.22.0.yaml` | <https://github.com/knative/serving/releases/download/knative-v1.22.0/serving-crds.yaml> |
| `serving-core-v1.22.0.yaml` | <https://github.com/knative/serving/releases/download/knative-v1.22.0/serving-core.yaml> |
| `kourier-v1.22.0.yaml` | <https://github.com/knative-extensions/net-kourier/releases/download/knative-v1.22.0/kourier.yaml> |
| `net-certmanager-v1.14.0.yaml` | <https://storage.googleapis.com/knative-releases/net-certmanager/previous/v1.14.0/net-certmanager.yaml> |

The current recipes retain the existing version pins. Upstream patch releases
can be assessed separately from the inventory migration.
