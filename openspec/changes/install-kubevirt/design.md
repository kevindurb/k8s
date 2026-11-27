# Design

## Context

The cluster runs no VMs today. It previously carried KubeVirt 1.5.2 (installed
2025-10-10, since removed as unused), leaving 16 orphaned `kubevirt.io` CRDs
and no operator. All eight nodes advertise KVM (`svm` on the AMD drones, `vmx`
on the unimatrix control plane). The kube-apiserver tolerates no extra taints;
control-plane nodes carry the standard `node-role.kubernetes.io/control-plane:NoSchedule`.
Node-local storage is `zfs-local` (OpenEBS LocalPV-ZFS) on the drone workers.
See `proposal.md` for why this exists at all (CI runners for forgejo Actions).

## Goals / Non-Goals

**Goals:**
- A stock upstream KubeVirt install, reconciled by Argo CD, with no drift.
- A clean slate: orphan CRDs removed before install; no version skew ever.
- KVM actually usable by VMs (validated by a smoke VM before declaring done).

**Non-Goals:**
- CDI / Golden image cloning (not needed while VM disks come from
  containerDisks; revisit if we want per-job ephemeral VMs).
- Custom networking (SR-IOV, bridges, Multus) — pod NAT is enough for CI.
- Live migration tuning, CPU pinning, hugepages.
- VM images themselves — those belong to `add-forgejo-ci`.

## Decisions

### 1. Install from upstream release manifests via Argo CD, not Helm
KubeVirt ships one supported artifact: the versioned `operator.yaml` +
`kubevirt.yaml` release manifests from the kubevirt releases. There is no
first-party Helm chart worth adopting (community charts lag and fork the
operator). We vendor the two manifests (or pin them via a remote kustomize
base) under `infrastructure/kubevirt/`, plus our own `kubevirt-instance.yaml`
carrying the `KubeVirt` CR.
Rationale: matches how Tekton Triggers were vendored here (upgrades become a
visible file diff), keeps us on the same upgrade treadmill as upstream, and
avoids a third-party chart as a new failure domain. Tekton itself was later
removed — that is fine; the pattern (pin, vendor, diff in review) is what we keep.
Alternative considered: operator-sdk-style OLM install — rejected; adds OLM,
which this cluster doesn't run.

### 2. Delete the 16 orphaned CRDs before syncing
The 2025-10 CRDs are v1.5.2 vintage with no owner and no instances (verified:
`kubectl get virtualmachineinstances` is empty). The new operator may or may not
adopted them gracefully; not gambling. Any newer operator will reinstall what it
needs. This is the only destructive step; it removes zero objects with data.

### 3. Namespace: `kubevirt`, PSS `privileged`
`virt-operator`/`virt-handler` require host `/dev/kvm`, `/dev/net/tun`-ish
access and broad capabilities. One dedicated namespace with
`pod-security.kubernetes.io/enforce: privileged` is the smallest hole; no other
namespace changes policy. (Same pattern as `metallb-system`, `tailscale`.)

### 4. Placement is a VM-authoring concern, not an operator one
KubeVirt schedules VMs like pods; worker preference comes from the VM's
nodeAffinity/tolerations (drone workers schedulable, unimatrix and drone-04
taints respected). The operator itself is tolerated onto control-plane nodes if
needed (virt-operator is small); virt-handler runs everywhere KVM exists, which
is everywhere, and that's fine.

### 5. Smoke-test with a throwaway VM, then delete it
Done-ness is "a VM boots", not "pods are Running". The validation VM is a
small cirros-like containerDisk or busybox-ish image with an `ls /dev/kvm`
health check; deleted in the same change after green. This proves KVM,
scheduling, and cloud-init networking end to end before B builds on top.

## Risks / Trade-offs

- [`/dev/kvm` missing on a node despite cpuid flags] → Verify per node
  (`kubectl debug` on the node or ssh) before install; FCOS ships the kvm
  modules, so this should be a formality. If absent: load via
  `bootc/overlay` kargs module or blacklist — do not ship before verifying.
- [Orphan CRD deletion races with a sync] → Delete CRDs _before_ the Argo app
  exists; Argo can't resurrect deleted CRDs if the operator is yet to be synced.
- [virt-handler churn on node reboots] → same as any DaemonSet; acceptable.
- [KubeVirt upgrade treadmill] → one component to bump occasionally; same
  class as the Tekton vendored files we already carried.
- [Control-plane taints] → we do NOT add tolerations for VMs; if the drones
  are full, VMs pend (desired behavior — no quiet evictions of CI onto etcd
  nodes).

## Migration Plan

1. Verify `/dev/kvm` on drone-01..04.
2. `kubectl delete crd` the 16 orphaned CRDs.
3. Commit `infrastructure/kubevirt/{operator.yaml, kubevirt-instance.yaml, kustomization.yml, app.yml}`; register in `infrastructure/kustomization.yml`.
4. Sync; wait for `Kubevirt/operator` Available and `virt-handler` DaemonSet rollout; smoke-test VM; delete smoke VM.
5. Rollback: delete the Argo app + `kubectl delete kubevirt kubevirt -n kubevirt` + the CRDs; nodes are otherwise untouched.

## Open Questions

- None blocking. Whether to add CDI later is genuinely deferrable (needs a use case first).
