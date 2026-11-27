# Tasks

## 1. Preflight checks

- [ ] 1.1 Verify every node exposes `/dev/kvm` (SSH or `kubectl debug node/<name> --image=busybox -- ls -l /dev/kvm`); expect drone-01..04 readable/writable KVM device; stop and reassess if missing
- [ ] 1.2 Inventory the orphaned CRDs from the 2025-10 install: `kubectl get crd -o name | grep kubevirt.io` (expect ~16); record the list in the commit message
- [ ] 1.3 Confirm none of those CRDs holds data: `kubectl get virtualmachines.kubevirt.io,virtualmachineinstances.kubevirt.io -A` returns empty lists

## 2. Clean slate

- [ ] 2.1 Delete the orphaned kubevirt CRDs listed in 1.2; verify `kubectl get crd | grep -c kubevirt` is 0
- [ ] 2.2 No other cluster objects reference them (spot-check namespaces for `virt`-named objects: `kubectl get all -A | grep -i virt`)

## 3. Install KubeVirt via Argo CD

- [ ] 3.1 Vendor the pinned upstream release manifests (`virt-operator` + `kubevirt` CR for the chosen version, e.g. v1.5.x or newer stable) into `infrastructure/kubevirt/` with a pinned source URL recorded in a comment; keep the raw files byte-identical to upstream
- [ ] 3.2 Add `infrastructure/kubevirt/kustomization.yml` and `infrastructure/kubevirt/app.yml` (Argo Application, project `infrastructure`, sync wave after CRDs, automated prune+selfHeal for operator only — instance CR immutable fields documented)
- [ ] 3.3 Register in `infrastructure/kustomization.yml`; `kustomize build infrastructure/kubevirt` passes; `just check-kustomize` passes
- [ ] 3.4 Add `infrastructure/kustomization.yml` entry; commit; push; let Argo CD sync
- [ ] 3.5 Verify: `kubectl -n kubevirt get kubevirt kubevirt -o yaml` shows phase `Deployed`/`Available`; all virt-operator/controller/handler/api pods Ready; CRD versions match the operator

## 4. Smoke test

- [ ] 4.1 Create a one-off throwaway VirtualMachine (tiny containerDisk image, e.g. cirros) pinned to a drone worker; verify it reaches `Running`, gets a masquerade IP, and reaches `kubernetes.default.svc` (`curl`/`wget` from the VM console via `virtctl console`)
- [ ] 4.2 Verify the VM does not schedule onto unimatrix nodes even when explicitly requested without tolerations (or confirm control-plane taint rejects it) — record observation
- [ ] 4.3 Delete the throwaway VM; confirm no leftover PVCs/pods in the test namespace
- [ ] 4.4 Write `docs/kubevirt.md`: what runs where, how to bump the version, how to uninstall (delete Argo app → delete kubevirt CR → remove CRDs)

## 5. Wrap-up

- [ ] 5.1 No gatus entry (platform component, not a user-facing service); instead add the smoke-test evidence (commands + output summary) to the change notes
- [ ] 5.2 Confirm no other changes were snuck in: `git diff main --stat` shows only `infrastructure/kubevirt/**`, `infrastructure/kustomization.yml`, `docs/kubevirt.md`

## Workflow follow-up

- Archive once `add-forgejo-ci` is also merged and a real runner VM has booted from this platform.
