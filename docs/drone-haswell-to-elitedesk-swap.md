# Replace drone-01/02/03 (Haswell desktops → HP EliteDesk 705 G4 DM)

## Context

Three HP EliteDesk 705 G4 Desktop Mini units replace `drone-01`, `drone-02` and `drone-03`. The replacements keep the **same hostnames and the same static IPs** (`.21`, `.22`, `.23`).

Reusing the hostnames is not just convenience. `healthchecks` pins every CronJob to a node by label — for example `healthchecks-cronjob-drone-03` carries `nodeSelector: kubernetes.io/hostname: drone-03`. Renaming a node means editing manifests across the repo for no benefit.

Replacement hardware, identical per node:

|         |                                                                                     |
| ------- | ----------------------------------------------------------------------------------- |
| CPU     | AMD Ryzen 5 PRO 2400GE — 4C/8T, 3.2 GHz base / 3.8 GHz boost, 4 MB L3, **35 W**       |
| iGPU    | Radeon RX Vega 11 — VCN1 video engine: H.264 + HEVC 8-bit encode, HEVC 10-bit decode  |
| RAM     | **16 GB** DDR4-2666, 2× SODIMM (dual channel), 32 GB max                              |
| Storage | SSD — **confirm SATA vs M.2 NVMe per unit**, the SKU shipped both ways                |
| NIC     | Realtek RTL8111EPH, single 1 GbE                                                      |
| Power   | 65 W external brick, 7.4 × 5.0 mm barrel; **~11 W idle** once the iGPU firmware loads  |
| WiFi    | 802.11ac + BT (M.2 2230) — irrelevant for a node                                      |

Retiring hardware: i5-4590 (Haswell, 4C/4T, 84 W), 16/24/16 GiB DDR3-1333/1600, **legacy BIOS** boot, 1 GbE `enp0s25`, one Quadro P620 on drone-01 and one on drone-02.

Net effect per node: threads 4 → 8, RAM 16/24/16 → 16/16/16, idle draw roughly 35–45 W → ~11 W. Cluster DRAM across the four drones drops from 72 GB to 64 GB.

## What was verified before writing this

Read from the live cluster, not from HARDWARE.md:

- **Actual node CPUs** (`/proc/cpuinfo` via privileged pods): drone-01/02/03 = `Intel Core i5-4590 @ 3.30GHz`; drone-04 = `AMD Ryzen 7 2700`; unimatrix-01..03 = `Intel Core i5-3210M`.
- **Boot mode**: drone-01/02/03 boot **legacy BIOS**; drone-04 boots UEFI. These minis must be UEFI-only.
- **GPU placement**: two Quadro P620s — one in drone-01, one in drone-02, each reported as 4 slices by the device plugin (MPS). `scrypted` holds one on drone-01, `jellyfin` holds one on drone-02.
- **Jellyfin is portable.** `jellyfin-nas-media` is plain NFS from `192.168.42.24:/media` with **no node affinity**, and `jellyfin-config-pvc` is `zfs-generic-nvmeof-csi` (NVMe-oF TCP). Neither ties Jellyfin to a node, so it can move to any node without touching storage.
- **Stale local PVs**: two `Released` PVs carry node affinity for drone-03 (`mayastor-etcd-localpv`, `openebs-minio-localpv`). They will not block a drain; delete them at cleanup.
- **Provisioning path**: `bootc/Containerfile` (uCore + k3s) for the OS, `butane/node.bu.j2` for per-host identity, `ansible/roles/k3s` for the join. `bootc/justfile` has `gen-ignition` and `build-iso`.

## Phase 0 — readiness (no production hardware touched)

Runs before the first chassis is powered down. Two items are hard blockers: until 0.1 and 0.3 are done, a replacement node cannot join at the right k3s version, and the four existing drones are one reboot away from breaking on their own.

### 0.1 — End the k3s skew by upgrading the cluster to 1.37.2

`bootc/Containerfile` pins `K3S_VERSION=v1.37.2+k3s1`; every node runs **v1.35.6+k3s1**. Rather than build a throwaway image at the old version, upgrade the cluster: the 1.37.2 image is **already built and already staged on all four drones**, so there is no build work and the installer carries no custom tag.

Order matters — an agent may not run ahead of its API server:

