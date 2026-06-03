# Grafana dashboards (committed to Git)

Dashboard JSON files placed in this directory are intended to be loaded into
Grafana automatically by the Grafana **sidecar**. The metrics chart values
(`cluster/observability/victoria-metrics/values.yaml`) enable
`grafana.sidecar.dashboards`, which watches for ConfigMaps labelled
`grafana_dashboard: "1"` and imports their contents.

To add a dashboard:

1. Export the dashboard JSON from Grafana (Share → Export → Save to file), or
   author it by hand.
2. Save it here, e.g. `node-overview.json`.
3. Wrap it in a labelled ConfigMap and apply it, for example:

   ```bash
   kubectl -n monitoring create configmap grafana-dashboard-node-overview \
     --from-file=node-overview.json \
     --dry-run=client -o yaml | \
   kubectl -n monitoring label --local -f - grafana_dashboard=1 -o yaml | \
   kubectl apply -f -
   ```

   The sidecar picks it up within ~1 minute; no Grafana restart is needed.

The `victoria-metrics-k8s-stack` chart also ships a set of built-in Kubernetes
and VictoriaMetrics dashboards (enabled by default), so this directory starts
empty except for this README.

**Backups:** EP-7 (`docs/plans/7-backups-secrets-and-disaster-recovery.md`) owns
backing up and restoring the dashboards committed here, so keep custom dashboards
in version control rather than only inside Grafana's database.
