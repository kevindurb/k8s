# Off-site backups: CSI snapshots → restic → Backblaze B2

Status: **planned (2026-10-30)**. Nothing in this document is applied yet.

The cluster has local ZFS snapshots (sanoid) but no off-site copy of anything. A pool failure, a `zfs destroy`, or a fat-fingered `rm -rf` in qbittorrent takes every stateful app with it. This document plans a single backup system that covers every volume on `zfs-generic-nvmeof-csi`, produces point-in-time consistent copies without stopping or quiescing applications, and stores them client-side encrypted in B2.

## Goals

- Every CSI-backed PVC gets a nightly off-site backup.
- The copy is **crash-consistent**: taken from an atomic snapshot, never from a live, written-to filesystem.
- No database dumps, no maintenance windows, no application downtime. (Decided 2026-10-30: snapshots replace dumps entirely.)
- Restic encrypts on the client; B2 receives ciphertext only.
- One restore runbook that works for every app.
- An alert fires if a backup silently stops happening.

## Non-goals

- The `nas-media` share (7.9 TB of `/media` on static NFS PVs). Not snapshottable, not worth $55/month, and re-downloadable. sanoid already snapshots `rust/media` locally.
- Point-in-time recovery (WAL archiving). Retention is nightly, not per-second.
- Ransomware-proof immutability. Could be added later with B2 Object Lock at the cost of breaking `restic prune`.
- Replacing sanoid. Local snapshots stay as they are and remain the fast "oops" recovery path.

## What already exists

Most of the storage layer is done, which is why this is a small change:

| Piece | Where | State |
| --- | --- | --- |
| `VolumeSnapshotClass` `zfs-generic-nvmeof-csi` | `infrastructure/democratic-csi/app.yml` (`volumeSnapshotClasses`) | exists, driver `org.democratic-csi.nvmeof` |
| `csi-snapshotter` sidecar + snapshot CRDs | `snapshot-controller` in `kube-system` | running |
| Detached snapshot zvols | `driver-config.yml`: `detachedSnapshotsDatasetParentName: rust/k8s/snapshots` | configured |
| Local snapshots | `ansible/roles/nas_zfs/files/sanoid.conf`: `rust/k8s/volumes` hourly 24 / daily 14 / weekly 4; `rust/media` hourly 36 / daily 30 / weekly 8 / monthly 6 | configured |

The `VolumeSnapshotClass` has been in git since the democratic-csi migration, so nothing needs to change in `infrastructure/democratic-csi`. What is missing is the thing that *drives* snapshots into a restic repository.

## Why snapshots instead of dumps

Restic reading a live PVC through a mounted volume is not a snapshot: it walks files over minutes while the application keeps writing. The result is a set of files from different moments, which is a state the filesystem was never in — Postgres finds an inconsistent `pg_control`, and you discover it during the restore.

A zvol snapshot is instantaneous copy-on-write. The captured ext4 image is exactly a crash state, which ext4 and every supported database are designed to recover from. Restic then reads that frozen image, so it is irrelevant how long the read takes.

Every volume in scope is `fsType: ext4` (`storageClasses[].parameters` in the democratic-csi app), so journal replay on restore is the only recovery step needed above the application's own crash recovery.

## Architecture

```
app writes to PVC
        │  (never stopped)
        ▼
VolumeSnapshot (instant, CoW)          ← zfs snapshot of the zvol
        ▼
temp PVC cloned from snapshot          ← democratic-csi clones + exports over NVMe-oF
        ▼
restic mover pod (VolSync)             ← reads a frozen filesystem
        ▼
AES-256-CTR + Poly1305-AES, client-side
        ▼
B2 bucket /<namespace>                 ← ciphertext only
```

The snapshot and the temp PVC are deleted after each run. Durability lives entirely in the restic repository; the snapshot exists only to freeze the filesystem for the duration of the read.