1. Control plane: `unimatrix-01`, `-02`, `-03`, **one at a time**. Drain, reboot into the staged image, wait for `Ready` and etcd quorum before the next.
2. Then the drones, drained one at a time. drone-04 is never rebooted casually (see the storage-node note in `AGENTS.md`).
3. Confirm `kubectl get nodes` reports `v1.37.2+k3s1` everywhere, Argo is Synced/Healthy, Gatus green.

**Verify first:** this is a two-minor jump (1.35 → 1.37, skipping 1.36), the range where removed APIs live. `pluto detect-all-in-cluster` (or `kubent`) against the live cluster settles it in minutes. The manifests are current-API; the `pod-security.kubernetes.io/enforce-version: v1.35` labels are cosmetic.

Once this lands, 0.3's switch target is plain `latest`, and the "deploy at 1.35.6, rebase later" step disappears from the plan entirely.

### 0.2 — Clear the staged deployment

`rpm-ostreed` runs `AutomaticUpdatePolicy=stage`, and the weekly Sunday build republished `latest` after the 1.37.2 bump. Every drone currently has `2026.11.08` staged — the same digest, `sha256:da4d862c…` — so a reboot boots an agent at 1.37.2 against a 1.35.6 server.

If 0.1 is done first this is a no-op: rebooting into that image *is* the upgrade. Confirm per node that `bootc status` shows the expected booted version and nothing unexpected staged.

**Do not reboot any node for any other reason until this is settled** — including the "reboot drone-03 to pick up the current kernel" line in `HARDWARE.md`.

### 0.3 — Make the installer produce a joinable node

The ISO produces a bare FCOS install, not a cluster member. Two gaps, both manual and undocumented today.

**Bootc switch.** `butane/node.bu.j2` is `variant: fcos` and `build-iso` wraps it into a plain FCOS installer, but the nodes boot `ghcr.io/kevindurb/k8s-node` — confirmed live: `bootc status` reports `ostreeContainer`, stateroot `fedora-coreos`. Nothing in the repo performs the switch. Either document `sudo bootc switch ghcr.io/kevindurb/k8s-node:latest` + reboot as an explicit install step, or automate it with a first-boot unit in the ignition.

**Tailscale.** `ansible/roles/tailscale/tasks/main.yml` runs `tailscale up --accept-dns=false --ssh` with no auth key (`tailscale_auth_key` is declared and unused) and no `--advertise-tags`. A fresh node therefore needs an interactive login and comes back **untagged**, not `tag:k8s-node` — a different ACL position from every other node. It also cannot resolve `ansible_host: drone-03` before it is on the tailnet, so the current Step 4 → Step 5 ordering is not achievable as written. Fix by supplying an auth key carrying `tag:k8s-node` (with `--advertise-tags`), or by running the first join from the LAN with `-e ansible_host=192.168.42.30`.

### 0.4 — Validate one mini end to end, without the cluster

Do this on one unit before any of the three is scheduled. Nothing here touches Kubernetes.

1. Live USB: `ip -br link` (the Realtek will be `enp1s0`/`enp2s0`, **not** `enp0s25`), `lsblk` (SATA `/dev/sda` vs NVMe `/dev/nvme0n1`), `test -d /sys/firmware/efi`.
2. BIOS (F10): Secure Boot → Disable, Legacy Support → Disable, UEFI order first. Clear Absolute Persistence on corporate units.
3. Install, then confirm `hostname`, the static IP answering, `tailscale status`, `ssh core@…`.
4. **Vega ID:** `lspci -nn | grep -i vga`. Raven Ridge is normally `15dd`; some Picasso parts report `15d8`. Hard gate — a wrong ID fails silently in Phase 4, because the node simply never receives the label.
5. **Transcode:** `vainfo` (not in the base image; run it from a container) must report `VAEntrypointVLD` and `VAEntrypointEncSlice` on `renderD128`. Then one 1080p transcode and **one 4K HDR title**, deliberately: Vega 11's known loss is HEVC 10-bit encode, and its known crash is `error 139` on HEVC 10-bit HDR with Vulkan tone-mapping. After Phase 1 there is no other hardware transcode path in the cluster, so this is where you find out.
6. **Idle power:** ≈ 11 W at the wall, not ≈ 18 W. The higher figure means `amdgpu` firmware did not load.

Record `lsblk` for all three units — disk interface is the one field that varies by SKU — but only one needs the full test.

