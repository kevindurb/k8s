# Kubernetes Node Hardware Inventory

**Cluster:** beaver-cloud.ts.net (7 nodes) · **Collected:** 2026-11-19 · **Access:** `ssh core@<host>` via Tailscale SSH

**OS (all nodes):** Fedora CoreOS 44 (uCore), kernel 7.2.11-200.fc44.x86_64 — immutable, composefs root, zram swap

## Cluster summary

|                    | Count / Total                                                                       |
| ------------------ | ----------------------------------------------------------------------------------- |
| Physical machines  | 7 (3× HP EliteDesk 705 G4 DM, 1× DIY Ryzen desktop, 3× Mac mini 2012)                |
| Physical CPU cores | 26 cores / 26 vCPU — every node runs `mitigations=auto,nosmt`, so SMT threads are offline |
| Total RAM          | ~129 GiB DDR4/DDR3                                                                   |
| Discrete GPUs      | **0** — the two Quadro P620s and the GTX 1060 have all left the cluster              |
| NVMe SSDs          | 3 × 1 TB (Kingston SA2000M8, one per mini) · drone-04: 480 GB Team (+ 112 GB SATA OS) |
| HDDs               | 2 × 12 TB (Seagate Exos HUH721212ALE601), ZFS mirror `rust` on drone-04             |
| Optical            | 2 × Blu-ray writers on drone-04                                                     |

The three mini PCs are identical: `HP EliteDesk 705 G4 DM 35W (TAA)`, AMD Ryzen 5
PRO 2400GE (4C/8T, 4 vCPU after `nosmt`), Radeon RX Vega 11 iGPU, ~22 GiB DDR4,
one 1 TB Kingston NVMe, Realtek `eno1` 1 GbE, **UEFI with Secure Boot disabled**,
~11 W idle. Their NVMe is split `root` 331 GiB + `k8s` ZFS pool 600 GiB.

## Node details

### drone-01

|         |                                                                                    |
| ------- | ---------------------------------------------------------------------------------- |
| Unit    | EliteDesk #2 — disk `…659C`, BIOS `Q26 Ver. 02.16.00`                              |
| CPU     | AMD Ryzen 5 PRO 2400GE — 4C/8T, 4 vCPU (`nosmt`)                                   |
| GPU     | Radeon Vega 11 iGPU — not used for transcoding (Jellyfin lives on drone-03)         |
| RAM     | ~22 GiB DDR4-2666                                                                  |
| Storage | 1 TB Kingston SA2000M81000G NVMe — `root` 331 GiB XFS + `k8s` ZFS pool 600 GiB      |
| NIC     | eno1 (1 GbE), MAC `80:e8:2c:22:87:a3`                                              |
| Boot    | UEFI, Secure Boot disabled                                                         |

### drone-02

|         |                                                                                    |
| ------- | ---------------------------------------------------------------------------------- |
| Unit    | EliteDesk #1 — disk `…65AF`, BIOS `Q26 Ver. 02.18.01`                              |
| CPU     | AMD Ryzen 5 PRO 2400GE — 4C/8T, 4 vCPU (`nosmt`)                                   |
| GPU     | Radeon Vega 11 iGPU — unused                                                       |
| RAM     | ~22 GiB DDR4-2666                                                                  |
| Storage | 1 TB Kingston SA2000M81000G NVMe — `root` 331 GiB XFS + `k8s` ZFS pool 600 GiB      |
| NIC     | eno1 (1 GbE), MAC `80:e8:2c:25:93:d0`                                              |
| Boot    | UEFI, Secure Boot disabled                                                         |

### drone-03

|         |                                                                                    |
| ------- | ---------------------------------------------------------------------------------- |
| Unit    | EliteDesk #3 — disk `…6680`, BIOS `Q26 Ver. 02.09.00`                              |
| CPU     | AMD Ryzen 5 PRO 2400GE — 4C/8T, 4 vCPU (`nosmt`)                                   |
| GPU     | **Radeon Vega 11 iGPU — Jellyfin transcodes here** (`media/gpu=amd-vega`)          |
| RAM     | ~22 GiB DDR4-2666                                                                  |
| Storage | 1 TB Kingston SA2000M81000G NVMe — `root` 331 GiB XFS + `k8s` ZFS pool 600 GiB      |
| NIC     | eno1 (1 GbE), MAC `80:e8:2c:25:95:26`                                              |
| Boot    | UEFI, Secure Boot disabled                                                         |

