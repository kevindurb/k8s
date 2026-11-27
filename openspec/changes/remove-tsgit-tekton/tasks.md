# Tasks

Depends on: `add-forgejo-runner` merged and proven (all migrated repos green,
mirror healthy). Do not start until then.

## 1. Preflight

- [ ] 1.1 Confirm `add-forgejo-runner` is complete: dotfiles builds green on forgejo, push-mirror to GitHub verified, all image-building repos migrated and green
- [ ] 1.2 Record the exact SHAs of forgejo `dotfiles` vs tsgit `dotfiles` (must match): `git ls-remote` both — abort if mismatch
- [ ] 1.3 Inventory soon-to-be-deleted objects: `kubectl get ns | grep -E 'tekton|tsgit'`, `kubectl get applications -n argocd | grep -E 'tekton|tsgit'`, `kubectl get pipelineruns -n tekton-pipelines` (informational), `kubectl get pvc -n tsgit`

## 2. GitOps removal (this repo)

- [ ] 2.1 Remove `apps/tsgit/` and its entry in `apps/kustomization.yml`
- [ ] 2.2 Remove `infrastructure/tekton/` and `infrastructure/tsgit-ci/` and their entries in `infrastructure/kustomization.yml`
- [ ] 2.3 Remove the Tekton exclusions from `infrastructure/argocd/resources/config.patch.yml` (the `tekton.dev` group block)
- [ ] 2.4 Remove the `tsgit-egress` ProxyGroup and `tsgit` ExternalName Service from `infrastructure/tailscale/resources.yml` (keep the others)
- [ ] 2.5 Remove the `tsgit` entry from the CoreDNS rewrite in `infrastructure/coredns/coredns-custom.yml` (restore `^(idp|ai)\.beaver-cloud\.ts\.net\.?$`)
- [ ] 2.6 Remove the `192.168.42.222/32 # forgejo ssh` MetalLB reservation in `infrastructure/metallb/address-pool.yml`
- [ ] 2.7 `just check-kustomize` passes; commit; push

## 3. Cluster deletion (out-of-band, one-way)

- [ ] 3.1 Delete Argo CD Applications: `kubectl -n argocd delete application tsgit tekton tsgit-ci`
- [ ] 3.2 Delete the vendored Tekton CRDs exactly as installed: `kubectl delete -f infrastructure/tekton/triggers-release.yaml -f infrastructure/tekton/triggers-interceptors.yaml` (before deleting the directory from git, or from the commit) and the Tekton Pipelines CRDs (`kubectl get crd | grep -E 'tekton\.dev|triggers\.tekton\.dev'`); accept CR deletion cascades PipelineRuns
- [ ] 3.3 Delete namespaces: `kubectl delete ns tsgit tekton-pipelines`
- [ ] 3.4 Delete any remaining cluster-scoped Tekton RBAC/webhooks: `kubectl get clusterrole,clusterrolebinding,mutatingwebhookconfiguration,validatingwebhookconfiguration -A | grep -iE 'tekton|pipeline'` — delete leftovers
- [ ] 3.5 Delete PVCs in `tsgit` ns if they survived (they don't — namespace deletion covers them); confirm `kubectl get pvc -A | grep -E 'tsgit|tekton'` is empty
- [ ] 3.6 Verify nothing references the removed Services: `kubectl get svc,ep -A | grep -i tsgit` empty
- [ ] 3.7 Delete stray pipeline images/caches if any on nodes (skip — cosmetic)

## 4. kevindurb/infra PR (separate repo)

- [ ] 4.1 Branch + PR removing from `tailnet/policy.hujson`: `tag:tekton`, `tag:tekton-hooks`, `tag:tsgit` from `tagOwners`; `cap/repo` (tekton→tsgit), `cap/hooks` and `cap/funnel` on `tag:tsgit`; any `autoApprovers.services` entries for the above; keep the PR's `terraform plan` output clean (only removals)
- [ ] 4.2 After merge and CI apply: from a throwaway pod, confirm `git ls-remote https://tsgit.beaver-cloud.ts.net` fails (no route/no grant) and the forgejo path works

## 5. Docs and specs

- [ ] 5.1 Delete `docs/tsgit-ci.md`; grep the repo for `tsgit|tekton` and fix/remove stragglers (README, AGENTS.md if present, docs)
- [ ] 5.2 The `tsgit` spec delta in this change removes the capability entirely — archived with this change's archive
- [ ] 5.3 `openspec archive add-tsgit-ci` with a note "superseded by add-forgejo-runner + remove-tsgit-tekton"; close the 1 outstanding task as moot in the archive commit message
- [ ] 5.4 Verify final state: `kubectl get applications -n argocd | grep -E 'tsgit|tekton'` empty; `openspec list` shows no add-tsgit-ci

## 6. Final sweep

- [ ] 6.1 `grep -riE 'tsgit|tekton' --exclude-dir=.git .` returns only: archived change dirs under `openspec/changes/archive/`, this change's files, and intentional historical mentions (design docs)
- [ ] 6.2 `just check-kustomize` green; `kustomize build` every touched tree; pre-commit passes
- [ ] 6.3 Confirm forgejo + runner still healthy after the tailnet policy change (5.4 smoke test repeated post-policy-merge)

## Workflow follow-up

- Archive this change once merged.