### 0.5 — Rehearse the join under a throwaway hostname

All three swaps depend on install → switch → join → Ready, and that cannot be rehearsed as `drone-03` while `drone-03` is live. Install one unit as `test-node` on an address outside the cluster range (e.g. `192.168.42.30`), run `provision.yml --limit test-node`, confirm `Ready`, then drain/delete and wipe.

This is the cheapest place to catch a wrong interface name in the ignition, a missing Tailscale auth key, or a version mismatch — an evening's work instead of a production node.

### 0.6 — Git-only changes that are safe now

**Scrypted** — it does not use the GPU (see the Scrypted section). Its HomeKit path is a remux, not a transcode, and `nvidia-smi` on drone-01 shows no processes. Change it now, while the P620 is still installed as a revert:

- image → `ghcr.io/koush/scrypted:v0.147.0-noble-amd@sha256:9c8f6dff157be7acc074712e3c050e7dc0a898e1b2c00ede457840f652c8011d`
- drop `runtimeClassName: nvidia`, the `nvidia.com/gpu.product` selector and the `nvidia.com/gpu: '1'` limit
- keep `hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet` (HomeKit needs Bonjour)

`-noble-amd` needs `/dev/dri` plus `supplementalGroups: [105]` (the `render` group) before it accelerates anything; that arrives with the Vega in Phase 1. Until then it behaves exactly as today.

**Jellyfin does not belong here.** Dropping `runtimeClassName` while the selector still points at drone-02's P620, or landing on a node with no `/dev/dri`, silently downgrades it to software transcode. Its edits land with the drone-03 move.

## Phase 1 — swap order

Phase 0 comes first; nothing here starts until 0.1–0.6 are done.

1. **Swap drone-03**, validate. Jellyfin keeps running on drone-02's P620 throughout.
2. **Move Jellyfin to drone-03's Vega 11**, validate transcoding.
3. **Swap drone-02** — now GPU-free, because Jellyfin already left it.
4. **Swap drone-01** — the last P620 retires with the chassis. Scrypted came off its GPU back in Phase 0, so nothing is waiting on this.
5. **Retire gpu-operator** and switch NFD to `vendor`+`device` PCI labels — Phase 4 below.

This ordering means the replacement transcode path is proven before the only node Jellyfin can fall back to is touched, and the operator teardown stays single-variable at the end. **One node in flight at a time**, and one Jellyfin move, with validation between each. drone-01 is no longer a GPU node in any operative sense — Scrypted comes off its P620 in Phase 0 — so it is last for one-variable-at-a-time reasons, not because a GPU leaves with it.

## Jellyfin → Vega 11 (after Step 1, before drone-02)

### Why a discrete GPU is not an option

The EliteDesks have **no PCIe slot of any kind**. The only discrete option is the MXM (J41) connector, which accepts **only** HP's own Radeon RX 560 4 GB assembly (L21472-001 / L21472-002 / L35096-001). That card needs a 150 W adapter, consumes the 2.5" drive bay, and covers the M.2/WLAN/RTC service area — and its encoder is no better than the Vega 11 already on the board. Not worth it.

### What the Vega 11 can and cannot do

| | Vega 11 (VCN1) | Quadro P620 (NVENC 4th gen) |
| --- | --- | --- |
| H.264 decode / encode | ✅ / ✅ | ✅ / ✅ |
| HEVC 8-bit decode / encode | ✅ / ✅ | ✅ / ✅ |
| HEVC 10-bit decode | ✅ | ✅ |
| **HEVC 10-bit encode** | ❌ | ✅ |
| AV1 | ❌ | ❌ |
| Concurrent encode sessions | Unlimited | ~8, further split by MPS |

Practical consequence: **decode is a wash and encode quality is worse**, but the only hard capability lost is HEVC **10-bit** encode. If the library is 1080p H.264/HEVC, nothing is lost. If it holds 4K HDR remuxes, transcode output drops to H.264 or 8-bit HEVC.

There is also a known ffmpeg crash (`error 139`) specific to the Ryzen 2400G when doing **HEVC 10-bit HDR with Vulkan tone-mapping**. That is exactly the corner where Vega loses — so test one HDR title before declaring success.

### Manifest changes (`apps/jellyfin/deployment.yml`)

Four edits, all in the pod spec:

