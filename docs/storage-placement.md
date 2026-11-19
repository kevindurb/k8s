# Storage: node-local ZFS with a replicated mesh

Status: **planned (2026-11-18).** Not started, but its prerequisite is met: all
three app nodes were rebuilt on 2026-11-19 and each carries a healthy 600 GiB
`k8s` pool ([`drone-03-rebuild.md`](drone-03-rebuild.md)). Step 2 of the migration
order (the CSI canary) is therefore unblocked.

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

| App | Local volumes (declared / used) |
| --- | --- |
| immich-server | `immich-data` → **NFS, see below** |
| immich-postgres | 20Gi / 1.0 GiB |
| immich-machine-learning | 10Gi / 1.8 GiB (regenerable cache) |
| jellyfin | 50Gi / 15.0 GiB + `jellyfin-nas-media` |
| audiobookshelf | config 1Gi, metadata 1Gi, books 10Gi / 1.4, audiobooks 10Gi / 1.8, podcasts 11Gi / 1.2 |
| romm | resources 20Gi / 13.7, assets 10Gi, config 1Gi, launchbox 10Gi + `romm-library` |
| romm-mariadb | 5Gi / 0.43 |
| romm-redis | 5Gi / 0.22 |
| navidrome | 5Gi / 0.38 + `navidrome-nas-media` |
| calibre / calibre-web | 1Gi each / 0.02 & 0 + `*-nas-media` |
| kiwix, dufs | NAS only |
| pocket-id | 1Gi / 0.006 |

≈ **37 GB** live. Pinned with `storage-home-drone-01`; `jellyfin` also keeps its
`media/gpu=amd-vega` capability label.

### drone-02 — home / IoT

| App | Local volumes (declared / used) |
| --- | --- |
| zigbee2mqtt | 1Gi / 0.03 — **USB dongle is physically here** |
| mosquitto | 1Gi / ~0 |
| home-assistant | 40Gi / 0.69 — hostNetwork |
| omada | 10Gi / 0.66 — hostNetwork |
| syncthing | 100Gi / 0.80 + `syncthing-nas-media` — hostNetwork |
| scrypted | 10Gi / 0.10 — hostNetwork |
| donetick | 5Gi / 0 |
| mealie | 10Gi / 0.03 |

≈ **2.3 GB**. Sparse on purpose: the node is defined by the dongle, and everything
else here is one functional group.

### drone-03 — platform + background

| App | Local volumes (declared / used) |
| --- | --- |
| prometheus | 35Gi / 1.7 |
| alertmanager / gatus | 1G each / ~0 |
| rakazo (api, worker, web, postgres) | data 30Gi / 0.01, database 20Gi / 0.09, web-assets 2Gi / 0.05 |
| browser | 5Gi / 0.48 |
| radarr / sonarr | 10G each / 0.80 & 0.24 + `*-nas-media` |
| qbittorrent | config 10Gi, ts-state 1Gi + `qbittorrent-nas-media` |
| f1timing / pokesim | 30Gi / 3.2, 10Gi / 0.68 |
| minecraft | 10Gi / 0.42 |
| semaphore, tsgit ×2, linkding, golink, consignment-app | <0.15 total |

≈ **7.8 GB**. `rakazo` is already pinned to `drone-03` in git
(`apps/rakazo/{workloads,bootstrap,migrate}.yml`), which makes it the natural first
canary: pinned, small, and a database to prove real recovery.

### Not pinned at all

`drone-04`: `makemkv`, `transcoding`, the per-node `healthchecks` CronJobs,
`zfs-exporter`. Cluster infrastructure stays free to float: argocd, coredns,
metallb, gpu-operator, node-exporter, tailscale, and the CSI node DaemonSet.

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
- **Node labels.** `kubectl label node <n> openebs.io/nodeid=<n>` on all three.
  OpenEBS uses that identity for its documented PV-migration procedure, which is
  the supported alternative to hand-writing a PV during a promotion.
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
(`k8s/replicas/drone-02/pvc-x`). `pull` receives to `$root_fs/$source_path` — exactly
`k8s/replicas/pvc-x`, a flat tree where a volume has one obvious path on every node.

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
| Live state, excluding `immich-data` | 47.4 GB | 8 % |
| Each node in the mesh holds | ~47 GB live + both peers' replicas = **the whole set** | 8 % |
| Plus received snapshot history | small (bounded by the `keep_receiver` grid) | — |

Seeding is the only expensive moment: ~47 GB per peering, six peerings, sequential
because they share one 1 GbE — well under an hour.

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

**Tier 2 — small volumes (everything else here).** Two pods and a scratch path:

1. scale the app to 0 (pause its Argo app first, as in the old migration runbook);
2. pod on the **source** node: mount the old PVC, `rsync` to `drone-04:/media/.migrate/<app>`;
3. change the pin in git; the new PVC binds on the target node;
4. pod on the **target** node: `rsync` back into the new PVC;
5. unpause, verify, delete the old PVC (leave the PV `Retain` for a week).

A single Job **cannot** do this in one step: two node-local PVCs have contradictory
node affinities, so a pod mounting both is unschedulable. The old runbook's
"mount old read-only and new, rsync" trick does not carry over.

**Tier 3 — big volumes and node recovery.** The replica is already on the
destination, so promotion costs no copy time:

```bash
# 1. stop the app, then wait one zrepl interval (or `zrepl signal wakeup pull-<peer>`)
#    so the destination's replica is current. This replaces the old "final send".
kubectl -n <ns> scale deploy/<app> --replicas=0

# 2. demote on the old owner: it leaves the source job's glob, so this node stops
#    snapshotting and serving it
ssh old "sudo zfs rename k8s/volumes/<vol> k8s/replicas/<vol>"

# 3. promote on the new owner: it joins the source job's glob
ssh new "sudo zfs rename k8s/replicas/<vol> k8s/volumes/<vol>"
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
- **`immich-data` stays on drone-04** as a static NFS PV (`/media/immich`, the
  `romm-library` pattern) with B2 as its real protection. 335 GB of write-once
  photos belongs next to the media it resembles, not tripled onto consumer SATA
  SSDs; immich's 1 GiB postgres stays on drone-01 in the mesh.
- **Bulk media** (`rust/media`, 9 TB) is replaceable and stays out of both the mesh
  and restic.

## Capacity

| | |
| --- | --- |
| `zfs-generic-nvmeof-csi` PVCs today | 48, 383.0 GB allocated, 47.4 GB excluding `immich-data` |
| Largest non-immich | jellyfin 15.0 · romm-resources 13.7 · audiobookshelf 4.4 · f1timing 3.2 · prometheus 1.7 |
| Pool per node | 600 GiB, 8 % used by the mesh |
| Headroom | `immich-data` could join the mesh later at 59 %; today it does not |

## Migration order

1. **Pools.** `docs/drone-03-rebuild.md` for drone-03, then drone-01/02 as they are
   built. Nothing else can start until three pools exist.
2. **CSI canary.** `infrastructure/openebs-zfs` (zfs-localpv only), the
   `openebs.io/nodeid` labels, the `zfs-local` StorageClass and the
   `VolumeSnapshotClass`. Move `rakazo` (already pinned, has a database), `golink`
   and `gatus`, one at a time. **This is the go/no-go for OpenEBS versus the
   democratic-csi `zfs-local-zvol` fallback** — decide before any further volume
   moves, because `spec.csi.driver` is immutable.
3. **The mesh.** zrepl RPM in the image, config rendered by `node_zfs`, then confirm
   with `zrepl status` that every `k8s/volumes/*` exists on both peers, and wire
   `zrepl prometheus` into the scrape config with a lag alert. Do not migrate
   further until this is green.
4. **drone-02's stack**, then **drone-01's media** — one node at a time, one short
   outage each.
5. **immich last**: move `immich-data` from the zvol to the NFS dataset (a local
   copy on drone-04, minutes), then its postgres to `zfs-local`.
6. **Teardown** only after a week of green.

## Cleanup found while planning

- `minecraft/app-deployment` is at 0 replicas with a 0-byte `data` PVC — a leftover
  from a rename. Delete rather than migrate.
- `qbittorrent` is at 0 replicas with two PVCs; confirm before moving them.
- `immich-machine-learning-cache` is regenerable. Replicating it is 1.8 GB of
  pointless traffic. With OpenEBS a second StorageClass on `poolname: k8s/scratch`
  would be trivial, but zrepl's `source` glob would still have to exclude it — an
  `emptyDir` is the simpler answer if it ever matters.

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
  `k8s/volumes`. Fallback, if the canary fails: democratic-csi `zfs-local-zvol`.
- **Replication: zrepl**, `source` + two `pull` jobs per node, 15-minute interval.
  Fallback: sanoid + syncoid fan-out.
- Full mesh, single-writer fan-out, `zfs rename` promotion.
- Downtime accepted for node maintenance; no failover automation.
- `immich-data` on drone-04's NFS share; everything else in the mesh.
- 600 GiB pool / ~330 GiB root per node (see the rebuild doc).
- democratic-csi is retired entirely once the last volume has moved.

Open, deliberately deferred:

- Converting the hostNetwork apps to ClusterIP + Ingress so they can move again.
- Whether `prometheus` should keep a PVC or move to a static local PV per node.
- Whether the `browser` app (unpinned today) should join the platform group
  explicitly or keep floating.
