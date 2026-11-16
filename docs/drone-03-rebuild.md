# Rebuild drone-03 with a ZFS pool on the boot NVMe

Status: **planned (2026-11-16).** Not started. This is the first of the three app
nodes to get a node-local `k8s` pool, and therefore the rehearsal for drone-01
and drone-02.

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
- **No app data lives on the node.** All 45 PVCs are zvols on drone-04 exported
  over NVMe-oF, so wiping drone-03 loses nothing. Pods reschedule; the storage
  stays where it is.
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
| App state, excluding immich | 44 GB across 45 volumes |
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

Six changes. Everything here is reusable for drone-01/02, so it is worth doing
properly rather than by hand on the night.

### 1. `bootc/justfile` — an optional installer config

The validated flow is a stock FCOS live ISO with `coreos-installer iso customize`
and an embedded install command. The lever for keeping a partition is
`--save-partlabel`, which `iso customize` reaches through `--installer-config`:

```make
# Optional install config (YAML) for the embedded installer, e.g. to preserve a
# partition: build-iso drone-03 /dev/nvme0n1 drone-03-install.yaml
build-iso hostname device installer_config='':
  #! /usr/bin/env bash
  set -euxo pipefail
  ISO=$(ls {{dist}}/fedora-coreos-*.iso | tail -1 | xargs basename)
  rm -f {{dist}}/{{hostname}}.iso

  EXTRA=()
  if [ -n "{{installer_config}}" ]; then
    EXTRA=(--installer-config "/data/{{installer_config}}")
  fi

  podman run --rm --privileged \
  -v {{dist}}:/data \
  {{coreos_installer}} \
  iso customize \
  --dest-device {{device}} \
  --dest-ignition /data/{{hostname}}.ign \
  "${EXTRA[@]}" \
  --output /data/{{hostname}}.iso \
  "/data/$ISO"
```

With no third argument the recipe behaves exactly as it does today, so drone-03's
existing install path is unchanged unless you pass one.

```make
# Installer config that preserves the ZFS partition. Key names are coreos-installer
# long options without the leading "--"; repeatable options are arrays.
gen-installer-config hostname device label:
  #! /usr/bin/env bash
  set -euxo pipefail
  mkdir -p {{dist}}
  printf 'dest-device: %s\nsave-partlabel:\n  - %s\n' "{{device}}" "{{label}}" \
    > {{dist}}/{{hostname}}-install.yaml
  cat {{dist}}/{{hostname}}-install.yaml
```

`save-partlabel` matches the **GPT partition label, not a filesystem label**
(`coreos-installer` man page), so `sgdisk -c 5:zfs` is what makes this work. Do
not `mkfs` the partition.

### 2. `ansible/inventory/host_vars/drone-03.yml`

```yaml
---
k3s_role: agent
k3s_hostname: drone-03
k3s_server: 192.168.42.1

tuned_profile: k8s-node

# Node-local ZFS pool for the zfs-local CSI class; the vdev is a GPT partition,
# so resolve it by label, never by number (coreos-installer renumbers saved
# partitions if it has to).
zfs_pool_name: k8s
zfs_pool_device: /dev/disk/by-partlabel/zfs

k3s_node_labels:
  - media/gpu=amd-vega
```

The same two `zfs_pool_*` keys go into drone-01/02 when they are rebuilt.

### 3. `ansible/roles/node_zfs` + a provision play

A small role alongside `nas_zfs`. It must be idempotent, because it will be
re-run after every rebuild and on all three nodes.

```yaml
# ansible/roles/node_zfs/defaults/main.yml
---
zfs_pool_name: k8s
zfs_pool_device: /dev/disk/by-partlabel/zfs
zfs_datasets:
  - volumes
  - replicas
```