[VolSync](https://volsync.readthedocs.io/) (`backube/volsync` Helm chart) drives this. Its restic mover has `copyMethod: Snapshot` plus `volumeSnapshotClassName`, retention (`retain.hourly/daily/weekly/monthly/yearly`), `pruneIntervalDays`, and a `ReplicationDestination` for restores.

K8up was considered and rejected: it mounts live PVCs and has no CSI snapshot support (its `Snapshot` CRD is restic-snapshot metadata, not a `VolumeSnapshot`). It would have reintroduced the torn-copy problem and required dumps anyway.

## Scope

44 PVCs use `zfs-generic-nvmeof-csi`. The other 13 are static NFS PVs for the media share — `*-nas-media`, `dufs-nas`, `romm-library`, `transcoding/nas-media` — all backed by `192.168.42.24:/media`.

**Included** (41 objects, one `ReplicationSource` per PVC):

| Namespace | Volumes |
| --- | --- |
| `immich` | `immich-postgres-volume`, `immich-data` |
| `ente` | `ente-postgres-volume`, `ente-garage-volume` |
| `romm` | `romm-mariadb-volume`, `romm-config`, `romm-assets`, `romm-launchbox`, `romm-resources` |
| `audiobookshelf` | `config`, `metadata`, `books`, `audiobooks`, `podcasts` |
| `jellyfin` | `jellyfin-config-pvc` |
| `home-assistant` | `home-assistant-volume` |
| `syncthing` | `syncthing-volume` |
| `miniflux` | `miniflux-postgres-volume` |
| `navidrome` | `navidrome-data` |
| `minecraft` | `minecraft-data`, `data` |
| `qbittorrent` | `qbittorrent-config`, `qbittorrent-ts-state` |
| `radarr` / `sonarr` | `radarr-volume`, `sonarr-volume` |
| `calibre` / `calibre-web` | `calibre-config`, `calibre-web-config` |
| `gatus` | `gatus-app-volume` |
| `golink` | `golink-volume` |
| `linkding` | `linkding-data` |
| `donetick` | `donetick-data` |
| `pokesim` | `pokesim-data` |
| `f1timing` | `f1timing-data` |
| `omada` | `omada-volume` |
| `scrypted` | `scrypted-volume` |
| `semaphore` | `semaphore-data` |
| `pocket-id` | `pocket-id-data` |
| `zigbee2mqtt` | `zigbee2mqtt-app-volume` |
| `mosquitto` | `mosquitto-app-volume` |
| `consignment-app` | `consignment-app-data` |
| `alertmanager` | `alertmanager-app-volume` |

**Excluded on purpose:**

| Volume | Why |
| --- | --- |
| `immich-machine-learning-cache` | regenerable model cache |
| `romm-redis-data` | redis, rebuilt from mariadb |
| `prometheus-app-volume` | 4.8 GB of graphs; Prometheus' own snapshot API is the right tool if this is ever wanted |
| all `*-nas-media`, `dufs-nas` | NFS, out of scope (see non-goals) |

## Design decisions to verify in Phase 0

Three things are not certain until tested. Each has a fallback, so none of them block the design.

1. **Clone-from-snapshot over NVMe-oF.** VolSync provisions a temp PVC from the `VolumeSnapshot`, so democratic-csi must clone the zvol and export it as a new NVMe-oF namespace on the mover's node. The driver supports it, but the cluster uses `shareStrategy: nvmetCli` with `nr-io-queues=1` (workaround for the loopback node on kernel 7.2.5) — worth proving before writing 40 manifests.
2. **Restic snapshot scoping in a shared repo.** The design gives each namespace one restic repo (`b2:bucket:/<namespace>`) and one Secret, shared by that namespace's sources. If VolSync does not pass a per-source `--host`/tag to restic, one source's `retain` could `forget` another's snapshots. Fallback: one Secret (and repo path) per PVC, at the cost of ~40 secrets.
3. **Mover UID/GID.** The mover must be able to read the volume. Baseline PSS forbids `privileged: true`, so the `volsync.backube/privileged-movers` annotation is only an option in the namespaces already at `privileged`. Verify ownership with `ls -ln` on a debug mount, then set `moverSecurityContext` to match.

## Repo layout

```
infrastructure/volsync/
  app.yml                  # Argo Application: Helm chart backube/volsync
  kustomization.yml
apps/<app>/
  backup.yml               # ReplicationSource + SealedSecret for the restic repo
```

The operator lives under `infrastructure/` as one more Argo app. Each app owns the backup of its own PVC, next to the PVC's other manifests, and its `kustomization.yml` gains `./backup.yml`. This touches ~29 app directories but keeps the "app owns its resources" convention and means the backup's namespace, `namePrefix` and sealed-secret naming follow the existing rules automatically.

The alternative — one `infrastructure/backups/` kustomization holding all 41 `ReplicationSource` objects with explicit `metadata.namespace` — centralizes the scope but breaks the convention and bypasses `namePrefix`. Not chosen.

A `just backup-add <namespace> <pvc>` scaffolding helper is worth adding once the shape is settled.

## Manifests

### Operator

`infrastructure/volsync/app.yml`, mirroring the democratic-csi app (Helm source + pinned chart version, Renovate bumps it):

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: volsync
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://backube.github.io/helm-charts/
      targetRevision: 0.17.0        # latest chart as of 2026-10-30; Renovate bumps this
      chart: volsync
  destination:
    server: https://kubernetes.default.svc
    namespace: volsync-system
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
    automated:
      enabled: true
      prune: false
      selfHeal: true
```

The operator is confined to `volsync-system`; the mover jobs run in the *application* namespace and must satisfy that namespace's Pod Security level. They do not need privileged mode, so `baseline` namespaces work as long as `moverSecurityContext` matches the volume owner (see below). Scraping reuses the existing `kubernetes-service-endpoints` job in `infrastructure/prometheus/config/prometheus.yml`, which selects on `prometheus.io/scrape: "true"` — add that annotation to the chart's metrics Service (via chart values if supported, otherwise as a kustomize patch on the Service).

### Restic repository secret

Per namespace, sealed with **cluster-wide** scope so the same ciphertext can be applied everywhere, and named so that `namePrefix` produces the reference used in `backup.yml`:

```sh
openssl rand -base64 32 > /tmp/restic-password   # 256-bit repo password

kubectl create secret generic restic-config \
  --from-literal=RESTIC_PASSWORD="$(cat /tmp/restic-password)" \
  --from-literal=RESTIC_REPOSITORY='b2:beaver-k8s-backup:miniflux' \
  --from-literal=AWS_ACCESS_KEY_ID='<bucket-scoped keyID>' \
  --from-literal=AWS_SECRET_ACCESS_KEY='<bucket-scoped applicationKey>' \
  --dry-run=client -o yaml \
  | kubeseal --scope cluster-wide \
      --controller-namespace kube-system --controller-name sealed-secrets-controller \
      -o yaml > apps/miniflux/backup-sealed-secret.yml
```

`RESTIC_REPOSITORY` = `b2:<bucket>:<path>`, path = namespace. The B2 key is bucket-scoped with only `listFiles, readFiles, writeFiles, deleteFiles`; the account master key is never used. After `namePrefix`, the secret above is `miniflux-restic-config` — that is the name the `ReplicationSource` references.

### ReplicationSource

One per PVC, e.g. `apps/miniflux/backup.yml`:

```yaml
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: backup
spec:
  sourcePVC: miniflux-postgres-volume
  trigger:
    schedule: "17 3 * * *"        # off-peak, staggered per app (see Risks)
  restic:
    repository: miniflux-restic-config   # the unsealed Secret, i.e. post-namePrefix
    copyMethod: Snapshot
    volumeSnapshotClassName: zfs-generic-nvmeof-csi
    retain:
      hourly: 0
      daily: 7
      weekly: 4
      monthly: 6
      yearly: 0
    pruneIntervalDays: 7          # only one source per namespace may prune
    moverSecurityContext:         # matches the volume owner; see table below
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
    exclude:
      caches: true                # skip CACHEDIR.TAG directories
```

Both names are written **post-`namePrefix`**: kustomize's name-reference transformer does not know that `spec.sourcePVC` and `spec.restic.repository` are references, so it will not rewrite them. Same trap as `SealedSecret` references in `docs/secrets.md`. Verify with `kustomize build apps/<app> | grep -E 'sourcePVC|repository:'`.

### moverSecurityContext per app

Checked against the running Deployments on 2026-10-30:

| UID | Apps |
| --- | --- |
| `1000:1000` | immich (both), ente (both), romm, audiobookshelf, jellyfin (`fsGroup` only; container uid 1000), home-assistant, syncthing, miniflux, navidrome, minecraft, qbittorrent, radarr, sonarr, gatus, golink, linkding, donetick, pokesim, f1timing, semaphore, pocket-id, mosquitto, consignment-app, alertmanager |
| needs a check | `calibre`, `calibre-web`, `omada`, `scrypted` — no explicit `securityContext`, so the image default applies. Verify with `ls -ln` before setting. |
| `immich-postgres-volume` | uid 1000, **no `fsGroup`** in the Deployment; the mover still needs `runAsUser: 1000` at minimum |

If a volume turns out to be root-owned, the options in order are: set the mover UID to the owner, or add the `volsync.backube/privileged-movers: "true"` namespace annotation in `jellyfin`, `home-assistant` or `syncthing` (already `privileged`), which is not available in `baseline` namespaces.

### Alerting

`infrastructure/prometheus/config/rules/rules.yml`, new group. VolSync exposes per-object metrics with `obj_name`, `obj_namespace`, `role` labels; both gauges require a `trigger.schedule`, which every source has:

```yaml
  - name: VolSync
    rules:
      - alert: VolSyncBackupOutOfSync
        expr: volsync_volume_out_of_sync{role="source"} == 1
        for: 6h
        labels:
          severity: warning
        annotations:
          summary: Volume backup out of sync
          description: '{{ $labels.obj_namespace }}/{{ $labels.obj_name }} has not completed a backup on schedule.'

      - alert: VolSyncBackupStalled
        expr: increase(volsync_sync_duration_seconds_count{role="source"}[26h]) < 1
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: No backups in 26h
          description: '{{ $labels.obj_namespace }}/{{ $labels.obj_name }} has not run in 26 hours.'

      - alert: VolSyncMissedIntervals
        expr: increase(volsync_missed_intervals_total{role="source"}[24h]) > 0
        labels:
          severity: info
        annotations:
          summary: Backups are overrunning their schedule
          description: '{{ $labels.obj_namespace }}/{{ $labels.obj_name }} is taking longer than the gap between runs.'
```

Alertmanager already routes everything except `Watchdog` to email, so no routing change is needed.

## Encryption

Encryption is entirely in restic, not VolSync, not B2, and there is no configuration in which plaintext is uploaded.

- **Cipher.** AES-256 in CTR mode with a Poly1305-AES MAC per blob. Repository master keys are derived from the password with scrypt and stored encrypted in the repo. Repository format v2 additionally zstd-compresses before encrypting.
- **What is encrypted.** File contents, **file names and paths**, snapshot metadata (tags, host, paths), and the index. Deduplication is content-defined, so identical blocks across apps collapse into one stored object.
- **What B2 can see.** Opaque blobs, their approximate sizes, upload timestamps and object counts. Not file names, not directory structure, not contents. Size and timing leakage is inherent to any encrypted deduplicating backup.
- **In transit.** HTTPS to B2 (TLS 1.2+), via the `b2:` backend in restic.
- **At rest in B2.** Two independent layers: restic's ciphertext is what is stored, and B2 additionally applies SSE-B2 (AES-256) server-side. Enable SSE-B2 per bucket as defense in depth; it is not load-bearing.
- **In the cluster.** The temp PVC cloned from the snapshot is plain ext4 on ZFS, same exposure as the application's own volume today. This design does not widen the plaintext footprint.
- **Credentials.** Two separate secrets:
  - `RESTIC_PASSWORD`: 32 random bytes, sealed cluster-wide, **plus an offline copy** (password manager and a printed copy). Without it the repository is unrecoverable. This is the single largest operational risk in the whole design.
  - B2 application key: scoped to the one bucket with `listFiles, readFiles, writeFiles, deleteFiles`. `deleteFiles` is required for `prune`; the account master key is never used.
- **Rotation.** restic supports multiple keys: `restic key add` a new password, then `restic key remove` the old one. No re-upload required. Rotate the B2 application key independently in the B2 console and reseal.

Optional hardening, deliberately deferred: B2 Object Lock (governance mode) makes objects undeletable for N days and stops a compromised cluster from wiping backups — but it also breaks `prune` until retention expires. Do not enable it without also reworking retention.

## Phases

**Phase 0 — prove the path (no manifests committed).** Snapshot `miniflux-postgres-volume` (1 Gi, mostly empty), create a PVC from the snapshot, mount it, run `fsck -n`, count files. Then repeat against `immich-postgres-volume` while immich is writing, and confirm Postgres starts on the restored copy. This settles decision 1; decision 2 (shared-repo pruning) is settled as soon as a namespace gets its second source.

**Phase 1 — one namespace end to end.** `infrastructure/volsync` + B2 bucket + bucket-scoped key + `apps/miniflux/backup.yml` and its sealed secret. Acceptance: one successful run visible in `kubectl -n miniflux get replicationsource backup -o yaml` (`.status.lastSyncTime`, `.status.conditions`), a second run that only uploads new chunks, and a full restore drill into a scratch PVC (see runbook).

**Phase 2 — roll out.** The remaining 40 sources, in this order: small config volumes first (calibre, gatus, golink, linkding, donetick, mosquitto, zigbee2mqtt, pocket-id), then databases (ente, romm, immich), then the big ones (jellyfin 17 GB, syncthing 0.8 GB, home-assistant 0.7 GB). Resolve the UID unknowns before each app lands.

**Phase 3 — monitoring and retention.** Prometheus rule group, `prometheus.io/scrape` annotation on the metrics Service, confirm `volsync_*` appears in Prometheus, tune retention after two weeks of real data (the 6-month monthly tier is the one to reconsider if B2 grows).

**Phase 4 — optional.** Nothing in this plan keeps more than a few minutes of local snapshots (VolSync deletes them after each run). sanoid already covers local rollback for `rust/k8s/volumes` at hourly/daily/weekly, so this is only worth revisiting if the sanoid schedule turns out not to be applied on drone-04.

## Restore runbook

Preferred path is declaring a `ReplicationDestination` — it recreates the restic repo, restores the most recent snapshot into a new PVC, and is declarative like everything else. The tool-agnostic fallback, which is what to use when the cluster itself is the problem:

1. Scale the app down: `kubectl -n <ns> scale deploy/<app> --replicas=0`.
2. Run a one-off pod with the restic image, the namespace's restic Secret (e.g. `miniflux-restic-config`) and a scratch PVC of at least the original size.
3. `restic snapshots` → pick the ID. Confirm it is the one you want by path and host.
4. `restic restore <id> --target /restore --include /path/inside/volume`.
5. Verify: `fsck -n`, then start the app once against the scratch PVC (patch `claimName` via kustomize) and confirm it recovers.
6. Move data into the original claim, or delete the original PVC and reclaim the restored one — the latter needs a git change because claim names are fixed.
7. Delete the scratch PVC and the temporary pod.

Almost every app runs as uid 1000 (see the table above), and the mover/restore jobs run as the same uid, so restic restores files with the ownership the applications expect without needing root.

A `just restore <ns> <pvc>` wrapper around steps 2–4 is worth writing once the first restore has been done by hand.

## Definition of done

- All 41 sources show `.status.lastSyncTime` younger than 26h for seven consecutive days.
- `restic check` (run from a debug pod against one namespace repo) passes.
- A restore drill has been completed for one database volume (miniflux) and one plain-files volume (gatus), including starting the app against the restored data.
- Pausing one source (`spec.paused: true`) triggers `VolSyncBackupOutOfSync`/`VolSyncBackupStalled` within the expected window, and unpausing clears it.
- No orphaned `VolumeSnapshot` or `volsync-*` PVCs remain after a week (`kubectl get volumesnapshot,pvc -A | grep -i volsync`).
- The repo password and the B2 application key exist in two offline locations.

## Retention and cost

| | |
| --- | --- |
| Stored after the first full seed | ~25–30 GB (measured usage, not PVC requests) |
| Nightly growth | 100–500 MB (immich photos, romm, HA recorder) |
| B2 price | $6.95/TB/month |
| Monthly cost | **~$0.20**, including the 7d/4w/6m retention tiers |
| Restore egress | free (B2 allows 3× average stored per month; a full restore is ~1×) |

Snapshot space on `rust` is transient and copy-on-write; the pool has ~3.1 TB free, and no snapshot lives longer than one backup run.

## Risks

- **Repository password loss is unrecoverable.** Offline copy is mandatory. This is the only unmitigated failure mode in the design.
- **One source per namespace may prune.** With several sources sharing a namespace repo, `pruneIntervalDays` must be set on exactly one, or restic's `forget` may race. Resolved definitively in Phase 0 (see decision 2).
- **Effectively serialized movers.** The controller waits for each mover job before starting the next source, so the fleet runs in sequence. ~30 GB at 1 GbE plus per-file overhead is roughly 10–30 minutes total, but jellyfin alone is 17 GB. Stagger schedules (different minute offsets) rather than firing everything at 03:00.
- **Cross-volume inconsistency.** immich's postgres and its uploads snapshot seconds apart; a restore can leave orphaned thumbnails or a row pointing at a missing asset. Not corruption, and immich regenerates thumbnails. `VolumeGroupSnapshot` would fix it and democratic-csi does not implement it.
- **Failed runs leave objects behind.** A mover that dies may leave a `VolumeSnapshot`/temp PVC. Both are labelled by VolSync; a small `kubectl delete` sweep or a periodic reaper is worth adding if this happens in practice.
- **Baseline PSS blocks privileged movers.** Handled by `moverSecurityContext`, but a future app that writes as root will need an explicit decision.
- **Media remains outside the design.** Accidental deletion of `/media` is covered only by sanoid's local snapshots. That is the realistic loss case and it is local-only.
- **B2 is a third party with the ciphertext.** Acceptable because restic's encryption does not depend on B2, but the bucket is single-vendor. A `restic copy` to a second target can be added later without changing the sources.
