# Migrating democratic-csi: `rust/k8s/volumes` → `tank/k8s/volumes`

Status: researched 2026-11-03. Not started.
Target pool: `tank` — 2× 500 GB NVMe mirror on drone-04, ~465 GiB usable.
Source: `rust/k8s/volumes` — 43 zvols, **496 GiB used**, 1,086 GiB declared, on the 12 TB HDD mirror exported over NVMe-oF/TCP.

---

## Verdict

**Doable.** Two things make it much easier than the Longhorn migration:

1. **`volumeHandle` does not encode the pool.** Every PV's handle is just `pvc-<uuid>`, and
   `volumeAttributes` carries only `nqn`, `nsid`, `transports`. The backing path
   (`/dev/zvol/<pool>/<datasetParentName>/<volumeHandle>`) is derived at attach time from the
   **driver config**, not stored in the PV. So the pool is not baked into any PV object.

2. **No clones, no driver-managed snapshots.** Verified: `origin` is `-` on all 45 zvols, and
   `rust/k8s/snapshots` holds 0 snapshots. The `zfs send | recv` hazard from upstream issue #391
   (clone bookkeeping, `zfs receive -F` refusing) does not apply.

And one thing that makes it harder:

3. **One driver deployment = one `datasetParentName`, and it cannot be overridden per
   StorageClass.** Confirmed by the maintainer in [issue #446](https://github.com/democratic-csi/democratic-csi/issues/446):
   > "Your assessment is correct … it was decided against such configurations … `server+parent_dataset`
   > defines volume identity, and changing the way it works would be tricky."

   So you cannot point a new StorageClass at `tank` and migrate app by app. The cutover is
   **all-or-nothing at the driver level.**

---

## The blocker: capacity

`immich-data` alone is 600 GiB declared / **317 GiB used**. Everything else is 180 GiB.

| | used | declared |
|---|---|---|
| All 45 ZFS PVCs | 497 GiB | 1,296 GiB |
| minus `immich/immich-data` | **180 GiB** | 696 GiB |
| `tank` usable | — | **465 GiB** |

**497 GiB does not fit in 465 GiB. 180 GiB fits comfortably (39%).**

⇒ Moving `immich`'s pictures to the NFS media mount on `rust` is a **prerequisite**, not an
optimisation. Good news: you already planned exactly that.

---

## Two paths

### Path A — cutover the single deployment (recommended)

Interrupted once, for the whole cluster. No new driver, no new StorageClass, **zero PVC manifest
changes**, `storageClassName: zfs-generic-nvmeof-csi` stays put. Blast radius: every app with a ZFS
PVC restarts together.

Downtime is dominated by app restarts and waiting for detach, not by the copy. ~180 GiB of local
pool-to-pool send at HDD read speeds is roughly 15–20 min; the data can be seeded *before* the
outage and only an incremental sent inside it.

### Path B — second deployment, app-by-app granularity

Granularity, but pays for it. A second Helm release with a distinct `csiDriver.name`
(e.g. `org.democratic-csi.nvme`), `instance_id: tank`, and
`datasetParentName: tank/k8s/volumes`, plus a new StorageClass. Because `spec.csi.driver` on a PV is
immutable, every migrated volume needs a **new PV object**: create temp PVC on the new class →
`CopyVolumeData` rsync → set new PV `Retain` → delete temp PVC → re-point the app's claim →
`DeleteVolume`. That is the Longhorn runbook in `docs/longhorn-to-democratic-csi.md` repeated 42 times.

Extra risks Path B introduces that Path A does not:
- Two node DaemonSets × 4 nodes and two controllers running permanently.
- **Both deployments write the same `/etc/nvmet/config.json`.** democratic-csi's nvmetCli share
  strategy keeps nvmet state in that one file (default `configPath`, unset in your config). Two
  controllers doing read-modify-write on it can clobber each other's subsystems. Untested, and the
  reason I would not choose this path.
- During dual-run, **`nvmetcli clear` must never be run** — it tears down the exports for *both*
  pools. Your `20-shutdown-order.conf` drop-in runs it on shutdown, which is fine, but any manual
  clear is now a two-pool outage.

If you want Path B, verify the shared-config question in a throwaway namespace first, or use
upstream's `contrib/pv-updater.sh`.

---

## Prerequisites

- [ ] **`immich` pictures moved to the NFS media mount** and `immich/immich-data` deleted.
      (600 GiB declared, 317 GiB used freed. `immich-server` is on drone-02, so it starts reading
      over 1 GbE — do this *with* the 10GbE upgrade if you can.)
- [ ] **Second 500 GB NVMe physically installed.** Only `nvme0n1` exists today (`01:00.0`, the
      CPU-attached M.2). One more M.2 slot needed on the B450M Pro4.
- [ ] **L2ARC removed** so `nvme0n1` is free — see Phase 1.
- [ ] `zpool list rust` shows ≥2 TB free (it does: 2.07 TB).

---

## Phase 0 — reclaim dead weight (zero risk, no downtime)

```bash
# 158 GB of orphaned Longhorn leftovers. 2 empty dirs (backup, backupstore),
# 0 of 69 PVs reference it. Confirmed 2026-11-03.
zfs destroy rust/longhorn
```

Pool goes 80% → ~78.5%. Also drop the now-dead `[rust/longhorn]` stanza from
`ansible/roles/nas_zfs/files/sanoid.conf`, and note that `/var/mnt/rust/longhorn` is currently in
`/etc/exports.d/zfs.exports` — it disappears with the dataset.

**Remove the two orphan zvols** (both `Released`, both claimed by the deleted `tsidp` app):

```bash
kubectl get pv | grep Released          # pvc-547e4f81… and pvc-80a0a381…
zfs destroy -r rust/k8s/volumes/pvc-547e4f81-f286-46be-afc3-bd33f6b9eb93
zfs destroy -r rust/k8s/volumes/pvc-80a0a381-5d7e-4b7f-9c4c-aedbc4725c47
kubectl delete pv pvc-547e4f81-f286-46be-afc3-bd33f6b9eb93 pvc-80a0a381-5d7e-4b7f-9c4c-aedbc4725c47
```

Both are sanoid-snapshotted (`pvc-547e4f81…` had 42), so without `-r` the delete fails with
`filesystem has dependent snapshots` — the documented gotcha. Leave `tank` with exactly 42 zvols
after the migration, not 45.

## Phase 1 — retire the L2ARC and build `tank`

```bash
zpool remove rust nvme0n1        # reversible, frees the drive
```

Then, with the second drive installed:

```bash
zpool create -o ashift=12 -O compression=lz4 -O atime=off \
  tank mirror /dev/nvme0n1 /dev/nvme1n1
zfs create tank/k8s
zfs create tank/k8s/volumes
zfs create tank/k8s/snapshots
```

Then raise the ARC that the L2ARC was eating — `zfs_arc_max=8589934592` in
`/etc/modprobe.d/zfs.conf` was sized for an 8 GiB ceiling that 1.84 GB of L2ARC index was sharing.
drone-04 is tainted `dedicated=storage:NoSchedule`, so ZFS gets the RAM; 10–12 GiB is reasonable
with 15 GiB total. Tune live via `/sys/module/zfs/parameters/zfs_arc_max`, then persist in
`bootc/overlay/etc/modprobe.d/zfs.conf`.

## Phase 2 — seed the data (apps still running)

Crash-consistent zvol snapshots are fine here; ext4 journal replay covers the copy. The final
incremental in Phase 3 is what has to be clean.

```bash
# On drone-04. Snapshot every source zvol, then send|recv into the same uuid name.
for z in $(zfs list -H -o name -d1 rust/k8s/volumes | grep pvc-); do
  u=${z##*/}
  zfs snapshot "$z@migrate"
  zfs send "$z@migrate" | zfs recv -u tank/k8s/volumes/"$u"   # -u: don't mount, keep @migrate
done
```

`zfs recv` preserves `volsize` and `volblocksize=16K`, and your zvols are **thin** —
`zvolEnableReservation: false` in the driver config, and `refreservation` is `none`. So 1,296 GiB
of declared capacity lands on a 465 GiB pool without failing.

> **Trap:** do **not** flip `zvolEnableReservation: true` in the new pool's config. It would try to
> reserve 696 GiB on a 465 GiB pool and every create would fail.

Sanity check before continuing:

```bash
zfs list -H -o name -d1 tank/k8s/volumes | grep -c pvc-      # expect 42
zfs get -H -o value volblocksize -r tank/k8s/volumes | sort -u  # expect 16K
```

## Phase 3 — cutover (downtime window)

```bash
# 1. Freeze GitOps. Otherwise Argo recreates/rolls things mid-flight.
kubectl -n argocd patch app <each-app> --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
#    (or scale the apps down explicitly; the point is nothing must restart on its own)

# 2. Stop every writer. All pods mounting a zfs-generic-nvmeof-csi PVC.
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim) |
  "\(.metadata.namespace) \(.metadata.name)"'     # build the list from this

# 3. Wait until every export is detached — do NOT skip this.
zfs list -H -o name -r rust/k8s/volumes | while read z; do
  zfs get -H -o value volmode "$z"; done
#    and confirm no initiator still has a controller open:
nvme list-subsys | grep -c pvc-            # on drone-01..03 and drone-04, expect 0

# 4. Final incremental per zvol (now quiesced = consistent)
for z in $(zfs list -H -o name -d1 rust/k8s/volumes | grep pvc-); do
  u=${z##*/}
  zfs snapshot "$z@migrate2"
  zfs send -i @migrate "$z@migrate2" | zfs recv -u tank/k8s/volumes/"$u"
done

# 5. Point the driver at the new pool
#    infrastructure/democratic-csi/driver-config.yml:
#      datasetParentName: tank/k8s/volumes
#      detachedSnapshotsDatasetParentName: tank/k8s/snapshots
just -f infrastructure/democratic-csi/justfile reseal     # regenerates the sealed secret
#    commit + push, let Argo sync the driver-config sealed secret, then:
kubectl -n democratic-csi rollout restart deploy/democratic-csi-controller

# 6. Bring apps back up (re-enable Argo auto-sync or sync each app)
```

The apps come up against the same `volumeHandle`s, so the driver derives
`/dev/zvol/tank/k8s/volumes/pvc-<uuid>`, recreates the nvmet subsystems and NQNs are unchanged.
**No PVC or PV manifest changes at all.**

## Phase 4 — verify

```bash
# backend
zfs list -H -o name -d1 tank/k8s/volumes | grep -c pvc-            # 42
grep -o "/dev/zvol/[^\"]*" /etc/nvmet/config.json | grep -vc "/dev/zvol/tank/"   # 0
grep -o "/dev/zvol/[^\"]*" /etc/nvmet/config.json | wc -l          # 42
cat /sys/kernel/config/nvmet/ports/1/param_mdts                    # 8  <- must survive
nvmetcli save /etc/nvmet/config.json    # persist the *new* paths for boot restore

# cluster
kubectl get pv | grep -vE 'Bound'                                  # nothing unexpected
kubectl -n democratic-csi logs deploy/democratic-csi-controller -c csi-driver --since=15m
gatus / homer green; Argo all Synced/Healthy
```

Then run the smoke test from `.claude/skills/democratic-csi/SKILL.md` (1Gi PVC → write on drone-04 →
read on drone-02 → expand → delete, confirm cleanup) before trusting it.

## Phase 5 — cleanup and docs

- `zfs destroy -r rust/k8s` once you're confident (drops `rust` to ~7.9 TiB used, 27%).
- Add `[tank/k8s/volumes]` to `ansible/roles/nas_zfs/files/sanoid.conf` using `template_volumes`,
  `recursive = yes`, `process_children_only = yes`. Remove `[rust/k8s/volumes]`.
- Update `.claude/skills/democratic-csi/SKILL.md`: backing store, `datasetParentName`, the sanoid
  dataset, and the note that the pool is now a local NVMe mirror rather than the HDD array.
- Write this up at `docs/rust-to-tank-migration.md` alongside `docs/longhorn-to-democratic-csi.md`.

---

## Traps specific to this setup

1. **Blast radius inversion.** The Longhorn migration was one app at a time under Argo with a
   rollback net. This one is 42 volumes and a driver-config change in a single window. Treat it as
   a cluster-wide storage outage and schedule it like the drone-04 reboot runbook says to.

2. **`nvmetcli clear` is now doubly dangerous** if any `rust` subsystems survive into Phase 3 — it
   tears down everything on port 4420.

3. **Boot config will be stale mid-migration.** `/etc/nvmet/config.json` still lists
   `/dev/zvol/rust/…` until `nvmetcli save` in Phase 4. If drone-04 reboots inside the window,
   `nvmet.service` fails to restore those namespaces. **Do not reboot drone-04 between Phase 3
   and Phase 4.** Note the drop-in creates `/var/run/nvmet-config-loaded` on `ExecStartPost`
   regardless, so the driver will *think* the config is loaded even if restoration failed —
   check the journal, not just the flag.

4. **`/usr/etc/nvmet/config.json` is a stale overlay copy** (differs from `/etc/…`). After
   cutover, reconcile it or the next image rebuild will restore old paths.

5. **`MDTS = 8`** is a *port* attribute, so it survives subsystem churn — but re-verify it. If it
   resets to 0, `mkfs.ext4` on the larger zvols fails with `I/O Error … DNR` and pods hang in
   `ContainerCreating`.

6. **Sanoid will block destroys on `tank` too**, same as on `rust`, unless the new stanza uses
   `process_children_only = yes`. Expect `filesystem has dependent snapshots` on any PVC you later
   delete.

7. **Overcommit is now 696 GiB declared on 465 GiB.** Nothing alerts on it — Prometheus and
   zfs-exporter see pool usage, not thin overcommit. Add a `tank` capacity alert at 80%.

8. **drone-04 remains a single point of failure for all storage.** Moving PVCs onto its local NVMe
   makes the pool faster, not more available. Same target host, same NQN, still one machine. The
   mirror protects against drive failure, not host failure.

9. **`?nr-io-queues=1` and the `-EXDEV` loopback workaround follow the pool.** Any latency
   benchmark taken on drone-04 itself is distorted; measure from drone-02 or drone-03 — and with
   the 10GbE upgrade, re-check whether the workaround is still needed (the comment ties it to
   kernel 7.2.5).

10. **`immich` on NFS is slower over 1 GbE than the zvol was.** 317 GiB of library reads across a
    gigabit link on `immich-server`. Do the NFS move *after* the 10GbE upgrade if the timing allows.
