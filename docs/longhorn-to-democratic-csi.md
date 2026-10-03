# Migrate all Longhorn PVCs → democratic-csi (`zfs-generic-nvmeof-csi`)

## Context

democratic-csi went live today (`infrastructure/democratic-csi`, zvols under `rust/k8s/volumes` on drone-04, exported over NVMe-oF TCP, plus snapshot-controller). No PVCs use it yet. All 27 app PVCs are still on `longhorn-replicated`, which keeps 3 replicas on the drone NVMe disks. The goal is to move every one of them to ZFS and then retire Longhorn. NAS-backed static PVs (`*-nas-media`, `dufs-nas`, `storageClassName: ''`) are out of scope.

Things found while exploring that shape the plan:
- **`storageClassName` can't be changed on an existing PVC.** Editing git alone would leave Argo stuck failing to sync. Each PVC has to be deleted and recreated, and the data copied across.
- **Durability changes.** We go from 3 Longhorn replicas spread across nodes to one ZFS mirror on drone-04. If drone-04 is down, every stateful app is down. The Longhorn backups already sit on the same box (`nfs://192.168.42.24:/longhorn` → `rust/longhorn`), so off-box durability doesn't get worse.
- **The `rust` pool is 86% full** (1.43T free). Real Longhorn usage is only about 70 GB, so it fits. ZFS slows down above about 80% full, though, and these volumes become HDD-backed, which matters most for prometheus, postgres and home-assistant.
- democratic-csi node pods run on all 4 drones. Unimatrix nodes are tainted, so they don't matter here.
- sanoid already runs on drone-04 (`ansible/roles/nas_zfs/files/sanoid.conf`) and can take over the snapshot job from Longhorn's RecurringJobs.

## Step 0 – Save this plan into the repo

Copy this plan to `docs/longhorn-to-democratic-csi.md`, next to `docs/secrets.md`. Commit it on its own (`docs: add longhorn → democratic-csi migration plan`) and treat it as the living runbook: tick off each phase and PVC there as it completes.

## Checkpoints (applies to everything below)

- **Stop after every phase.** Report what changed and what was verified, then wait for an explicit go-ahead before starting the next phase.
- **Stop after every single PVC migration** inside Phase 2, including each PVC within a multi-PVC app such as audiobookshelf ×5 or qbittorrent ×2. After each one, report the verification results (app up, gatus green, Argo Synced, zvol present) and wait for a go-ahead before touching the next PVC.
- No phase or PVC gets batched with another without approval.

## Stage -1 – Inline the `app-volume` component (pure refactor, no live change)

Five apps get their PVC from `components/app-volume`: `infrastructure/{prometheus,alertmanager,gatus}` and `platform/{mosquitto,zigbee2mqtt}`. Inlining it means each PVC can then be migrated on its own like every other app.

For each of the five:
1. Save the render before the change: `kustomize build <dir> > scratchpad/<app>.before.yml`.
2. Append the PVC as another document in the app's main manifest (`prometheus/prometheus.yml`, `alertmanager/alertmanager.yml`, `gatus/deployment.yml`, `mosquitto/deployment.yml`, `zigbee2mqtt/deployment.yml`). Keep **`name: app-volume`**, the `app.kubernetes.io/component: app` label, `storageClassName: longhorn-replicated` and the current size. Those are 1G each, except **35Gi** for prometheus.
3. Remove `../../components/app-volume` from the app's `components:` list. For prometheus, also delete the `replacements:` block that set 35Gi.
4. Run `kustomize build <dir>` and `diff` it against the saved render. The output **must be identical**, apart from document ordering at most. That way Argo sees no change and the live PVCs aren't touched.

Then delete `components/app-volume/`, run `just check-kustomize`, commit, push, and confirm all five Argo apps are `Synced` with no diff. **Stop here for review.**

## Progress

