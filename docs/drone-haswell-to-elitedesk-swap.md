# Replace drone-01/02/03 (Haswell desktops → HP EliteDesk 705 G4 DM)

## Context

Three HP EliteDesk 705 G4 Desktop Mini units replace `drone-01`, `drone-02` and `drone-03`. The replacements keep the **same hostnames and the same static IPs** (`.21`, `.22`, `.23`).

Reusing the hostnames is not just convenience. `healthchecks` pins every CronJob to a node by label — for example `healthchecks-cronjob-drone-03` carries `nodeSelector: kubernetes.io/hostname: drone-03`. Renaming a node means editing manifests across the repo for no benefit.

Replacement hardware, identical per node:

|         |                                                                                     |
| ------- | ----------------------------------------------------------------------------------- |
| CPU     | AMD Ryzen 5 PRO 2400GE — 4C/8T, 3.2 GHz base / 3.8 GHz boost, 4 MB L3, **35 W**       |
| iGPU    | Radeon RX Vega 11 — VCN1 video engine: H.264 + HEVC 8-bit encode, HEVC 10-bit decode  |
| RAM     | **16 GB** DDR4-2666, 2× SODIMM (dual channel), 32 GB max — ⚠️ varies per unit; the first measured unit has **22 GiB usable** |
| Storage | SSD — **confirm SATA vs M.2 NVMe per unit**, the SKU shipped both ways                |
| NIC     | Realtek RTL8111EPH, single 1 GbE                                                      |
| Power   | 65 W external brick, 7.4 × 5.0 mm barrel; **~11 W idle** once the iGPU firmware loads  |
| WiFi    | 802.11ac + BT (M.2 2230) — irrelevant for a node                                      |

Retiring hardware: i5-4590 (Haswell, 4C/4T, 84 W), 16/24/16 GiB DDR3-1333/1600, **legacy BIOS** boot, 1 GbE `enp0s25`, one Quadro P620 on drone-01 and one on drone-02.

Net effect per node: threads 4 → 8, RAM 16/24/16 → 16/16/16, idle draw roughly 35–45 W → ~11 W. Cluster DRAM across the four drones drops from 72 GB to 64 GB.

## What was verified before writing this

Read from the live cluster, not from HARDWARE.md. Re-checked live **2026-11-12**; ✅ marks what has landed since this was written, ⚠️ what is corrected.

- **Actual node CPUs** (`/proc/cpuinfo` via privileged pods): drone-01/02/03 = `Intel Core i5-4590 @ 3.30GHz`; drone-04 = `AMD Ryzen 7 2700`; unimatrix-01..03 = `Intel Core i5-3210M`.
- **Boot mode**: drone-01/02/03 boot **legacy BIOS**; drone-04 boots UEFI. These minis must be UEFI-only.
- **GPU placement** ⚠️: two Quadro P620s — one in drone-01, one in drone-02, each reported as 4 slices by the device plugin (MPS) and **both** labelled `nvidia.com/gpu.product: Quadro-P620-SHARED`, so a GPU pod can land on either node. As of 2026-11-12 `jellyfin` runs on **drone-01** — it moved there when drone-02 rebooted around 2026-11-10. The two stale `Unknown` leftovers from those reboots (`scrypted-…-4k2qt` on drone-01, `jellyfin-…-xzm8p` on drone-02) were ✅ **force-deleted 2026-11-12**; no replacement pods spawned and the cluster had no non-Running pods left. Jellyfin is now the only pod holding an `nvidia.com/gpu` limit. Note that `--field-selector status.phase=Unknown` does **not** match these — list `kubectl get pods -A` and filter, or you will think they are already gone.
- **Jellyfin is portable.** `jellyfin-nas-media` is plain NFS from `192.168.42.24:/media` with **no node affinity**, and `jellyfin-config-pvc` is `zfs-generic-nvmeof-csi` (NVMe-oF TCP). Neither ties Jellyfin to a node, so it can move to any node without touching storage.
- **Stale local PVs** ⚠️: nine `Released` PVs carry node affinity, not two. drone-03 has the two originally noted (`mayastor-etcd-localpv`, `openebs-minio-localpv`), **drone-02 has two more**, and drone-04 plus unimatrix-01/02/03 account for the rest. None blocks a drain; delete all nine at cleanup.
- **The NIC rename cannot break the join.** `enp0s25` appears only in this doc, `HARDWARE.md`, and the inventory's informational `static_iface`; `ansible/roles/k3s/templates/agent.yaml.j2` sets no `node-ip` or `flannel-iface`. Only the docs need updating, never the k3s config.
- **Provisioning path**: `bootc/Containerfile` (uCore + k3s) for the OS, `butane/node.bu.j2` for per-host identity, `ansible/roles/k3s` for the join. `bootc/justfile` has `gen-ignition` and `build-iso`.

## Phase 0 — readiness (no production hardware touched)

Runs before the first chassis is powered down. **0.1 and 0.2 have landed** (2026-11-12, see below), so only **0.3** is still a hard blocker: until the installer produces a joinable node, a replacement cannot join at all.

### 0.1 — k3s skew: ✅ landed 2026-11-12