1. **Remove `runtimeClassName: nvidia`.** Leaving it in means the pod asks for the NVIDIA runtime on a node that has none, and it will not start.
2. **Replace the GPU node selector.** `nvidia.com/gpu.product: Quadro-P620-SHARED` must go. Prefer a dedicated label so the placement survives future moves:

   ```yaml
   nodeSelector:
     media/gpu: amd-vega
   ```

   Label drone-03 with `kubectl label node drone-03 media/gpu=amd-vega`. Pinning `kubernetes.io/hostname: drone-03` also works and matches the `healthchecks` style, but hardcodes the node.
3. **Mount the render node** — there is no `nvidia.com/gpu` resource for a hostPath device:

   ```yaml
   volumes:
     - name: dri
       hostPath:
         path: /dev/dri
         type: Directory
   # container:
     volumeMounts:
       - name: dri
         mountPath: /dev/dri
   ```
4. **Drop the GPU limit** — remove `nvidia.com/gpu: "1"` from `resources.limits`, keep `memory: 4G`.

`securityContext.privileged: true` is already set and is sufficient for `/dev/dri` access; no `supplementalGroups` needed. If it is ever dropped, the `render` group GID must be added instead (`getent group render` on the host).

### Jellyfin's own setting

The transcode hardware is stored in Jellyfin's **config, not in git** — switching nodes is not enough. In the dashboard:

- Dashboard → Playback → Transcoding → Hardware acceleration: **VA-API**
- Enable hardware decoding for H.264 and HEVC, **leave HEVC 10-bit encoding off**
- Enable tone mapping only if you accept the Vulkan crash risk above

### Validate before touching drone-02

- [ ] Pod running on drone-03, not CrashLooping on runtime class
- [ ] `vainfo` inside the pod reports `VAEntrypointVLD` and `VAEntrypointEncSlice` on `renderD128`
- [ ] A forced 1080p transcode plays and shows low CPU on drone-03
- [ ] One 10-bit HEVC title transcoded deliberately, to confirm it falls back rather than crashing
- [ ] Jellyfin playback over Tailscale still works (ingress unaffected)

If this fails, Jellyfin may go back to drone-02 temporarily — but drone-02 cannot be drained until it works, so treat this as the real gate on step 3. After drone-02 and drone-01 are gone there is no discrete GPU anywhere in the cluster: the only fallback is software transcode on a 4C/8T node, which is not viable for 4K or HEVC-heavy sources. That is why Phase 0 requires a 4K HDR title to be tested before any swap begins.

## Scrypted — no GPU, and none needed

Scrypted is a HomeKit gateway for the security cameras, and its HomeKit path does not transcode. The live ffmpeg invocation is a remux — `-vcodec copy -acodec copy` against the Reolink `h264Preview_01_sub` substream at 640x480 / 640x360, 10 fps — and `nvidia-smi` on drone-01 reports **no processes** with 3 MiB of 2048 MiB in use. The `nvidia.com/gpu: '1'` request has been holding a time-slice slot for nothing, and no object detection is in play.

Consequence for the plan: **Scrypted is not a step-4 concern at all.** It never used the P620, so taking it off the NVIDIA runtime is Phase 0 work (0.6), done while the card is still installed as a revert. That also deletes the "loses hardware detection at step 4" risk and the "run it for a week before the Haswells leave" gate.

The one case not yet exercised: the GPU selector has kept it on drone-01/drone-02 until now, so it has never had to land on a 2-core control-plane node. It is `hostNetwork: true`, so add a `kubernetes.io/hostname` selector only if that ever matters — movement between drones has been painless in practice, including HomeKit pairing.

### Image

`v0.147.0` publishes no plain `-noble` tag. The non-NVIDIA variants are `-noble-amd`, `-noble-full`, `-noble-intel` and `-noble-lite`; use **`-noble-amd`**, which keeps VA-API available for the day HKSV or a main stream is enabled:

```
ghcr.io/koush/scrypted:v0.147.0-noble-amd@sha256:9c8f6dff157be7acc074712e3c050e7dc0a898e1b2c00ede457840f652c8011d
```

It costs nothing today — the render node only matters when it actually transcodes, and that mounts with the Vega in Phase 1. An image variant change does not lose installed plugins: Scrypted keeps them in the PVC (`/server/volume/plugins`). Verify with a live view in the Home app after the change.

---

## Phase 4 — retire gpu-operator, proper PCI labels

