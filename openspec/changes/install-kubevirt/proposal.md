# Proposal

## Why

The cluster has no way to run full virtual machines. An earlier KubeVirt 1.5.2
install (2025-10-10) was removed for lack of use, leaving its 16 CRDs behind as
orphans. Running CI builds meant for a virtual machine — e.g. a Fedora bootc
runner image for forgejo Actions — requires real KVM guests, and the pod-shaped
alternatives are all blocked: unprivileged user namespaces are denied by the
RuntimeDefault seccomp profile, `/dev/fuse` is absent from pods, and a
privileged `docker:dind` sidecar works (verified end-to-end on 2026-11-27) but
gives every workflow job host-root-equivalent access on the node. A VM gives CI
builds a real kernel boundary with native rootless podman inside, matching the
GitHub-hosted-runner experience this change's follow-on work wants to preserve.

## What Changes

- Install KubeVirt (virt-operator + virt-controller + virt-handler) via an
  Argo CD application, pinned by digest/version, sourced from the upstream
  release manifests (no Helm chart upstream), with the instance CR managed
  declaratively.
- Delete the 16 orphaned `*.kubevirt.io` / `*.kubevirt.io` CRDs left by the
  removed 1.5.2 install before the fresh install reconciles, so there is no
  version-skew ambiguity.
- KubeVirt runs in its own namespace(s) with the privileges the operator
  requires (`virt-handler` needs access to `/dev/kvm` and host devices); it is
  the only privileged virtualization layer this cluster carries.
- No VMs are created by this change — it is the platform only. Consumers
  (starting with the CI runner in `add-forgejo-ci`) are separate.
- Scheduling: all nodes advertise KVM (`cpu-cpuid.svm` / `vmx` feature labels);
  no node-level enablement changes are required. No affinity rules are baked in
  here; placement policy belongs to the consuming workloads.

## Capabilities

### New Capabilities
- `kubevirt`: The cluster SHALL run KubeVirt as the supported way to run VMs as
  first-class Kubernetes resources: operator lifecycle via Argo CD, a usable
  `VirtualMachine` API on KVM-capable nodes, and a documented, repeatable
  install/uninstall path that does not leak CRDs.

### Modified Capabilities
- None.

## Impact

- New Argo CD app (`infrastructure/kubevirt`) and a new `kubevirt` (and
  optionally `kubevirt-manager`) namespace; the CRDs left over from the 1.5.2
  attempt are deleted as part of the install.
- virt-handler runs privileged on every node (unavoidable — it opens
  `/dev/kvm`); this is a deliberate, narrowly-scoped exception to the
  cluster's "no privileged app pods" posture.
- No app workloads are touched; no storage is consumed until the first VM
  exists (next change).
- Argo selfHeal is expected to revert operator config drift; the KubeVirt
  instance CR is part of the same sync wave as the operator.
