# Rebuild drone-03 with a ZFS pool on the boot NVMe

Status: **prerequisites landed (2026-11-19).** The six changes below are in git;
the rebuild window has not run yet. This is the first of the three app nodes to
get a node-local `k8s` pool, and therefore the rehearsal for drone-01 and
drone-02.

## Context

The planned storage change replaces democratic-csi's NVMe-oF zvols on drone-04
with a ZFS pool on each of the three app nodes, replicated between them
(`k8s/volumes` is what a node sends, `k8s/replicas` is what it receives). That
needs a pool per node, and there is no budget for new drives.

Each EliteDesk 705 G4 DM has a single 1 TB NVMe with Fedora CoreOS on it. Today
that disk is one XFS root partition filling the whole device, and **XFS cannot be
shrunk** — so the space has to be reserved at install time. drone-03 was installed
with the whole-disk flow (`docs/drone-haswell-to-elitedesk-swap.md`), which is why
it needs a rebuild and drone-01/02 (still Haswell, still pending) do not.

Three facts make this cheap:

- **ZFS is already in the image.** The base is `ghcr.io/ublue-os/ucore:stable-nvidia-lts`,
  which ships the ZFS kmod matched to its own kernel. No akmods, no derived
  image, no runtime `dnf install`. drone-04 has been running ZFS from this image
  since 2026-10-03.
- **No app data lives on the node.** All 48 zvols are on drone-04, exported over
  NVMe-oF, so wiping drone-03 loses nothing. Pods reschedule; the storage stays
  where it is.