Runs **last**, after drone-01 is swapped. Scrypted is already off the NVIDIA runtime from Phase 0, so the only remaining dependency is Jellyfin's move. Do not interleave this with the hardware swap.

### Why the two changes are linked

`infrastructure/node-feature-discovery/app.yml` restricts PCI label fields to vendor only:

```yaml
pci:
  deviceLabelFields:
    - 'vendor'   # gpu-operator expects only vendor
```

That restriction exists **solely** to satisfy gpu-operator. With the operator gone there is nothing to satisfy, so the fields can be chosen for usefulness instead. Note the NFD default is `[class, vendor]`, which yields `pci-0300_1002.present` — the PCI *class*, identical on every display adapter and useless for telling two GPUs apart. Step C sets `vendor` + `device` instead, which gives real identity: `pci-1002_15dd.present`.

### Verified before writing this

- **85 stale `nvidia.com/*` node labels** will be orphaned: 37 on drone-01, 37 on drone-02, 11 on drone-04. Nothing removes them on uninstall.
- **No repo consumer of PCI labels.** The only `feature.node.kubernetes.io` selector anywhere is zigbee2mqtt's `usb-ff_10c4_ea60.present` — a **USB** label, governed by `sources.usb`, untouched by `sources.pci`. Changing PCI label fields cannot break it.
- **The containerd `nvidia` handler is not the operator's — the binary is.** `/var/lib/rancher/k3s/agent/etc/containerd/config.toml` carries `runtimes.'nvidia'` → `/usr/local/nvidia/toolkit/nvidia-container-runtime`, and that is a **host** path written by the toolkit DaemonSet, so it survives uninstall. There is **no `default_runtime_name`** in that file and no `config-v3.toml.d/` drop-in, so runc is the implicit default. `CONTAINERD_SET_AS_DEFAULT: 'true'` points at `/etc/containerd/config.toml.tmpl`, which does not exist on a k3s node, so it never took effect — the default-runtime risk is already settled.
- **The driver is not the operator's.** `nvidia-driver-daemonset` reports 0 desired / 0 ready; the driver comes from `ghcr.io/ublue-os/ucore:stable-nvidia-lts` in `bootc/Containerfile`. Retiring the operator leaves an NVIDIA driver installed on all nodes, including the AMD ones. Harmless, separate rebase decision.
- **Three of the RuntimeClasses are the operator's; one is not.** `nvidia`, `nvidia-cdi` and `nvidia-legacy` carry `ownerReferences` → `ClusterPolicy/cluster-policy` (266d, same age as the operator), so deleting the Application garbage-collects them. `nvidia-experimental` is 396d old with no owner — a k3s built-in — and **stays**. It has no matching containerd handler, so it is already inert.

### Step A — confirm nothing requests the NVIDIA runtime

Both apps must stop requesting `runtimeClassName: nvidia` before the RuntimeClass objects disappear, or they fail to schedule.

- `apps/scrypted/` — done in Phase 0 (0.6).
- `apps/jellyfin/` — done in the Jellyfin phase above.

That ordering is now a formality rather than a race: once drone-01 and drone-02 are swapped there is no NVIDIA hardware left in the cluster, so nothing will ever reference the runtime again. Keep the order anyway, so a failure at step B cannot be confused with a scheduling failure at step A.

### Step B — add the NodeFeatureRule

The CRD already exists (`nodefeaturerules.nfd.k8s-sigs.io`, zero instances). Add to `infrastructure/node-feature-discovery/`:

```yaml
apiVersion: nfd.k8s-sigs.io/v1alpha1
kind: NodeFeatureRule
metadata:
  name: amd-vega-gpu
spec:
  rules:
    - name: amd.vega
      matchFeatures:
        - feature: pci.device
          matchExpressions:
            vendor: {op: In, value: ["1002"]}
            device: {op: In, value: ["15dd"]}
      labels:
        media/gpu: "amd-vega"
```

`NodeFeatureRule` matches raw PCI features, not labels, so it works regardless of `deviceLabelFields` — verified in the NFD source: `deviceLabelFields` is only read inside `GetLabels()`, while `Discover()` publishes the full attribute map (`class`, `vendor`, `device`, subsystem ids) into the `pci.device` feature either way. So Step B does not need to wait for Step C. Prefer it to `kubectl label` — the label then follows the hardware if Jellyfin ever moves nodes.

