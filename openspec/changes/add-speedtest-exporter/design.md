# Design

## Context

See `proposal.md` for motivation and `specs/internet-speed-monitoring/spec.md` for the
behavior contract. Relevant existing state:

- Every infrastructure exporter (`node-exporter`, `smartctl-exporter`, `zfs-exporter`, `nut`)
  is its own Kustomize root registered in `infrastructure/kustomization.yml`, with an Argo CD
  `Application` in the same directory and a `gatus.yml` wired through a ConfigMap generator.
- Prometheus scrapes exporters through one annotation-driven job,
  `kubernetes-service-endpoints`, in `infrastructure/prometheus/config/prometheus.yml`. It has
  no per-target interval override, and its `scrape_timeout` was already raised to 45s for
  `smartctl-exporter`. The global interval is 1m.
- Node placement: `drone-04` is tainted `dedicated=storage:NoSchedule` and hosts the ZFS pool
  plus the NVMe-oF target; `drone-03` is the Jellyfin transcode node (`media/gpu=amd-vega`).
  All nodes are 1 GbE. The Mac minis are control-plane and tainted.
- There is no Grafana in the cluster; Prometheus's own UI is the only query surface.
- Namespaces set `pod-security.kubernetes.io/enforce` through
  `syncPolicy.managedNamespaceMetadata`; infrastructure exporters that need host access use
  `privileged` with a written exemption comment.

## Goals / Non-Goals

**Goals:**

- One exporter, one scrape target, one alert, one health check — matching the existing
  exporter pattern closely enough that it needs no special-casing.
- A measurement cadence that is explicit, cheap enough for a home uplink, and adjustable
  without code changes.
- No new Prometheus scrape job and no privileged access.

**Non-Goals:**

- Dashboards or recording rules.
- Comparing multiple Ookla servers, or pinning a server ID.
- Measuring from more than one node, or correlating results with LAN traffic.
- Retrying a failed measurement before the next interval.

## Decisions

### Exporter image

Use `ghcr.io/heathcliff26/speedtest-exporter:v1.8.2`
(`sha256:07eb2a3772fa558526fd66fe55ca8252cb4e1110843881894094633dedbd0eab`).

- Go implementation over `speedtest-go`, Apache-2.0, released 2026-11-13. Runs as
  `nobody:nobody` on Alpine.
- Emits `speedtest_up`, `speedtest_download_megabits_per_second`,
  `speedtest_upload_megabits_per_second`, `speedtest_ping_latency_milliseconds`,
  `speedtest_jitter_latency_milliseconds`, `speedtest_data_used_megabytes`,
  `speedtest_duration_milliseconds`.
- Alternatives rejected: `MiguelNdeCarvalho/speedtest-exporter` (Python + official Ookla CLI,
  GPL-3.0, last release 2023), `jraviles/prometheus_speedtest` (test runs on every `/probe`
  scrape, so cadence lives in Prometheus config), `danopstech/speedtest_exporter` and
  `kutovoys/speedtest-exporter` (less active, noisier metric/label sets).
- The same project publishes a `cli` image flavor using the official Ookla binary; that is
  the fallback if `speedtest-go` ever breaks against Ookla's API.

### Cadence: internal cache, not scrape-triggered

The exporter caches its result for a configured `cache` duration and runs a new test when the
cache has expired. Set it to `6h`. Prometheus keeps scraping every 1m and receives the last
result.

- This keeps `up` and target visibility continuous; a scrape-interval-driven design
  (e.g. `scrape_interval: 6h`) would make `up` stale and the target's presence hard to read.
