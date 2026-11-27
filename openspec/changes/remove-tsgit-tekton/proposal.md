# Proposal

## Why

tsgit and its Tekton CI companion exist to serve a workflow that is being
replaced by `add-forgejo-runner`. Once forgejo is live and the migrated repos build
green on it, the old stack is pure dead weight: two namespaces of controllers, a
vendored Tekton Triggers install, an egress ProxyGroup and CoreDNS rewrite
whose only consumer was the Tekton pipeline, tailnet policy grants, and the
`2025-11-07`-era `tsgit` capability spec that no longer describes anything the
owner wants operated. Removing them reclaims the machinery budget and stops
two parallel CI stories from confusing the next person.

## What Changes

- **BREAKING**: remove the `apps/tsgit` app (Deployment, PVCs, SealedSecret),
  the `tsgit` Argo CD Application, and the `tsgit` capability spec — the
  forge moves to forgejo (see `add-forgejo-runner`).
- **BREAKING**: remove the Tekton stack: `infrastructure/tekton/` (Pipelines
  Helm app, vendored Triggers + interceptors, Dashboard, gatus check) and
  `infrastructure/tsgit-ci/` (EventListener, tailnet ingress, prune CronJob,
  RBAC), their Argo Applications, and their namespace.
- Remove the CI-only network plumbing: the `tsgit-egress` ProxyGroup and
  `tsgit` ExternalName Service in `infrastructure/tailscale/resources.yml`, and
  the `tsgit.beaver-cloud.ts.net` rewrite in `infrastructure/coredns/coredns-custom.yml`.
- Remove the Tekton-resource exclusions for `tekton.dev` from
  `infrastructure/argocd/resources/config.patch.yml` (no longer needed).
- Delete orphaned Tekton CRDs/cluster objects that Argo prunes does not cover
  (vendored CRDs and any `PipelineRun` history; keep nothing — history is not
  worth keeping).
- Delete `docs/tsgit-ci.md`; update any references (README/docs) to forgejo.
- Archive the in-flight `add-tsgit-ci` change (already complete except its
  final report) as superseded by this migration.
- In `kevindurb/infra` (separate repo, its own PR): remove `tag:tekton`,
  `tag:tekton-hooks`, `tag:tsgit` (if no other consumer remains), the
  `cap/repo`, `cap/hooks`, `cap/funnel` grants, and the `tagOwners` entries.
- Drop the `192.168.42.222/32 # forgejo ssh` reservation in
  `infrastructure/metallb/address-pool.yml` — the tailnet-only design makes it
  dead.

Prerequisite: `add-forgejo-runner` must be merged, forgejo proven green on the
migrated repos, and mirrors verified. **Do not start this change until then.**

## Capabilities

### New Capabilities
- None.

### Modified Capabilities
- `tsgit`: remove all 12 requirements — the forge it describes no longer exists.

## Impact

- Argo CD apps removed: `tsgit`, `tekton`, `tsgit-ci`. Cluster loses: tekton
  controllers, triggers, dashboard, eventlistener; the tsgit pod; the egress
  path for CI clones.
- Cluster keeps: forgejo (from `add-forgejo-runner`) as the only git forge/CI.
- External (separate repo `kevindurb/infra`): tailnet policy cleanup PR.
- Data loss: the `tsgit-repos` PVC (bare repos, already migrated) and
  `tsgit-state` PVC, and any un-migrated repositories there (only `ci`, the
  superseded sketch — deliberately not migrated).
- Documentation: `docs/tsgit-ci.md` deleted; repo docs updated to point at
  forgejo docs (to be written in `add-forgejo-runner`).