**Verify the device ID first.** Raven Ridge is normally `15dd`; some Picasso parts report `15d8`. Check each mini with `lspci -nn | grep -i vga` before hardcoding. A wrong ID fails silently — that node simply never receives the label.

### Step C — widen the PCI label fields

Once Scrypted is confirmed off the NVIDIA path:

```yaml
worker:
  config:
    sources:
      pci:
        deviceLabelFields:
          - 'vendor'
          - 'device'
```

Drop the `# gpu-operator expects only vendor` comment with it. Expect `feature.node.kubernetes.io/pci-1002_15dd.present` etc. to appear, and the old `pci-10de.present` labels to be recalculated on the next worker run.

### Step D — remove gpu-operator

`prune: false` is set at **both** levels — `clusters/borg/infrastructure.yml` (the parent `infrastructure` Application) and `infrastructure/gpu-operator/app.yml` — so dropping the entry from `infrastructure/kustomization.yml` deletes **nothing**. It orphans the Application, and the orphan keeps reconciling its own resources with `selfHeal: true`. Argo will report Synced while the operator keeps running.

Order matters, because the parent self-heals:

1. Drop the reference in git first — remove `infrastructure/gpu-operator/` (`app.yml`, `kustomization.yml`, `config/any.yaml`) and its entry in `infrastructure/kustomization.yml` — and let the parent sync. The Application is now orphaned but still running.
2. Delete it explicitly: `kubectl delete application -n argocd gpu-operator`. Application deletion cascades its managed resources, which is what actually tears the chart down. Doing this before step 1 would just get it recreated by the parent.
3. Verify rather than assume: `kubectl get ns gpu-operator`, `kubectl get clusterpolicy`, `kubectl get ds -n gpu-operator`.

This also removes the 4× time-slicing replicas and the `time-slicing-config-all` ConfigMap.

### Step E — clean the stale node labels

Nothing garbage-collects them. Per node, remove every `nvidia.com/*` key — 37 on drone-01, 37 on drone-02, 11 on drone-04:

`jq` is available on `dev` (linuxbrew). Dry-run the list first, then remove:

```sh
# 1. preview what will be removed
kubectl get node drone-01 -o json \
  | jq -r '.metadata.labels | keys[] | select(startswith("nvidia.com/"))'

# 2. remove them — note the `| . + "-"`, which appends the
#    trailing minus kubectl needs to delete a label
kubectl get node drone-01 -o json \
  | jq -r '.metadata.labels | keys[] | select(startswith("nvidia.com/")) | . + "-"' \
  | xargs -r -n1 kubectl label node drone-01 --overwrite

# 3. repeat for drone-02 and drone-04
```

The trailing `-` is the whole trick and is easy to lose in a pipeline; a single label by hand is:

```sh
kubectl label node drone-01 nvidia.com/gpu.product-
```

Then verify no app still selects `nvidia.com/gpu.product`:

```sh
grep -rn 'nvidia.com/gpu' apps/ platform/ infrastructure/
```

### Step F — verify

- [ ] No pods requesting `nvidia.com/gpu` anywhere (`kubectl get pods -A -o json` scanned for GPU limits)
- [ ] `kubectl get runtimeclass` — `nvidia`, `nvidia-cdi` and `nvidia-legacy` gone; `nvidia-experimental` remains (k3s built-in, no handler, inert)
- [ ] Jellyfin transcoding still works on `renderD128` (it never used the operator)
- [ ] Scrypted Running as a HomeKit gateway — no GPU, no detection, live view in the Home app works
- [ ] New `pci-*` labels present, e.g. `pci-1002_15dd.present` on the node holding the Vega (no `pci-10de_*` anywhere — no NVIDIA hardware remains)
- [ ] `media/gpu=amd-vega` present on exactly the node running Jellyfin
- [ ] zigbee2mqtt still scheduled (its USB label must be intact)
- [ ] No `default_runtime_name` in `/var/lib/rancher/k3s/agent/etc/containerd/config.toml` after a reboot — runc is the implicit default
- [ ] Cluster Healthy in Argo, Gatus green

### Rollback

`git revert` the `infrastructure/gpu-operator/` deletion and the NFD value change, and Argo reinstalls the operator. The node labels are recreated by gpu-feature-discovery, but **only where a GPU is physically present** — after the swap that is nowhere, so a rollback restores the operator without restoring any GPU capacity. Treat this as a one-way door for acceleration.