| PVC | Status |
|---|---|
| audiobookshelf ×5 (config, metadata, audiobooks, books, podcasts) | **Migrated 2026-10-03** (`809c9e85`). Old PVs kept `Retain`/`Released` |
| omada/volume | **Migrated 2026-10-03** (`ec4c5653`). Host-networked and unpinned: the pod moved from drone-02 (192.168.42.22) to drone-04 (192.168.42.24), so its IP changed |
| scrypted/volume | **Migrated 2026-10-03** (`a9965e6d`) |
| navidrome/data | **Migrated 2026-10-03** (`dd2f00bb`). After the migration it was OOMKilled at the 256M limit while resuming an interrupted scan (the scale-down interrupted one). Fixed by raising the limit to 1G (`0b798eff`); the scan then completed in 44s with no restarts |
| qbittorrent config + ts-state | **Migrated 2026-10-03** (`006abf33`). The deployment is at 0 replicas, so it hasn't been run on the new volumes yet |
| sonarr/volume | **Migrated 2026-10-03** (`e5cc6fcb`) |
| radarr/volume | **Migrated 2026-10-03** (`83f4b76b`) |
| tsidp/data | **Migrated 2026-10-03** (`b3cf12cc`). Old PV `pvc-e8404b9e…` kept `Retain`/`Released`. Parent Argo app is `platform`, so run the scripts with `PARENT=platform` (or `infrastructure` for that tree) |
| calibre-web/config | **Migrated 2026-10-03** (`2d9bf6a5`). Old PV `pvc-b1ea29ae…` kept `Retain`/`Released` |
| calibre/config | **Migrated 2026-10-03** (`5bf6d1e7`). Old PV `pvc-04b41406…` kept `Retain`/`Released` |
| linkding/data | **Migrated 2026-10-03** (`c113f8da`). Old PV `pvc-f29dd1b7…` kept `Retain`/`Released` |
| golink/volume | **Migrated 2026-10-03** (`bfb07357`). Old PV `pvc-7ea27847…` kept `Retain`/`Released` |
| consignment-app/data | **Migrated 2026-10-03** (`b6fdc1c4`). Old Longhorn PV `pvc-2b81ebb7…` kept as `Retain`/`Released` until Phase 4 |

Notes from the first migration: a one-off `alpine` + `apk add rsync` Job works for the copy (the volume is ext4 with a setgid `2775` root dir, which `rsync -a` preserves). Verify with `md5sum` plus `stat` of the root dir. The app image may have no shell, so verify through its logs and health endpoint.

**Wave 2 was blocked 2026-10-03 by nvmet-tcp advertising unlimited MDTS** (large `mkfs`/writes failed). Fixed by setting `param_mdts=8` on drone-04's port and restarting nvmet; see the first gotcha in `.claude/skills/democratic-csi/SKILL.md`. radarr was started before the fix and rolled back (still on Longhorn). A leftover `Released` PV `pvc-c5ce2bab…` with sanoid snapshots needs `zfs destroy -r` on drone-04.

## Live inventory (actual used size)

| Wave | PVCs (ns/name) | Used |
|---|---|---|
| 1 – canaries | consignment-app/data, golink/volume, linkding/data, calibre/config, calibre-web/config, tsidp/data | <0.1G each |
| 2 – media apps | radarr/volume, sonarr/volume, qbittorrent/config + ts-state (currently detached), navidrome/data, scrypted/volume, omada/volume, audiobookshelf ×5 | ~0.1–1.9G |
| 3 – home automation (do together) | mosquitto/app-volume, zigbee2mqtt/app-volume, home-assistant/volume | 16G (HA) |
| 4 – big / DB | miniflux/postgres-volume, jellyfin/config-pvc (50Gi, 17.7G used), syncthing/volume (9G) | |
| 5 – observability (last, so we keep alerting during the earlier waves) | gatus/app-volume, alertmanager/app-volume, prometheus/app-volume (16.5G) | |

## Phase 0 – Prove democratic-csi before moving any data

**Status: done 2026-10-03.** Findings are in `.claude/skills/democratic-csi/SKILL.md`. Two results change later phases:
- drone-04 took ~7 min to reboot and remote initiators give up after ~10 min (`ctrl_loss_tmo`). Drain or scale down stateful apps before rebooting drone-04.
- Sanoid snapshots on `rust/k8s/volumes` block `DeleteVolume` ("dependent snapshots"), so deleted PVs stay `Released` until `zfs destroy -r` is run by hand. Phase 2 and Phase 4 PV deletions need that extra step.

1. Apply a scratch PVC plus a pod in a test namespace and pin it to **drone-04** first (the loopback case, which had the `nr-io-queues` problem), then to one other drone. Check write → delete pod → reschedule on another node → data still there.
2. Test expansion (raise the PVC size), a VolumeSnapshot, and restoring a PVC from that snapshot. Then delete everything and confirm the zvol under `rust/k8s/volumes` is gone too.
3. Reboot drone-04 while a test volume is attached. Confirm nvmet comes back (`nvmet-config-loaded` flag) and the pod recovers. Recent bootc commits touched this, so test it before real data depends on it.
4. Add sanoid coverage in `ansible/roles/nas_zfs/files/sanoid.conf`: `[rust/k8s/volumes]` with `recursive = yes` and `use_template = production` (or `backups`). Run the nas_zfs role. This replaces Longhorn's `daily-backup` RecurringJob.

## Phase 1 – Groundwork in git (one commit)

- `infrastructure/democratic-csi/app.yml`: set `defaultClass: true` on `zfs-generic-nvmeof-csi`.
- `infrastructure/longhorn/storage-class.yml`: remove the `is-default-class` annotation from `longhorn-replicated`. Also clear the `local-path` default, since there are currently two defaults.
- Fix the copy-paste label in `infrastructure/democratic-csi/kustomization.yml` (`app.kubernetes.io/name: longhorn-system` → `democratic-csi`).

