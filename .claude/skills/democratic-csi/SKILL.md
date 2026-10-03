---
name: democratic-csi
description: Operate and debug the cluster's democratic-csi storage (zfs-generic-nvmeof-csi, ZFS zvols on drone-04 exported over NVMe-oF/TCP). Use when creating, migrating, snapshotting, expanding or deleting PVCs on that class, when a PV is stuck Released, when drone-04 reboots, or when working on the Longhorn → democratic-csi migration (docs/longhorn-to-democratic-csi.md).
---

# democratic-csi (zfs-generic-nvmeof-csi)

## How it is wired

- Argo app: `infrastructure/democratic-csi/app.yml` (chart `democratic-csi`, driver `zfs-generic-nvmeof`). Driver config lives in `driver-config.yml` and is committed only as a sealed secret (`driver-config-sealed-secret.yml`); regenerate it with `just -f infrastructure/democratic-csi/justfile reseal`.
- Storage class and snapshot class are both named `zfs-generic-nvmeof-csi`. ext4, `allowVolumeExpansion: true`, reclaim `Delete`, binding `Immediate`.
- Backing store: pool `rust` on **drone-04** (2×12T mirror), zvols under `rust/k8s/volumes`, driver-managed snapshots under `rust/k8s/snapshots`. The controller SSHes to drone-04 (`core@192.168.42.24`) to run `zfs` / `nvmetcli`.
- Export: kernel nvmet, TCP port 4420, one subsystem per PVC (`nqn.2003-01.org.linux-nvme:pvc-<uid>`, `allow_any_host=1`). Config persists in `/etc/nvmet/config.json`, restored at boot by `nvmet.service`. A drop-in creates `/var/run/nvmet-config-loaded`, which the driver requires before it will run.
- Initiators use one I/O queue (`?nr-io-queues=1` in the transport URI). drone-04 itself can't connect more than one queue to its own target (-EXDEV on kernel 7.2.5).
- Node pods run on drone-01..04; the controller currently runs on drone-02. The unimatrix nodes are tainted, so they don't use it.

## Verified behaviour (tested 2026-10-03, Phase 0)

| Test | Result |
|---|---|
| Provision + mount on drone-04 (loopback) | Works, 17s to Running |
| Move the same PVC to drone-02 | Works, ~9s attach, data intact |
| Online expand 1Gi → 2Gi | Works. The pod saw 1.9G within seconds |
| VolumeSnapshot, then restore PVC on drone-01 | Works. The restore is a ZFS **clone** (`origin` = source snapshot) containing data as of the snapshot |
| Delete snapshot, then PVCs | zvols, snapshots and nvmet subsystems are removed a few seconds after the PVC is gone |
| Reboot drone-04 with one local and one remote (drone-02) volume attached | See below |

### drone-04 reboot

- drone-04 took about **7 minutes** to come back: ping returned first, sshd and the kubelet came later.
- nvmet restored both subsystems on its own, `/var/run/nvmet-config-loaded` was recreated, and nfs-server and k3s-agent were active.
- The remote initiator on drone-02 retried every 10s and reconnected at attempt 46/60. The kernel default `ctrl_loss_tmo` is 600s, so an outage longer than **about 10 minutes** drops the controller and the pod will need a restart. Consider `ctrl-loss-tmo=-1` in the transport URI. This is untested.
- The remote pod (drone-02) never restarted. Its I/O stalled for roughly 8 minutes, then resumed with no data loss. The local pod on drone-04 was marked for eviction at the 5-minute NotReady point and a replacement was created. The deletion was cancelled once the node returned, and the replacement pod mounted the volume and carried on, with the same data and about the same 8-minute gap in its log.
- Anything stateful depends on drone-04 being up. Treat its reboots as a cluster-wide storage outage and drain or scale down stateful apps first.

## Gotchas

- **Sanoid snapshots block volume deletion.** `ansible/roles/nas_zfs/files/sanoid.conf` snapshots `rust/k8s/volumes` (`recursive = yes`, `process_children_only = yes`, template `volumes`: 24 hourly, 14 daily, 4 weekly). democratic-csi's `DeleteVolume` fails with `filesystem has dependent snapshots` while those exist, so the PV sits in `Released` and the controller retries forever. To clean up, confirm the target and run `sudo zfs destroy -r rust/k8s/volumes/<pv-name>` on drone-04. The PV then disappears on the next retry. This is also a safety net, because deleted PVC data stays recoverable until you destroy it. For the rebind migration flow, use `Retain` and don't delete PVs.
- Sanoid snapshots of mounted ext4 zvols are crash-consistent, not application-consistent. That's fine for most apps, but for databases take a `pg_dump` too.
- Test volumes created while checking things leave Released PVs if you forget to destroy them. Always `kubectl get pv | grep Released` after experiments.
- The `rust` pool was **86% full** (1.43T free) when this was written. Check `zpool list` before large migrations.
- **drone-01..03 share one NVMe hostnqn.** They all report `nqn.2014-08.org.nvmexpress:uuid:03000200-0400-0500-0006-000700080009`, derived from a default firmware ID, and there is no `/etc/nvme/hostnqn`. It's harmless with `allow_any_host=1` and RWO volumes. It would break per-host ACLs.
- `sanoid` has no `--configcheck`. Validate with `sudo sanoid --take-snapshots --verbose --readonly`.
- `ansible-playbook` needs `ansible/vault.secret`, which isn't on every machine. The sanoid step of the `nas_zfs` role is just a copy to `/etc/sanoid/sanoid.conf` (mode 644). Run `provision.yml --tags zfs` where the vault file exists.
- Boot quirk: `kubectl get node` can show drone-04 Ready before its NVMe-oF target is serving. Check `nvmet.service` and `/var/run/nvmet-config-loaded`.

## Handy commands

```
# what exists on the backend
ssh core@drone-04 'zfs list -t all -r rust/k8s'
ssh core@drone-04 'sudo nvmetcli ls | grep "pvc-.*enabled"'
# initiator side, on any node
ssh core@<node> 'sudo nvme list-subsys | grep -A3 pvc-'
# driver logs
kubectl -n democratic-csi logs deploy/democratic-csi-controller -c csi-driver --since=10m
# stuck PVs
kubectl get pv | grep -E 'Released|Failed'
```

## Quick smoke test (use for any change to the driver config)

1. Apply a namespace `csi-test` with a 1Gi PVC (`storageClassName: zfs-generic-nvmeof-csi`) and a busybox pod using `nodeName: drone-04` that writes a file.
2. Delete the pod, then mount the same PVC from `nodeName: drone-02` and read the file.
3. Patch the PVC to 2Gi and check `df` in the pod.
4. `delete ns csi-test`, then verify `zfs list -r rust/k8s/volumes` is empty and no `csi-test` PVs remain. Destroy leftovers by hand if sanoid has snapshotted them (see Gotchas).

## Related

- Migration plan and runbook: `docs/longhorn-to-democratic-csi.md`.
- Secrets workflow: `docs/secrets.md`.