- Consequence: the test runs *inside* the scrape that finds an expired cache and blocks it for
  ~25s (upstream reports 22-24s; the server's `WriteTimeout` is 60s). The shared job's 45s
  timeout covers the typical case; a slower test costs one scrape, and the completed result is
  still published on the next one.
- The measurement therefore also costs 1m of scrape traffic per test, which is irrelevant
  beside the ~2-3 GB the test itself transfers.

### Service wiring via the existing annotation job

Annotate the Service with `prometheus.io/scrape: 'true'` and `prometheus.io/port: '8080'`,
matching `smartctl-exporter` and `zfs-exporter`. No `prometheus.yml` change and no dedicated
job.

- Fallback if the target flaps on slow tests: give it its own static job with
  `scrape_timeout: 90s`, the same escape hatch used for the smartctl timeout.

### Placement: pinned to `drone-01`

`nodeSelector: kubernetes.io/hostname: drone-01`.

- `drone-04` is excluded by duty (storage/NVMe-oF) and its taint; `drone-03` runs Jellyfin.
- `drone-02` hosts the largest share of NVMe-oF controllers, so a test there competes with
  more initiator traffic on the same 1 GbE NIC.
- Pinning also keeps the measured path stable across restarts, so a change in results points
  at the uplink rather than at a different switch port.

### Stateless pod

`persistCache: false` and no volume; the ConfigMap is mounted at `/config` and passed
explicitly with `-config /config/config.yaml`. The image only defaults to that path when the
podman/docker `container` env var is set, which Kubernetes does not set: without the flag it
silently runs on built-in defaults, i.e. a test every five minutes.

- A pod restart discards the cached result and the first scrape triggers a fresh test, which
  is desirable after a rollout.
- A PVC would add a `zfs-*` volume and a failure mode for zero benefit. An `emptyDir` would
  only preserve a reading that is about to be retaken anyway.

### Single replica with `Recreate`

Two replicas would run tests concurrently during a rollout and each would measure the other's
traffic; `Recreate` guarantees at most one test is ever in flight. The exporter is not
user-facing, so the restart gap is acceptable.

### Probes on `/`, hardening inline

- Probes use `httpGet: /`, not `/metrics`: `/metrics` blocks on a test, so a probe would
  either time out or trigger WAN traffic (the spec forbids the latter for the health check).
- `runAsNonRoot`, uid/gid 65534 (`nobody`, the image's user), `readOnlyRootFilesystem: true`,
  `allowPrivilegeEscalation: false`, drop ALL capabilities. Namespace enforces `baseline`.
- The `app-pod-hardening` component is not used: it targets `app.kubernetes.io/component=app`
  workloads with uid 1000 and pairs with `app-tmp-dirs`; none of the other infrastructure
  exporters use it, and this container needs no writable path.
- CPU limit is 1 core rather than the exporters' usual 250m. The Go client must drive a
  gigabit stream; CPU throttling would depress the number being measured. Requests stay small
  (25m/32Mi) so the scheduler is not reserving the burst.

### Alert scope for this change

One rule, `SpeedtestFailed`, on `speedtest_up == 0` for 10m at `severity: warning`, in a new
`Speedtest` group in `rules.yml`.

- `speedtest_up` is emitted without labels, and throughput/latency series are omitted on a
  failed run, so the success indicator is the only reliable signal.
- After a failure the gauge stays 0 until the next test succeeds (up to 6h), so the alert
  remains active after connectivity recovers. That is accepted; the exporter has no retry
  mechanism.
- Threshold alerts are deferred until a week of samples and the reported
  `speedtest_data_used_megabytes` show what "normal" is. Existing
  `PrometheusTargetMissing` already covers the exporter being unreachable, so no duplicate
  alert is added.

### Naming and registration

`infrastructure/speedtest-exporter/` with `namespace`/`namePrefix` `speedtest-exporter`;
container `app`, port `http`; Service `service` → `speedtest-exporter-service`; Gatus group
`infrastructure` against `http://speedtest-exporter-service.speedtest-exporter/`. Register
`- speedtest-exporter/app.yml` in `infrastructure/kustomization.yml` after
`snapshot-controller`. Renovate's Kubernetes manager already covers
`infrastructure/**/*.yml`, so the digest is maintained without config changes.

## Risks / Trade-offs

- **The test saturates the pod's 1 GbE NIC for ~25s**, competing with that node's own NVMe-oF
  initiator traffic → 6-hour cadence limits it to four windows a day; pinning to `drone-01`
  keeps it off the storage and transcode nodes.
- **A measurement that exceeds the 45s scrape timeout** makes one scrape fail → next scrape
  succeeds; `PrometheusTargetMissing` needs 5m of failures so it will not page. If it becomes
  routine, add the dedicated 90s-timeout job.
- **Ookla API drift can break `speedtest-go`** → `SpeedtestFailed` surfaces it, and the
  fallback is the project's `cli` flavor or the Ookla-CLI-based exporter.
- **WAN data cost** is ~2-3 GB per test, ~10 GB/day at 6h → measured, not assumed, via
  `speedtest_data_used_megabytes`; raising the interval is a one-line ConfigMap change.
- **The configured instance name is rewritten by relabeling**: the scrape job sets `instance`
  to the pod's node, so the exporter's own label surfaces as `exported_instance`. Queries and
  future alerts must not assume `instance` names the exporter.
- **Removal is manual**: `prune: false`, so deleting the parent registration leaves the
  Application and namespace behind; rollback must delete both.

## Migration Plan

1. Add `infrastructure/speedtest-exporter/` (`app.yml`, `kustomization.yml`,
   `deployment.yml`, `config/config.yaml`, `gatus.yml`).
2. Add the `Speedtest` rule group to `infrastructure/prometheus/config/rules/rules.yml`.
3. Register the Application in `infrastructure/kustomization.yml`.
4. `kustomize build infrastructure/speedtest-exporter` and `just check-kustomize`.
5. Commit; Argo CD syncs `infrastructure` and `prometheus` (the rules ConfigMap change rolls
   Prometheus).
6. Verify: pod Running, `/metrics` returns a result, the target is up in Prometheus,
   `speedtest_up == 1`, Gatus shows the endpoint healthy, and the first `SpeedtestFailed`
   rule loads without evaluation errors.
7. Rollback: remove the registration line and the rule group, then delete the Argo CD
   Application and the `speedtest-exporter` namespace (prune is off, so neither goes away on
   its own).

## Open Questions

None blocking. The download/upload alert thresholds and whether the interval should tighten
to 1h are deferred until the first week of data.
