# Design

## Context

See proposal.md for motivation. Key facts this design is built around:

- `tsgit` serves smart HTTP over tailnet only. No webhooks, no server-side hooks, no commit-status API. The only trigger available to us is polling `git ls-remote`.
- Cluster pods cannot reach the tailnet directly. The established pattern for "pods reach a tailnet service" is: Tailscale operator **egress ProxyGroup** (new tag) + ExternalName `Service` in `tailscale` namespace + a `rewrite` rule in the `coredns-custom` ConfigMap (`ai`/`idp` already work this way). The pod stays a normal cluster citizen; the proxy is the tailnet peer and carries the tag.
- tsgit authorizes purely on tailnet identity (`WhoIs`) plus the `github.com/kevindurb/tsgit/cap/repo` capability. An egress proxy tagged `tag:tekton` granted the `read` capability on the relevant repositories gives builds clone access with **no git credential anywhere**.
- Deployment pattern for apps here: `app.yml` (Argo Application) + `kustomization.yml` + manifests, synced by Argo CD (`selfHeal: true`), Tailscale Ingress for anything HTTP.
- The `dotfiles` repo is chezmoi-managed and hosted only on tsgit. No `justfile` exists there yet, so the validation pipeline is defined inline in the Tekton resources.

## Goals / Non-Goals

**Goals:** a working, observable CI path for tsgit-hosted repos using only cluster-native primitives; `dotfiles` building green on a push; everything GitOps-managed.

**Non-Goals:** CD of any kind, notifications, commit statuses back into tsgit (impossible), mirroring repos, multi-cluster, pipeline caching/artifact stores, Tekton Chains/signing, Tekton Triggers or Pipelines-as-Code (both require a webhook-capable git provider tsgit is not).

## Decisions

### 1. Tekton Pipelines as the engine (not Concourse, Argo Workflows, DIY)
- Tasks run as ordinary pods with our own `securityContext`, RBAC, and `RuntimeDefault` seccomp — no privileged container, no containerd-in-pod. Concourse's worker model violates the cluster's rootless-hardened posture.
- Polling is absent upstream (the upstream poller never shipped; Triggers/PaC need webhooks), so we ship a deliberately small poller (Decision 3). A stale community poller operator will not be used.
- Argo Workflows would need the same hand-written poller *plus* re-implements CI semantics (artifacts, workspaces, history UI) that Tekton gives for free.
- Kubernetes-native specs (Task/Pipeline/PipelineRun) match the repo's everything-is-CRDs style and Argo CD lifecycle management.

### 2. Install via the CD Foundation Helm chart, wrapped by Argo CD
- `helmCharts` source in an Argo Application pointing at `oci://ghcr.io/cdfoundation/charts/tekton-pipeline` (the CDF-official chart), plus a small kustomization for the Dashboard if its own chart is not used, and RBAC/namespace tweaks. Namespace `tekton-pipelines` (upstream default) for the controllers.
- Alternative considered: vendoring upstream `release.yaml` into the repo. Rejected: ~5k lines of generated YAML to review and bump; the chart tracks upstream with values overrides.
- Tekton Dashboard installed alongside (read-oriented UI), fronted by a Tailscale `Ingress` in the app (no public exposure, no separate auth — tailnet is the perimeter, consistent with other tailnet-only UIs in this repo).

### 3. Poller = CronJob (every 2 minutes) in `tekton-pipelines`
- One `JobTemplate` in CronJob `tsgit-poll`: image `alpine/git`-style minimal image, script checks out nothing — it runs `git ls-remote --heads https://tsgit.beaver-cloud.ts.net/<path>.git` per registered repo (list stored in a ConfigMap `tsgit-poll-repos` as `repo=path branch=name` lines, managed in git).
- Compares the SHA against `lastPolledSHA` recorded in the *same* ConfigMap (written back by the job via `kubectl patch` with a namespace-scoped Role) or, simpler, in a tiny PVC (`tsgit-poll-state`) holding one file per repo. **Decision: PVC + one file per repo** — no RBAC on ConfigMaps-as-state, no API-server chatter, corruption is one lost file.
- On change: renders a `PipelineRun` (from a template in the same manifest set, parameterized by repo/sha/branch) and `kubectl apply`s it. `concurrencyPolicy: Forbid` on the CronJob; runs are cheap (a no-op poll takes <1s).
- First sight of a repo builds its current head once, then baselines.
- Rejected alternative: one CronJob *per repo* — ConfigMap-driven loop keeps it one resource; adding a repo = one line in one ConfigMap.

### 4. Repo → pipeline mapping: one PipelineRun template, parameters per repo
- The pipeline definition lives in the built repo (`ci/pipeline.yaml` in dotfiles) and is resolved at run time by Tekton's `git` remote resolver (already shipped in the chart), pinned to the exact pushed SHA. Tekton's `emptyDir` workspaces are per-pod, so the pipeline is a single task with three steps (clone → pinned-chezmoi download → dry-run + shellcheck); steps share `/workspace/source` and `/workspace/tools` within the one pod. The k8s repo keeps only the poller/RBAC/PVC/prune; pipeline content is owned by the repo it builds.
- Images: `ghcr.io/twpayne/chezmoi` (official) and `koalaman/shellcheck-alpine` (or alpine + apk) — pinned by digest in the Task definitions, Renovate-tracked like everything else.
- Non-Linux templates render only partially under `--dry-run` (Go-template branches for `darwin` are parsed but not executed); accepted — this catches syntax and Linux-relevant render errors, not macOS-runtime semantics.

