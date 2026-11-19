# Node-level exporters: bootc image or Kubernetes DaemonSet?

## Question

Would moving `node-exporter` (and the other host-metrics exporters) out of Kubernetes and into the bootc node image as systemd units be worth it? This note records the analysis and a recommendation. Nothing has been changed yet.

**Recommendation:** yes, but only for the three exporters that read the host, and in this order: `zfs-exporter`, `smartctl-exporter`, `node-exporter`. Everything that talks to the apiserver stays in Kubernetes. `node-exporter` is worth at least a cheap partial fix (`hostPID` + a `NoExecute` toleration) whether or not the move happens.

## Current state

All three run as a workload, discovered by Prometheus through the `kubernetes-service-endpoints` job (`infrastructure/prometheus/config/prometheus.yml`) and a `prometheus.io/scrape` annotation on their `Service`.

| Exporter | File | Needs | Notes |
|---|---|---|---|
| `node-exporter` | `infrastructure/node-exporter/node-exporter.yml` | `hostNetwork` (via `components/host-networking`), hostPath `/` and `/sys` | PSS namespace enforces `privileged`; **no `hostPID`**; tolerates `NoSchedule` only |
| `smartctl-exporter` | `infrastructure/smartctl-exporter/smartctl-exporter.yml` | `privileged: true`, `runAsUser: 0`, hostPath `/dev` | `--smartctl.interval=5m` because 32 NVMe-oF controllers make a poll take 10–30 s on drone-02 |
| `zfs-exporter` | `infrastructure/zfs-exporter/zfs-exporter.yml` | `privileged`, `hostPID`, hostPath `/var/lib/zfs-exporter`, pinned to `drone-04` | An initContainer `wget`s the tarball from GitHub at pod start, then the main container `nsenter -t 1 --mount` runs it from the host |

## Why moving them helps

### 1. The metrics survive a broken node

This is the strongest argument and the reason it matters here more than in a normal cluster. A DaemonSet pod needs a working kubelet, a running container runtime, a cached image and a schedulable node. The failures the exporters exist to catch break exactly those things:

- `/var` fills → kubelet reports disk pressure, the image gets garbage collected, the pod cannot start. `node_filesystem_avail_bytes` is the alert for that condition and it is the first thing to disappear.
- k3s-agent will not start, or the node is `NotReady` and after five minutes the pod is evicted — the tolerations tolerate `NoSchedule`, not `NoExecute`.
- A node wedged badly enough to need a reboot is the node you most want to keep scraping during the reboot.

A systemd unit starts from PID 1 and keeps serving on `:9100` with the apiserver and the container runtime down. Prometheus runs on another node, so it can still scrape it.

### 2. `up == 0` starts working again

Because discovery is `role: endpoints`, targets are derived from pod endpoints. When a node dies its pod leaves the endpoint list and the target disappears from Prometheus entirely, so `up` never becomes 0 for it and `PrometheusTargetMissing` (`rules.yml`, `up == 0 unless on(job) (sum by(job) (up) == 0)`) cannot fire for the node you just lost. The `ZfsExporterDown` rule shows the workaround: it needs `or absent(up{...})` to notice the target is gone at all.

Scraping node IPs directly (see below) keeps the target in the TSDB while the node is unreachable, which is what that rule assumes. `kube_node_status_condition` is currently the only thing that catches a dead node, and it stops working if the dead node was the apiserver.

### 3. Two `privileged` PSS namespaces go away

`node-exporter/app.yml`, `smartctl-exporter/app.yml` and `zfs-exporter/app.yml` each carry a "exemption: privileged" comment and set `pod-security.kubernetes.io/enforce: privileged` on their whole namespace. A host unit is strictly tighter than a privileged container:

```ini
[Service]
User=prometheus
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
DevicePolicy=closed
```

`smartctl-exporter` and `zfs-exporter` need raw device access, but `DeviceAllow=/dev/nvme*` scoped to those devices is a far smaller grant than `privileged: true` on a pod that can `nsenter` into PID 1.

### 4. It closes the `zfs-exporter` supply-chain hole

That initContainer downloads and sha256-verifies a tarball from GitHub every time the pod starts. The version is not in Argo, not in Renovate and not in the image. Building it into the image makes it pinned in CI, cosign-signed with the rest of the node, and rollback-able atomically.

### 5. Host visibility without namespace tricks

`node-exporter` today passes `--path.sysfs` and `--path.rootfs` but not `--path.procfs` and does not set `hostPID`, so the process collector reads the container's PID namespace: `node_procs_*` and `node_processes_*` describe the exporter itself and nothing else. Anything that is namespaced per-process or per-mount (process counts, `/proc/mounts`-derived collectors) needs a mount or flag workaround. On the host there is nothing to work around.

### 6. It matches how the rest of the node is managed

`k3s`, `nvmet`, `tailscaled`, `chronyd`, `tuned`, `cockpit` and `iscsid` are already systemd units in `bootc/overlay`. The exporters are the only host-facing daemons still deployed as pods, and `zfs-exporter` is effectively half-moved already (host binary, host mount namespace, host PID namespace) — it just keeps the awkward parts.

