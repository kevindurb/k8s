# tsgit CI (Tekton)

CI for repositories hosted on [tsgit](https://tsgit.beaver-cloud.ts.net), built
on Tekton Pipelines. Repos on tsgit are served tailnet-only with no webhooks
and no status API, so this is designed around polling and git smart HTTP
only — no forge features are required or used.

## Pieces

| Piece | Where | What it does |
|---|---|---|
| Tekton Pipelines | `infrastructure/tekton/app.yml` (Helm chart, ns `tekton-pipelines`) | Task/Pipeline/PipelineRun CRDs, controller, webhook, Dashboard |
| Tekton Dashboard | same app, `infrastructure/tekton/` vendored `dashboard-release.yaml` | `https://tekton.beaver-cloud.ts.net` (tailnet-only, Tailscale ingress) |
| tsgit egress | `infrastructure/tailscale/resources.yml` + CoreDNS rewrite | In-cluster pods reach `tsgit.beaver-cloud.ts.net` as `tag:tekton`, read-only (`cap/repo`), granted in `kevindurb/infra` (`tailnet/policy.hujson`) |
| Poller | `infrastructure/tsgit-ci/poller.yml` (CronJob, every 2 min) | `git ls-remote`-equivalent per repo; creates a `PipelineRun` for new commits |
| Pipelines | `infrastructure/tsgit-ci/pipeline.yml` | `validate-repo`: `clone` → `dotfiles-check` (chezmoi dry-run + shellcheck) |
| Prune | `infrastructure/tsgit-ci/prune.yml` | Deletes `PipelineRun`s older than 14 days, every 6h |

## Using it

Watch a repo: edit `infrastructure/tsgit-ci/poller.yml` (`tsgit-poll-repos`
ConfigMap) — one line per repo: `name url branch`. Merge; the next poll picks
it up and builds the branch head once.

Watch a build: Dashboard at `https://tekton.beaver-cloud.ts.net`, or:

```sh
kubectl get pipelineruns -n tekton-pipelines
kubectl logs -n tekton-pipelines -l tekton.dev/pipelineRun=<name> --all-containers
```

(`tkn` CLI works too if installed locally.)

State lives in the `tsgit-poll-state` PVC (`infrastructure/tsgit-ci/poller.yml`).
Deleting `<repo>.sha` forces a rebuild of the current head.

## Adding a new pipeline for a repo

Add a `Pipeline` (and its Tasks) to `infrastructure/tsgit-ci/pipeline.yml` and a
row to the poller ConfigMap pointing at it. The poller currently always runs
`validate-repo`; parameterize `pipelineRef` in the CronJob payload if a repo
needs different stages. Image references are digest-pinned; keep them pinned
and bump deliberately.

## Credentials and permissions

There are none for git access, by design: the poller and the clone task reach
tsgit through the `tsgit-egress` proxy, which authenticates to tsgit as
`tag:tekton` with read-only `cap/repo` on `kevindurb/*`. The tag grant lives in
`kevindurb/infra` (`tailnet/policy.hujson`) and must exist before the egress
path works; without it, clones get 404. If the grant is ever narrowed to
specific repos, keep the poller's list within that scope.

Namespace RBAC (`tsgit-ci` ServiceAccount) can create/read/delete
`PipelineRuns` in `tekton-pipelines` — nothing else. Task pods carry no
service-account rights (`automountServiceAccountToken: false` via the PipelineRun
spec) and run non-root with a read-only root filesystem.

## Known limits / non-goals

- **No status in tsgit.** tsgit has no status API; green/red shows in the
  Dashboard and `kubectl`/`tkn` only.
- **~2 minute latency** from push to build start (poll interval).
- **First run after state loss** rebuilds the current head once per repo.
- **macOS-only chezmoi branches** are parse-checked but not executed
  (Linux-only runners).
- **No CD, no notifications.** Images/releases are not produced yet; wire
  GHCR push + the existing Renovate → Argo CD flow when a repo needs it.
- Tekton CRDs come from the Helm chart's `crds/` directory: they are not
  upgraded by chart bumps and must be applied manually on chart upgrades
  (`kubectl apply -f <crds>`) when CRDs change.
