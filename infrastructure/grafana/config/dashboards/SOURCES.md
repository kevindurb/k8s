# Grafana dashboard provenance

All dashboards here are provisioned read-only into Grafana via the file provider
(see `config/provisioning/dashboards/dashboards.yml`). They are vendored copies,
not auto-updated — bump by re-downloading and re-applying the patches below.

All datasource references were rewritten to uid `prometheus`; `__inputs` /
`__requires` were stripped along with any `type: datasource` template variables.

| File | Source | Upstream ID | Revision fetched | Local patches |
| --- | --- | --- | --- | --- |
| `node-exporter-full.json` | grafana.com/dashboards/1860 | 1860 | latest (2026-11) | `job` variable default set to `kubernetes-service-endpoints` (node-exporter is scraped through the `kubernetes-service-endpoints` job) |
| `kubernetes-global.json` | grafana.com/dashboards/15757 | 15757 (kubernetes-mixin) | latest | `cluster` variable made optional (`includeAll`, `allValue: .*`) because our metrics carry no `cluster` label; `job` variable default `kubernetes-service-endpoints` |
| `node-zfs-stats.json` | grafana.com/dashboards/7968 | 7968 | latest | datasource only |
| `smartctl.json` | grafana.com/dashboards/22604 | 22604 | latest | datasource only (matches `smartctl-exporter` v0.15: `device`, `interface`, `model_name`, `serial_number` labels) |
| `speedtest.json` | grafana.com/dashboards/20115 | 20115 | latest (by heathcliff26, author of the deployed exporter) | `instance` variable query changed to `label_values(speedtest_up, instance)` (upstream filtered on `job="speedtest-exporter"`) |
| `gatus.json` | grafana.com/dashboards/24379 | 24379 | latest (official gatus example) | datasource only (`gatus_results_total` / `gatus_results_duration_seconds` match our gatus version) |
| `argocd.json` | grafana.com/dashboards/14584 | 14584 | latest | default namespace variable pinned to `argocd` (the namespace its metrics are scraped from) |
| `prometheus-overview.json` | grafana.com/dashboards/3662 | 3662 | latest | datasource only |
| `zfs-pools.json` | hand-built | — | — | covers the pdf/zfs_exporter pool metrics (`zfs_pool_size/allocated/free_bytes`, `zfs_pool_fragmentation_ratio`, `zfs_pool_health`) which no community dashboard covers |
| `nut-ups.json` | hand-built | — | — | matches `druggeri/nut_exporter` metric names (`network_ups_tools_*`), not the `nut_*` names community NUT dashboards use |
| `zrepl.json` | hand-built | — | — | no community zrepl dashboard exists; covers last-success lag, errors, bytes replicated, exporter liveness |

Re-downloading an upstream dashboard:

```sh
curl -sfL https://grafana.com/api/dashboards/<id>/revisions/latest/download -o <file>.json
# then strip __inputs/__requires, point all datasource refs at uid `prometheus`,
# drop `type: datasource` templating vars, and re-apply the row above.
```
