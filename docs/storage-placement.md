# Storage: node-local ZFS with a replicated mesh

## Status (2026-11-19)

**In progress.** The pools exist and the first volume has left democratic-csi —
but not for OpenEBS yet: Immich's photos moved to the NAS. No application uses
`zfs-local` and no volume has joined the mesh.

### Done

- **All three node-local `k8s` pools**: drone-01, drone-02 and drone-03 were
  rebuilt on 2026-11-19 with a 600 GiB pool at the end of the NVMe and a 331 GiB
  root (`docs/drone-03-rebuild.md`). Each is healthy, imports at boot, and uses
  `lz4`/`atime=off`/`xattr=sa` with a 2 GiB ARC.
- The provisioning side of the plan is in git and exercised three times:
  `ansible/roles/node_zfs`, `k3s_node_labels`, the `storage_nodes` group, and the
  installer `save-partlabel` flow that reserves the partition.
- `zfs send | zfs recv` into `k8s/replicas` was verified end to end on drone-03
  (Phase 5), which is the primitive zrepl will use.
- **`immich-data` → NFS (2026-11-19).** The 600 GiB, 318 GiB-used zvol became
  `/media/immich` on drone-04's media export, exposed as the static PV
  `immich-nas` and mounted at `/data` exactly as before (`apps/immich/nas.yml`,
  the `romm-library` pattern). The copy ran **pool-local on drone-04** with the
  zvol mounted read-only — no 1 GbE hop for 318 GiB. `server.yml` was not
  touched: the claim keeps the name `data`, so only the PVC's class changed. The
  old PV is `Retain`ed for a week. This is the "immich last" step of the original
  order, pulled forward because it needs no CSI, no pin and no zrepl.

### Verified live (2026-11-19)

- `zpool list` on all three app nodes: `k8s` 596 G, **~700 K allocated**;
  `k8s/volumes` and `k8s/replicas` both exist and are empty.
- `systemctl is-enabled zrepl` → **not-found** on all three: the mesh does not
  exist yet.
- No `openebs` namespace and no `openebs`/`mayastor` CRDs: a clean slate for the
  LocalPV-ZFS install.
- **42 democratic-csi PVCs, 4 on `zfs-local`, 43 GiB of live data.** The stale
  `Released` PVs, labels, empty namespaces and `rust/longhorn` this section used to
  list were all cleared the same day — see "Cleanup found while planning".

### Canary — done 2026-11-20

`infrastructure/openebs-zfs` is live: the `openebs/openebs` 4.6.2 chart with only
the LocalPV-ZFS engine enabled, `zfs-local` StorageClass, `VolumeSnapshotClass`,
and the node agent running on exactly drone-01/02/03 (not tolerated onto
drone-04 or the control plane).

Smoke test on drone-03 passed end to end: create → write 64 MB → **expand**
(1 GiB → 2 GiB, block then filesystem) → **snapshot** → **restore** → delete,
with no leftovers. The zvol came up `volblocksize=16K`, `refreservation=none`
(thin), `compression=lz4`, exactly as configured.

Four real volumes now run on it, all on drone-03:

| App | Volume | Verified |
| --- | --- | --- |
| `golink` | 1 GiB | 26 files / 56,450 bytes, identical `golink.db` md5; serves over tsnet (`https://go.beaver-cloud.ts.net` → 200) |
| `gatus` | 954Mi | 43 files / 6,224,544 bytes; `/health` → 200 and it is monitoring again |
| `rakazo` | `database` 20Gi | 2,181 files / 91,462,043 bytes; Postgres answers, 352 tables |
| `rakazo` | `web-assets` 2Gi | 302 files / 44,545,549 bytes |

`rakazo-data` (30Gi) deliberately **stayed on democratic-csi** — see gotcha 5.
42 PVCs remain on `zfs-generic-nvmeof-csi`.

**Decision: OpenEBS LocalPV-ZFS it is.** The `zfs-local-zvol` fallback is not
needed, so `spec.csi.driver` is settled before the rest of the volumes move.

Four things the canary taught us, all now in the procedure below:

1. **A `VolumeSnapshot` pins its zvol.** zfs-localpv snapshots the volume's own
   dataset, so deleting the PVC while the snapshot exists leaves the zvol behind
   (`DeleteVolume` fails on dependent snapshots, the same as sanoid). Delete
   snapshots *before* PVCs.
2. **A pre-bound PV will bind a PVC with the wrong class.** `claimRef` matching
   overrides the class check, so if Argo creates the PVC from a stale revision you
   get a `zfs-local`-backed claim labelled `zfs-generic-nvmeof-csi` — and
   `storageClassName` is immutable. Make sure the app is on the new revision
   (hard refresh / explicit sync revision) *before* the PVC is recreated.
3. **The parent app-of-apps undoes a child's pause.** Resuming `apps` while a
   child is still paused re-enables its `automated` policy within seconds (that is
   what brought the pod — and the PVC-deleting `pvc-protection` finalizer — back).
   Pause `borg → apps → <app>` and resume `<app> → apps → borg`, as written.