```yaml
# ansible/roles/node_zfs/tasks/main.yml
---
- name: Load the zfs module now
  community.general.modprobe:
    name: zfs
    state: present

# `zpool create` does not load the module itself; failing here is a clear error
# rather than a confusing one from zpool.
- name: Assert the zfs module is loaded
  ansible.builtin.command: grep -qw zfs /proc/modules
  changed_when: false

# Duplicate hostids are how "pool was last accessed by another system" happens.
# Every node has a pool with the same name here, so be explicit about it.
- name: Generate a hostid if this machine has none
  ansible.builtin.command: zgenhostid
  args:
    creates: /etc/hostid

- name: Resolve the pool partition
  ansible.builtin.stat:
    path: "{{ zfs_pool_device }}"
  register: pool_dev
  failed_when: not pool_dev.stat.exists

- name: Create the pool
  community.general.zpool:
    name: "{{ zfs_pool_name }}"
    vdevs: ["{{ zfs_pool_device }}"]
    mountpoint: none          # zvols only: nothing is mounted, nothing to mount
    pool_properties:
      ashift: '12'
      autotrim: 'on'
    extra_zfs_properties:
      compression: lz4
      atime: 'off'
      xattr: sa

- name: Create the volume and replica datasets
  community.general.zfs:
    name: "{{ zfs_pool_name }}/{{ item }}"
    state: present
    extra_zfs_properties:
      mountpoint: none
  loop: "{{ zfs_datasets }}"

- name: Show pool health
  ansible.builtin.command: zpool status -x {{ zfs_pool_name }}
  register: pool_status
  changed_when: false
  failed_when: pool_status.rc != 0
```

Two details worth keeping:

- `mountpoint: none` on the pool **and** on the datasets. A pool created without
  it tries to mount at `/<poolname>`, which cannot be created on the read-only
  root, and any mount outside `/var` is unsupported on a bootc image. A zvol-only
  pool sidesteps the constraint entirely instead of working around it.
- The device is `by-partlabel/zfs`, not `/dev/nvme0n1p5`. coreos-installer
  renumbers saved partitions "if necessary", so the number is not a stable
  identifier. (Note from `nas_zfs`: `community.general.zpool` records the path it
  was given, and has surprised us before on whole-disk vs partition paths — if the
  role reports a permanent change on every run, fall back to the plain device
  node for `vdevs`.)

Hook it into `ansible/provision.yml` next to the existing `zfs` play:

```yaml
- name: Setup node-local ZFS pools
  remote_user: core
  tags: node_zfs
  hosts: storage_nodes          # drone-01, drone-02, drone-03
  become: true
  roles: [node_zfs]
```

…with a `storage_nodes` group in `ansible/inventory/prod.yml`.

### 4. `k3s_node_labels`

`media/gpu=amd-vega` is currently applied by hand and is
[documented as a manual step](drone-haswell-to-elitedesk-swap.md) after
every rebuild. Move it into the role, mirroring `k3s_node_taints`:

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

### 5. ARC sizing — do not let the image's 8 GiB follow you

`bootc/overlay/etc/modprobe.d/zfs.conf` sets `zfs_arc_max=8589934592` (8 GiB).
That was sized for drone-04, which is tainted `dedicated=storage` and runs
nothing but ZFS. **On drone-01/02/03 that same 8 GiB of unreclaimable-ish ARC
would sit on a ~21 GiB node that also runs a dozen pods** — the kind of thing that
shows up a week later as an unexplained OOM.

Make it per-node from the role rather than in the image:

```yaml
# ansible/roles/node_zfs/defaults/main.yml
zfs_arc_max_bytes: 2147483648   # 2 GiB on app nodes; 45 GB of zvols does not need more
```

```yaml
# tasks: a later-sorting file overrides the image's zfs.conf, and set it live
# because the module is already loaded by now.
- name: Cap the ARC for app nodes
  ansible.builtin.copy:
    content: |
      # Overrides /etc/modprobe.d/zfs.conf from the image (later file wins).
      options zfs zfs_arc_max={{ zfs_arc_max_bytes }}
    dest: /etc/modprobe.d/99-zfs-arc.conf
    mode: '644'

- name: Apply the ARC cap now
  ansible.builtin.shell: |
    set -o pipefail
    echo {{ zfs_arc_max_bytes }} > /sys/module/zfs/parameters/zfs_arc_max
  changed_when: false
```

drone-04 keeps the image's 8 GiB (it does not run this play). Verify with
`cat /sys/module/zfs/parameters/zfs_arc_max` after the play.

