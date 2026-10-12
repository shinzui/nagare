# Pinned observability charts

These are the exact chart archives consumed by the reviewed observability
inventory. `SHA256SUMS` pins the archive bytes, including bundled subcharts.
The versions match the previous `cluster/observability/install.sh` release set.

The `victoria-metrics-k8s-stack` chart, version 0.81.0, and the three
VictoriaMetrics logs/traces charts came from the official
`https://victoriametrics.github.io/helm-charts/` chart repository. The
`opentelemetry-collector` chart, version 0.158.0, came from the official
`https://open-telemetry.github.io/opentelemetry-helm-charts` chart repository.

The metrics values enable cert-manager for the operator webhook. The chart's
default self-signed certificate generation changes the post-rendered manifests
on every run. The review gate requires byte-identical Helm post-renderer input.