4. **Component files are `kustomize.config.k8s.io/v1alpha1`**, not `v1beta1`.
5. **One RWO PV cannot serve two pods.** zfs-localpv mounts the zvol per pod and
   refuses a second stage on the same node (`verifyMount: device already
   mounted`). `rakazo` is the only app in the cluster that shares a volume between
   two workloads (`api` + `worker` both mount `/data`), so that one volume stays on
   democratic-csi; its siblings moved. A volume like this needs a single pod with
   two containers, or RWX over NFS, before it can follow.

### Mesh — done 2026-11-20

zrepl v0.7.0 runs on all three app nodes: `zrepl status` is clean, the three
`:9811` exporters are scraped (`up{job="zrepl"} = 1` with a `node` label), the
lag/error alerts are loaded and not firing, and drone-01 and drone-02 each hold
**4 replicas** of drone-03's four volumes.

Two config facts the sketch below did not have:

- The `tcp` transport **requires a `clients` allowlist** on the `source` job, and
  pull jobs need `recv.placeholder.encryption: inherit` — zrepl refuses to guess
  the encryption of the intermediate datasets it creates.
- A `source` job has **no `pruning` parameter**; the pullers' `keep_sender` grid
  is what prunes the source's snapshots.

**Before any reboot:** the nodes are running zrepl from a `bootc usr-overlay`
(transient writable `/usr`), because the package only reaches the image with this
commit's build. Until the nodes have upgraded to that image, a reboot loses the
binary and `zrepl.service` stops. Sequence it as: CI build → pull the image →
reboot.

### Not started

- **Step 2 is complete** (golink, gatus, rakazo). The next volumes are a policy
  call, not a canary: move them per node as `storage-home-*` pins land.
- **Step 3 — the mesh**: zrepl RPM in the image, config rendered by `node_zfs`,
  `zrepl status` green on every peer, `zrepl prometheus` scraped with a lag alert.