`bootc/Containerfile` pins `K3S_VERSION=v1.37.2+k3s1` (since `708e46d4`, 2026-11-04) and every node now reports **v1.37.2+k3s1**, so the skew that would have made a fresh node unjoinable is closed:

```
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion
drone-01       v1.37.2+k3s1
…
unimatrix-03   v1.37.2+k3s1
```

`kubeletVersion` is the running agent, so the control plane and all four drones already rebooted into the 1.37.2 image, and Argo reports everything Synced/Healthy.

What remains is a paper trail, not a gate. This was a two-minor jump (1.35 → 1.37, skipping 1.36), the range where removed APIs live; run `pluto detect-all-in-cluster` (or `kubent`) once if you want it recorded. The manifests are current-API, and the `pod-security.kubernetes.io/enforce-version: v1.35` labels are cosmetic.

Because this landed, 0.3's switch target is plain `latest`, and the "deploy at 1.35.6, rebase later" step does not exist.

### 0.2 — Staged deployment: ✅ moot

`rpm-ostreed` runs `AutomaticUpdatePolicy=stage`, and the weekly Sunday build republished `latest` after the 1.37.2 bump. The hazard was real — a drone rebooted into the staged `2026.11.08` image (`sha256:da4d862c…`) would have run an agent at 1.37.2 against a 1.35.6 server. The nodes have since rebooted into a 1.37.2 image and the API server is on 1.37.2 too (`kubeletVersion` proves both halves), so the mismatch never appeared. All nodes still report the same `44.20261023.3.1` base, though, so a newer build may be pending.

Keep it as a per-node check before touching hardware: `bootc status` must show the expected booted image and nothing unexpected staged. After that the standing freeze on unrelated reboots is discharged.

One correction while you are there: the "reboot drone-03 to pick up the current kernel" line in `HARDWARE.md` is obsolete — all nodes, drone-03 included, run 7.2.11-200.fc44.

### 0.3 — Make the installer produce a joinable node

The ISO produces a bare FCOS install, not a cluster member. Two gaps, both manual — one documented below, one decided to stay manual rather than wired into the role.

**Bootc switch.** `butane/node.bu.j2` is `variant: fcos` and `build-iso` wraps it into a plain FCOS installer, but the nodes boot `ghcr.io/kevindurb/k8s-node` — confirmed live: `bootc status` reports `ostreeContainer`, stateroot `fedora-coreos`. Nothing in the repo performs the switch. Options considered, and where they landed:

1. **Install from the node image directly** — ❌ **ruled out, verified 2026-11-12.** The pinned installer image (`quay.io/coreos/coreos-installer:release`, version **0.27.0**) exposes no `--target-imgref` on either `iso customize` or `install`, so the customized ISO cannot be pointed at `ghcr.io/kevindurb/k8s-node`. Re-check only if the `:release` tag moves and its help grows the flag.
2. **Automate it** with a first-boot systemd unit in the ignition — works, but adds a unit plus a reboot to the boot path for three installs, and leaves the ignition harder to reason about when a boot fails.
3. **Document it** as the explicit two commands in Step 4 — ✅ **chosen.** Three nodes, once each; a hands-on reboot is worth less than an extra moving part in the first-boot path.

**Tailscale.** ✅ **decided 2026-11-12: keep the join manual too.** `ansible/roles/tailscale/tasks/main.yml` stays exactly as it is — `tailscale up --accept-dns=false --ssh`, no key, no tags — so the role is unchanged and no credential is threaded through `provision.yml`. The first join on each fresh node is done by hand, before Ansible, with a **reusable preauth key tagged `tag:k8s-node`**:

```sh
sudo tailscale up --accept-dns=false --ssh \
  --auth-key=tskey-auth-… --advertise-tags=tag:k8s-node
```

Why it cannot be skipped: without a tagged key the node comes back **untagged**, which is worse than a different ACL position — an untagged device becomes an *owned device*, reachable only through the own-device rules, because `tag:k8s-node` has no network grants of its own and node SSH is `group:admins → tag:k8s-node` (`docs/tailscale-acl-hardening.md` already tracks this gap, around line 464). `--advertise-tags` only works when the key itself carries the tag, so create the key tagged, not plain.

It also cannot resolve `ansible_host: drone-03` before it is on the tailnet, so the join is not reachable at all until this runs. The very first `provision.yml` can run over the LAN either way — `-e ansible_host=192.168.42.23` — which is the fallback if the Tailscale step has to wait.

### 0.4 — Validate one mini end to end, without the cluster

Do this on one unit before any of the three is scheduled. Nothing here touches Kubernetes.