## What it costs

- **No Argo reconciliation.** Changing a flag means editing `bootc/overlay` or the `Containerfile`, waiting for `.github/workflows/build-bootc.yml`, then `just playbook pull-upgrade.yml` and a reboot. For `node-exporter` (stable, roughly yearly releases, currently in lockstep with Fedora's package) that trade is reasonable; it is the same one already accepted for k3s and nvmet.
- **No per-exporter rollback.** A bad version rolls back the whole node image instead of one `git revert` of an image digest.
- **Scrape wiring changes.** The `Service` + annotation + `role: endpoints` path is replaced by `role: node` jobs in `prometheus.yml`, and the object disappears from Argo entirely. See below.
- **No pod `resources:`.** Set `CPUQuota=`/`MemoryMax=` in the unit; enforcement is at least as good as cgroup limits on a pod.
- **Version bumps need a node reboot**, which for `drone-04` means `just playbook reboot-drone-04.yml` and its scale-down/scale-up dance.

## What must stay in Kubernetes

`kube-state-metrics`, `node-feature-discovery`, `gpu-operator`/DCGM, `metallb` speaker, `kube-vip`, the `tailscale` operator, the democratic-csi node plugin, `coredns`, `prometheus` and `alertmanager` all need the apiserver, leader election, CRDs or the kubelet's own endpoints. Moving them to bootc would mean reimplementing an operator on a node, which is not worth it.

## If it is done

### Packaging

- `node-exporter` is packaged in Fedora (`node-exporter-1.12.1-1.fc44`, the exact version pinned in the manifest today). It installs `/usr/bin/prometheus-node-exporter` and `node_exporter.service`, which runs as `prometheus`, reads `ARGS` from `/etc/default/prometheus-node-exporter` and `Requires=network-online.target`. Add the package to `bootc/Containerfile` and drop the flags that only exist because of the container (`--path.sysfs`, `--path.rootfs`, the pod mount-point ignores); keep `--no-collector.wifi`, the ethtool device filter and the netclass device filter.
- `smartctl_exporter` and `zfs_exporter` are not packaged in Fedora. Add them as release tarballs the same way `k3s` is added today, with a `# renovate: datasource=github-releases` annotation per `ARG` so Renovate still tracks them, and a `sha256sum -c` in the `RUN` so a bad upstream build fails the image build rather than a pod start.

### Units and which node runs what

One image for all nodes, so gate the host-specific ones with systemd conditions instead of node selectors:

- `zfs-exporter`: `ConditionPathExists=/dev/zfs` (or `ExecCondition=/usr/sbin/zpool list -H -o name`), so it is a no-op everywhere except `drone-04`. It needs `/usr/sbin/zpool` and `/usr/sbin/zfs`, which the base image already has.
- `smartctl-exporter`: root, `DevicePolicy=closed`, `DeviceAllow=/dev/nvme* /dev/sd*`, `--smartctl.interval=5m` retained.
- `node-exporter`: as `prometheus`, `MemoryMax=192M`, `CPUQuota=25%` (the current pod limits).

### Prometheus

Replace three endpoint-discovered targets with `role: node` jobs, which the file already uses for kubelet and cadvisor. Ports are fixed per binary, so the relabel is small, and `instance` must be set from the node name because the existing rules query `instance="drone-04"` and `instance=~"drone-0[123]"`:

```yaml
  - job_name: node-exporter
    kubernetes_sd_configs:
      - role: node
    relabel_configs:
      # role: node sets __address__ to the node address on the kubelet port
      - source_labels: [__address__]
        regex: (.+):\d+
        replacement: $1:9100
        target_label: __address__
      # keep instance = node name, so existing rules and dashboards still match
      - source_labels: [__meta_kubernetes_node_name]
        target_label: instance
```

Repeat with `:9633` and `:9134`. `ZfsExporterDown` then becomes `up{job="zfs-exporter"} == 0` and the `absent(...)` fallback can be dropped. This assumes IPv4 node addresses (192.168.42.x); the `$1:port` replacement would need bracket handling if the nodes ever get IPv6 addresses.

No `Service`, `Endpoints`, `namespace` or `app.yml` remains for any of the three, so `infrastructure/node-exporter/`, `infrastructure/smartctl-exporter/` and `infrastructure/zfs-exporter/` get deleted rather than migrated, along with their entries in `infrastructure/kustomization.yml`. They have no Gatus checks today, so nothing else references them.

## Cheaper alternative

If only one change is made, add to the `node-exporter` DaemonSet:

```yaml
      hostPID: true
      tolerations:
        - effect: NoSchedule
          operator: Exists
        - effect: NoExecute
          operator: Exists
```

That fixes the empty process collector and stops the pod being evicted from a sick node. It does not fix a node whose kubelet or `/var` is broken, and `up == 0` still will not fire.