### drone-04

|         |                                                                                                                                                  |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| CPU     | **AMD Ryzen 7 2700** — 8C/16T, 8 vCPU (`nosmt`)                                                                                                  |
| GPU     | **None** — the GTX 1060 was removed                                                                                                              |
| RAM     | ~15.5 GiB DDR4-2400                                                                                                                              |
| Storage | 112 GB Kingston SA400 (OS) · 480 GB Team NVMe (wiped spare) · **2× 12 TB Exos mirror** (`rust`, 10.9 T, 82 % used) · 2× Blu-ray writers               |
| NIC     | enp5s0 (1 GbE)                                                                                                                                   |
| Role    | storage + hardware: NFS server for bulk media, ZFS, makemkv, transcode jobs                                                                      |

### unimatrix-01 / -02 / -03 (identical platform)

|          |                                                                                              |
| -------- | -------------------------------------------------------------------------------------------- |
| Platform | Apple Mac mini (Mid 2012) — board `Macmini6,1`                                               |
| CPU      | Intel Core i5-3210M (Ivy Bridge mobile) — 2C/4T, 2 vCPU (`nosmt`)                            |
| GPU      | Intel HD Graphics 4000 (iGPU only)                                                           |
| RAM      | ~15.5 GiB DDR3-1600 → 2× 8 GiB SO-DIMMs each                                                 |
| Storage  | 01: 240 GB Crucial MX100 SATA · 02: 240 GB Crucial MX100 SATA · 03: 240 GB Crucial M500 SATA   |
| NIC      | enp1s0f0 (Thunderbolt/GbE)                                                                   |

## Notes & observations

- **No discrete GPU anywhere.** Jellyfin's only acceleration is drone-03's Vega 11,
  reached through `/dev/dri` and the node label `media/gpu=amd-vega` (rendered from
  `k3s_node_labels`, not applied by hand). The GPU-operator is obsolete — see
  `docs/drone-haswell-to-elitedesk-swap.md` Phase 4.
- **Every drone has a node-local `k8s` ZFS pool** (600 GiB, 8 % used by the mesh
  plan) alongside a 331 GiB root — the reason for the 2026-11 reinstall rather than
  a resize, since XFS cannot shrink. See `docs/drone-03-rebuild.md` and
  `docs/storage-placement.md`.
- **drone-04 is storage-first:** tainted `dedicated=storage:NoSchedule` so app pods
  stay off it. Its ZFS ARC is pinned to 10 GiB by `/etc/modprobe.d/zz-zfs-arc.conf`
  (rendered by `ansible/roles/nas_zfs`), which overrides the image default of 2 GiB
  that the three app nodes use. The `zz-` prefix is load-bearing — modprobe.d is read
  lexicographically and the last `options zfs` wins, so the previous `99-` name lost
  to `zfs.conf` and the node silently ran a 2 GiB ARC for months.
- **The 480 GB Team NVMe on drone-04 is no longer an L2ARC** (removed 2026-11-20).
  It managed a 7.7 % hit rate (2.2M hits / 29.2M requests) while writing 86 GB to a
  DRAM-less SSD, and its ~1.84 GB index was crowded into a 2 GiB ARC. It is wiped
  and unused; `ansible/roles/nas_zfs` will remove any cache vdev it finds on `rust`.
- **drone-04's `nvme` devices are plain local disks, not network devices.** The
  NVMe-oF/democratic-csi target is gone (removed 2026-11-23); the app nodes' storage
  is the local `k8s` pool on each node. drone-04's exports are NFS (`/media`), not
  NVMe-oF.
- **`nosmt` is a kernel argument, not a BIOS setting.** It comes from Fedora CoreOS
  and drops each Ryzen from 8 threads to 4. Removing it (`rpm-ostree kargs
  --delete=mitigations=auto,nosmt`) would roughly double CPU on all four drones —
  a deliberate security trade, not a default.
- **1 GbE only, and no upgrade path:** the EliteDesk has no PCIe slot (the M.2
  slots are the boot NVMe and WiFi), so 10 GbE is not available.