1. **Bench stick:** in `bootc/`, `just download-iso` then `just bench-iso`, flash `bootc/dist/bench.iso`. It is the stock FCOS live ISO with a live ignition only — it comes up on **192.168.42.90** with `sshd` and the GitHub keys, and writes nothing to disk, so it is safe on a unit you are about to install over. Everything below can then be done over SSH instead of at a console.
2. Live USB: `ip -br link` (measured on the first unit: **`eno1`** — the onboard Realtek gets a firmware/DMI-derived name, so do **not** assume `enp1s0`/`enp2s0`), `lsblk` (SATA `/dev/sda` vs NVMe `/dev/nvme0n1`), `test -d /sys/firmware/efi`.
3. BIOS (F10): Secure Boot → Disable, Legacy Support → Disable, UEFI order first. Clear Absolute Persistence on corporate units. Note a unit that arrived with **Secure Boot enabled** still boots the bench stick, because the FCOS ISO is Fedora-signed — so a successful boot is not evidence that Secure Boot is off. See [Secure Boot must be off](#secure-boot-must-be-off) for why the node image is the part that fails.
4. Install, then confirm `hostname`, the static IP answering, `tailscale status`, `ssh core@…`.
5. **Vega ID:** `lspci -nn | grep -i vga`. Raven Ridge is normally `15dd`; some Picasso parts report `15d8`. Hard gate — a wrong ID fails silently in Phase 4, because the node simply never receives the label. Measured on the first unit: `1002:15dd` (rev d6), the expected ID.
6. **Transcode:** ⚠️ **do not use `vainfo` as the gate.** On this hardware `vainfo` lists only MPEG2/VP9/JPEG decode plus `VAEntrypointVideoProc` — **no H.264, no HEVC, no `EncSlice`** — on both Mesa 25.0.7 and 26.2.6, while real VA-API transcoding works perfectly. Gate on ffmpeg instead, in a container:

   ```sh
   podman run --rm --privileged --device /dev/dri --entrypoint bash -i \
     docker.io/linuxserver/ffmpeg -s <<'EOS'
   ffmpeg -f lavfi -i testsrc2=size=3840x2160:rate=24 -t 4 \
     -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast /tmp/h.mp4 -y </dev/null
   # decode 4K HEVC 10-bit, convert to 8-bit on the GPU, encode
   ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi \
     -i /tmp/h.mp4 -vf scale_vaapi=w=1920:h=1080:format=nv12 \
     -c:v h264_vaapi /tmp/o.mp4 -y </dev/null && echo H264_OK
   EOS
   ```

   Feeding a 10-bit VA-API surface straight into `h264_vaapi` fails with `No usable encoding profile found` — that is a missing `scale_vaapi` conversion, not a hardware limit. Then confirm the real thing: one 1080p transcode and **one 4K HDR title**, watching for the `error 139` SIGSEGV that hits HEVC 10-bit HDR with Vulkan tone-mapping. Measured on the first unit: 1080p H.264 transcode, HEVC 8-bit encode, and 4K HEVC 10-bit → 1080p H.264/HEVC all succeeded in 1–2 s for a 4 s clip.
7. **Idle power:** ≈ 11 W at the wall, not ≈ 18 W. The higher figure means `amdgpu` firmware did not load.

Record `lsblk` for all three units — disk interface is the one field that varies by SKU — but only one needs the full test.

#### 0.4 results — first unit, 2026-11-12

Bench stick booted on a unit whose internal disk still held Windows. Read-only over SSH, nothing written:

| | |
|---|---|
| Model | `HP EliteDesk 705 G4 DM 35W (TAA)`, board `83E9`, BIOS `Q26 Ver. 02.18.01` (2022-04-07) |
| CPU | `AMD Ryzen 5 PRO 2400GE`, 4C/8T, 3.8 GHz max — as specified |
| RAM | **22 GiB usable (~24 GB installed)** — *not* the 16 GB in the table above; measure per unit (`free -h`) |
| Disk | **`/dev/nvme0n1`**, `KINGSTON SA2000M81000G` 931.5 GiB — **NVMe**, and `sn 50026B7683E965AF` identifies the unit |
| On that disk now | Windows: `SYSTEM` 260M vfat, 16M MSR, 930.6G ntfs, `Windows RE Tools` 639M |
| NIC | **`eno1`**, MAC `80:e8:2c:25:93:d0` |
| Boot | **UEFI**, Secure Boot **enabled** (bench stick still boots; must be disabled for the node image) |
| GPU | `1002:15dd` rev d6, `/dev/dri/renderD128` present, `amdgpu` loaded, VCN fw `ENC 1.15 DEC 3` |
| Transcodes | H.264 1080p ✅, HEVC 8-bit encode ✅, 4K HEVC 10-bit decode ✅ (+ `scale_vaapi` → 1080p H.264/HEVC ✅) |

The ignition for this unit therefore needs `interface-name=eno1` and `--dest-device /dev/nvme0n1`; a wrong interface name here would have been the expensive failure the bench stick exists to catch.

#### Units processed

| # | disk sn (identity) | NIC MAC | BIOS | RAM | CPU threads | Disk | Health |
|---|---|---|---|---|---|---|---|
| 1 | `50026B7683E965AF` | `80:e8:2c:25:93:d0` | `02.18.01` (2022-04-07) | 22 GiB | 4 (nosmt) | Kingston SNV… 931.5 G, 21,284 h, 2 % used | clean |
| 2 | `50026B7683E9659C` | `80:e8:2c:22:87:a3` | `02.16.00` (2021-04-15) | 22 GiB | 4 (nosmt) | Kingston SNV… 931.5 G, 5,901 h, 1 % used | clean |
| 3 | `50026B7683E96680` | `80:e8:2c:25:95:26` | `02.09.00` (2019-10-22) | 22 GiB | 4 (nosmt) | Kingston SNV… 931.5 G, **56 h**, 0 % used, 2.0 GB/s | clean |

The serials differ only in the last three characters — **always pass the full serial to the wipe, never a prefix.** `unit-prep.sh wipe <ip> <serial-suffix>` reads the disk serial first and refuses on mismatch, and refuses a serial already recorded in `/tmp/opencode/wiped-serials.txt`.

⚠️ **Both units report 4 threads, and that is the image, not the BIOS.** `nproc` = 4, `/sys/devices/system/cpu/smt/active` = 0, `/sys/.../online` = `0,2,4,6` — because the boot command line carries `mitigations=auto,nosmt`:

```
$ cat /proc/cmdline | tr ' ' '\n' | grep -i smt
mitigations=auto,nosmt
```

That is a **Fedora CoreOS default** baked in at install time, present identically on the live stick (`isolinux/isolinux.cfg`) and in the installed nodes' grub entries (`/boot/loader/entries/ostree-*.conf`). `rpm-ostree kargs` reports it on drone-01, so it is a removable karg, not a firmware setting — **do not chase this in the HP BIOS.** (An earlier pass at this doc blamed a BIOS SMT toggle; that was wrong.)

Consequence for the swap: the Ryzen 5 PRO 2400GE is 4C/8T, so with `nosmt` these nodes present **4 CPUs each**, exactly like the i5-4590 Haswells they replace — which have no SMT to lose. Nothing regresses, but there is a free 2× CPU on the table if `nosmt` is dropped from the node image (`rpm-ostree kargs --delete=mitigations=auto,nosmt`, or a `--karg` at install). That is a deliberate security trade, not a default to change casually.

**Read the thread count with `nproc`, not `lscpu`.** `lscpu` prints `CPU(s): 8` on these boxes while only four are online, because that line counts *present* CPUs from ACPI; the giveaway is `Thread(s) per core: 1` next to `Core(s) per socket: 4`. `nproc`, `/sys/devices/system/cpu/smt/active` and `/sys/devices/system/cpu/online` are the trustworthy readings, and this artefact caused a false "this unit has SMT disabled" call on unit 2.

#### BIOS updates are not available over LVFS

fwupd is in the live image and does identify the HP BIOS as an updateable device — `System Firmware`, vendor `HP (DMI:HP)`, GUID `3c21dbd6-d562-459f-92ed-b5cf8e73d35e`, version `133376` = `0x020900` = **02.09.00** (unit 3's). That is as far as it goes:

```
$ sudo fwupdmgr get-updates 5e9f4648…      # the System Firmware device id
Devices with no available firmware updates:
 • System Firmware
$ sudo fwupdmgr get-releases 5e9f4648…
No releases found
$ https://fwupd.org/lvfs/component/3c21dbd6-d562-459f-92ed-b5cf8e73d35e  → 404
```

HP publishes no capsule for board `83E9`, and the firmware could not accept one anyway — `OsIndicationsSupported` = `0x1` (BOOT_TO_FW_UI only; the FMP capsule bits `0x4`/`0x8` are absent), which is also why fwupd reports `System firmware cannot accept DBX updates` for the dbx device.

So a BIOS update means HP's Windows SoftPaq, or **F10 → Update System BIOS** with the `.bin` on a FAT32 stick — both require hands on the machine. **Not worth it:** the OS loads microcode at boot (`microcode: Current revision: 0x08101016` at 0.68 s, from `amd-ucode-firmware` in the image), and `0x08101016` is the family 17h/11h revision that carries the Zenbleed fix. A 2019 BIOS therefore does not leave a known microcode hole open on the 2019-firmware unit.

#### Secure Boot must be off

The image is `ghcr.io/ublue-os/ucore:stable-nvidia-lts`. Its out-of-tree modules are signed with **Universal Blue's own key**, not one the HP firmware trusts:

```
$ modinfo -F signer zfs nvidia spl        # on a running node
ublue kernel
ublue kernel
ublue kernel
```

With Secure Boot enforcing, those modules are rejected at load time — which on this cluster means no `zfs`, so no pool, no datasets, no NVMe-oF target, and every PVC-backed app dead. It is not a cosmetic warning.

The current cluster already runs the proven configuration: **drone-04** — the only node that boots UEFI and runs this exact image — reports

```
$ mokutil --sb-state
SecureBoot disabled
Platform is in Setup Mode
```

Keeping Secure Boot on would mean enrolling the ublue public key into MOK on every machine (physical console, one-time password, `mokutil --import`), and re-doing it whenever that key changes. That is per-machine manual work at exactly the point we want hands-off installs, buying nothing here: the nodes are single-purpose and reachable only over the tailnet. **Decision: Secure Boot off on all three.**

Confirmed from the OS on the first unit after the BIOS change — the efivar is the reading the firmware cannot fake:

```
$ mokutil --sb-state
SecureBoot disabled
$ od -An -tu1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-…   → 0
$ od -An -tu1 -j4 -N1 /sys/firmware/efi/efivars/SetupMode-…   → 0
```

Worth knowing: the three Haswells being replaced are **legacy-booting** (`/sys/firmware/efi` absent on drone-01/02/03), so UEFI is a deliberate change, not a continuation — drone-04 proves the image handles it.

#### Wipe and health check — first unit, 2026-11-12

The unit arrived with a company Windows install (`SYSTEM` / MSR / 930.6 G NTFS / WinRE). Erased with `nvme format --ses=2` (crypto erase — `fna=0x4` reports it supported, and it is instant):

```sh
sudo nvme format /dev/nvme0n1 --ses=2 --force
sudo blockdev --rereadpt /dev/nvme0n1
```

Verified afterwards: no partition table, `blkid` silent, and direct reads at 1 M / 100 G / 500 G / 900 G all returned zeros. The controller never re-reports the old layout, so `--rereadpt` is required before `lsblk` looks clean.

Health, read before the wipe:

| | |
|---|---|
| `dmesg` MCE / AER / thermal / I/O errors | **0** |
| NVMe | `critical_warning 0`, 31 °C, 100 % spare, **2 % used**, **0 media errors**, 0 error-log entries, 21,284 h, 33 unsafe shutdowns |
| Read (2 GiB, O_DIRECT) | **1.1–1.2 GB/s** at `bs=1M`/`4M` — *not* the 85 MB/s a `bs=1M` first run reports cold |
| NIC | `eno1` 1000 Mb/s, full duplex, link up |
| Thermal | 30 °C, no throttling |

The read speed is worth re-running once if it looks slow: the first `dd` after boot can report ~85 MB/s purely from cold caches, which is alarming and wrong.

Transcode results on real files, beyond the synthetic 0.4 checks:

| Path | Result |
|---|---|
| 1080p H.264 → H.264 (hw) | ✅ fast |
| HEVC 8-bit encode (hw) | ✅ |
| 4K HEVC 10-bit decode (hw) | ✅ |
| 4K HDR10 → 1080p, **no** tone map | ✅ 1–2 s per 6 s clip |
| **VAAPI tone map** (`tonemap_vaapi`) | ❌ `VAAPI driver doesn't support HDR` — VCN1 has no HDR tone mapping |
| Software tone map (`zscale`+`hable`) | ✅ but **60 s for 6 s** (~0.1× realtime) |
| hw decode + soft tone map + hw encode | ✅ same ~0.1× |
| Vulkan/libplacebo tone map (`error 139` path) | inconclusive — no Vulkan ICD in `linuxserver/ffmpeg`; must be settled in Jellyfin's own image |

**Operational takeaway:** HDR→SDR transcoding on Vega 11 is not realtime. HDR titles must direct-play; everything else is fine. Samples kept in `/var/tmp/k8s-bench-clips/` on dev (`bbb_1080_h264.mp4`, `bbb_1080_hevc.mp4`, `bbb_hdr10_4k.mp4` — the HDR one is synthesised from BBB, since every free 4K HDR sample is Drive-gated).

### 0.5 — Rehearse the join under a throwaway hostname

All three swaps depend on install → switch → join → Ready, and that cannot be rehearsed as `drone-03` while `drone-03` is live. Install one unit as `test-node` on an address outside the cluster range (e.g. `192.168.42.30`), run `provision.yml --limit test-node`, confirm `Ready`, then drain/delete and wipe.

This is the cheapest place to catch a wrong interface name in the ignition, a forgotten manual `tailscale up` (or a key that came back untagged), or a version mismatch — an evening's work instead of a production node.

### 0.6 — Git-only changes that are safe now

**Scrypted** — ✅ **landed 2026-11-12** (`apps/scrypted/deployment.yml`): `v0.147.0-noble-amd`, no `runtimeClassName`, no GPU selector, no `nvidia.com/gpu` limit. It does not use the GPU (see the Scrypted section). Its HomeKit path is a remux, not a transcode, and `nvidia-smi` on drone-01 showed no processes, so this landed while the P620 was still installed as a revert:

- image → `ghcr.io/koush/scrypted:v0.147.0-noble-amd@sha256:9c8f6dff157be7acc074712e3c050e7dc0a898e1b2c00ede457840f652c8011d`
- dropped `runtimeClassName: nvidia`, the `nvidia.com/gpu.product` selector and the `nvidia.com/gpu: '1'` limit
- kept `hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet` (HomeKit needs Bonjour)

`-noble-amd` needs `/dev/dri` plus `supplementalGroups: [105]` (the `render` group) before it accelerates anything; that arrives with the Vega in Phase 1. Until then it behaves exactly as today.

✅ **Validated 2026-11-12:** Argo Synced/Healthy, pod Running on **drone-03** (it left the P620 nodes on its own once the selector went), ingress answering on `https://scrypted.beaver-cloud.ts.net/`, RTSP session open against the Reolink doorbell, and **both cameras confirmed working in the iOS Home app**. 0.6 is done — nothing Scrypted-shaped remains before the swaps.

**Jellyfin does not belong here.** Dropping `runtimeClassName` while the selector still points at drone-01's P620, or landing on a node with no `/dev/dri`, silently downgrades it to software transcode. Its edits land with the drone-03 move.

## Phase 1 — swap order

Phase 0 comes first; nothing here starts until 0.4–0.6 are done (0.1, 0.2 and the git half of 0.3/0.6 have already landed — what is left of 0.3 is the two manual commands each install runs).

1. **Swap drone-03**, validate. Jellyfin keeps running on **drone-01's** P620, which this step does not touch.
2. **Move Jellyfin to drone-03's Vega 11**, validate transcoding.
3. **Swap drone-02** — GPU-free, and it has not hosted Jellyfin since its 2026-11-10 reboot.
4. **Swap drone-01** — the last P620 retires with the chassis. By then nothing runs on it: Scrypted came off its GPU back in Phase 0, Jellyfin is on the Vega.
5. **Retire gpu-operator** and switch NFD to `vendor`+`device` PCI labels — Phase 4 below.

This ordering proves the replacement transcode path before the only node Jellyfin can fall back to is touched, and keeps the operator teardown single-variable at the end. **One node in flight at a time**, and one Jellyfin move, with validation between each.

Note the placement correction: drone-01 is not a bystander — it is the node transcoding right now, and its P620 is the rollback target. That is why it goes last, not because a GPU leaves with it.

## Jellyfin → Vega 11 (after Step 1, before drone-01)

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

### Validate before touching drone-01

- [ ] Pod running on drone-03, not CrashLooping on runtime class
- [ ] `vainfo` inside the pod reports `VAEntrypointVLD` and `VAEntrypointEncSlice` on `renderD128`
- [ ] A forced 1080p transcode plays and shows low CPU on drone-03
- [ ] One 10-bit HEVC title transcoded deliberately, to confirm it falls back rather than crashing
- [ ] Jellyfin playback over Tailscale still works (ingress unaffected)

If this fails, Jellyfin may go back to drone-01 temporarily — but drone-01 cannot be drained until it works, so treat this as the real gate on step 4. After drone-01 and drone-02 are gone there is no discrete GPU anywhere in the cluster: the only fallback is software transcode on a 4C/8T node, which is not viable for 4K or HEVC-heavy sources. That is why Phase 0 requires a 4K HDR title to be tested before any swap begins.

## Scrypted — no GPU, and none needed

Scrypted is a HomeKit gateway for the security cameras, and its HomeKit path does not transcode. The live ffmpeg invocation is a remux — `-vcodec copy -acodec copy` against the Reolink `h264Preview_01_sub` substream at 640x480 / 640x360, 10 fps — and `nvidia-smi` on drone-01 reports **no processes** with 3 MiB of 2048 MiB in use. The `nvidia.com/gpu: '1'` request has been holding a time-slice slot for nothing, and no object detection is in play.

Consequence for the plan: **Scrypted is not a step-4 concern at all.** It never used the P620, so taking it off the NVIDIA runtime is Phase 0 work (0.6), done while the card is still installed as a revert. That also deletes the "loses hardware detection at step 4" risk and the "run it for a week before the Haswells leave" gate.

The one case not yet exercised: the GPU selector has kept it on drone-01/drone-02 until now, so it has never had to land on a 2-core control-plane node. It is `hostNetwork: true`, so add a `kubernetes.io/hostname` selector only if that ever matters — movement between drones has been painless in practice, including HomeKit pairing.

### Image

`v0.147.0` publishes no plain `-noble` tag. The non-NVIDIA variants are `-noble-amd`, `-noble-full`, `-noble-intel` and `-noble-lite`; use **`-noble-amd`**, which keeps VA-API available for the day HKSV or a main stream is enabled:

```
ghcr.io/koush/scrypted:v0.147.0-noble-amd@sha256:9c8f6dff157be7acc074712e3c050e7dc0a898e1b2c00ede457840f652c8011d
```

It costs nothing today — the render node only matters when it actually transcodes, and that mounts with the Vega in Phase 1. An image variant change does not lose installed plugins: Scrypted keeps them in the PVC (`/server/volume/plugins`). Verified by live view in the Home app on 2026-11-12 — both cameras fine, plugins intact, pod rescheduled to drone-03.

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
   - **NIC name**: `ip -br link` — measured on the first unit it is **`eno1`**, not `enp0s25` and not necessarily `enp1s0`/`enp2s0` either. Never guess this one.
   - **Disk device**: `lsblk` — `/dev/sda` for SATA, `/dev/nvme0n1` for NVMe.
   - **Disk interface**: also tells you whether the SATA bay is free or occupied.
3. Confirm UEFI: `test -d /sys/firmware/efi && echo UEFI`.
4. Enter BIOS (F10) and set: **Secure Boot → Disable**, **Legacy Support → Disable**, **Network Boot → Disable**, **After Power Loss → On**, UEFI boot order first.

   Verify from the OS rather than trusting the BIOS screens — `efibootmgr` reads the firmware's own entries:

   ```
   $ sudo efibootmgr | grep -E '^Boot(Order|Current)|^Timeout'
   BootCurrent: 0004
   BootOrder: 0004,0007,0005,0003      # 0004 = the USB stick, 0007 = the internal NVMe
   Timeout: 0 seconds
   ```

   Network entries still exist as `Boot0002`/`Boot0006` but are absent from `BootOrder`, so they are never tried — that is what "network boot disabled" looks like, and it is fine. **The USB stick is first in `BootOrder`**, so unplug it after the install completes or the node will keep booting the live image instead of the installed system.

   On the first unit `efibootmgr` also listed `Boot0001`/`Boot0003` for a **WDC PC SN520 256G** that is not in the machine — a leftover from the corporate drive the reseller replaced. Harmless, but don't mistake it for a second disk: `lsblk -dno NAME,MODEL` shows only the one NVMe.

Skipping the interface check is the most expensive mistake available here: the host installs cleanly, then comes up with no network, no Tailscale and no SSH, which presents as a dead machine.

### Step 2 — Generate the installer (on dev)

```sh
cd ~/projects/k8s/bootc
just gen-ignition drone-03 <iface-from-step-1> 192.168.42.23
just build-iso drone-03 /dev/nvme0n1
```

✅ Fixed 2026-11-12: the recipes now resolve `../butane/` against the justfile (they used to look for `./butane/`, which does not exist under `bootc/`) and run `butane` from `quay.io/coreos/butane:release` instead of requiring a host binary. `cd bootc` and `just …` now works as written; artifacts land in the gitignored `bootc/dist/`.

`build-iso` takes the destination disk as its second argument (✅ landed 2026-11-12; it used to hardcode `--dest-device /dev/sda`). Pass what Step 1's `lsblk` showed — `/dev/nvme0n1` for the NVMe units, `/dev/sda` for SATA — and the recipe has no default so a forgotten argument fails instead of guessing. Getting this wrong installs over the wrong device.

### Step 3 — Retire the old node

```sh
# 1. clear pods left Unknown by earlier reboots (already empty on 2026-11-12)
#    note: --field-selector status.phase=Unknown does not match them; filter the list
kubectl get pods -A --field-selector status.phase=Unknown

# 2. drain and retire
kubectl drain drone-03 --delete-emptydir-data --ignore-daemonsets
kubectl delete node drone-03
```

Then power the chassis down and **remove and keep its SSD.** That disk is the rollback.

Wait for the pods that were on drone-03 to reschedule elsewhere and reach Ready before installing the replacement. Draining into an already-loaded cluster and installing at the same time makes failures hard to attribute.

### Step 4 — Install, then switch to the node image

Boot the generated ISO on the EliteDesk and let it complete. The ISO produces a **bare FCOS install** — not a cluster node. Finish it with the `bootc switch` from 0.3:

> ⚠️ **It will reinstall in a loop if you leave the stick in.** The USB is first in `BootOrder`, so after the unattended install finishes and the machine reboots it boots the installer again and wipes the disk again. Two options: sit and watch for the reboot and pull the stick (what we did, and it is easy to miss), or — better — **put the internal NVMe first in `BootOrder` and pick the USB with `F9` at power-on**. Then the post-install reboot lands on the installed system by itself.

```sh
sudo bootc switch ghcr.io/kevindurb/k8s-node:latest
sudo systemctl reboot
```

If the disk turns out to already be the node image, this block is skipped — continue to the checks below. With 0.3's option 1 ruled out it never is: the ISO is always bare FCOS, so expect the two commands every time.

Then bring the node onto the tailnet by hand (0.3 — the Ansible role does not do this), with a reusable key **created already tagged `tag:k8s-node`**:

```sh
sudo tailscale up --accept-dns=false --ssh \
  --auth-key=tskey-auth-… --advertise-tags=tag:k8s-node
```

After the reboot, confirm before touching k3s:

- `hostname` returns `drone-03`
- the static IP answers: `ping 192.168.42.23`
- `bootc status` reports `ghcr.io/kevindurb/k8s-node` and nothing unexpected staged
- `tailscale status` lists the node **tagged `tag:k8s-node`** — an untagged node is an owned device and will not accept the `group:admins → tag:k8s-node` SSH rule
- `ssh core@drone-03` works
- `/dev/dri/renderD128` exists (proves `amdgpu` loaded — see the idle-power note)

### Step 5 — Join k3s

```sh
ansible-playbook ansible/provision.yml -i ansible/inventory/prod.yml --limit drone-03
# if the tailnet name does not resolve yet, go over the LAN instead:
#   … --limit drone-03 -e ansible_host=192.168.42.23
```

The `tailscale` role in that run is a no-op re-`up` — it carries no key, so the join already happened manually in Step 4.

`provision.yml` runs several plays; the ones that matter for a rejoin are `base` (timezone, SSH keys, `tuned` profile) and `k3s`, which fetches the token from `192.168.42.1`, templates `/etc/rancher/k3s/config.yaml` from `ansible/roles/k3s/templates/agent.yaml.j2`, and starts `k3s-agent.service`. The `k3s` play already waits for the node to reach Ready.

Confirm `kubectl get node drone-03` reports **Ready** and that `kubeletVersion` matches the rest of the cluster (`v1.37.2+k3s1`). A mismatch means the node booted a different image than expected; check `bootc status` before anything else.

### Step 6 — Validate

Do not proceed to the next node until every line passes:

- [ ] Node **Ready**, `kubeletVersion` = cluster version
- [ ] `democratic-csi-node` pod running on the node
- [ ] `healthchecks-cronjob-drone-03` schedules and its Jobs complete
- [ ] Pods that were displaced by the drain are Ready (some will land here)
- [ ] No `Unknown` pods left over from the old node (`kubectl get pods -A --field-selector status.phase=Unknown`)
- [ ] Argo CD: all apps **Synced / Healthy**
- [ ] Gatus: all endpoints green
- [ ] Idle draw at the wall ≈ **11 W**, not ≈ 18 W — the higher number means `amdgpu` firmware did not load
- [ ] `/dev/dri/renderD128` present

**After drone-03 specifically:** do the Jellyfin → Vega 11 migration and its validation checks before starting drone-02.

### Step 7 — Cleanup after all three

- Update `ansible/inventory/prod.yml`: `static_iface` for drone-01/02/03 still says `enp0s25`. Note that `static_iface` and `static_ip` are **not consumed by any playbook or template** — they are documentation only, so this is accuracy rather than correctness. Worth doing anyway, so the inventory doesn't lie.
- Update `HARDWARE.md` CPU/RAM/GPU rows and the cluster summary. Note it is already wrong before the swap, so fix it early rather than only here: line 86 claims GPUs only exist on drone-01 and drone-04 (drone-02 has a P620 too), line 5 says kernel 7.0/7.1 (live is 7.2.11), the per-node OS strings are stale, and the "reboot drone-03 for the current kernel" note is obsolete. Mid-swap the inventory is 2× P620 (2 GB each); at the end it is **zero discrete GPUs** — the GTX 1060 leaves for another project. Also correct the summary's total RAM 120 → 112 GiB and cores 22 / 16 vCPUs → 26 / 52 threads, and the drone-03 iGPU row (Intel HD → Vega 11).
- Delete all nine stale `Released` PVs, not just drone-03's two: drone-03 and drone-02 have two each (`mayastor-etcd-localpv`, `openebs-minio-localpv`), the rest are on drone-04 and unimatrix-01/02/03.
- Record the final GPU state: Jellyfin on Vega 11, Scrypted on CPU. Confirm nothing still selects `nvidia.com/gpu.product: Quadro-P620-SHARED`.

## Rollback

Per node, and only until all three are validated: reinstall the original SSD in the Haswell chassis, power it on, and re-run Step 5 to rejoin. The ignition config is static and the k3s config is templated, so a rejoin is a few minutes of work.

**Jellyfin rolls back with git.** Reverting the deployment change returns it to `runtimeClassName: nvidia` + the P620 selector; on drone-01 that still works until drone-01 is drained in step 4. After that the only fallback is the Vega 11 — so do not consider drone-01 swapped until the Vega 11 path is proven.

The rollback window is wider than the swap order suggests: drone-01's P620 is both the live transcode node today and the revert target, and it is the last chassis to leave. Nothing needs to be re-provisioned to get back to a working GPU transcode path until step 4.

Keep all three Haswell SSDs — and their RAM, if it was pulled — until the whole migration is done. Do not repurpose or wipe them early.

## Risks

| Risk | Mitigation |
| --- | --- |
| Wrong interface name in the ignition config | Discover it on a live USB in Step 1 — it was `eno1` on the first unit, i.e. not `enp*s*` at all |
| `--dest-device /dev/sda` against an NVMe disk | Fixed — `build-iso` takes the disk as an explicit argument; `lsblk` in Step 1 tells you which |
| Legacy/CSM boot | UEFI-only, Secure Boot off — otherwise no `amdgpu` firmware, so 18 W idle and no transcoding |
| Assuming Jellyfin is pinned to drone-02 | It floats between the two P620 nodes and currently runs on drone-01. Re-check `kubectl get pod -n jellyfin -o wide` before every drain |
| Stale `Unknown` pods masking a reschedule problem | Cleared 2026-11-12, but re-check before every drain — list all pods and filter, since `--field-selector status.phase=Unknown` misses them |
| Jellyfin left on `runtimeClassName: nvidia` | Remove it with the selector, or the pod will not start on drone-03 |
| `vainfo` used as the transcode gate | It under-reports on this hardware (no H.264/HEVC, no `EncSlice`) while VA-API actually works — gate on a real ffmpeg transcode instead (0.4) |
| Losing HEVC 10-bit encode | Accepted — Vega 11 cannot do it. Test an HDR title first |
| Vega 11 Vulkan tone-mapping crash (`error 139`) | Leave Vulkan tone-mapping off for 10-bit HDR, or transcode to H.264 |
| Scrypted left on the NVIDIA runtime | Resolved — it runs `-noble-amd` with no runtime class as of 2026-11-12 (0.6), so there is nothing to fail on a node without the toolkit binaries |
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
