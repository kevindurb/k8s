# kubevirt Specification

## Purpose

Provide Kubernetes-native virtual machines as a first-class workload on this
cluster, used as the execution environment for CI builds (and, later, any other
workload that needs a real kernel rather than a container).

## Requirements

### Requirement: KubeVirt is installed and reconciled declaratively

The kubevirt operator (virt-operator), controllers, API, and handlers SHALL run
in a dedicated namespace and SHALL be reconciled by Argo CD from this
repository, with automated sync and self-heal. The KubeVirt CR SHALL pin the
operator version. Uninstalling (removing the Argo applications) MUST remove the
operator workloads; CRD handling MUST be deliberate (see orphan cleanup).

#### Scenario: Operator survives a pod eviction

- **WHEN** a virt-controller or virt-handler pod is deleted
- **THEN** Argo CD and the operator recreate it without human intervention
- **AND** no existing VirtualMachines are affected beyond normal virt-handler reconnection

#### Scenario: Version drift is corrected

- **WHEN** the pinned KubeVirt version in git is changed
- **THEN** Argo CD syncs the new operator version and the instance CR upgrades in order (operator first, then workload types)

### Requirement: No orphaned or skewed CRDs remain

The 16 `kubevirt.io` CRDs left by the removed 2025-10 install (v1.5.2, CRDs
present, operator absent) SHALL be deleted before the fresh install reconciles,
so the cluster never runs a mix of operator versions or CRDs without a matching
operator. After reconciliation, the CRD versions SHALL exactly match the
installed operator.

#### Scenario: Pre-install cleanup

- **WHEN** the install procedure runs against the cluster as of 2026-11
- **THEN** the orphaned kubevirt CRDs are removed before the new operator is synced
- **AND** no `VirtualMachine*` CRs from the old install exist afterwards

#### Scenario: Validation after sync

- **WHEN** the operator reports Ready
- **THEN** `kubectl get crd | grep kubevirt` shows exactly the CRDs for the installed version
- **AND** the stored versions match the served versions (no `NotServedVersion` warnings)

### Requirement: VMs are scheduled only on KVM-capable nodes

Every node in the cluster advertises SVM/VMX via NFD. VM scheduling SHALL NOT
rely on node-name pinning alone; the scheduling constraints MUST be satisfiable
only on KVM-capable nodes, and VMs SHALL fail fast rather than fall back to
software emulation if no such node is available.

#### Scenario: Scheduling on a capable node

- **WHEN** a VirtualMachine is created with default settings
- **THEN** it is scheduled onto a node whose cpuid advertises SVM or VMX
- **AND** the VMI reports `Running` with the host's KVM accelerator

#### Scenario: Scheduling is not faked by emulation

- **WHEN** no KVM-capable node can take a VM
- **THEN** the VMI stays pending rather than falling back to emulation
- **AND** the reason references the KVM/device constraint

### Requirement: Control-plane nodes stay off-limits to VMs

The unimatrix control-plane nodes carry the standard control-plane `NoSchedule`
taint. The KubeVirt installation SHALL NOT weaken, remove, or add blanket
tolerations for that taint, and no VirtualMachine created by this cluster's
automation SHALL carry it, so VMs land on the drone workers by default.

#### Scenario: A default VM never lands on a control-plane node

- **WHEN** a VirtualMachine is created without explicit tolerations
- **THEN** it schedules on a drone worker, never on a unimatrix control-plane node

### Requirement: Virtualization privileges are scoped to the operator

Only the virt-operator/virt-handler/virt-controller/virt-api components SHALL
run with the privileges KubeVirt requires (host device access for
`/dev/kvm`/kvm-related mounts, `SYS_NICE`, hostPath for
`/dev/kvm` and `/sys`). No application namespace SHALL gain new privileges;
VMs run as guest workloads isolated from the host except for the virt-launcher
boundary KubeVirt itself defines.

#### Scenario: Application namespaces unchanged

- **WHEN** KubeVirt is installed
- **THEN** pod security admission for existing namespaces is unchanged
- **AND** no new privileged pod exists outside the kubevirt namespace(s)

### Requirement: Guest networking reaches the cluster network

A VM SHALL be able to reach in-cluster services by cluster DNS name and the
cluster's external endpoints, using NAT (masquerade) networking with the pod
CIDR; no extra LAN exposure is created by default.

#### Scenario: VM resolves a ClusterIP service

- **WHEN** a VM is running with default networking
- **THEN** a DNS lookup for an in-cluster Service returns its ClusterIP from the cluster DNS
- **AND** TCP connect to that service succeeds

#### Scenario: VM cannot be reached from the LAN

- **WHEN** a device on 192.168.42.0/24 (not on the tailnet and not cluster-internal) attempts to open a connection to the VM's address
- **THEN** the connection is refused or dropped
