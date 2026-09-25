# Kubernetes Node Hardware Inventory

**Cluster:** beaver-cloud.ts.net (7 nodes) · **Collected:** 2026-09-25 · **Access:** `ssh core@<host>` via Tailscale SSH

**OS (all nodes):** Fedora CoreOS 44 (uCore), kernel 7.0.x/7.1.x-201.fc44.x86_64 — immutable, composefs root, zram swap

## Cluster summary

|                    | Count / Total                                                               |
| ------------------ | --------------------------------------------------------------------------- |
| Physical machines  | 7 (4× DIY Haswell/Ryzen desktops, 3× Mac mini 2012)                         |
| Physical CPU cores | 22 (16 threads / vCPUs reported)                                            |
| Total RAM          | 120 GiB DDR3/DDR4                                                           |
| Discrete GPUs      | 2 NVIDIA (Quadro P620 2GB, GTX 1060 6GB) = 8 GiB VRAM                       |
| NVMe SSDs          | 4 × 480 GB (Team TM8FP6512G)                                                |
| SATA SSDs          | 9 (56 GB – 954 GB, Crucial/Kingston/OCZ/Team)                               |
| HDDs               | 2 × 12 TB (Seagate Exos HUH721212ALE601)                                    |
| iSCSI LUNs         | Many "VIRTUAL-DISK" devices across nodes (network-attached, ~300+ GB total) |

## Node details

### drone-01

|         |                                                                                                   |
| ------- | ------------------------------------------------------------------------------------------------- |
| OS      | Fedora CoreOS 44.20260802.3.1 (uCore), kernel 7.1.6-201.fc44                                      |
| CPU     | Intel Core i5-4590 (Haswell) — 4C/4T @ 3.3 GHz (max), 1 socket                                    |
| GPU     | **NVIDIA Quadro P620 (GP107GL), 2 GB** — driver 580.173.02, healthy                               |
| RAM     | **16 GiB** DDR3-1333 → 4× 4 GiB DIMMs (Corsair CMX8GX3M2A1600C9 ×2, G.Skill F3-12800CL9-4GBXL ×2) |
| Storage | 240 GB Crucial M500 SATA SSD · 480 GB Team NVMe · 50 GB iSCSI LUN                                 |
| NIC     | enp0s25 (1GbE)                                                                                    |
| Swap    | 7.8 GiB zram                                                                                      |

### drone-02

|         |                                                                                                                |
| ------- | -------------------------------------------------------------------------------------------------------------- |
| OS      | Fedora CoreOS 44.20260829.3.1 (uCore), kernel 7.1.10-200.fc44                                                 |
| CPU     | Intel Core i5-4590 (Haswell) — 4C/4T @ 3.3 GHz                                                                |
| GPU     | NVIDIA Quadro P620, 2 GB — driver 580.173.02                                                                   |
| RAM     | **24 GiB** DDR3-1333 → 2× 4 GiB + 2× 8 GiB G.Skill F3-2400C11 (4GXM/8GXM)                       |
| Storage | 56 GB OCZ Vertex Plus SATA SSD · 480 GB Team NVMe · ~48 GB iSCSI LUNs                           |
| NIC     | enp0s25 (1GbE)                                                                                  |
| Swap    | 11.7 GiB zram                                                                                   |

### drone-03

|         |                                                                                  |
| ------- | -------------------------------------------------------------------------------- |
| OS      | Fedora CoreOS 44.20260720.3.1 (uCore), kernel 7.0.12-201.fc44                    |
| CPU     | Intel Core i5-4590 (Haswell) — 4C/4T @ 3.3 GHz                                   |
| GPU     | Intel HD Graphics (iGPU only) — `nvidia-smi` present but no NVIDIA driver loaded |
| RAM     | **16 GiB** DDR3-1600 → 4× 4 GiB G.Skill F3-2133C10-4GAB                          |
| Storage | 954 GB SPCC SATA SSD · 480 GB Team NVMe · ~167 GB iSCSI LUNs (many small LUNs)   |
| NIC     | enp0s25 (1GbE)                                                                   |
| Swap    | 7.6 GiB zram                                                                     |

### drone-04

|         |                                                                                                                                                  |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| OS      | Fedora CoreOS 44.20260802.3.1 (uCore), kernel 7.1.6-201.fc44                                                                                     |
| CPU     | **AMD Ryzen 7 2700** — 8C/16T, boost 4.1 GHz (the big node)                                                                                      |
| GPU     | **NVIDIA GeForce GTX 1060 6GB (GP106)** — driver 580.173.02, healthy                                                                             |
| RAM     | 16 GiB DDR4-2400 → 2× 8 GiB Teamgroup UD4-3200                                                                                                   |
| Storage | **2× 12 TB Seagate Exos X12 (HUH721212ALE601)** · 112 GB Kingston SA400 SSD · 480 GB Team NVMe · ~70 GB iSCSI LUNs · 2× HL-DT-ST Blu-ray writers |
| NIC     | enp5s0 (1GbE)                                                                                                                                    |
| Swap    | 7.8 GiB zram (+702 MiB in use)                                                                                                                   |

### unimatrix-01 / -02 / -03 (identical platform)

|          |                                                                                              |
| -------- | -------------------------------------------------------------------------------------------- |
| Platform | Apple Mac mini (Mid 2012) — board `Macmini6,1`                                               |
| OS       | Fedora CoreOS 44.20260802.3.1 (uCore), kernel 7.1.6-201.fc44                                 |
| CPU      | Intel Core i5-3210M (Ivy Bridge mobile) — 2C/4T, 2.5–3.1 GHz                                 |
| GPU      | Intel HD Graphics 4000 (iGPU only)                                                           |
| RAM      | **16 GiB** DDR3-1600 → 2× 8 GiB SO-DIMMs each                                                |
| Storage  | 01: 240 GB Crucial MX100 SATA · 02: 240 GB Crucial MX100 SATA · 03: 240 GB Crucial M500 SATA |
| NIC      | enp1s0f0 (Thunderbolt/GbE)                                                                   |
| Swap     | 7.8 GiB zram                                                                                 |

## Notes & observations

- **Capacity balance:** drone-02 was historically the weak node (8 GiB); it now carries 24 GiB (2× 8 GiB G.Skill added 2026-09) and is the only node with more than 16 GiB.
- **GPU workloads** can only target drone-01 (Quadro P620) and drone-04 (GTX 1060). drone-03's NVIDIA driver is missing despite the tooling being installed.
- **Storage tiers:** every DIY node has a 480 GB NVMe (Team TM8FP6512G); drone-04 adds 24 TB raw HDD capacity — likely PV/local-storage host or the iSCSI target box.
- **iSCSI LUNs** ("VIRTUAL-DISK" model) are distributed across drone-01/02/03/04 — consistent with a network storage backend for PVCs; unimatrix nodes have none.
- **Kernel drift:** drone-03 is one minor version behind (7.0.12 / build 20260720 vs 7.1.6 / 20260802) — reboot it to pick up the current bootentry.
- All nodes idle-scaled well (except drones pinned at 24% scaling = turbo behavior on Haswell).
