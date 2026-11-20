# Tasks

## 1. Application manifests

- [x] 1.1 Create `infrastructure/speedtest-exporter/kustomization.yml` and `config/config.yaml` (`cache: 6h`, `persistCache: false`, `port: 8080`, `instance: beaver-cloud`, `serverID: 0`, remote write disabled), and verify `kustomize build infrastructure/speedtest-exporter` renders a ConfigMap named `speedtest-exporter-config` with a `config.yaml` key in namespace `speedtest-exporter`
- [x] 1.2 Create `infrastructure/speedtest-exporter/deployment.yml` (single-replica Deployment with `strategy: Recreate`, `nodeSelector: kubernetes.io/hostname: drone-01`, container `app`, port `http` 8080, non-root read-only security context, probes on `/`, 1 CPU / 256Mi limit, ConfigMap mounted at `/config`, no volumes, plus the Service with `prometheus.io/scrape: 'true'` and `prometheus.io/port: '8080'`), and verify `kustomize build infrastructure/speedtest-exporter` renders both objects with those settings and no PVC, hostPath, or privileged flag
- [x] 1.3 Create `infrastructure/speedtest-exporter/gatus.yml` targeting `http://speedtest-exporter-service.speedtest-exporter:8080/` (group `infrastructure`, status 200) with a `gatus` ConfigMap generator entry, and verify the build renders a `speedtest-exporter-gatus` ConfigMap labelled `gatus.io/enabled: 'true'` whose endpoint host matches the rendered Service name
- [x] 1.4 Create `infrastructure/speedtest-exporter/app.yml` (project `default`, path `infrastructure/speedtest-exporter`, namespace labels `enforce: baseline` plus warn/audit `restricted`, automated sync with `prune: false`), and verify `kubectl apply --dry-run=server -f infrastructure/speedtest-exporter/app.yml` succeeds

## 2. Failure alert

- [x] 2.1 Add a `Speedtest` rule group to `infrastructure/prometheus/config/rules/rules.yml` with `SpeedtestFailed` (`speedtest_up == 0`, `for: 10m`, `severity: warning`) and a summary/description naming the failed uplink measurement, and verify the file passes `promtool check rules infrastructure/prometheus/config/rules/rules.yml` (or, if promtool is not installed locally, run the same check inside the Prometheus pod after the next step's sync)

## 3. Registration and repository validation

- [x] 3.1 Add `- speedtest-exporter/app.yml` to `infrastructure/kustomization.yml` in alphabetical position (after `snapshot-controller`), and verify `kustomize build infrastructure` succeeds and its output includes the `speedtest-exporter` Application exactly once
- [x] 3.2 Run `just check-kustomize` and verify it exits 0 for every kustomization under `apps`, `platform`, `infrastructure` and `clusters`
- [x] 3.3 Run the pre-commit hooks on the changed files (`pre-commit run --files <changed files>`) and verify yamllint and the trailing-whitespace/EOF checks pass

## 4. Rollout and verification

- [x] 4.1 Commit and push, then verify Argo CD reports the `speedtest-exporter` Application Synced/Healthy, the pod is Running and Ready, and `kubectl -n speedtest-exporter get deploy,svc` shows the expected names
- [x] 4.2 Verify the first measurement through `kubectl -n speedtest-exporter port-forward svc/speedtest-exporter-service 8080` and `curl localhost:8080/metrics`: the first call takes roughly 25 seconds and then returns `speedtest_up 1` with download, upload, ping, jitter and data-used series, and record the reported `speedtest_data_used_megabytes` for the follow-up review
- [x] 4.3 Verify Prometheus collection without config changes: `up{kubernetes_namespace="speedtest-exporter"} == 1` with `job="kubernetes-service-endpoints"`, throughput series present, and `infrastructure/prometheus/config/prometheus.yml` still containing no `speedtest` job
- [x] 4.4 Verify the Gatus check shows healthy in the `infrastructure` group and that health probes do not start tests: `curl localhost:8080/` returns immediately and `speedtest_duration_milliseconds` does not change between two consecutive probe cycles
- [x] 4.5 Verify the alert rule loaded and is quiet while healthy: Prometheus shows the `Speedtest` rule group with no evaluation error and `ALERTS{alertname="SpeedtestFailed"}` is empty while `speedtest_up == 1`
- [ ] 4.6 Verify the pod meets the baseline security requirements: container `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, no privileged flag, no hostPath, and no PersistentVolumeClaim in the namespace
- [x] 4.7 Verify a restart recovers without state: `kubectl -n speedtest-exporter rollout restart deployment/speedtest-exporter-deployment`, then confirm the pod returns to Ready and a new measurement is published on the first scrape and appears in Prometheus

## Workflow follow-up

- After roughly a week, review `speedtest_data_used_megabytes` and the observed download/upload/ping distribution, then propose threshold alerts (and an interval change if the WAN cost is too high) as a separate change.
- Archive this change once the rollout verification above is reviewed.
