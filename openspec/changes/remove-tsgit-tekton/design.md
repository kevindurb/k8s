# Design

## Context

Once `add-forgejo-ci` is merged and all migrated repos are green on forgejo,
the tsgit + Tekton stack has no remaining users. Its pieces live in:

- git: `apps/tsgit/`, `infrastructure/tekton/`, `infrastructure/tsgit-ci/`,
  `infrastructure/kustomization.yml`, `clusters/borg` references via parents,
  `docs/tsgit-ci.md`, `infrastructure/kustomization.yml`, the MetallB
  reservation comment, `argocd/resources/config.patch.yml`,
  `infrastructure/tailscale/resources.yml`, `infrastructure/coredns/coredns-custom.yml`,
  plus `openspec/specs/tsgit/` and archived change artifacts.
- cluster: Argo Applications `tsgit`, `tekton`, `tsgit-ci`; Helm release
  `tekton` (CRDs `pipelines.tekton.dev`, `triggers.tekton.dev`); namespaces
  `tsgit`, `tekton-pipelines`; PVCs `tsgit-repos`, `tsgit-state`.
- kevindurb/infra (separate repo): `tag:tekton`, `tag:tekton-hooks`, `tag:tsgit`
  in `tagOwners`; grants `tag:tekton → tag:tsgit cap/repo`,
  `cap/hooks` on `tag:tsgit`; any `autoApprovers` entries.

## Goals / Non-Goals

**Goals:** zero dangling resources, zero references, spec no longer describes a
dead system; the in-flight `add-tsgit-ci` change is closed out honestly.

**Non-Goals:** migrating any additional data; changing forgejo; touching
`kevindurb/infra` beyond the listed grant removals (that's a separate PR in
that repo, tracked here as a checklist item).

## Decisions

### 1. Gate on proof, then delete in dependency order
Order: (1) confirm all repos green on forgejo + mirrors healthy; (2) remove
Argo Applications and git manifests (stop GitOps from recreating);
(3) `kubectl delete` namespaces/PVCs/CRDs — PVCs **after** `tsgit-repos` has
served as migration source only while still needed (it will be unmounted; the
bare repos' canonical home after migration is forgejo, so deleting is correct);
(4) spec removal + archive `add-tsgit-ci`; (5) kevindurb/infra policy PR;
(6) doc sweep.
Rationale: Argo `prune: false` means git deletion alone leaves orphans — the
manual deletes are explicit, reviewable tasks, not an accident waiting to be
discovered later.

### 2. CRD deletion is a separate, explicit step
`tekton.dev` Pipelines/Triggers CRDs are cluster-scoped; deleting them
cascades deletion of all Tekton CRs (PipelineRuns etc.), which is desired.
They are not owned by any Helm uninstall (we vendored manifests, not a chart
for Triggers). Do it deliberately with `kubectl delete -f` on the vendored file
so exactly the same set goes that was installed.

### 3. `add-tsgit-ci` is archived, not completed
It reached 22/23 tasks with the final report outstanding. Archiving records
the true end state (superseded by forgejo CI) rather than pretending it was
"finished". `openspec archive add-tsgit-ci` with a note. The one remaining
task (post-merge verification report) is moot once tsgit is gone.

### 4. `specs/tsgit/` is removed, not marked deprecated
The capability is gone; a "deprecated" spec would misdescribe the cluster. The
delta in this change carries REMOVED with Reason/Migration per requirement.

### 5. GitHub mirror stays
Push mirrors (configured in `add-forgejo-ci`) are the public read path; they
are deliberately untouched here. This change does not touch DNS, GitHub, or
GHCR.

## Risks / Trade-offs

- [Deleting `tsgit-repos` PVC loses the only copy of repos that were never
  migrated (the `ci` repo)] → Verified before deletion: only `dotfiles` had
  content that matters; `ci` was a superseded sketch. Task checklist asserts
  forgejo has dotfiles with matching SHAs before PVC removal.
- [Orphaned Argo Application confusion] → `kubectl get applications -A | grep -E 'tsgit|tekton'`
  must return empty as a final gate; same for namespaces.
- [Removing grants breaks something nobody remembered] → the removed grants
  (`cap/repo`, `cap/hooks`, `cap/funnel`) have exactly one consumer each
  (tekton egress, tsgit webhook, funnel); all three are deleted in this change.
- [Docs drift] → `docs/tsgit-ci.md` deleted; `docs/forgejo.md` (from the
  add-forgejo-ci work) becomes the only reference.

## Migration Plan

Order: spec delta merge → verify (grep) → decommission cluster objects →
infra PR → archive change → final sweep. Rollback: none needed at this stage —
everything deleted here is already unused; restoration would mean reverting
this change's git commits and re-applying (kept possible by git history).

## Open Questions

- Whether to keep the `.git` history of `docs/tsgit-ci.md` referenced from
  forgejo docs (a link to the archived spec maybe). Cosmetic; decide at edit time.
