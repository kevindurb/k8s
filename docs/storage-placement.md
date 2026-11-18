# Storage: node-local ZFS with a replicated mesh

Status: **planned (2026-11-18).** Not started. Depends on the per-node pools from
[`drone-03-rebuild.md`](drone-03-rebuild.md).

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
three, with pods pinned.** Downtime on node maintenance is accepted. That trade
is what makes the rest of this document simple.

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

Placement assumes the Haswell → EliteDesk swap is finished on all three
(`drone-01`/`drone-02` are still Haswell as of 2026-11-18). Each node: 4 vCPU,
~21 GiB, 1 GbE, one 1 TB NVMe shared by the OS and a 600 GiB `k8s` pool.

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

## The CSI layer

A **second** Argo application, `infrastructure/democratic-csi-local`, on the same
chart but a distinct driver name:

```yaml
csiDriver:
  name: "org.democratic-csi.zfs-local"
storageClasses:
  - name: zfs-local
    fsType: ext4
    reclaimPolicy: Delete
    volumeBindingMode: WaitForFirstConsumer   # mandatory for local volumes
    allowVolumeExpansion: true
driver:
  config:
    driver: zfs-local-zvol
    zfs:
      datasetParentName: k8s/volumes
      zvolCompression: lz4
      zvolBlocksize: 16K
      zvolEnableReservation: false
```

Why this driver rather than `openebs/zfs-localpv`: it reuses the chart,
namespace, sealed-secret workflow and `just reseal` already in
`infrastructure/democratic-csi/`, and it writes the topology `nodeAffinity` onto
the PV for us. OpenEBS LocalPV-ZFS is the fallback if this one disappoints.

Because it touches no nvmet, no SSH and no share config, it runs **alongside**
`zfs-generic-nvmeof-csi` with no interference. That removes the all-or-nothing
cutover that `docs/democratic-csi-rust-to-tank-migration.md` was stuck with: apps
migrate one at a time.

## The mesh

### Pool layout

Each node has the same pool name and the same two datasets:

```
k8s                 mountpoint=none, ashift=12, compression=lz4, atime=off
k8s/volumes         what this node sends
k8s/replicas        what it receives
```

`mountpoint=none` everywhere: these are zvols, nothing is mounted, so no directory
is needed on the read-only root and nothing sits outside `/var`.

### Single-writer fan-out, not mutual sync

For each volume there is **one writer** — the node that hosts the app — and **two
read-only receivers**. Direction is a property of where the volume lives, not of
the link, so there is no bidirectional conflict to resolve.

The send set is derived from the pool, which is the whole reason there is no
config to keep in sync:

```bash
#!/usr/bin/env bash
# /usr/local/bin/syncoid-fanout — every storage node runs this on a timer.
set -euo pipefail
exec 9>/run/syncoid.lock
flock -n 9 || { echo "another syncoid/promote run holds the lock"; exit 0; }

me=$(hostname -s)
peers=$(printf '%s\n' drone-01 drone-02 drone-03 | grep -vx "$me")

for ds in $(zfs list -H -o name -d1 k8s/volumes | grep -v '^k8s/volumes$'); do
  for peer in $peers; do
    syncoid "$ds" "$peer:k8s/replicas/$(basename "$ds")"
  done
done
```

```ini
# /etc/systemd/system/syncoid-fanout.service
[Unit]
Description=Replicate local zvols to the other storage nodes

[Service]
Type=oneshot
ExecStart=/usr/local/bin/syncoid-fanout
```

```ini
# /etc/systemd/system/syncoid-fanout.timer
[Unit]
Description=Replicate local zvols every 15 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=15min
RandomizedDelaySec=120
Persistent=true

[Install]
WantedBy=timers.target
```

A new app needs nothing: its volume appears in `k8s/volumes`, and the next run
ships it to both peers. The first send of a 1 GiB volume takes seconds.

