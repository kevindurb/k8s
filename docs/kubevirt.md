# KubeVirt

KubeVirt runs VMs as first-class Kubernetes resources on this cluster. It exists
primarily so CI can run full virtual machines (e.g. Fedora bootc runners) instead of
unprivileged containers.

Installed version: **v1.10.0** (2026-11-18), as an Argo CD application managed from
this repo. No Helm chart is used — upstream only ships raw release manifests, which
are vendored verbatim.

## What runs where

| Component | Kind | Where |
|---|---|---|
| `kubevirt-operator` | Deployment | namespace `kubevirt`, any node per its own tolerations (untainted workers) |
| `virt-operator` | (operator) | reconciles the `KubeVirt` CR into the rest |
| `virt-controller` | Deployment (2 replicas) | control-plane nodes (no special taints tolerated) |
| `virt-api` | Deployment (2 replicas) | control-plane nodes |
| `virt-exportproxy` | Deployment (2 replicas) | anywhere |
| `virt-template-*` | Deployments | control-plane nodes |
| `virt-handler` | DaemonSet | only untainted nodes: **drone-01, drone-02, drone-03** (tolerates only `CriticalAddonsOnly`) |
| `virt-launcher` | Pod per VMI | same scheduling rules as any pod, subject to `kubevirt.io/schedulable=true` on the node |

Notes:

- Nodes must expose `/dev/kvm` (all 7 nodes do).
- The virt-handler DaemonSet carries no extra tolerations, so tainted nodes
  (unimatrix `control-plane`, drone-04 `dedicated=storage`) get no handler and
  `kubevirt.io/schedulable=false`; VMs land on the drone workers. Control-plane
  nodes additionally reject VM pods via their `NoSchedule` taint unless a VM adds
  a toleration (don't).
- KubeVirt labels nodes `kubevirt.io/schedulable`; only labeled-true nodes take VMs.
- `virt-handler` on drone-02 needed `fs.inotify.max_user_instances` raised from the
  default 128 → 512 (done live 2026-11-27 and persisted in
  `bootc/overlay/etc/sysctl.d/k8s.conf`). If a virt-handler crashes with
  `too many open files` / inotify errors, check that limit first.

## Layout in this repo

- `infrastructure/kubevirt/kubevirt-operator.yaml` — vendored upstream release
  manifest (CRDs + operator, **byte-identical to upstream**).
- `infrastructure/kubevirt/kubevirt-cr.yaml` — the `KubeVirt` custom resource
  (feature gates empty, `workloadUpdateStrategy` default).
- `infrastructure/kubevirt/kustomization.yml` — pins the source URLs, adds
  `argocd.argoproj.io/sync-wave: "1"` and `sync-options: Prune=false` to the CR
  (CRDs/operator are wave 0).
- `infrastructure/kubevirt/app.yml` — the `kubevirt` Argo Application
  (project `infrastructure`). `ServerSideApply=true` is required because the
  `kubevirts.kubevirt.io` CRD exceeds the 256 KiB last-applied-annotation limit.
  `prune`/`selfHeal` apply to the operator/CRDs; the `KubeVirt` CR is opted out
  of pruning via the annotation above.
- `infrastructure/project.yml` — the `infrastructure` AppProject (mirrors `apps`),
  applied at sync-wave `-1`.

## Upgrading

1. Check the release notes; download the new
   `kubevirt-operator.yaml` and `kubevirt-cr.yaml` from the matching GitHub
   release (`releases/download/vX.Y.Z/...`).
2. Replace the two vendored files **without editing them**.
3. Update the source URLs (and the version) in `infrastructure/kubevirt/kustomization.yml`'s comment.
4. `kustomize build infrastructure/kubevirt` and `just check-kustomize`.
5. Commit and push; Argo CD syncs: operator first (wave 0), then the CR (wave 1).
6. Watch `kubectl -n kubevirt get kubevirt kubevirt -o yaml` until
   `status.phase: Deployed` and all virt-* pods are Ready. KubeVirt upgrades are
   live: the operator rolls the handlers/controllers.

## The KubeVirt CR is GitOps-managed

Do not `kubectl edit` the `KubeVirt` resource; change `kubevirt-cr.yaml` in git.
Argo self-heals drift. Treat the spec as effectively immutable:
- `configuration` changes (e.g. `developerConfiguration.featureGates`) make the
  operator redeploy its components — expect a brief control-plane rollout.
- The operator rewrites `.status` freely; that is expected and does not conflict
  with self-heal (it excludes status).
- The CR is excluded from Argo pruning; deleting the Application does not delete
  the CR (see uninstall below).

## Uninstall

1. Delete all VMs and `VirtualMachineInstance`s (and any snapshotted data):
   `kubectl delete vm,vmi --all -A`.
2. Delete the Argo Application: `kubectl -n argocd delete app kubevirt`
   (and remove `infrastructure/kubevirt/` + the `infrastructure/kustomization.yml`
   entry from git, or the next sync recreates the app).
3. Delete the instance: `kubectl -n kubevirt delete kubevirt kubevirt` — this
   tears down virt-controller/api/handlers/exportproxy.
4. Delete the CRDs: `kubectl get crd -o name | grep kubevirt.io | xargs kubectl delete`.
   Fresh CRDs are left by the operator with no finalizers, so they delete cleanly.
   (The 2025-10 1.5.2 orphans had to be force-finalized once; that is not the
   normal path.)
5. Optionally delete the `kubevirt` namespace and the `infrastructure/project.yml`
   AppProject if unused.

## Verification / smoke test

Done 2026-11-27 (see `openspec/changes/install-kubevirt/notes.md`): a throwaway
cirros `VirtualMachine` pinned to drone-01 booted under KVM, got a masquerade IP,
resolved `kubernetes.default.svc.cluster.local` via cluster DNS and opened a TCP
connection to `kubernetes.default.svc:443`. A second VM pinned to a control-plane
node (`node-role.kubernetes.io/control-plane=true`, no tolerations) stayed
`Pending`/`Scheduling` and was never placed. Both VMs were deleted afterwards.
