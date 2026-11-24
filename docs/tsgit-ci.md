# tsgit CI (Tekton)

CI for repositories hosted on [tsgit](https://tsgit.beaver-cloud.ts.net), built
on Tekton Pipelines. Repos on tsgit are served tailnet-only; builds are
triggered by tsgit's push webhooks (tsgit >= v0.5.0), not by polling.

## Pieces

| Piece | Where | What it does |
|---|---|---|
| Tekton Pipelines | `infrastructure/tekton/app.yml` (Helm chart, ns `tekton-pipelines`) | Task/Pipeline/PipelineRun CRDs, controller, webhook, Dashboard |
| Tekton Triggers | `infrastructure/tekton/triggers-release.yaml` + `triggers-interceptors.yaml` (vendored from `infra.tekton.dev/tekton-releases/triggers/previous/v0.38.0/`) | EventListener, TriggerBinding/Template, CEL interceptor; curation notes in `kustomization.yml` |
| Tekton Dashboard | same app, `infrastructure/tekton/dashboard-release.yaml` | `https://tekton.beaver-cloud.ts.net` (tailnet-only, Tailscale ingress) |
| tsgit egress | `infrastructure/tailscale/resources.yml` + CoreDNS rewrite | In-cluster pods reach `tsgit.beaver-cloud.ts.net` as `tag:tekton`, read-only (`cap/repo`), granted in `kevindurb/infra` (`tailnet/policy.hujson`) |
| Webhook receiver | `infrastructure/tsgit-ci/webhook.yml` (EventListener `tekton-hooks`) | CEL-filters pushes to `refs/heads/main`, creates a `PipelineRun` per push |
| Webhook ingress | `infrastructure/tsgit-ci/ingress.yml` | Tailscale ingress `tekton-hooks.beaver-cloud.ts.net`, proxy tagged `tag:tekton-hooks` (reachable only from `tag:tsgit`) |
| Pipelines | _in the repo under test_ (`ci/pipeline.yaml`) | Resolved at run time by Tekton's git resolver at the exact pushed SHA; the k8s repo holds no pipeline copies |
| Prune | `infrastructure/tsgit-ci/prune.yml` | Deletes `PipelineRun`s older than 14 days, every 6h |

## How a build starts

1. A push to a watched repository moves a ref. tsgit compares refs before/after
   the receive-pack and emits one GitHub-shaped `push` event per changed ref.
2. The delivery goes over the tailnet to `https://tekton-hooks.beaver-cloud.ts.net/`
   (the EventListener's tailscale ingress). Which repos emit events is the
   `github.com/kevindurb/tsgit/cap/hooks` node attribute on `tag:tsgit` in
   `kevindurb/infra` (`tailnet/policy.hujson`); currently `kevindurb/dotfiles`.
3. The CEL interceptor drops everything except `X-GitHub-Event: push` on
   `refs/heads/main` with `deleted=false`.
4. The TriggerTemplate creates a `PipelineRun` with `pipelineRef` pointing at
   `ci/pipeline.yaml` in the pushed repo, pinned to the pushed SHA.
   The delivery is unsigned; only `tag:tsgit` can reach the listener, and a
   forged event can at worst re-build a commit that already exists. If
   hardening is ever wanted, tsgit supports `secretEnv` on the hook plus the
   `github` interceptor with `secretRef` — see "Signing" below.

## Watch a build

Dashboard at `https://tekton.beaver-cloud.ts.net`, or:

```sh
kubectl get pipelineruns -n tekton-pipelines
kubectl logs -n tekton-pipelines -l tekton.dev/pipelineRun=<name> --all-containers
```

(`tkn` CLI works too if installed locally.)

## Adding a repo

1. Add a `ci/pipeline.yaml` to the repo (see `dotfiles` for the pattern).
2. Add the repo to the `cap/hooks` entry on `tag:tsgit` in
   `kevindurb/infra/tailnet/policy.hujson` (merge + apply CI there).
3. Widen the CEL filter in `infrastructure/tsgit-ci/webhook.yml` if the repo
   should build non-`main` branches.

## Signing (optional, not configured)

Deliveries are currently unsigned, which is deliberate: the listener is
reachable only from `tag:tsgit`, and triggering a build of an existing commit
is the worst a forged event can do. To require HMAC instead:

1. Add `"secretEnv": "TSGIT_HOOK_TEKTON"` to the hook entry in the policy and
   set that env var on the tsgit pod from a SealedSecret.
2. Create a Secret with the same value in `tekton-pipelines` and switch the
   EventListener's interceptor to `github` with
   `secretRef: {secretName: …, secretKey: …}` and `eventTypes: [push]`.

## Credentials and permissions

There are none for git access, by design: the pipeline runs clone over the
`tsgit-egress` proxy, which authenticates to tsgit as `tag:tekton` with
read-only `cap/repo` on `kevindurb/*`. Task pods get no API token
(`automountServiceAccountToken: false`) and no cluster permissions.

The `tsgit-ci` ServiceAccount may create `PipelineRuns`/`EventListeners` work
and delete old `PipelineRuns` (prune) — nothing else. The ingress proxy speaks
only to the EventListener Service.

## Known limits / non-goals

- **No status in tsgit.** tsgit has no status API; green/red shows in the
  Dashboard and `kubectl`/`tkn` only.
- **CI definition is code.** Whoever can push to a repo controls what its
  pipeline does; the runner holds no secrets and no cluster permissions, so a
  hostile pipeline can burn CPU, nothing more.
- **Push-triggered only, best effort.** tsgit delivers at most 3 attempts and
  drops events on restart; there is no retry queue. A missed push means no
  build — push again (or `git commit --amend && git push -f`) to retrigger.
- **Branches.** Only `refs/heads/main` builds. Tag pushes and other branches
  are ignored by the CEL filter.
- **Force pushes rebuild.** `forced` is accepted and treated like any update.
- **macOS-only chezmoi branches** are parse-checked but not executed
  (Linux-only runners).
- **No CD, no notifications.** Images/releases are not produced yet; wire
  GHCR push + the existing Renovate → Argo CD flow when a repo needs it.
- Tekton CRDs come from the vendored `triggers-release.yaml`; bump by
  re-downloading from `https://infra.tekton.dev/tekton-releases/triggers/previous/<version>/`.
- **Pod Security.** The `tekton-pipelines` namespace enforces `baseline` with
  `restricted` warn/audit; Tekton Triggers pods are upstream defaults and run
  non-root, but if a Triggers upgrade logs `violates PodSecurity "baseline"`
  warnings, revisit the namespace labels rather than the pod spec.

## Retiring the poller

The `tsgit-poll` CronJob, the `tsgit-poll-state` PVC, the `tsgit-poll-repos` /
`tsgit-poll-script` ConfigMaps and the `tsgit-ci-poller` RBAC are gone (the
`tsgit-ci` Role was renamed to `tsgit-ci-prune`). Because Argo CD syncs with
`prune: false`, delete the orphans once by hand:

```sh
kubectl -n tekton-pipelines delete cronjob tsgit-poll
kubectl -n tekton-pipelines delete pvc tsgit-poll-state
kubectl -n tekton-pipelines delete configmap tsgit-poll-repos tsgit-poll-script
kubectl -n tekton-pipelines delete role,rolebinding tsgit-ci-poller
```