## Phase 2 – Per-PVC cutover procedure (repeat for each wave)

Keep the **same PVC name** so manifests only change on the `storageClassName` line. A PV rebind means the data is copied only once:

1. **Pause Argo** for the app. Patching only the app's own Application does **not** hold: the parent `apps` Application (and `borg` above it) have `selfHeal` and put the child's sync policy back within seconds, which also scales the deployment back up. Pause the whole chain, top-down:
   `for a in borg apps <app>; do kubectl -n argocd patch app $a --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'; done`
   Resume bottom-up after the git push, with `[{"op":"add","path":"/spec/syncPolicy/automated","value":{"enabled":true,"prune":false,"selfHeal":true}}]` on `<app>`, then `apps`, then `borg`.
2. `kubectl -n <ns> scale deploy --all --replicas=0`, then wait for the Longhorn volume to show `detached`.
3. Create a temp PVC `<pvc>-zfs` on `zfs-generic-nvmeof-csi`, same size and accessModes.
4. Run a one-off copy Job that mounts the old PVC read-only and the new PVC, and runs `rsync -aHAX --numeric-ids /old/ /new/`. Prefer an `alpine` + rsync Job manifest kept in the scratchpad. `pv-migrate` is an alternative. Compare file counts and `du`.
5. Rebind:
   - Set the new PV's `persistentVolumeReclaimPolicy: Retain`, then delete the temp PVC.
   - Set the old Longhorn PV to `Retain` too (a rollback safety net), then delete the old PVC.
   - Clear the new PV's `claimRef` and pre-bind it to `<ns>/<pvc>` (`claimRef: {namespace, name}`).
6. Edit git: `storageClassName: zfs-generic-nvmeof-csi` on that PVC. Drop `longhorn.io/data-locality` annotations where present (jellyfin, tsidp). Run `kustomize build`, commit, push.
7. Re-enable auto-sync (or sync once by hand). Argo creates the PVC with the original name, and it binds to the pre-claimed PV because the claimRef matches. Set the PV reclaim back to `Delete` and scale back up (Argo does this from git).
8. Check that the app works and its gatus check is green. Leave the old Longhorn PV and volume in place (Retain) until Phase 4.

**Rollback** for a wave: pause Argo, scale to 0, delete the new PVC, clear the old Longhorn PV's claimRef and bind it again, then revert the git commit.

9. **Stop and wait for review before the next PVC.**

Special cases:
- The five former `app-volume` users now have inline PVCs (Stage -1), so they follow the normal per-PVC procedure.
- **miniflux postgres**: stop it cleanly (scale to 0) before the rsync. That's enough for a file-level copy, and a `pg_dump` beforehand is cheap insurance.
- **Prometheus**: 16.5G of TSDB on HDD is fine. Expect a short gap in metrics during the copy.
- **qbittorrent**: both volumes are already detached (the app is at 0 or broken). Copy them without scaling anything.

## Phase 3 – Repo-wide cleanup after the last wave

- `grep -rn longhorn apps platform infrastructure components` should only match `infrastructure/longhorn`.

## Phase 4 – Retire Longhorn (after about 1–2 weeks of soak)

1. Final check: `kubectl get pvc -A | grep longhorn` returns nothing. Make one last Longhorn backup per volume (kept on `rust/longhorn`).
2. Delete the retained Longhorn PVs/volumes. Set the Longhorn `deleting-confirmation-flag` setting, then delete the `longhorn` Argo Application. Prune is off, so remove it from `infrastructure/kustomization.yml` and delete the app manually.
3. Remove everything that references it: `infrastructure/longhorn/`, the Longhorn group in `infrastructure/prometheus/config/rules/rules.yml` (replace it with ZFS pool-capacity alerts, since the pool is at 86%), the homer link in `apps/homer/config/config.yml`, the `/var/lib/longhorn` mount in `ansible/provision.yml`, `[rust/longhorn]` in sanoid (once old backups expire), and the comment in `bootc/overlay/etc/sysctl.d/nfsd.conf`. Update CLAUDE.md/AGENTS.md (storage list) and HARDWARE.md.
4. This frees the 480 GB NVMe in each drone.

## Verification

- After each wave: `kustomize build <dir>` / `just check-kustomize`, `kubectl get pvc -A` shows the zfs class and `Bound`, `zfs list -r rust/k8s/volumes` on drone-04, the app works, gatus is green, Argo is `Synced/Healthy` with no drift on the PVC.
- After Phase 0: a reboot of drone-04 and pod rescheduling were both tested.
- After Phase 4: Argo has no orphaned Longhorn resources, Prometheus has no firing Longhorn rules, and sanoid snapshots appear for every `rust/k8s/volumes/*` zvol.
