# install-kubevirt — implementation notes

## Smoke test evidence (2026-11-27)

Cluster: 7 nodes (3 control-plane "unimatrix", 4 drones). KubeVirt v1.10.0,
installed via the Argo CD application `kubevirt` from this repo.

### Preflight

- `/dev/kvm` present on all 7 nodes (via `kubectl debug node/<n> --profile=sysadmin`,
  `ls -l /host/dev/kvm` → `crw-rw-rw- root root 10,232`).
- Orphaned 1.5.2 CRDs: `kubectl get crd | grep kubevirt.io` → 16 CRDs, all with
  `virtOperatorFinalizer` set but no operator running. All held 0 instances.
  Deleted 2026-11-27; deletions hung on the finalizer, so it was cleared with
  `kubectl patch crd <name> --type=merge -p '{"metadata":{"finalizers":[]}}'`
  after confirming zero stored objects. `grep -c kubevirt` → 0 afterwards.

### Deploy

- Argo app `kubevirt` (project `infrastructure`, created in this change) synced
  wave 0 (CRD + operator), then wave 1 (KubeVirt CR). `ServerSideApply=true`
  required (CRD > 256 KiB annotation limit).
- Post-sync: `kubectl -n kubevirt get kubevirt kubevirt` → `phase=Deployed`,
  conditions `Available=True (All components are ready.)`,
  `observedKubeVirtVersion=v1.10.0`.
- All virt-operator/api/controller/exportproxy/template/handler pods `1/1 Running`.
  virt-handler DaemonSet: drone-01, drone-02, drone-03 (untainted nodes only;
  unimatrix-* have the control-plane taint, drone-04 `dedicated=storage`).

### Issue found and fixed during rollout

virt-handler on **drone-02** crash-looped: `Failed to create an inotify watcher:
too many open files`. drone-02 had hit `fs.inotify.max_user_instances=128`
(139 instances in use by kubelet/containerd/k3s/systemd/...). drone-01 was at
~122/128. Fixed live on drone-01/02/03 (`sysctl fs.inotify.max_user_instances=512`)
and persisted via `bootc/overlay/etc/sysctl.d/k8s.conf` (also raises
`max_user_watches` to 524288). Takes effect cluster-wide on the next bootc
image rollout; unimatrix/drone-04 got neither the live change nor a reboot and
don't run virt-handler anyway.

### VM smoke test (throwaway, deleted afterwards)

Namespace `kubevirt-smoke`, VM `smoke-test` (cirros containerDisk
`quay.io/kubevirt/cirros-container-disk-demo:latest`, 512Mi, pinned to
`kubernetes.io/hostname=drone-01`):

- `kubevirt.io/schedulable=true` on drone-01/02/03; VMI reached `phase=Running`
  on drone-01 in <10s, IP `10.42.8.8` (masquerade, pod CIDR).
- Console (`virtctl console smoke-test -n kubevirt-smoke`): OS booted under
  KVM (`Virt-type:` line, KVM accelerator in qemu cmdline `-accel kvm`).
- Guest network: `ip addr` → eth0 `10.42.8.8/24` via `10.42.8.1`;
  `route` default via `10.42.8.1`.
- DNS: `nslookup kubernetes.default.svc.cluster.local` → `10.43.0.1` via
  `10.43.0.10` (kube-dns). (Short name `kubernetes.default.svc` does not
  resolve — the guest resolv.conf only carries the
  `kubevirt-smoke.svc.cluster.local` search domain; FQDN works.)
- TCP: `nc -zvw5 10.43.0.1 443` → `open` (kubernetes.default.svc:443).
  (`wget` from BusyBox cannot do TLS — no openssl applet — hence nc.)
- Scheduling guard: a second VM with
  `nodeSelector: {node-role.kubernetes.io/control-plane: "true"}` and **no
  tolerations** stayed `Scheduling` / pod `Pending`; events:
  `0/7 nodes are available: 3 node(s) didn't match Pod's node affinity/selector,
  4 node(s) had untolerated taint(s)`. Deleted unscheduled.

Cleanup: both VMs and the `kubevirt-smoke` namespace deleted; no VMs, VMIs,
pods, or PVCs remain (`kubectl get vm,vmi -A`, `kubectl get pvc -A` → empty).

## Other notes

- `infrastructure` AppProject created in this change (cluster had only `default`
  and `apps`); applied at sync-wave -1 from `infrastructure/kustomization.yml`.
- No gatus endpoint added on purpose: KubeVirt is a platform component, not a
  user-facing HTTP service.
- `bootc/overlay/etc/sysctl.d/k8s.conf` change ships with the next bootc image;
  the live node sysctl was applied manually on drone-01/02/03.