**Prerequisite:** `syncoid` runs as root and assumes root SSH to the peers. Fedora
CoreOS locks the root account, so the `node_zfs` role has to drop
`/root/.ssh/authorized_keys` (same keys as `core`) and leave
`PermitRootLogin prohibit-password` in place. Three LAN machines that already grant
`core` passwordless sudo — but it is a real exception to document, not a detail.

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
| Plus received sanoid history | small (bounded by sanoid's 24h/14d/4w) | — |

Seeding is the only expensive moment: ~47 GB per peering, six peerings, sequential
because they share one 1 GbE — well under an hour.

### Snapshot rules

- **sanoid owns `k8s/volumes` on each node** (hourly/daily/weekly, same template
  as `rust/k8s/volumes`).
- **Never run sanoid on `k8s/replicas`.** If the receiver prunes a snapshot the
  sender still needs as an incremental base, the next run fails with a missing
  source snapshot. syncoid only prunes the `syncoid_*` snapshots it created, so
  sanoid's history on the replica survives — which means the replica doubles as a
  snapshot archive. That is what makes it possible to `zfs clone` an older snapshot
  on a peer when an app corrupts its own volume.
- **Alert on lag, not on failure.** For every peer, the age of the newest snapshot
  in `k8s/replicas/<vol>` older than 2× the interval is the real signal — a silent
  no-op is the failure mode.

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
# on both nodes, under the same lock the timer takes
flock /run/syncoid.lock bash -c '
  # final delta while the old copy is still authoritative
  syncoid k8s/volumes/<vol> new:k8s/replicas/<vol>

  # demote the old owner FIRST: it drops out of the send loop
  ssh old "sudo zfs rename k8s/volumes/<vol> k8s/replicas/<vol>"

  # then promote the new one: it enters the send loop
  ssh new "sudo zfs rename k8s/replicas/<vol> k8s/volumes/<vol>"
'
```

Then a static PV pointing at the new node, and the `nodeSelector` moved in git.
Because a zvol can only be in one tree on one host, there is **no state in which
two nodes both consider a volume theirs** — the stale-sender data-loss case is
structurally impossible instead of a rule to remember. Order matters: demote, then
promote, both under the lock.

A node that is gone for good follows the same script, with the replica already
current to the last timer run; a node that is merely rebooting needs nothing at all
— its pods come back on it.

## Backups and integrity

The mesh is **not** a backup: same rack, same switch, same house, same power.

- **sanoid** on `k8s/volumes` per node is the fast "oops" path and the source of
  the snapshot history the replicas carry.
- **restic → B2** from each node, reading sanoid snapshots directly, replaces the
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

1. **Prove the driver with three apps** once three pools exist: `rakazo` (already
   pinned, has a database), `golink`, `gatus`. `WaitForFirstConsumer`, one app at a
   time, `zfs-local` class, verify with the promote script still unused.
2. **The mesh.** `syncoid-fanout` timers, root SSH keys, the lag alert. Confirm every
   `k8s/volumes/*` has a copy in both peers' `k8s/replicas/` before trusting it.
3. **drone-02's stack**, then **drone-01's media** — one node at a time, one short
   outage each.
4. **immich last**: move `immich-data` from the zvol to the NFS dataset (a local
   copy on drone-04, minutes), then its postgres to `zfs-local`.
5. **Teardown** only after a week of green.

## Cleanup found while planning

- `minecraft/app-deployment` is at 0 replicas with a 0-byte `data` PVC — a leftover
  from a rename. Delete rather than migrate.
- `qbittorrent` is at 0 replicas with two PVCs; confirm before moving them.
- `immich-machine-learning-cache` is regenerable. Replicating it is 1.8 GB of
  pointless traffic; if that ever matters, an `emptyDir` is the answer, not a
  separate StorageClass (a second `datasetParentName` would need a second driver).

## Teardown after the last app moves

- `infrastructure/democratic-csi` (nvmeof app, sealed driver config) and the
  `zfs-generic-nvmeof-csi` StorageClass.
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
- Full mesh, single-writer fan-out, `zfs rename` promotion.
- Downtime accepted for node maintenance; no failover automation.
- `immich-data` on drone-04's NFS share; everything else in the mesh.
- 600 GiB pool / ~330 GiB root per node (see the rebuild doc).

Open, deliberately deferred:

- Converting the hostNetwork apps to ClusterIP + Ingress so they can move again.
- Whether `prometheus` should keep a PVC or move to a static local PV per node.
- Whether the `browser` app (unpinned today) should join the platform group
  explicitly or keep floating.