- **`stable-nvidia-lts` is the LTS kernel flavour**, i.e. the mitigation for the
  OpenZFS-lags-Fedora-kernel problem. See [Kernel/ZFS skew](#6-kernelzfs-skew).

## Target layout

```
/dev/nvme0n1   1 TB (931 GiB)
  p1      BIOS boot     1 MiB     coreos-installer
  p2      ESP           127 MiB   coreos-installer
  p3      /boot         384 MiB   coreos-installer
  p4      /  (XFS)     ~330 GiB   coreos-installer, from the free gap
  p5      ZFS `k8s`     600 GiB   ours, GPT partition label `zfs`
```

`sgdisk` takes the lowest free space, so p5 physically lands immediately after
p3 and the root gap ends up after it; the numbers and the address order may not
match after the installer runs. That is harmless — Phase 3 resolves the pool by
partition label, never by number.

Sizes:

| | |
| --- | --- |
| App state, excluding immich | 47.4 GB across 47 volumes (48 PVCs incl. `immich-data`) |
| Live + replicas per node in the mesh | ~45 GB |
| With sanoid history (20 % margin) | ~54 GB → **8 % of 600 GiB** |
| If immich joins the mesh later | ~380 GB → 59 % |
| OS footprint measured | 50 GB (drone-03, all pods) / 180 GB worst case (drone-01) |

330 GiB of root is deliberate headroom for container images; drone-02's 59 GB
disk is currently in kubelet image-GC thrash, and that is the failure mode to
avoid. 600 GiB for the pool keeps immich in the mesh a live option.

**The pool holds only zvols**, so it needs no mountpoint at all — see
[Pool creation](#phase-4--rejoin-label-and-create-the-pool). Nothing is mounted
at `/` level and `/etc` is untouched, which is what keeps this on the supported
path for a bootc image (the image's own content cannot be split across
filesystems).

## Changes to land before the window

Six changes, ✅ **all landed 2026-11-19**. Everything here is reusable for
drone-01/02, so it was worth doing properly rather than by hand on the night.

### 1. `bootc/justfile` — an optional installer config

✅ **Landed.** The validated flow is a stock FCOS live ISO with `coreos-installer
iso customize` and an embedded install command. The lever for keeping a partition
is `--save-partlabel`, which `iso customize` reaches through
`--installer-config` (confirmed on `coreos-installer 0.27.0`: `iso customize` has
`--installer-config`, and `install` has `--save-partlabel`/`--save-partindex`).

`build-iso` now takes an optional third argument, and with it omitted the recipe
behaves exactly as before:

```sh
just gen-installer-config drone-03 zfs                  # → dist/drone-03-install.yaml
just build-iso drone-03 /dev/nvme0n1 drone-03-install.yaml
```

Both paths were built and inspected on 2026-11-19. The resulting ISO carries two
config files, and **the split between them matters**:

```
/etc/coreos/installer.d/0000-drone-03-install.yaml   # ours
save-partlabel:
  - zfs

/etc/coreos/installer.d/0001-customize.yaml          # from iso customize
ignition-file: /etc/coreos/dest.ign
dest-device: /dev/nvme0n1
```

⚠️ **`dest-device` must appear in exactly one of them.** `coreos-installer-service`
passes *every* file in `installer.d/` as its own `--config-file`, and each one
that names `dest-device` contributes the positional device argument. Two of them
produce two positionals and the install dies **before touching the disk**:

```
Running with arguments: --save-partlabel zfs /dev/nvme0n1 --ignition-file … /dev/nvme0n1
error: unexpected argument '/dev/nvme0n1' found
```

This is exactly what the first real attempt did on 2026-11-19, because
`gen-installer-config` originally emitted `dest-device` too. It now emits only
`save-partlabel`; the device stays with `iso customize --dest-device`, which is
also what makes the install unattended. Reproduced and fixed against the same
`coreos-installer 0.27.0` binary the live environment runs:

```
# good: one positional
--save-partlabel zfs --ignition-file /etc/coreos/dest.ign /dev/nvme0n1 --fetch-retries infinite
```

A failed install like this is harmless to the disk — the argument parsing aborts
before any write, so the partition plan survives and a retry is just a reflash.

`save-partlabel` matches the **GPT partition label, not a filesystem label**
(`coreos-installer` man page), so `sgdisk -c 5:zfs` is what makes this work. Do
not `mkfs` the partition.

### 2. `ansible/inventory/host_vars/drone-03.yml`

✅ **Landed.** Role vars are prefixed per `ansible-lint` (`var-naming`), so the
keys are `node_zfs_*`, not the `zfs_pool_*` this doc originally proposed:

```yaml
---
k3s_role: agent
k3s_hostname: drone-03
k3s_server: 192.168.42.1

tuned_profile: k8s-node

# Node-local ZFS pool for the zfs-local CSI class; the vdev is a GPT partition,
# so resolve it by label, never by number (coreos-installer renumbers saved
# partitions if it has to).
node_zfs_pool_name: k8s
node_zfs_pool_device: /dev/disk/by-partlabel/zfs

k3s_node_labels:
  - media/gpu=amd-vega
```

The same two `node_zfs_pool_*` keys go into drone-01/02 when they are rebuilt.

### 3. `ansible/roles/node_zfs` + a provision play

✅ **Landed** (`ansible/roles/node_zfs`, play `tags: node_zfs`). It is idempotent,
because it re-runs after every rebuild and on all three nodes. Shape and
invariants, rather than a second copy of the file:

- load `zfs` with plain `modprobe` (a two-task check-then-load, so no
  `community.general.modprobe` dependency), then `zgenhostid` if `/etc/hostid` is
  missing — every node has a pool with the same name, so duplicate hostids are a
  real hazard;
- pool `k8s` on `/dev/disk/by-partlabel/zfs`, `mountpoint: none` **on the pool and
  on both datasets**, `ashift=12`, `autotrim=on`, `lz4`, `atime=off`, `xattr=sa`;
- datasets `volumes` (what this node serves) and `replicas` (what it receives);
- `zpool status -x` as the health gate, so a degraded pool fails the play.

**Not** in this role: the ARC cap — see [5](#5-arc-sizing--do-not-let-the-images-8-gib-follow-you).

The play is hooked into `ansible/provision.yml` next to the existing `zfs` play:

```yaml
- name: Setup node-local ZFS pools
  remote_user: core
  tags: node_zfs
  hosts: storage_nodes
  become: true
  roles: [node_zfs]
```

`storage_nodes` currently contains **drone-03 only**. drone-01/02 lack the
partition until they are rebuilt, and the role fails closed when
`/dev/disk/by-partlabel/zfs` is absent — listing them early would break every
plain `provision.yml` run. Each host is added in the commit that rebuilds it.

⚠️ Note for the window: the role does **not** load the ZFS module unless the play
runs. Because `provision.yml --limit drone-03 --tags base,k3s` skips it (Phase 4
runs it separately), the pool is created only by the `node_zfs` run.

### 4. `k3s_node_labels`

✅ **Landed.** `media/gpu=amd-vega` used to be applied by hand and
[documented as a manual step](drone-haswell-to-elitedesk-swap.md) after every
rebuild. It is now a host var, mirroring `k3s_node_taints`:

```yaml
# ansible/roles/k3s/defaults/main.yml
k3s_node_labels: [] # only applied at node registration; also `kubectl label` live
```

```jinja
{# ansible/roles/k3s/templates/agent.yaml.j2 #}
{% if k3s_node_labels %}
node-label:
{% for label in k3s_node_labels %}
  - {{ label }}
{% endfor %}
{% endif %}
```

That removes a failure mode that has already cost time once ("Jellyfin sits
Pending with an unschedulable warning — nothing in Argo will complain").

Verified in check mode: the rendered `/etc/rancher/k3s/config.yaml` for drone-03
gains exactly `node-label: - media/gpu=amd-vega`, and drone-04's config is
unchanged (no spurious restart on nodes that have no labels).

### 5. ARC sizing — do not let the image's 8 GiB follow you

⚠️ **Changed from the original plan.** `bootc/overlay/etc/modprobe.d/zfs.conf`
used to set `zfs_arc_max=8589934592` (8 GiB), sized for drone-04, which is tainted
`dedicated=storage` and runs nothing but ZFS. Letting that follow onto
drone-01/02/03 — ~21 GiB nodes that also run a dozen pods — is how you get an
unexplained OOM a week later.

Rather than override it on three nodes, the default was **flipped**: the image now
ships **2 GiB**, which is what the three app nodes want, and drone-04 is the one
node that overrides it back up:

```ini
# bootc/overlay/etc/modprobe.d/zfs.conf
options zfs zfs_arc_max=2147483648
```

```yaml
# ansible/roles/nas_zfs — drone-04 only, which is why it lives here and not in
# node_zfs. A later-sorting filename wins over the image's zfs.conf on merge.
- name: Cap the ZFS ARC for this storage node
  ansible.builtin.copy:
    content: |
      options zfs zfs_arc_max={{ nas_zfs_arc_max_bytes }}
    dest: /etc/modprobe.d/99-zfs-arc.conf
    mode: '0644'
```

…with `nas_zfs_arc_max_bytes: 8589934592` in
`ansible/inventory/host_vars/drone-04.yml`. A second task writes the value live,
guarded so it only reports changed when the value actually differs.

⚠️ **Ordering:** this must land on drone-04 *before* drone-04 boots a node image
carrying the 2 GiB default, or its ARC silently drops to 2 GiB on that boot. The
`99-` file then keeps winning through the `/etc` 3-way merge.

Verify with `cat /sys/module/zfs/parameters/zfs_arc_max` after the play.

✅ **Landed 2026-11-19**, image default and drone-04 variables both. drone-04 must
read `8589934592`; a rebuilt app node must read `2147483648`.

### 6. Kernel/ZFS skew

A uCore kernel bump that moves ahead of the ZFS kmod now breaks **the app tier on
three nodes**, not just drone-04. Two existing behaviours cover most of it:

- `provision.yml` sets `rpm-ostreed` to `AutomaticUpdatePolicy=stage`, so a new
  deployment (and kernel) waits for a reboot. **Before rebooting any storage
  node, check `bootc status` for a staged deployment** and treat it as part of the
  window.
- Pin the base image by digest in `bootc/Containerfile` so a kernel move is a
  reviewable commit rather than tag drift. Renovate already opens those PRs.
  ✅ **Landed 2026-11-19** as `stable-nvidia-lts@sha256:59d41bc9…` (index digest
  for `44.20261023.3.1`, the version every node already runs).

## Pre-flight

- [ ] `just check-kustomize` clean; nothing uncommitted in the working tree.
- [ ] All Argo applications `Synced`/`Healthy` (`prune: false` means nothing is
      deleted by the rebuild, but a dirty tree makes the diff unreadable).
- [ ] `kubectl get pods -A --field-selector status.phase=Unknown` is empty. Note
      that this field selector does not match every stale pod — filter the list.
- [ ] **Decide about Jellyfin.** drone-03 is the only `media/gpu=amd-vega` node, so
      Jellyfin is Pending for the whole window. ✅ **Decided 2026-11-19: accept the
      outage** and run the window at a quiet hour — no temporary P620 revert, so
      there is no second Jellyfin move to undo and no HDR path to re-validate. The
      P620 fallback only exists until drone-01 is replaced anyway.
- [ ] `healthchecks-cronjob-drone-03` will fail during the window. Expected;
      do not "fix" it.
- [ ] ISO artifacts built and inspected — ✅ **done 2026-11-19**, already in the
      gitignored `bootc/dist/`:
      `drone-03.ign`, `drone-03-install.yaml`, `drone-03.iso` (979 MB, built from
      the GPG-verified `44.20261023.3.1` live ISO, carrying
      `installer.d/0000-drone-03-install.yaml`). The ISO is bare FCOS + ignition
      only, so a new `k8s-node` image does **not** invalidate it — that arrives by
      `bootc switch` in Phase 4. Rebuild only if the ignition, hostname or
      interface changes.

## Phase 1 — Retire the node

Straight from the swap doc's Step 3, which is already correct:

```sh
kubectl drain drone-03 --delete-emptydir-data --ignore-daemonsets
ssh core@drone-03 sudo systemctl stop k3s-agent      # before deleting, or it re-registers
kubectl delete node drone-03                          # scrubs the old hardware labels
ssh core@192.168.42.23 sudo tailscale logout          # frees the MagicDNS name
```

Gate: all pods Ready elsewhere and **zero `VolumeAttachment`s naming drone-03**.
A stale attachment blocks reattach after the reinstall and the pod sits in
`ContainerCreating`, which looks like a storage bug and is not one.

```sh
kubectl get volumeattachment -o wide | grep -c drone-03    # expect 0
```

Then power the chassis down and keep the NVMe — it is the rollback.

## Phase 2 — Partition and install

Boot the bench ISO (`just bench-iso`, `192.168.42.90`) — not the installer ISO.
Read-only, and it is where you confirm the two things that must not be guessed:

```sh
lsblk -dno NAME,MODEL,SIZE        # expect nvme0n1, one disk, 1 TB
ip -br link                       # expect eno1 on this model, but confirm
sudo sgdisk -p /dev/nvme0n1       # expect p1..p3 and p4 filling the rest
```

Reclaim the tail of the disk for the pool. p4 is deleted because the whole
partition is about to be recreated by the installer anyway:

```sh
sudo sgdisk -d 4 /dev/nvme0n1
sudo sgdisk -n 5:0:+600G -t 5:bf01 -c 5:zfs /dev/nvme0n1

# p5 begins exactly where p4 began, so the OLD root XFS superblock now sits at
# the start of the new partition. Not formatting p5 is right; leaving a stale
# filesystem signature on it is not — it reads back as LABEL="root" TYPE="xfs",
# fails Phase 3's "no TYPE=" check, and leaves a second filesystem claiming the
# label `root`.
sudo wipefs -a /dev/nvme0n1p5

sudo udevadm settle
sudo sgdisk -p /dev/nvme0n1        # p5 present, 600 GiB, name zfs
sudo sgdisk -i 5 /dev/nvme0n1      # code 6A898CC3… = Solaris /usr & Mac ZFS
sudo blkid -t PARTLABEL=zfs        # PARTLABEL/PARTUUID only — no TYPE=
```

Three corrections from the drone-03 run (2026-11-19):

- **`-t 5:bf01`, not `bf00`.** `bf00` is *Solaris root*; the ZFS GUID is
  `6A898CC3-1DD2-11B2-99A6-080020736631` = **`bf01` Solaris /usr & Mac ZFS**.
  Cosmetic — the pool resolves by `PARTLABEL` — but it is what a human reads.
- **`wipefs` is required, and it is not formatting.** It erases the 4-byte XFS
  magic at offset 0 of p5 and nothing else.
- **`partprobe` is not in the live image** (`command not found`). `sgdisk`
  already triggers the re-read; `udevadm settle` is enough.

`sgdisk` allocates from the lowest free sector, so p5 lands immediately after the
FCOS partitions and the ~330 GiB free gap ends up after it — which is where the
installer expects to build the root. Measured after this step: 694183311 sectors
(**331.0 GiB**) free.

Power off, plug in the installer ISO built in the pre-flight, and boot it. The
embedded install runs unattended. **Pull the USB stick when it reboots** (or put
the internal NVMe first in `BootOrder` and use F9), or it reinstalls in a loop.

## Phase 3 — Verify the layout (hard gate)

Boot the installed system and check before reconnecting anything:

```sh
sudo sgdisk -p /dev/nvme0n1
#  p5 exists, ~600 GiB, name zfs, code BF01
#  root is the OTHER big partition, ~330 GiB — and its NUMBER is not necessarily
#  4: the installer may reuse the freed slot 4 or take the next free number.
#  Check it by label and size, never by number. If root grew to fill the disk,
#  the preserve failed.

lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINT
df -h /var          # ~330 GiB total, not the full disk
sudo blkid -t PARTLABEL=zfs     # should print the partition and NO TYPE= line
```

If p5 is missing or root filled the disk, the install did not preserve the
partition. Nothing has been lost — the node is already drained — so wipe and
retry, and this time compare against [Fallbacks](#fallbacks).

**This is the point of doing drone-03 first.** A retry here costs 20 minutes; the
same mistake on drone-01 means doing the whole swap twice.

## Phase 4 — Rejoin, label, and create the pool

```sh
# base + k3s only: the tailscale role runs `tailscale up`, which blocks on an
# auth URL on a fresh node. Join the tailnet by hand afterwards.
just playbook provision.yml --limit drone-03 --tags base,k3s

ssh core@192.168.42.23 sudo tailscale up --accept-dns=false --ssh
# open the printed URL, or pass --authkey=... from the admin console
```

The `media/gpu=amd-vega` label arrives with the k3s role (change 4). Now the pool:

```sh
just playbook provision.yml --limit drone-03 --tags node_zfs
```

Expect:

```sh
zpool status -x k8s      # "pool 'k8s' is healthy"
zfs list -r k8s          # k8s, k8s/volumes, k8s/replicas, all mountpoint=none
zfs get -H -o value ashift,compression,atime k8s
cat /sys/module/zfs/parameters/zfs_arc_max    # 2147483648 — the image default
```

`zpool create` is deliberately **not** run from the live ISO. `zpool.cache` and
`/etc/hostid` have to land in the *installed* system's `/etc`, which is not
coherent until it has booted.

Finally: `kubectl get node drone-03 --show-labels` shows `media/gpu=amd-vega`,
and Jellyfin schedules back onto the Vega.

## Phase 5 — Prove the pool

Exercise the exact primitives the mesh will use, before any application depends
on them:

```sh
sudo zfs create -V 1G k8s/volumes/probe
sudo mkfs.ext4 -q /dev/zvol/k8s/volumes/probe
sudo mkdir -p /mnt/probe
sudo mount /dev/zvol/k8s/volumes/probe /mnt/probe
sudo dd if=/dev/urandom of=/mnt/probe/blob bs=1M count=64 status=none
SUM=$(sudo md5sum /mnt/probe/blob | cut -d' ' -f1)
sudo umount /mnt/probe

# the primitive the mesh depends on: snapshot, send, receive under the replica tree
sudo zfs snapshot k8s/volumes/probe@proof
sudo zfs send k8s/volumes/probe@proof | sudo zfs recv k8s/replicas/probe

# mount the received copy read-only and compare, without mounting the same
# filesystem twice by UUID
sudo mount -o ro,noload /dev/zvol/k8s/replicas/probe /mnt/probe
[ "$SUM" = "$(sudo md5sum /mnt/probe/blob | cut -d' ' -f1)" ] && echo SEND-RECV OK
sudo umount /mnt/probe

sudo zfs destroy -r k8s/replicas/probe
sudo zfs destroy -r k8s/volumes/probe
sudo zfs list -r k8s
```

A reboot with the pool in place is worth doing once here too: `zpool status`
afterwards proves import-at-boot works on this image, which matters more than it
does on drone-04 (that pool has been up for months).

**Stop there.** Do not install the `zfs-local` CSI driver or move applications in
this window. The rebuild and the storage migration are two separately verifiable
changes, and mixing them makes a failure ambiguous.

## Rollback

- Up to Phase 2: the node is drained, so nothing is broken; reboot the old disk
  and uncordon.
- Phase 2/3 failure: reinstall with the plain whole-disk flow
  (`just build-iso drone-03 /dev/nvme0n1`) and the node returns exactly as it is
  today. If a local pool is still wanted in the interim, a fully-allocated
  file-backed vdev works (`fallocate`, never `truncate -s`) and can later be
  promoted with `zpool replace k8s /var/lib/zfs/k8s.img /dev/disk/by-partlabel/zfs`.
- Keep the pulled NVMe until the node has run a week.

## Fallbacks

If `--save-partlabel` does not preserve the partition on this coreos-installer
version:

1. `--save-partindex 5` instead of the label (needs the number to survive; it may
   not).
2. Hand-partition the whole disk and install with `bootc install to-filesystem`
   onto a pre-made root, leaving p5 untouched. This is the documented,
   maximum-control path, but it is a *different install mechanism* from the one
   this repo has validated three times, and it needs podman plus
   `--boot-mount-spec` in the live environment. Treat it as the fallback, not the
   default.
3. File-backed vdev now, real partition at the next rebuild.

## Risks

| Risk | Mitigation |
| --- | --- |
| `save-partlabel` does not preserve p5 | Phase 3 is a hard gate; a retry on a drained node is 20 minutes |
| Root ends up too small for image pulls | 330 GiB vs a 180 GB worst case; `df -h /var` in Phase 3 |
| Installer boot loop from the USB | Internal NVMe first in `BootOrder`, F9 for the stick |
| Wrong NIC name → node comes up unreachable | Confirm `eno1` with `ip -br link` on the bench ISO before building the ISO |
| Stale `VolumeAttachment` blocks reattach | The zero-attachments gate at the end of Phase 1 |
| Jellyfin down for the window | Quiet hour, or the drone-01 P620 fallback (last one) |
| `media/gpu` label forgotten | Moved into `k3s_node_labels` (change 4) |
| Kernel/ZFS skew breaks the app tier after the fact | `bootc status` gate before reboots, base image pinned by digest |
| An 8 GiB ARC starves an app node | Image default is now 2 GiB (change 5); verify `zfs_arc_max` = `2147483648` after the play |
| Partition vdev cannot be grown by swapping a bigger disk | Size decided now (600 GiB); growth needs `attach`/`detach` |

## Out of scope

- The `zfs-local` CSI driver, the three `storage-home-*` components, and any
  application migration.
- `syncoid` fan-out and the replication lag alert.
- drone-04's retirement as a storage node (it keeps the pool, NFS and the drives).
- Converting the hostNetwork applications to ClusterIP + Ingress.

## Follow-on

1. **drone-01 and drone-02** reuse this with only `hostname`/`ip`/`iface`/disk
   changing. Both are still Haswell, so this gets folded into
   `docs/drone-haswell-to-elitedesk-swap.md` rather than being a separate rebuild.
2. When all three pools exist: `infrastructure/openebs-zfs` (OpenEBS LocalPV-ZFS,
   `zfs-local` StorageClass), zrepl for replication, the per-node
   `components/storage-home-*` components, and the app moves — see
   [`storage-placement.md`](storage-placement.md) for the placement, the mesh, and
   the promote runbook.
3. Then the teardown: `zfs-generic-nvmeof-csi`, the nvmet driver deployment and
   sealed config, `bootc/overlay/etc/systemd/system/nvmet.service.d/*`,
   `usr/libexec/nvmet-detach-local`, `modules-load.d/nvmeof.conf`, the
   `dedicated=storage` taint and its six tolerations, and
   `ansible/reboot-drone-04.yml`.
