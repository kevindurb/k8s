# Design

## Context

Forgejo 15.0.12 runs in `platform/forgejo` as a Helm release (`forgejo` chart
17.3.3, `code.forgejo.org/forgejo-helm`) configured via `gitea.config` values,
which the chart renders into a single `GITEA_APP_INI` environment variable on
the container. There is no Service/Ingress or UI toggle for push-to-create —
it is app.ini-only (`[repository]` section). Argo CD syncs the Application and
rolls the pod on config change; a full restart is required for app.ini changes
to take effect.

Current state: `ENABLE_PUSH_CREATE_USER` and `ENABLE_PUSH_CREATE_ORG` are both
unset (default `false`), so pushes to nonexistent paths fail with "push to
create is not enabled" — visible today as an intentional rejection, not an
error. `DEFAULT_PUSH_CREATE_PRIVATE` defaults to `true` upstream.

## Goals / Non-Goals

**Goals:**

- Push-to-create for the user namespace (`kevindurb/<name>`) and for
  organization namespaces the user belongs to.
- Push-created repositories are private by default.
- Verification on the live instance proves the whole path end-to-end.

**Non-Goals:**

- `FORCE_PRIVATE` enforcement — explicit `repo.private=false` pushes stay
  possible; the spec only requires private *by default*.
- Creation limits (`MAX_CREATION_LIMIT`) — single-user instance, no abuse
  vector worth throttling.
- Org membership modeling — org repo-creation permission is enforced by
  forgejo against org membership; this change does not alter org structure,
  teams, or permissions.
- Any change to the mirror workflow, CI runner, or registration settings.

## Decisions

**1. Set the two `ENABLE_PUSH_CREATE_*` keys via `gitea.config.repository`.**
Alternatives: `FORGEJO__repository__ENABLE_PUSH_CREATE_USER` env vars directly
on the deployment (works, but bypasses the chart's values path and duplicates
config authority), or `kubectl edit` (anti-GitOps). The values path matches
how every other app.ini key is managed here and keeps Argo CD as the only
writer.

**2. Pin `DEFAULT_PUSH_CREATE_PRIVATE: "true"` explicitly.**
It is the upstream default, but the spec's private-by-default requirement
should not depend on an unpinned upstream default surviving chart/forgejo
upgrades. Explicitly setting it is free and self-documenting.

**3. Enable org push-create alongside user push-create.**
The spec calls for both. Org push-create only grants what org membership
already grants elsewhere — creating repositories in that org through the UI —
so it adds no new privilege class, only a new path to exercise it. The exact
org permission forgejo checks (membership vs. a dedicated "create repositories"
org permission) is not crisply documented for 15.0.12; treat any org-side
permission failure as a forgejo-side signal to inspect, not as a blocker for
the user-namespace half of the feature. If verification shows org pushes fail
for a permission reason, the resolution is an org setting or a spec tweak, not
more config keys.

**4. No `MAX_CREATION_LIMIT`.**
`-1` (unlimited) upstream default is acceptable: single user, tailnet-only,
repos deletable. Adding a limit would be unrequested policy, not safety.

**5. Rollout via the normal Argo sync; verify live, then revert nothing.**
Push options are honored by forgejo at push time; no migration, no backfill,
no new repos created by the change itself. Verification uses throwaway
repositories (`kevindurb/push-to-create-smoke` and an org equivalent if orgs
exist), created and then deleted after the check. The change is trivially
reversible: remove the three keys, sync, pod rolls back to rejecting
push-to-create.

## Risks / Trade-offs

- **[Surprise repos from typos]** → Any `git push` to a misspelled remote name
  now creates an empty private repository. Mitigation: private-by-default,
  visible in the UI, trivially deletable; no automatic mirror/mirror-of-mirror
  side effects.
- **[Public push via `-o repo.private=false`]** → A push flag can create a
  non-private repo (still tailnet-scoped). Mitigation: documented in
  `docs/forgejo.md`; `FORCE_PRIVATE=true` remains available if it ever bites.
- **[Org permission semantics]** → Org push-create may depend on org-level
  settings beyond membership; if verification fails there, user push-create
  still works and the org requirement gets revisited (spec or org settings).
- **[Config drift via manual edits]** → Drift is corrected by Argo selfHeal;
  the keys must only ever be changed in `platform/forgejo/app.yml`.

## Migration Plan

1. Merge the manifest change; Argo CD rolls the forgejo deployment.
2. Confirm pod ready, `https://forgejo.beaver-cloud.ts.net/api/healthz` green.
3. Verify over SSH and HTTPS with a scratch repo (create + push + delete).
4. Rollback if needed: revert the commit; Argo re-syncs; pushes to
   nonexistent paths are rejected again. Existing push-created repos are
   ordinary repos and are unaffected.

## Open Questions

- Whether an org exists on this instance to exercise the org scenario is
  unverified; the tasks include checking and, if no org exists, verifying the
  user path and noting the org scenario as untested rather than blocking.