### 5. Egress identity and DNS
- New ProxyGroup `tsgit-egress` (tag `tag:tekton`) in `infrastructure/tailscale/resources.yml` (+ Service `tsgit` → `tsgit.tailscale.svc.cluster.local`, port 443) + CoreDNS `rewrite` extended: `^(idp|ai|tsgit)\.beaver-cloud\.ts\.net\.?$`.
- Tailnet policy (in `kevindurb/infra`, **not this repo**): add `"tag:tekton"` to tagOwners and grants `{"src": ["tag:tekton"], "dst": ["tag:tsgit"], "ip": ["tcp:443"], "app": {"github.com/kevindurb/tsgit/cap/repo": [{"repos": ["kevindurb/*"], "access": "read"}]}}`. Read-only; `write` is intentionally not granted. Prerequisite — this repo's CI goes red at the clone step until it lands.
- Pipelines pods then clone over `https://tsgit.beaver-cloud.ts.net/<ns>/<repo>.git` with zero secrets.

### 6. Placement and GitOps shape
- New `infrastructure/tsgit-ci/` app (Argo CD Application → `infrastructure/tsgit-ci/kustomization.yml`): Tekton Dashboard ingress, poller CronJob + PVC + repo ConfigMap, the `validate-repo` Pipeline + tasks, RBAC (Role for PipelineRun create; ServiceAccount per component).
- Modified: `infrastructure/tailscale/resources.yml` (egress ProxyGroup + Service), `infrastructure/coredns/coredns-custom.yml` (regex + comment). Argo apps for both already exist — no new app-of-apps wiring beyond the new app's registration in `infrastructure/kustomization.yml`.
- Namespace: everything lands in `tekton-pipelines` (controllers + dashboard) and pipelines run in `tekton-pipelines` too; tasks get per-run pods with `runAsNonRoot`, `readOnlyRootFilesystem` where the tool allows (clone needs a writable workspace — `emptyDir` mounts only), `RuntimeDefault` seccomp, all capabilities dropped.

### 7. Retention and resource bounds
- CronJob `concurrencyPolicy: Forbid`; per-Task `resources.limits` (cpu 1 / mem 512Mi for clone+check — measured, this repo is tiny); Pipeline `spec.timeouts` default 10m.
- A small prune CronJob (or documented `kubectl delete pipelinerun --older-than`) keeps the last ~50 runs; implemented as a second CronJob using `kubectl` image with a 6h schedule. (Alternative considered: leaving Tekton history forever — rejected, unbounded etcd/CR growth.)
- Dashboard exposed tailnet-only; no public endpoint.

### 8. Observability scope
- Build status = Dashboard or `kubectl get pipelineruns` / `tkn pr list`. No metrics pipeline, no notifications — explicitly deferred (see Non-Goals). Prometheus already scrapes cluster components where annotated; Tekton controller metrics opted-in via `--metrics-port`-adjacent config only if trivially available in the chart values, otherwise skipped.

## Risks / Trade-offs

- **[Polling latency / redundant parses]** → 2-minute polls are cheap (one `ls-remote`); accepted as the cost of tsgit's missing webhooks. Webhook migration path documented in the proposal if tsgit ever grows them (replace poller, keep Pipeline).
- **[Privileged-ish workloads avoided, but tekton controllers are still cluster-scoped]** → install is a scoped cluster-admin action already routine in this repo (operators get blanket RBAC); pipeline RBAC stays namespace-scoped and minimal.
- **[Poller state on single-replica PVC]** → PVC on `zfs-local`; losing it causes at most one duplicate build of current head per repo. Acceptable.
- **[Chart/version drift vs. upstream Tekton]** → pin chart version; Renovate's `helm` manager handles bumps (same as other Helm apps here). CRDs come from the chart but are not auto-removed (Helm behavior), upgrades of CRDs are called out in release notes when the chart flags them.
- **[Clone via egress tag sees all `kevindurb/*` repos]** → read-only, one purpose, tag exists for this; rotation = flip grants in infra repo. If undesired, narrow the grant to `dotfiles`/`ci` — recorded as the fallback.
- **[chezmoi dry-run blind spots]** → only Linux-relevant templates are truly exercised; macOS-only branches get syntax (parse) checking, not semantic checks. Accepted; the repo is Linux-friendliness-critical but macOS-shaped too.

## Migration Plan

1. Land the `kevindurb/infra` tailnet-policy PR first (tag + grant). Verify with a manual clone from a debug pod.
2. Apply cluster changes via the new `infrastructure/tsgit-ci` app (Argo sync). Tekton controllers come up; dashboard reachable tailnet-only.
3. Register `dotfiles` in the poller ConfigMap; wait for first build; iterate on the pipeline until green.
4. Rollback: delete the `tsgit-ci` Application + remove the Coredns/egress lines; nothing else depends on it. tsgit untouched throughout.

## Open Questions

- None blocking. (Non-blocking: whether to later add a `just ci` contract in dotfiles so CI calls `just ci` uniformly — deliberately not in scope now; whether the poller should also cover the `ci` repo itself — trivially achievable by adding a line to the ConfigMap once its pipeline exists.)