### 6. Kernel/ZFS skew

A uCore kernel bump that moves ahead of the ZFS kmod now breaks **the app tier on
three nodes**, not just drone-04. Two existing behaviours cover most of it:

- `provision.yml` sets `rpm-ostreed` to `AutomaticUpdatePolicy=stage`, so a new
  deployment (and kernel) waits for a reboot. **Before rebooting any storage
  node, check `bootc status` for a staged deployment** and treat it as part of the
  window.
- Pin the base image by digest in `bootc/Containerfile` so a kernel move is a
  reviewable commit rather than tag drift. Renovate already opens those PRs.

## Pre-flight

- [ ] `just check-kustomize` clean; nothing uncommitted in the working tree.
- [ ] All Argo applications `Synced`/`Healthy` (`prune: false` means nothing is
      deleted by the rebuild, but a dirty tree makes the diff unreadable).
- [ ] `kubectl get pods -A --field-selector status.phase=Unknown` is empty. Note
      that this field selector does not match every stale pod — filter the list.
- [ ] **Decide about Jellyfin.** drone-03 is the only `media/gpu=amd-vega` node, so
      Jellyfin is Pending for the whole window. Either do this at a quiet hour or
      temporarily point it at drone-01's Quadro P620 (`runtimeClassName: nvidia`,
      see the rollback section of the swap doc). The P620 fallback only exists
      until drone-01 is replaced — it is the last Haswell.
- [ ] `healthchecks-cronjob-drone-03` will fail during the window. Expected;
      do not "fix" it.
- [ ] Build and test the ISO artifacts before draining anything
      (`just gen-ignition drone-03 eno1 192.168.42.23`,
      `just gen-installer-config drone-03 /dev/nvme0n1 zfs`,
      `just build-iso drone-03 /dev/nvme0n1 drone-03-install.yaml`).

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
sudo sgdisk -n 5:0:+600G -t 5:bf00 -c 5:zfs /dev/nvme0n1
sudo partprobe /dev/nvme0n1
sudo udevadm settle
sudo sgdisk -p /dev/nvme0n1        # p5 present, 600 GiB, name zfs, no filesystem
```

`sgdisk` allocates from the lowest free sector, so p5 lands immediately after the
FCOS partitions and the ~330 GiB free gap ends up after it — which is where the
installer expects to build the root. Do **not** format or mount p5: an untouched
partition is the cleanest thing to preserve, and a filesystem on it would confuse
both the installer and anyone reading `lsblk` later.

Power off, plug in the installer ISO built in the pre-flight, and boot it. The
embedded install runs unattended. **Pull the USB stick when it reboots** (or put
the internal NVMe first in `BootOrder` and use F9), or it reinstalls in a loop.

## Phase 3 — Verify the layout (hard gate)

Boot the installed system and check before reconnecting anything:

```sh
sudo sgdisk -p /dev/nvme0n1
#  p5 exists (number may differ), ~600 GiB, name zfs, type bf00
#  p4 is the root, ~330 GiB — if it grew to fill the disk, the preserve failed

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
cat /sys/module/zfs/parameters/zfs_arc_max    # 2147483648, not the image's 8 GiB
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
| The image's 8 GiB ARC starves an app node | Per-node cap via `99-zfs-arc.conf` (change 5); verify `zfs_arc_max` after the play |
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
2. When all three pools exist: second democratic-csi Argo app
   (`zfs-local-zvol`, driver `org.democratic-csi.zfs-local`), the per-node
   `components/storage-home-*` components, and the app moves in the placement
   agreed for drone-01 (media + identity), drone-02 (home/IoT + USB dongle) and
   drone-03 (platform).
3. Then the teardown: `zfs-generic-nvmeof-csi`, the nvmet driver deployment and
   sealed config, `bootc/overlay/etc/systemd/system/nvmet.service.d/*`,
   `usr/libexec/nvmet-detach-local`, `modules-load.d/nvmeof.conf`, the
   `dedicated=storage` taint and its six tolerations, and
   `ansible/reboot-drone-04.yml`.