### Consequence for drone-04's GTX 1060

Moot — the card leaves the cluster for another project as part of this work. Worth recording anyway: it was **never** a schedulable resource. `drone-04` allocatable is `nvidia.com/gpu: 0` today and no `nvidia-*` DaemonSet pod runs there, because the `dedicated=storage:NoSchedule` taint keeps the operator's DaemonSets off the node. Removing gpu-operator changes nothing about the 1060 that was not already true.

---

## Per-node procedure

Repeat Steps 1–7 for each of drone-03, drone-02, drone-01 — with the Jellyfin move inserted after drone-03's Step 6.

### Step 1 — Discover the hardware (live USB, before touching the cluster)

The interface name and disk device are unknown until you look, and both are baked into the installer. Get them right first.

1. Boot a live Linux USB on the EliteDesk.
2. Record:
   - **NIC name**: `ip -br link` — the Realtek will be something like `enp1s0` or `enp2s0`, **not** `enp0s25`.
   - **Disk device**: `lsblk` — `/dev/sda` for SATA, `/dev/nvme0n1` for NVMe.
   - **Disk interface**: also tells you whether the SATA bay is free or occupied.
3. Confirm UEFI: `test -d /sys/firmware/efi && echo UEFI`.
4. Enter BIOS (F10) and set: **Secure Boot → Disable**, **Legacy Support → Disable**, UEFI boot order first.

Skipping the interface check is the most expensive mistake available here: the host installs cleanly, then comes up with no network, no Tailscale and no SSH, which presents as a dead machine.

### Step 2 — Generate the installer (on dev)

```sh
cd ~/projects/k8s/bootc
just gen-ignition drone-03 <iface-from-step-1> 192.168.42.23
just build-iso drone-03
```

`build-iso` hardcodes `--dest-device /dev/sda`. If Step 1 showed an NVMe disk, override it to `/dev/nvme0n1` before building, or the install will target the wrong device.

### Step 3 — Retire the old node

```sh
kubectl drain drone-03 --delete-emptydir-data --ignore-daemonsets
kubectl delete node drone-03
```

Then power the chassis down and **remove and keep its SSD.** That disk is the rollback.

Wait for the pods that were on drone-03 to reschedule elsewhere and reach Ready before installing the replacement. Draining into an already-loaded cluster and installing at the same time makes failures hard to attribute.

### Step 4 — Install, then switch to the node image

Boot the generated ISO on the EliteDesk and let it complete. The ISO produces a **bare FCOS install** — not a cluster node. Finish it with the `bootc switch` from 0.3:

```sh
sudo bootc switch ghcr.io/kevindurb/k8s-node:latest
sudo systemctl reboot
```

After the reboot, confirm before touching k3s:

- `hostname` returns `drone-03`
- the static IP answers: `ping 192.168.42.23`
- `bootc status` reports `ghcr.io/kevindurb/k8s-node` and nothing unexpected staged
- `tailscale status` lists the node **tagged `tag:k8s-node`** (this needs the auth key from 0.3)
- `ssh core@drone-03` works
- `/dev/dri/renderD128` exists (proves `amdgpu` loaded — see the idle-power note)

### Step 5 — Join k3s

```sh
ansible-playbook ansible/provision.yml -i ansible/inventory/prod.yml --limit drone-03
```

`provision.yml` runs several plays; the ones that matter for a rejoin are `base` (timezone, SSH keys, `tuned` profile) and `k3s`, which fetches the token from `192.168.42.1`, templates `/etc/rancher/k3s/config.yaml` from `ansible/roles/k3s/templates/agent.yaml.j2`, and starts `k3s-agent.service`. The `k3s` play already waits for the node to reach Ready.

Confirm `kubectl get node drone-03` reports **Ready** and that `kubeletVersion` matches the rest of the cluster — `v1.37.2+k3s1` if Phase 0.1 landed. A mismatch means the node booted a different image than expected; check `bootc status` before anything else.

### Step 6 — Validate

Do not proceed to the next node until every line passes:

