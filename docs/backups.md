# Off-site backups: zrepl snapshots → restic → B2

Status: **design only — nothing here is built.** This document replaces the
2026-10-30 VolSync/CSI-snapshot plan, which targeted the retired
`zfs-generic-nvmeof-csi` driver and was never applied. The storage layer it was
written for no longer exists; see `storage-placement.md`.

The cluster still has **no off-site backup**. A pool failure, a `zfs destroy`
fat-finger, or ransomware takes every stateful app with it. The mesh replicates
volumes between three nodes in the same house — that is not a backup.

## What exists today (2026-11-23)

| Piece | Where | State |
| --- | --- | --- |
| `k8s/volumes` (per node) | `k8s/volumes` on drone-01/02/03 | OpenEBS LocalPV-ZFS zvols, ext4 |
| Replication | zrepl: `source` + two `pull` jobs per node, 15-min snapshots in `k8s/volumes`, replicas in `k8s/replicas` | running, alerted |
| Deletes/exports | `rust/media` on drone-04 (NFS `/media`, incl. `immich/`) | sanoid, hourly 36 / daily 30 / weekly 8 / monthly 6 |
| Immich photos | `/media/immich` on `rust/media`, ~318 GiB, PV `immich-nas` | NFS; **not** covered by the mesh |

## Design

restic on each node, reading **ZFS snapshots directly** — no in-cluster movers,
no PVCs cloned by a controller, no VolSync.

```
per node (systemd timer, every 6h):
  for each zvol in k8s/volumes (locally):
      clone the newest zrepl snapshot to k8s/backup-scratch/<name>@<snap>
      zfs mount the clone → /run/restic-snap
      restic backup /run/restic-snap --tag <node> --tag k8s/volumes
      umount, destroy the clone
drift watchdog: textfile metric → node-exporter → Alertmanager

drone-04 additionally:
  rust/media @ latest sanoid snapshot → mount → restic backup, filtered to
  immich/ only (the rest of /media is re-downloadable; see Non-goals)
```

Why a clone+mount per zvol and not a filesystem tree walk of the live dataset:
restic needs a consistent file tree; a zvol snapshot is a block device, not a
tree, and reading a live zvol mid-write is exactly the torn-copy failure mode
this design exists to avoid. The clone is cheap (CoW), independent of the
source, and is destroyed in the same run. Snapshots are the same mechanism the
mesh already relies on, so there is one snapshot discipline for replication
*and* backup.

Why not back up from `k8s/replicas` on a peer: it works, but it makes backups
depend on mesh health and doubles the read traffic of every replication step.
Backing up each node's own live data keeps the blast radius small and the
runbook boring. The downside (backing up a possibly-corrupt replica would be
avoided anyway, since the clone source is a snapshot of the *primary*) is nil.

### Repository layout

One restic repository per node — `b2:<bucket>:<hostname>` — over a single
bucket with one B2 application key scoped to that bucket
(`listFiles, readFiles, writeFiles, deleteFiles`). Per-node repos keep `restic
forget --prune` independent (a buggy prune on one node can't reach another
node's history) at the cost of per-node lock contention, which does not exist
here. All nodes share one repo password.

Credentials live in `/etc/restic/env` (root-only, `0600`), rendered by the
`node_zfs` ansible role from Ansible Vault variables — the repo password and
the B2 app key/secret. The password also goes offline (password manager +
printout); without it the repositories are unrecoverable. Ansible Vault keeps
the *repo* recoverable but not the password's offline copy.

### Retention

`restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune`, run at
the end of each backup job. Roughly: 17 snapshots per node plus immich history
on drone-04. Expected size is small (restic dedupes across snapshots of the
same volumes; the mesh already keeps ~30 days of local snapshot history, and
this is the *same* data).

### What about restic-vs-zrepl divergence?

The backup job uses its own clone of the *latest* snapshot at run time — it
does not hold references that would block zrepl's `keep_sender` pruning
(zrepl's grid is `not_replicated` + time-based; a backup clone is a temporary
dataset destroyed within minutes, and it holds no snapshot pins afterwards).
If a backup run is interrupted, the scratch dataset is left behind; the next
run (or a janitor in the same script) destroys `k8s/backup-scratch/*` older
than 24 h before cloning again.

## Scope

**In:** every zvol in `k8s/volumes` on the three app nodes (same data the mesh
already carries); `/media/immich` on drone-04 via sanoid snapshots.

**Out:**
- the rest of `/media` (re-downloadable: *arr libraries, etc.)
- node OS images (rebuilt by CI; nothing stateful there)
- bulk-restore drills beyond one node per quarter (see Restore)

**Not covered / explicitly absent:** database-consistent dumps. As with every
snapshot-based approach, databases are backed up crash-consistent; Postgres et
al. replay their WALs on restore. If that ever stops being true, add `pg_dump`
as an app-level hook — don't rewrite this design.

## Implementation (when this gets built)

1. Bucket + scoped key; vault variables; `node_zfs` renders `/etc/restic/env`
   (or a dedicated `node_backups` role — don't bolt it onto the zfs role if it
   grows a second consumer).
2. `restic init` per node; `restic check` after first write.
3. `k8s-backup.service` (Type=oneshot) + `.timer` (every 6h on a per-node
   offset), `Nice=19`, `IOSchedulingClass=idle` — it must never slow the apps.
4. Drone-04: same shape against `rust/media@latest` filtered to `immich/`.
5. Prometheus: node-exporter textfile metric (`restic_backup_last_success_timestamp_seconds`,
   `restic_backup_last_result`), and a `ResticBackupFailed` /
   `ResticBackupStale` alert; route to Alertmanager as usual.
6. First restore drill before calling it done: restore `miniflux-postgres`
   volume into a scratch zvol on a spare node, fsck, start the app against it.

## Restore runbook (file level)

```sh
# on any node with the restic env
set -a; . /etc/restic/env; set +a
restic snapshots --tag drone-02 --path /restore/pvc-xxxx | tail
restic restore <id> --target /restore/<pvc> --include /run/restic-snap
```

For a **whole-volume** loss (or a node gone):

1. Recreate (or repurpose) a zvol of the same size: `zfs clone` from a surviving
   `k8s/replicas` copy (`docs/storage-placement.md`, promotion runbook), **or**
   create a new `zfs-local` PVC on another node and restore files into it via
   the file-level procedure with a helper pod mounting it.
2. For immich: clone the chosen sanoid snapshot to a scratch dataset, mount,
   `rsync -a` back into `/media/immich`, verify, destroy the scratch.
3. Verify app health (gatus) before retiring the incident.

## Open questions

- **B2 object lock / immutability**: worth it? Prevents a compromised node from
  deleting history, but blocks `forget --prune` until retention expires. Decide
  before first real data lands.
- **zrepl vs. backup snapshot selection**: back up the exact snapshot zrepl
  just sent (cheap, couples jobs) or an independent `@backup-<ts>` snapshot
  (cleaner failure isolation, one extra snapshot per run)? Lean: independent —
  "latest zrepl snapshot" has a race with `keep_sender` pruning at the margin.
- **Prune cadence**: weekly prune inside the backup job vs. a separate weekly
  timer. Inside is simpler; separate is easier to pause during an incident.
- Whether to include `k8s/scratch`-style datasets if a churn tier ever appears.
- **restic version pinning** in the image and renovate wiring (it is a Go
  static binary; pin like zrepl).

## Non-negotiables if this ships

- Offline copy of the repo password. Lose it, lose everything.
- `restic check` quarterly (`--read-data-subset=5%` if `check` is too heavy).
- A failed prune must page — silent history growth is the failure mode that
  looks like success.
