# Proposal

## Why

The cluster monitors hosts, disks, the UPS and its own services, but nothing measures the
internet connection itself. When the uplink degrades — ISP congestion, a bad modem, a
failing router, or a link that has renegotiated below its rated speed — the only evidence
today is a user noticing. A periodic speedtest turns that into history and an alert, and
gives the ISP conversation concrete numbers.

## What Changes

- Add a new infrastructure application, `infrastructure/speedtest-exporter/`, running
  `ghcr.io/heathcliff26/speedtest-exporter` (v1.8.2, pinned by digest).
- The exporter runs a speedtest on a fixed internal interval (6 hours) and serves the last
  result as Prometheus metrics between tests; it is scraped through the cluster's existing
  service-endpoint discovery, so `infrastructure/prometheus/config/prometheus.yml` does not
  change.
- Pin the single replica to `drone-01` so the measured path is stable and the test does not
  compete with the storage node or the transcoding node.
- Add a Gatus check and a `SpeedtestFailed` alert (`speedtest_up == 0`).
- Record the observed bandwidth cost (`speedtest_data_used_megabytes`) so the interval can be
  justified or tightened later; download/upload threshold alerts are deliberately deferred
  until there is baseline data.

## Capabilities

### New Capabilities

- `internet-speed-monitoring`: how the cluster measures the WAN uplink — periodic speedtest
  execution, the metrics it publishes, how Prometheus collects them, the health check, and
  the alert when a test fails.

### Modified Capabilities

None. Existing capability specs (`power-monitoring`, `tsgit`) are unaffected.

## Impact

- New: `infrastructure/speedtest-exporter/` — `app.yml`, `kustomization.yml`,
  `deployment.yml`, `config/config.yaml`, `gatus.yml`.
- Modified: `infrastructure/kustomization.yml` (registers the new Application),
  `infrastructure/prometheus/config/rules/rules.yml` (new `Speedtest` rule group).
- No change to `infrastructure/prometheus/config/prometheus.yml`: the Service's
  `prometheus.io/scrape` annotation routes it into the existing `kubernetes-service-endpoints`
  job, whose 45s scrape timeout already accommodates a blocking test.
- Cluster impact: one pod, ~25s of a 1 GbE NIC saturation per test, roughly 2-3 GB of WAN
  traffic per test (~10 GB/day at the 6-hour interval). No storage, no privileges, no
  namespace PSA exemption beyond the standard `baseline` enforcement.
- Renovate picks up the image digest through its existing Kubernetes manager; no config
  change.
- Out of scope: dashboards (there is no Grafana in the cluster), per-server comparison,
  speed tests from more than one node, WAN latency/loss probing (Gatus already covers basic
  reachability), and replacing the router's own monitoring.