- **Steps 4–6**: `components/storage-home-*` and the app moves (drone-02's stack,
  then drone-01's media), then the teardown of `zfs-generic-nvmeof-csi`.

### Decisions still open

- ~~OpenEBS vs the democratic-csi `zfs-local-zvol` fallback~~ — **settled
  2026-11-20: OpenEBS LocalPV-ZFS**, proven by the canary (see Status).
- **Where Jellyfin lives.** Since 2026-11-19 `media/gpu=amd-vega` comes from a
  `NodeFeatureRule` and matches **all three** minis (identical Vega 11), so
  Jellyfin floats. This doc's placement table assumed drone-01 as the media node;
  either pin it deliberately or accept the float.
- **Churny volumes must not enter the mesh.** `rust/k8s/volumes` holds 127 GiB of
  sanoid history on 43 GiB of data, dominated by `romm-redis` (62 GiB on a 5 GiB
  volume) and `prometheus` (28 GiB). Replicating that to two peers triples it.
  Either move them to a `k8s/scratch` StorageClass (second `poolname`) or exclude
  them from zrepl's glob; regenerable caches (`immich-machine-learning-cache`)
  should be `emptyDir`.
- `prometheus` PVC vs a static local PV per node, and whether the hostNetwork apps
  become movable (both listed at the bottom of this doc).

## Why this exists

The old complaint was not failover, it was **maintenance**. Every stateful app sat
on `zfs-generic-nvmeof-csi`: zvols on drone-04 exported over NVMe-oF and mounted
by initiators on the other nodes. That bought one thing — a volume can attach to
any node — and charged for it with a permanent maintenance tax:

- The storage box is a Kubernetes node, so its OS update is a cluster storage
  event: stop Argo, scale 48 workloads to zero, wait for NVMe-oF detach, reboot,
  count exported subsystems, scale back up (`ansible/reboot-drone-04.yml`, 230
  lines).
- The transport is coupled to both kernels: bounded `param_mdts`, one I/O queue
  for the loopback initiator, a 10-minute `ctrl_loss_tmo` cliff, stale
  `/dev/nvme*` devices, shutdown-ordering drop-ins, `nvmetcli clear`.
- One node down takes **every** stateful app and all 9 TB of media with it.

Replicated local storage was considered and rejected: Longhorn (already retired
after a metadata-corruption incident), Mayastor (leftover `Released` PVs still in
the cluster), Ceph and DRBD/LINSTOR (more moving parts than the problem, no 10 GbE
to run them on, and an out-of-tree module treadmill on a bootc image).

What replaced it: **a small ZFS pool on each app node, replicated between all
three, with pods pinned.** The CSI layer is **OpenEBS LocalPV-ZFS** (its
*non*-replicating engine — not Mayastor, which stays rejected) and replication is
**zrepl**. Downtime on node maintenance is accepted. That trade is what makes the
rest of this document simple.

## Target architecture

```
                 ┌──────────────────────────────────────────────┐
                 │  drone-04   Ryzen 7, 2×12 TB ZFS mirror       │
                 │  rust/media → NFS  (bulk media, immich, romm)│
                 │  makemkv, transcoding, healthchecks          │
                 └──────────────────────────────────────────────┘
                            ▲ NFS (bulk only)
   ┌────────────────────────┼──────────────────────┐
   │                        │                      │
┌──┴──────────┐      ┌──────┴───────┐      ┌───────┴──────┐
│  drone-01   │      │   drone-02   │      │   drone-03   │
│  media      │      │  home / IoT  │      │  platform    │
│  k8s/       │◀────▶│  k8s/        │◀────▶│  k8s/        │
│  volumes    │sync  │  volumes     │ sync │  volumes     │
│  replicas   │      │  replicas    │      │  replicas    │
└─────────────┘      └──────────────┘      └──────────────┘
   each node: local volumes + a replica of every other node's volumes
```

Every volume exists on all three nodes: one live copy in `k8s/volumes` on its home
node, and one replica in `k8s/replicas` on each of the other two. Bulk media never
enters the mesh — it is replaceable or B2-backed and lives on the 12 TB mirror.

## Node roles

Placement assumes the Haswell → EliteDesk swap is finished on all three — it is,
as of 2026-11-19. Each node: 4 vCPU, ~22 GiB, 1 GbE, one 1 TB NVMe split into a
331 GiB root and a 600 GiB `k8s` pool.

| Node | Role | Rationale |
| --- | --- | --- |
| **drone-01** | media playback + photos + identity | everything that reads the NFS share or the photo library, so one node takes the media I/O; `pocket-id` sits here to keep auth off the platform node |
| **drone-02** | home / IoT | defined by hardware: the Zigbee USB dongle is here, so the automation stack follows it |
| **drone-03** | platform + background | Prometheus/Alertmanager/Gatus, the *arr stack, personal apps, `rakazo`, `browser` |
| **drone-04** | bulk media + hardware | 12 TB pool, NFS, Blu-ray drives, transcode jobs. Keeps its `dedicated=storage` taint; never joins the mesh |

Three deliberate separations:

1. **Monitoring is not on the home node.** If automation breaks you still get the
   alert, and if the platform node dies the house keeps running.
2. **Auth is not with monitoring.** A platform-node failure does not take out
   observability and identity together.
3. **Media lives together.** A media-node loss is "no watching tonight" — the
   cheapest failure available.

## Placement

Local volumes are the ones that move with the app; NAS volumes are the static NFS
PVs and stay where they are. Sizes are measured use on 2026-11-18.

### drone-01 — media + identity

Live data measured 2026-11-19 (`usedbydataset`, so snapshot history is excluded).

| App | Local volumes (declared / live) |
| --- | --- |
| immich-server | `immich-data` → **NFS `/media/immich`** (318 GiB, PV `immich-nas`) |
| immich-postgres | 20Gi / 0.8 GiB |
| immich-machine-learning | 10Gi / 1.7 GiB (regenerable cache) |
| jellyfin | 50Gi / 10.6 GiB + `jellyfin-nas-media` |
| audiobookshelf | config 1Gi, metadata 1Gi, books 10Gi / 1.3, audiobooks 10Gi / 1.7, podcasts 11Gi / 1.1 |
| romm | resources 20Gi / 12.7, assets 10Gi, config 1Gi, launchbox 10Gi + `romm-library` |
| romm-mariadb | 5Gi / 0.4 |
| romm-redis | 5Gi / **4.4 — 88 % full**, plus 62 GiB of sanoid snapshots on it |
| navidrome | 5Gi / 0.4 + `navidrome-nas-media` |
| calibre / calibre-web | 1Gi each / ~0 + `*-nas-media` |
| kiwix, dufs | NAS only |
| pocket-id | 1Gi / ~0 |

≈ **31 GiB** of local data plus 318 GiB of photos on the NAS. Pinned with
`storage-home-drone-01`; `jellyfin` also keeps its `media/gpu=amd-vega` capability
label.

### drone-02 — home / IoT

| App | Local volumes (declared / live) |
| --- | --- |
| zigbee2mqtt | 1Gi / ~0 — **USB dongle is physically here** |
| mosquitto | 1Gi / ~0 |
| home-assistant | 40Gi / 0.9 — hostNetwork |
| omada | 10Gi / 2.0 — hostNetwork |
| syncthing | 100Gi / 0.8 + `syncthing-nas-media` — hostNetwork |
| scrypted | 10Gi / 0.1 — hostNetwork |
| donetick | 5Gi / ~0 |
| mealie | 10Gi / ~0 |

≈ **4 GiB**. Sparse on purpose: the node is defined by the dongle, and everything
else here is one functional group.

### drone-03 — platform + background

| App | Local volumes (declared / live) |
| --- | --- |
| prometheus | 35Gi / 2.2 (plus 28 GiB of snapshot history on the current pool) |
| alertmanager / gatus | 1G each / ~0 |
| rakazo (api, worker, web, postgres) | data 30Gi / ~0, database 20Gi / 0.1, web-assets 2Gi / 0.05 |
| browser | 5Gi / 0.5 |
| radarr / sonarr | 10G each / 0.8 & 0.2 + `*-nas-media` |
| qbittorrent | config 10Gi, ts-state 1Gi + `qbittorrent-nas-media` (app at 0 replicas) |
| f1timing / pokesim | 30Gi / 1.7, 10Gi / 0.9 |
| minecraft | 10Gi / 0.7 |
| semaphore, tsgit ×2, linkding, golink, consignment-app | <0.1 total |

≈ **7 GiB**. `rakazo` is already pinned to `drone-03` in git
(`apps/rakazo/{workloads,bootstrap,migrate}.yml`), which makes it the natural first
canary: pinned, small, and a database to prove real recovery.

### Not pinned at all

`drone-04`: `makemkv`, `transcoding`, the per-node `healthchecks` CronJobs,
`zfs-exporter`. Cluster infrastructure stays free to float: argocd, coredns,
metallb, node-exporter, tailscale, and the CSI node DaemonSet.

## How an app is pinned

A component per node, applied to the app's `components:` list. Strategic merge, so
an app that already has a `nodeSelector` (`jellyfin`'s `media/gpu`, `zigbee2mqtt`'s
USB label) keeps it:

```yaml
# components/storage-home-drone-02/kustomization.yml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Component
patches:
  - target:
      kind: Deployment
      labelSelector: app.kubernetes.io/component=app
    patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: ignored
      spec:
        template:
          spec:
            nodeSelector:
              kubernetes.io/hostname: drone-02
```

`grep -rl storage-home apps/` is then the whole placement inventory.

**The pin and the PVC must land together.** The StorageClass uses
`volumeBindingMode: WaitForFirstConsumer`, so a volume is created on whichever node
its pod first schedules to. Pin first, then let the PVC bind; after that the PV's
`nodeAffinity` is the enforced truth, and a wrong `nodeSelector` produces a
**Pending pod**, never a write to the wrong copy.

Exceptions and consequences:

- **`zigbee2mqtt` gets no `storage-home-*` component.** It keeps only
  `feature.node.kubernetes.io/usb-ff_10c4_ea60.present`. The dongle's node *is* its
  storage home; moving the dongle is a deliberate promotion, not a scheduling
  decision.
- **`rakazo` keeps its three explicit `kubernetes.io/hostname: drone-03`
  selectors** rather than gaining a component — the Jobs need the same pin so
  their image pulls resolve. Do not add both; two writers to one key merge
  ambiguously.
- **hostNetwork apps** (`home-assistant`, `omada`, `scrypted`, `syncthing`) get
  stable LAN IPs as a side effect, which ends the "the pod moved and its IP
  changed" incidents. Converting them to ClusterIP + Ingress is deliberately out
  of scope and would make them movable again.
- **Media readers do not need locality.** The `*-nas-media` mounts are RWX over
  NFS from drone-04, so `radarr`'s home is about its config volume, not its media.

## The CSI layer: OpenEBS LocalPV-ZFS

Provisioner `zfs.csi.openebs.io`, installed as its own Argo application
(`infrastructure/openebs-zfs`) from the `openebs/openebs` Helm chart in namespace
`openebs`, with only the `zfs-localpv` engine enabled (the chart ships several;
verify the value names against the chart version — Renovate bumps it).

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: zfs-local
provisioner: zfs.csi.openebs.io
parameters:
  poolname: "k8s/volumes"    # must exist under exactly this name on every node
  fstype: "ext4"            # ⇒ a zvol, formatted ext4
  volblocksize: "16k"       # power of two; matches the volumes being replaced
  compression: "lz4"
  dedup: "off"
volumeBindingMode: WaitForFirstConsumer   # mandatory for node-local volumes
allowVolumeExpansion: true
reclaimPolicy: Delete
```

Decisions worth naming:

- **ext4 on a zvol, not `fstype: zfs`.** Native datasets are faster — no filesystem
  layer — but a dataset carries its `mountpoint` property into replication, and the
  restore runbook that has actually been rehearsed is "mount the zvol, `fsck -n`,
  start the app". 16 KiB blocks and lz4 match what is being replaced, so
  `fsGroup: 1000`, the ext4 journal and every note in the existing migration docs
  still hold.
- **`poolname` is `k8s/volumes`,** so the zvols land in exactly the tree the old
  driver used, and the replication job's glob is the same tree.
- **`WaitForFirstConsumer`** — the pin decides the home, exactly as in
  [How an app is pinned](#how-an-app-is-pinned).
- **Node labels.** `kubectl label node <n> openebs.io/nodeid=<n>` on the three
  **app** nodes only. drone-04 and unimatrix-01/02/03 still carry five
  `openebs.io/*` keys from the retired Mayastor install (`csi-node`,
  `csi-node.nvme-ana`, `engine`, `nodeid`, `nodename`); strip those first, or
  `openebs.io/nodeid` means two different things depending on the node. OpenEBS
  uses that identity for its documented PV-migration procedure, which is the
  supported alternative to hand-writing a PV during a promotion.
- **Volumes are `ZFSVolume` objects.** `kubectl -n openebs get zfsvolume` shows
  node, size and state — better visibility than a driver-internal volume name.

Snapshot support reuses the `snapshot-controller` already running in `kube-system`;
the `VolumeSnapshotClass` needs `driver: zfs.csi.openebs.io`. Those are for ad-hoc
restores only — zrepl owns the periodic history.

**Fallback.** If LocalPV-ZFS misbehaves, the alternative is democratic-csi's
`zfs-local-zvol` on the same pool and the same `k8s/volumes` parent (a second
release of that chart, driver name `org.democratic-csi.zfs-local`). Since
`spec.csi.driver` on a PV is immutable, the choice is settled before the first
application moves — the canary in [Migration order](#migration-order) is the
decision point.

**Coexistence.** This is a different operator from `infrastructure/democratic-csi`,
so the nvmeof app keeps serving un-migrated volumes with no shared code path and no
all-or-nothing cutover. Apps move one at a time.

## The mesh: zrepl

### Pool layout

Each node has the same pool name and the same two datasets:

```
k8s                 mountpoint=none, ashift=12, compression=lz4, atime=off
k8s/volumes         what this node snapshots and serves
k8s/replicas        what it receives
```

`mountpoint=none` everywhere: these are zvols, nothing is mounted, so no directory
is needed on the read-only root and nothing sits outside `/var`.

### Single-writer fan-out, not mutual sync

For each volume there is **one writer** — the node that hosts the app — and **two
read-only receivers**. Direction is a property of where the volume lives, not of the
link, so there is no bidirectional conflict to resolve.

Each node runs three zrepl jobs:

| Job | Purpose |
| --- | --- |
| `source` | snapshot `k8s/volumes/*` every 15 minutes and serve them to peers |
| `pull-drone-0X` ×2 | one per peer: receive that peer's `k8s/volumes/*` into `k8s/replicas` |

Sketch (exact keys come from zrepl's `source`/`pull` documentation; the
`node_zfs` role renders this per host from `host_vars`):

```yaml
jobs:
  - name: source
    type: source
    serve:
      type: tcp
      listen: "192.168.42.<this node>:8888"   # exact `serve` shape per zrepl docs
    filesystems:
      "k8s/volumes/*": true
    snapshotting:
      type: periodic
      interval: 15m
      prefix: zrepl_

  - name: pull-drone-02
    type: pull
    connect:
      type: tcp
      address: "drone-02:8888"
      client_identity: drone-01
    root_fs: k8s/replicas
    interval: 15m
    pruning:
      keep_sender:
        - type: not_replicated
        - type: grid
          grid: 1x1h(keep=all) | 24x1h | 14x1d
          regex: "^zrepl_.*"
      keep_receiver:
        - type: grid
          grid: 1x1h(keep=all) | 24x1h | 35x1d | 6x30d
          regex: "^zrepl_.*"
    # initial_replication: most_recent (default) sends one snapshot the first
    # time; "all" seeds the whole history onto the new replica, which is worth
    # doing once if you want every peer to be a full snapshot archive.
```

**Why pull rather than push.** A `sink` job receives to
`$root_fs/$client_identity/$source_path`, which would add a per-peer level
(`k8s/replicas/drone-02/...`). `pull` receives to `$root_fs/$source_path`, so a
volume has one path on every node — but `$source_path` is the **full** source
filesystem, so the tree is nested, not flat:

```
k8s/replicas/k8s/volumes/pvc-<uuid>      # what drone-01/02 hold of drone-03's volumes
```

**Nothing has to be kept in sync with the placement.** The `source` job exposes a
glob over `k8s/volumes`; demoting a volume renames it out of that tree, so the node
stops exposing it, and promoting one renames it in, so it starts. The only per-host
difference is the peer address list, which the role renders.

### What zrepl enforces that a script cannot

- **Step holds.** `keep_sender: not_replicated` withholds any snapshot a
  replication step still needs, so pruning cannot break the next incremental. This
  removes the whole "a pruner deleted the base snapshot" failure class that the
  sanoid + syncoid design had to guard against with a written rule.
- **A replication cursor** in ZFS user properties on both sides: resumes after a
  reboot or a failed transfer without guessing, and without a surprise full send.
- **Fails closed on divergence.** If a replica has drifted so that no common
  snapshot exists, the step fails and says so in `zrepl status` and the metrics; it
  does not overwrite or delete the diverged filesystem. Clearing it is then a
  deliberate `zfs destroy` of that replica. syncoid can do the same only with
  `--force-delete`, which is an argument you can also type by mistake.
- **Visibility.** `zrepl status` for humans; `zrepl prometheus` for the existing
  scrape config and the lag alert — no bespoke textfile collector.

If the two pullers ever race and a common base is gone, the worst case is a re-sent
volume (1 GiB, seconds), never a silent overwrite.

### Packaging and transport

- Not in Fedora proper: a statically linked Go binary from the vendor's RPM
  repository. That repo's metadata GPG check cannot be automated, so install the
  release RPM **by URL** in `bootc/Containerfile` — the same shape as the existing
  `k3s-selinux` line — and **pin the version**: zrepl is pre-1.0 and the repo tracks
  latest.
- `zrepl.service` enabled by the image; the config is rendered to
  `/etc/zrepl/zrepl.yml` by the `node_zfs` role.
- Transport: `tcp` is plaintext on the LAN, which is acceptable on the segmented
  network from [`network-segmentation.md`](network-segmentation.md) (firewalld is
  off on every node). `tls` with mutual certs is supported if that changes.
  `ssh+stdinserver` works but brings back root SSH, which this design avoids.

### Why full mesh rather than a ring

A ring (each node → the next) gives the same availability for a third of the
traffic — with three nodes, surviving two simultaneous failures is meaningless.
The mesh buys **promotion anywhere for free**: every node is already a valid home
for every app, so a rebalance never needs a `zfs send`, only a `zfs rename`.

Cost: every node stores the whole mesh dataset.

| | on disk | of the 600 GiB pool |
| --- | --- | --- |
| Live app data (measured 2026-11-19) | 43 GiB | 7 % |
| Each node in the mesh holds | ~43 GB live + both peers' replicas = **the whole set** | 7 % |
| Plus received snapshot history | bounded by the `keep_receiver` grid — but see the churn warning below | — |

Seeding is the only expensive moment: ~43 GB per peering, six peerings, sequential
because they share one 1 GbE — well under an hour.

**Snapshot history is the cost that is easy to forget.** `rust/k8s/volumes` holds
43 GiB of data inside 127 GiB of sanoid history: `romm-redis` is 62 GiB of
snapshots on a 5 GiB volume and `prometheus` is 28 GiB. zrepl's grids are tighter
than sanoid's here, but any volume that rewrites itself constantly should be
deliberately outside `k8s/volumes` (scratch class or `emptyDir`), or every peer
carries the churn.

### Snapshot rules

- **zrepl owns the app tier's snapshots and pruning**: snapshotting on the `source`
  job's schedule, pruning through `keep_sender`/`keep_receiver` on each `pull`. No
  sanoid on `k8s/volumes` or `k8s/replicas`.
- **sanoid stays on drone-04 only**: `rust/media`, and `rust/k8s/volumes` until the
  last zvol has moved.
- The replica doubles as a snapshot archive: `keep_receiver` retains a longer grid
  than the sender, so any peer can `zfs clone` an older snapshot when an app
  corrupts its own volume.
- **Alert on lag, not on failure**: scrape `zrepl prometheus` and alert when a
  replication step is idle or behind by more than 2× the interval.

## Moving an app, and recovering a node

Both are the same operation, which is why it is worth scripting once.

**Tier 1 — rebuildable.** Caches, redis, `qbittorrent-ts-state`, prometheus. Change
the pin, delete the PVC, let it recreate on the target. Nothing to move.

**Tier 2 — small volumes (everything else here).** Which procedure applies
depends on where the *source* volume lives.

*Off democratic-csi — every volume moving today.* One Job, exactly like
`docs/longhorn-to-democratic-csi.md`: scale the app to 0 (pause its Argo chain
first), let the Job run on the **destination** node with the old PVC attached
over NVMe-oF at the same time as the new `zfs-local` PVC, and
`rsync -aHAX --numeric-ids /old/ /new/` between them. Verified 2026-11-19:
democratic-csi PVs carry **no** `nodeAffinity`, so nothing pins the old volume
away from the destination — the old runbook's trick does carry over here.

*Node-local → node-local — promotions after the move.* Two pods and a scratch
path:

1. scale the app to 0 (pause its Argo app first, as in the old migration runbook);
2. pod on the **source** node: mount the old PVC, `rsync` to `drone-04:/media/.migrate/<app>`;
3. change the pin in git; the new PVC binds on the target node;
4. pod on the **target** node: `rsync` back into the new PVC;
5. unpause, verify, delete the old PVC (leave the PV `Retain` for a week).

A single Job **cannot** do *that* in one step: two node-local PVCs have
contradictory node affinities, so a pod mounting both is unschedulable.

**Tier 3 — big volumes and node recovery.** The replica is already on the
destination, so promotion costs no copy time:

```bash
# 1. stop the app, then wait one zrepl interval (or `zrepl signal wakeup pull-<peer>`)
#    so the destination's replica is current. This replaces the old "final send".
kubectl -n <ns> scale deploy/<app> --replicas=0

# 2. demote on the old owner: it leaves the source job's glob, so this node stops
#    snapshotting and serving it
ssh old "sudo zfs rename k8s/volumes/<vol> k8s/replicas/k8s/volumes/<vol>"

# 3. promote on the new owner: it joins the source job's glob
ssh new "sudo zfs rename k8s/replicas/k8s/volumes/<vol> k8s/volumes/<vol>"
```

Then the PV and the pin: use OpenEBS's documented PV-migration procedure
(`openebs.io/nodeid`) or a static PV pointing at the new node, move the
`storage-home-*` component in git, and unpause.

Two properties make this safe rather than merely scripted:

- A zvol can only be in one tree on one host, so there is **no state where two
  nodes both consider a volume theirs**.
- The demoted copy on the old owner is now a replica *of* the new owner. The history
  is shared, so the next pull continues incrementally. If the copy was written to
  after the last replication, the pull fails with a missing common snapshot — zrepl
  neither overwrites nor deletes it. `zfs destroy` the diverged copy and let the
  puller re-create it (seconds for a 1 GiB volume). The failure mode is a refusal
  you clear by hand, never an overwrite.

A node that is gone for good follows the same steps, with the replica already
current to the last interval; a node that is merely rebooting needs nothing — its
pods come back on it.

## Backups and integrity

The mesh is **not** a backup: same rack, same switch, same house, same power.

- **zrepl** owns snapshotting on `k8s/volumes` per node: it is both the fast
  "oops" path and the source of the history the replicas carry.
- **restic → B2** from each node, reading those snapshots directly, replaces the
  VolSync/CSI-snapshot design in [`backups.md`](backups.md). It is materially
  simpler there: no mover pods, no temp PVC clones, no privileged-mover-vs-PSS
  problem and no shared-repo pruning question, because the snapshots already exist
  on the host and restic just reads them. `backups.md` needs revising to match.
- **Immich's photos live on drone-04's NAS** (`/media/immich`, PV `immich-nas`,
  done 2026-11-19): 318 GiB of write-once photos, growing, next to the media they
  resemble rather than tripled onto consumer SATA SSDs. `backups.md` excludes
  `/media` as "re-downloadable", which is **not true of these** — restic → B2 has
  to cover `/media/immich` explicitly. Immich's 1 GiB postgres stays on drone-01
  in the mesh.
- **Bulk media** (`rust/media`, 9 TB) is replaceable and stays out of both the mesh
  and restic.

## Capacity

Measured 2026-11-19, after the immich photos moved off the pool:

| | |
| --- | --- |
| `zfs-generic-nvmeof-csi` PVCs | 42; 4 volumes now on `zfs-local` (golink, gatus, rakazo database + web-assets) |
| Live data on them | 43 GiB — the rest of `rust/k8s/volumes` (85 GiB) is snapshot history |
| Largest | prometheus 28.2 incl. 28 GiB of snapshots · jellyfin 17.0 · pokesim 13.3 incl. snapshots · romm-resources 12.9 · omada 9.2 volume / 1.5 live |
| Snapshot overhead | 127 GiB total; `romm-redis` 62 GiB on a 5 GiB volume |
| Pool per node | 600 GiB; the mesh set is ~43 GiB of data |
| Headroom | immich's postgres (1 GiB) joins drone-01; the photo library never joins the mesh |

## Migration order

1. **Pools.** `docs/drone-03-rebuild.md` for drone-03, then drone-01/02 as they are
   built. Nothing else can start until three pools exist.
2. **Immich photos → NFS.** Done 2026-11-19 (Status above). It needed no CSI, no
   pin and no zrepl, so it went first: the largest volume is off the pool and the
   mesh only ever has to seed the small stuff.
3. **CSI canary — done 2026-11-20.** `infrastructure/openebs-zfs`, node labels,
   `zfs-local`, `VolumeSnapshotClass`, smoke test, then `golink` as the first real
   volume. `gatus` and `rakazo` remain, one at a time.
4. **The mesh — done 2026-11-20.** zrepl in the image and rendered by
   `node_zfs`, `zrepl status` clean, every `k8s/volumes/*` present on both peers,
   `zrepl prometheus` scraped with lag/error alerts (see Status).
5. **drone-02's stack**, then **drone-01's media** — one node at a time, one short
   outage each, including immich's postgres to `zfs-local` on drone-01.
6. **Teardown** only after a week of green.

## Cleanup found while planning

**Done 2026-11-19**, so that a "longhorn", "mayastor" or "openebs" hit always means
something live:

- **Nine `Released` PVs** from the retired Mayastor install (`mayastor-etcd-localpv`
  ×6, `openebs-minio-localpv` ×3), 275–405 days old, bound to claims in a
  namespace that no longer exists. **Deleted**, along with the
  `/var/local/openebs/` trees on drone-04 and unimatrix-01/02/03 (drone-02/03 had
  none left after their rebuilds).
- **Stale `openebs.io/*` labels** (five keys) **stripped** from drone-04 and
  unimatrix-01/02/03; no node carries an `openebs.io` key now.
- **`rust/longhorn`** (158 GiB of orphaned Longhorn backupstore) and `rust/test`
  **destroyed**; the NFS export line went with them. Note the gotcha: Cockpit runs
  with `-v /:/host`, so its mount namespace pinned both datasets. Restarting
  `cockpit.service` was the step that made the destroy possible.
- **Eight empty namespaces deleted**: `collabora`, `freepbx`, `ingress-nginx`
  (had two admission secrets), `neko`, `paperless-ngx` (had a hand-made TLS secret,
  backed up outside the repo before deletion), `vikunja`, `wireguard`,
  `generic-device-plugin`.
- **`minecraft/app-deployment`** — the pre-`namePrefix` leftover holding PVC `data`
  (116 MB zvol) — **deleted** with its PVC, zvol and PV. The live server
  (`minecraft-app-deployment` on `minecraft-data`) was untouched.
- **`romm-redis` removed from ZFS entirely.** Its 42 sanoid snapshots were pruned
  (54.9 GiB freed), then the cache became an `emptyDir` (commit `c733ae8e`):
  `/redis-data` held one 209 MB `dump.rdb` and a stale temp file in 5 GiB, no
  redis-server of its own, and the ext4/zvol mismatch meant ZFS referenced 4.2 GiB
  of already-freed blocks. The PVC, PV and zvol are gone. `sanoid.conf` keeps
  `[template_nosnap]` for the next churny volume.

Still open:

- **`qbittorrent`** is at 0 replicas with two PVCs (10 Gi + 1 Gi); confirm before
  moving them, or drop the app.
- **`immich-machine-learning-cache`** is regenerable. Replicating it is 1.8 GB of
  pointless traffic. With OpenEBS a second StorageClass on `poolname: k8s/scratch`
  would be trivial, but zrepl's `source` glob would still have to exclude it — an
  `emptyDir` is the simpler answer if it ever matters. `prometheus` (28 GiB of
  snapshots on 2.2 GiB of data) deserves the same `template_nosnap` treatment if
  its TSDB history is not wanted.
- `apps/template` **stays**: it is a deliberately live template Application, not a
  leftover. Don't "clean it up".

## Teardown after the last app moves

- `infrastructure/democratic-csi` (the nvmeof app and its sealed driver config) and
  the `zfs-generic-nvmeof-csi` StorageClass. `infrastructure/openebs-zfs` stays.
- **sanoid** drops to drone-04 only (`rust/media`); the `[rust/k8s/volumes]` stanza
  goes.
- `bootc/overlay/etc/systemd/system/nvmet.service.d/*`,
  `usr/libexec/nvmet-detach-local`, `modules-load.d/nvmeof.conf`,
  `/etc/nvmet/config.json`, the `param_mdts` workaround notes.
- The `dedicated=storage:NoSchedule` taint, its six tolerations, and
  `k3s_node_taints` in `host_vars/drone-04.yml` (keep the node, lose the taint; it
  still hosts the drives and NFS).
- `ansible/reboot-drone-04.yml`, `node_reboot_refuse_hosts`, and the "never reboot
  drone-04" rules in `ansible/justfile` and `AGENTS.md`.
- `.claude/skills/democratic-csi/SKILL.md` — most of its gotchas become history.
- `docs/democratic-csi-rust-to-tank-migration.md` (superseded) and the
  NVMe-oF material in `docs/longhorn-to-democratic-csi.md` (keep as history).
- Sanity: `grep -rn "nvmeof\|nvmet" apps platform infrastructure bootc` should only
  match drone-04's own notes.

## Decisions and open questions

Decided:

- Per-node `zfs-local` pools, not a `tank` pool on drone-04, and not a distributed
  filesystem.
- **CSI: OpenEBS LocalPV-ZFS** (`zfs.csi.openebs.io`), ext4 on 16 KiB zvols under
  `k8s/volumes`. **Confirmed by the canary 2026-11-20** — the democratic-csi
  `zfs-local-zvol` fallback is not needed, so `spec.csi.driver` is settled.
- **Replication: zrepl**, `source` + two `pull` jobs per node, 15-minute interval.
  Fallback: sanoid + syncoid fan-out.
- Full mesh, single-writer fan-out, `zfs rename` promotion.
- Downtime accepted for node maintenance; no failover automation.
- **`immich-data` on drone-04's NFS share** (`/media/immich`, static PV
  `immich-nas`, the romm pattern — a subdirectory of the existing `/media` export
  rather than a new dataset and export). Everything else in the mesh.
- 600 GiB pool / ~330 GiB root per node (see the rebuild doc).
- democratic-csi is retired entirely once the last volume has moved.
- `apps/template` is a **live template**, deployed on purpose — not cleanup.

Open, deliberately deferred:

- **Churny volumes**: a `k8s/scratch` StorageClass versus excluding them from
  zrepl's `source` glob (see the snapshot-history note under the mesh).
- Converting the hostNetwork apps to ClusterIP + Ingress so they can move again.
- Whether `prometheus` should keep a PVC or move to a static local PV per node.
- Whether the `browser` app (unpinned today) should join the platform group
  explicitly or keep floating.
