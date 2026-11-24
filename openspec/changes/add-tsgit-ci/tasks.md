# Tasks

## 1. Prerequisite: tailnet policy (repo `kevindurb/infra`)

- [ ] 1.1 (BLOCKED on merge of kevindurb/infra#19 + terraform apply) In `kevindurb/infra`, add `tag:tekton` to `tagOwners` and a grant `{src: ["tag:tekton"], dst: ["tag:tsgit"], ip: ["tcp:443"], app: {"github.com/kevindurb/tsgit/cap/repo": [{"repos": ["kevindurb/*"], "access": "read"}]}}` to `tailnet/policy.hujson`; verify with `just`/CI apply in that repo. Done so far: kevindurb/infra#19 opened (`terraform validate` clean; PR CI plans the tailnet root). Remaining: merge → CI applies → in-cluster curl check (rolled into 2.3).
- [x] 1.2 Decided: `kevindurb/*` read, not a narrow list — one grant, room for future repos.

## 2. Tailnet egress for in-cluster access

- [x] 2.1 Add `tsgit-egress` ProxyGroup (`type: egress`, tag `tag:tekton`, 2 replicas) and a `tsgit` ExternalName Service to `infrastructure/tailscale/resources.yml`; `kustomize build infrastructure/tailscale` passes.
- [x] 2.2 Extend the CoreDNS rewrite in `infrastructure/coredns/coredns-custom.yml` to `^(idp|ai|tsgit)\.beaver-cloud\.ts\.net\.?$`; `kustomize build infrastructure/coredns` passes and the file still holds exactly one `rewrite` line.
- [ ] 2.3 Apply both via Argo CD sync; from a throwaway pod, `git ls-remote https://tsgit.beaver-cloud.ts.net/kevindurb/dotfiles.git` succeeds with no credentials mounted.

## 3. Tekton installation

- [x] 3.1 Create `infrastructure/tekton/app.yml` + `kustomization.yml`: Argo Application (project `infrastructure`? — follow neighboring infra apps; project `default` like `tailscale` if unsure) deploying the CDF Tekton Pipelines Helm chart (`oci://ghcr.io/cdfoundation/charts/tekton-pipeline`, pinned version) into namespace `tekton-pipelines`, created by the app with baseline pod-security labels.
- [x] 3.2 Install Tekton Dashboard as part of the same app (separate chart or upstream `dashboard/release.yaml` vendored), exposed with a plain Tailscale `Ingress` (`ingressClassName: tailscale`); no other exposure.
- [x] 3.3 Verify: `kubectl -n tekton-pipelines get pods` all Ready; dashboard reachable from the tailnet; not reachable off-tailnet (check from a non-tailnet vantage or confirm ingress class).

## 4. Poller and shared plumbing

- [x] 4.1 Create `infrastructure/tsgit-ci/` app (namespace `tekton-pipelines`): `app.yml` registered in `infrastructure/kustomization.yml` (and `clusters/borg/kustomization.yml` if not covered by parent), `kustomization.yml` listing all resources below.
- [x] 4.2 Add `tsgit-poll-repos` ConfigMap listing repos (`dotfiles` with branch `main`, clone path `kevindurb/dotfiles.git`) — editing it is the only step to add future repos.
- [x] 4.3 Add `tsgit-poll-state` PVC (zfs-local, 1Gi, RWO) and the `poller` CronJob (every 2 min, `concurrencyPolicy: Forbid`, alpine/git-based image, digest-pinned): per repo, `ls-remote` the configured branch, compare to `state/<repo>.sha` on the PVC, `kubectl apply` a `PipelineRun` on change (first sight = build current head), write the new SHA afterwards. ServiceAccount + Role/RoleBinding limited to `pipelineruns` create/get/list + `pods` get/list in `tekton-pipelines`.
- [ ] 4.4 Verify end-to-end poll: seed state file with an old SHA, run the job once manually, observe a `PipelineRun` created; run again, no new run; confirm duplicate-free behavior across a forced pod restart.

## 5. `dotfiles` validation pipeline

- [x] 5.1 Add `Task` `clone` (shallow clone into a workspace `emptyDir`, non-root, `RuntimeDefault` seccomp, read-only root fs).
- [x] 5.2 Add `Task` `dotfiles-check`: run `chezmoi --dry-run --verbose apply` with a scratch `HOME`/`--source` against the clone, and render every `*.sh.tmpl` via `chezmoi execute-template` piped to `shellcheck -s bash`; plus `shellcheck` over plain `*.sh`. Pin `ghcr.io/twpayne/chezmoi` and the shellcheck image by digest.
- [x] 5.3 Add `Pipeline` `validate-repo` (clone → dotfiles-check) with params `repo`, `revision`, `repoPath`; `timeouts` 10m; per-step CPU/mem limits; `status: skipped`-safe wiring between tasks.
- [ ] 5.4 Verify on a real push: create a scratch commit (e.g. add a file) on tsgit `dotfiles`, watch the PipelineRun appear via the poller, reach `Succeeded`; then push a deliberately broken template (e.g. unmatched `{{`) and see `Failed` with the shell/template error visible in `tkn pr logs`.
- [ ] 5.5 Revert/cleanup the deliberate-break commit (or land the fix as a real commit) so the repo is green.

## 6. Retention, limits, and docs

- [x] 6.1 Add prune CronJob (every 6h) deleting `PipelineRun`s older than 14 days or keep latest 50, whichever is simpler to express; verify against existing runs.
- [x] 6.2 Add a short `docs/tsgit-ci.md` (or README section in the app) covering: how to register a repo, how to read a build, how to add a pipeline for a new repo, and the egress/grant dependency on `kevindurb/infra`.
- [x] 6.3 `just check-kustomize` passes; `repomix`/lint clean; pre-commit hooks pass.

## 7. Rollout and handoff

- [x] 7.1 Decided: dashboard at `https://tekton.beaver-cloud.ts.net` via the shared Tailscale ingress (`tag:infra`), verified returning 200 from the tailnet.
- [ ] 7.2 Verify `kustomize build` for every changed directory (done, all pass) and Argo CD sync of `tekton`, `tsgit-ci`, `coredns`, `tailscale` apps (all Synced/Healthy). Re-verify after PR #19 merge unblocks the egress path (ProxyGroup currently ProxyGroupCreationFailed on the missing tag:tekton grant).
- [ ] 7.3 Report: dashboard URL, `tkn` quick-start, poller interval, and the explicit follow-ups deferred (CD via GHCR+Renovate, notifications, `just ci` contract in dotfiles).

## Workflow follow-up

- Archive this change once deployed and the first green run is observed.
- Potential follow-up change: register the `ci` repo itself once its pipeline contract exists.
- Potential follow-up change: notifications (e.g. Home Assistant webhook from a `finally:` task) — deliberately out of scope here.