- [ ] Node **Ready**, `kubeletVersion` = cluster version
- [ ] `democratic-csi-node` pod running on the node
- [ ] `healthchecks-cronjob-drone-03` schedules and its Jobs complete
- [ ] Pods that were displaced by the drain are Ready (some will land here)
- [ ] Argo CD: all apps **Synced / Healthy**
- [ ] Gatus: all endpoints green
- [ ] Idle draw at the wall ≈ **11 W**, not ≈ 18 W — the higher number means `amdgpu` firmware did not load
- [ ] `/dev/dri/renderD128` present

**After drone-03 specifically:** do the Jellyfin → Vega 11 migration and its validation checks before starting drone-02.

### Step 7 — Cleanup after all three

- Update `ansible/inventory/prod.yml`: `static_iface` for drone-01/02/03 still says `enp0s25`. Note that `static_iface` and `static_ip` are **not consumed by any playbook or template** — they are documentation only, so this is accuracy rather than correctness. Worth doing anyway, so the inventory doesn't lie.
- Update `HARDWARE.md` CPU/RAM/GPU rows and the cluster summary. Mid-swap the inventory is 2× P620 (2 GB each); at the end it is **zero discrete GPUs** — the GTX 1060 leaves for another project. Also correct the summary's total RAM 120 → 112 GiB and cores 22 / 16 vCPUs → 26 / 52 threads, and the drone-03 iGPU row (Intel HD → Vega 11).
- Delete the two stale `Released` PVs bound to drone-03.
- Record the final GPU state: Jellyfin on Vega 11, Scrypted on CPU. Confirm nothing still selects `nvidia.com/gpu.product: Quadro-P620-SHARED`.

## Rollback

Per node, and only until all three are validated: reinstall the original SSD in the Haswell chassis, power it on, and re-run Step 5 to rejoin. The ignition config is static and the k3s config is templated, so a rejoin is a few minutes of work.

**Jellyfin rolls back with git.** Reverting the deployment change returns it to `runtimeClassName: nvidia` + the P620 selector; on drone-02 that still works until drone-02 is drained. After drone-02 is gone, the only fallback is the Vega 11 — so do not consider drone-02 swapped until the Vega 11 path is proven.

Keep all three Haswell SSDs — and their RAM, if it was pulled — until the whole migration is done. Do not repurpose or wipe them early.

## Risks

| Risk | Mitigation |
| --- | --- |
| Wrong interface name in the ignition config | Discover it on a live USB in Step 1 |
| `--dest-device /dev/sda` against an NVMe disk | `lsblk` in Step 1, override before `build-iso` |
| Legacy/CSM boot | UEFI-only, Secure Boot off — otherwise no `amdgpu` firmware, so 18 W idle and no transcoding |
| k3s agent 1.37.2 vs server 1.35.6 | Phase 0.1 upgrades the cluster first; never reboot a node into the staged image before the control plane is on 1.37.2 |
| Jellyfin left on `runtimeClassName: nvidia` | Remove it with the selector, or the pod will not start on drone-03 |
| Losing HEVC 10-bit encode | Accepted — Vega 11 cannot do it. Test an HDR title first |
| Vega 11 Vulkan tone-mapping crash (`error 139`) | Leave Vulkan tone-mapping off for 10-bit HDR, or transcode to H.264 |
| Scrypted left on the NVIDIA runtime | Only a Phase 0 cleanup — it never used the GPU. Check anyway, or the pod fails on any node without the toolkit binaries |
| Absolute Persistence armed in BIOS on a corporate unit | Clear it before reimaging |
| Stale Node object colliding with the rejoin | `kubectl delete node` in Step 3, before the new node joins |
| Expecting a 10 GbE upgrade later | Not possible — no PCIe slot. The M.2 2280 slot is the boot disk and the 2230 slot is WiFi. Accept 1 GbE. |

## Non-goals

- Renaming nodes or re-IPing them. Hostnames and addresses are preserved deliberately.
- Adding a discrete GPU to the minis. The MXM path only accepts HP's RX 560 and costs the 2.5" drive bay and the quiet idle.
- Giving Scrypted hardware detection. It has no object detection in use — it is a HomeKit gateway only, and its stream is a remux.
- Rebasing nodes off `ucore:stable-nvidia-lts`. The NVIDIA driver stays installed but unused — separate change.
- Keeping the GTX 1060 usable. The card leaves the cluster for another project, and it was never registered as a schedulable resource.
- Replacing drone-04. It stays: Ryzen 7 2700, 8C/16T, the ZFS pool and the 12 TB disks all live there. The GTX 1060 comes out of it for another project.
