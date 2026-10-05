# Retire Longhorn (Phase 3/4 of docs/longhorn-to-democratic-csi.md)

## Context
All app PVCs are now on `zfs-generic-nvmeof-csi` (jellyfin was the last, 2026-10-03). Longhorn is
still deployed, with 38 `Released` retained PVs / 25 detached Longhorn volumes kept as rollback
safety nets, plus references scattered across the repo. Goal: remove Longhorn from the cluster and repo.

## Steps (stop for approval before the destructive cluster steps)

1. **Preflight (read-only):** `kubectl get pvc -A` shows no longhorn class; `kubectl get pv | grep -i longhorn` lists only `Released`.
   Confirm no remaining workloads use `longhorn-*` StorageClasses.
2. **Delete retained data (destructive, needs your OK):** delete the Released Longhorn PVs and the
   `volumes.longhorn.io` objects. First set the Longhorn setting `deleting-confirmation-flag=true`.
   Old backups stay on `rust/longhorn` (NFS) untouched for now.
3. **Git cleanup (one commit):**
   - `infrastructure/kustomization.yml`: drop `longhorn/app.yml`; `git rm -r infrastructure/longhorn/`
   - `infrastructure/prometheus/config/rules/rules.yml`: remove the `Longhorn` rule group (~lines 130-205); add ZFS pool-capacity alert if a zfs-exporter metric is available (pool is ~86% full)
   - `ansible/provision.yml:65`: remove the "Mount for longhorn" task (`/var/lib/longhorn`)
   - `bootc/overlay/etc/sysctl.d/nfsd.conf:1`: reword comment (drop Longhorn backup target)
   - `AGENTS.md` (lines 42, 83) and `HARDWARE.md`: remove longhorn mentions; `docs/longhorn-to-democratic-csi.md`: mark Phase 3/4 done
   - Check `apps/homer/config/config.yml` for a Longhorn link
   - Leave `[rust/longhorn]` in sanoid and the `nas_zfs` dataset task until old backups are deliberately expired
4. **Cluster removal:** Prune is off, so after push delete the Argo `longhorn` Application manually, then namespace `longhorn-system`
   and Longhorn CRDs/StorageClasses if they linger. Also clean `/var/lib/longhorn` on drones (frees the 480 GB NVMe in each) — separate, host-level step, confirm first.

## Verification
- `just check-kustomize`; `grep -rIi longhorn --exclude-dir=.git .` only hits docs history / sanoid
- `kubectl get app -n argocd` all Synced/Healthy; `kubectl get crd | grep longhorn` empty; `kubectl get sc` shows only zfs class
- Prometheus has no Longhorn rules firing; gatus green
