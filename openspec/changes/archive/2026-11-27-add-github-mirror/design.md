# Design

## Context

See proposal.md — forgejo is the primary forge; the GitHub copies of
repositories need to stay in sync without any long-lived GitHub credential
stored on forgejo. Forgejo runners already execute forgejo Actions workflows
(validated by `dotfiles`). forgejo resolves `owner/repo` action references
against github.com (as `actions/checkout` does), supports `workflow_call`
reusable workflows, and supports user- and org-level Actions secrets
("A repository, a user or an organization can hold secrets" — Forgejo docs).

Key external facts this design rests on:

- GitHub App installation tokens work for git pushes and the REST/GraphQL
  API, scoped by the app's permissions and installation repositories.
- GitHub App installation tokens do **not** work for GHCR package pushes
  (github.com/octo-sts/app#840, "closed: not planned"); only
  `GITHUB_TOKEN` and PATs can push packages. Hence GHCR is out of scope.
- forgejo's built-in push mirror was never enabled for `dotfiles`
  (`push_mirrors` is empty); we replace that mechanism rather than repair it.
- The mirror must tolerate GitHub-side refs it does not own (Renovate
  branches) — hence no `--mirror`/`--prune`.

## Goals / Non-Goals

**Goals:**
- Zero long-lived GitHub credentials stored on forgejo; a run mints its own
  short-lived token.
- One implementation reused by every forgejo repo (dotfiles first, others
  opt-in by adding a small caller workflow).
- Visibility: mirror health = workflow run status in forgejo.
- Self-healing: scheduled run converges after transient failures.

**Non-Goals:**
- Pushing OCI images to GHCR (impossible with App tokens — see Context).
- Mirroring GitHub → forgejo (GitHub remains a dumb, read-mostly mirror).
- Two-way sync, conflict resolution, or protecting GitHub-side content from
  forgejo (force-push is by design; forgejo is authoritative).
- Mirroring anything other than git refs (wikis, releases, packages, issues).
- WIF/OIDC from the runner via tsiam — considered and rejected as
  disproportionate for this use case.

## Decisions

### 1. Shared reusable workflow in a dedicated forgejo repo

`gh-mirror` (new forgejo repo, tailnet-only source; the workflow itself is
non-secret) hosts `.forgejo/workflows/mirror.yml` with
`on: workflow_call`. Callers do:

```yaml
on:
  push: { branches: ['**'], tags: ['**'] }
  schedule: [{ cron: '23 * * * *' }]
  workflow_dispatch:

jobs:
  mirror:
    uses: kevindurb/gh-mirror/.forgejo/workflows/mirror.yml@main
    with:
      github-repo: kevindurb/<name>   # defaults to github.com/<owner>/<repo-name>
    secrets: inherit
```

Alternatives considered:
- **Inline copy per repo** — drifts; rejected after deciding this is for
  "all future repos", not just dotfiles.
- **forgejo built-in push mirror** — requires a static PAT in forgejo's
  mirror config; invisible when it breaks; abandoned by its own nature.
- **scripts in each repo** — same duplication problem as inline workflows.

Fallback if cross-repo `workflow_call` resolution misbehaves on our forgejo
version: vendor the workflow into the calling repo (one file, still tiny) and
revisit. This is a one-time decision made at implementation time, recorded in
the change notes.

### 2. GitHub App (`forgejo-mirror`) as the only credential

- Installed on the `kevindurb` account for **all repositories** (user's
  explicit choice), permissions: `contents: write`, `workflows: write`,
  metadata read (mandatory). No `packages`, nothing else.
- `workflows: write` is required because a mirror must be able to push
  `.github/workflows/*` changes; without it, repos containing workflow files
  would get rejected pushes (`refusing to allow a GitHub App ... workflows`).
- App ID and PEM private key stored as forgejo **user-level** secrets
  (`MIRROR_APP_CLIENT_ID`, `MIRROR_APP_PRIVATE_KEY`), visible to all repos
  under the account, inherited into the reusable workflow via
  `secrets: inherit`. (Fallback: per-repo secrets — more clicks, more
  drift; only if user-level secrets are unavailable at implementation time.)
- Token minted per run with `actions/create-github-app-token@v3` (client-id
  input; resolved from github.com by forgejo like `actions/checkout`). No
  hand-rolled crypto; ~2-line step.

Alternatives considered: fine-grained PAT (simple, but static, ≤1y expiry,
re-paste everywhere); classic PAT (rejected — broad scope, never expires);
tsiam WIF (rejected — needs funnel + STS broker, disproportionate); keeping
the GitHub-Actions-only status quo (means dotfiles builds stay GitHub-side
and nothing changes).

### 3. Refs mirrored: force-update heads and tags, never delete

`git push --force <url> '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'`
— i.e. force-update branches and tags, never delete. Rationale: any
GitHub-side refs we don't own (Renovate branches, etc.) survive; forgejo is
authoritative for content of refs it has. Stale GitHub-only branches linger
(cosmetic; documented in docs/forgejo.md).

Alternative: full `--mirror` — rejected; it would delete GitHub-only refs,
including Renovate branches created on GitHub.

### 4. Verification is part of the contract

After pushing, the job compares `git ls-remote` of source and destination for
the same refspecs; any mismatch fails the run. The run is the notification
surface (forgejo shows red + logs; commit status on the forgejo side).

### 5. Mirror target: same owner/name by default; repo must exist

The workflow takes an optional `github-repo` input (`owner/name`); default is
`<owner>/<repo>` derived from the forgejo repo. The GitHub repository is a
manual prerequisite: App installation tokens cannot create repositories
(`POST /user/repos` is rejected for installation tokens), so the workflow
checks for the repo at runtime and fails fast with an explicit message
naming it. The operator creates the repo once (private, same name) when
onboarding a repository; the checklist lives in the reusable workflow's
README and in `docs/forgejo.md`.

### 6. `dotfiles` is the pilot; everything else opts in later

`dotfiles` gains the ~15-line caller workflow in the same change (this is
what actually fixes the 15-commits-stale GitHub mirror). Other repos (e.g.
`bootc`, `containers`) opt in later; their GitHub Actions builds are
unaffected (this change never touches them).

## Risks / Trade-offs

- [Force-push corrupts GitHub-side history] → forgejo is the source of
  truth by design; mirror refs are limited to heads/tags; verification step
  fails the run loudly. `git reflog` on forgejo still protects the source.
- [GitHub outage blocks mirror] → caller includes a `schedule` trigger;
  mirror converges on the next tick. Mirror is best-effort by contract.
- [Tailnet-only access to forgejo breaks the reusable workflow's clone] →
  the runner runs on the tailnet; checkout hits the forgejo VPN URL, not
  public DNS. Fine as-is; noted for the day forgejo goes public.
- [App private key leak via forgejo logs] → secrets are redacted in forgejo
  logs; app can be uninstalled/key rotated in GitHub settings in minutes;
  key grants no permissions outside `contents`/`workflows: write` on user's
  own repos.
- [Branch protection on GitHub `main` blocks force-push] → GitHub blocks the
  push; run goes red with a clear reason. Mitigation: allow the app
  (`forgejo-mirror`) to bypass, or drop required-linear-history/force-push
  restrictions on the GitHub side (it's a mirror). Documented in the rollout.
- [Creating GitHub repos automatically] → dropped; operator creates the repo
  once (documented), workflow only pushes.
- [Reusable-workflow resolution across repos on this forgejo version] →
  verified at implementation; fallback is vendoring the file per repo.

## Migration Plan

1. Create GitHub App `forgejo-mirror`; install on all repos; record App ID
   and PEM.
2. Create forgejo `gh-mirror` repo with the reusable workflow; push.
3. Add forgejo user-level secrets `MIRROR_APP_CLIENT_ID`,
   `MIRROR_APP_PRIVATE_KEY`.
4. Ensure `github.com/kevindurb/dotfiles` exists and its default branch
   tolerates force pushes (or the app is exempt from protection).
5. Add `.forgejo/workflows/mirror.yml` caller to `dotfiles`; push; confirm
   first run is green and GitHub `main` matches forgejo `main` (SHA compare).
6. Update `docs/forgejo.md` (replace the stale-mirror note) and
   `add-forgejo/tasks.md` (task 4.3 superseded by this change).

Rollback: delete the caller workflow and the App; GitHub copies remain as
they are; nothing else depends on this. `add-forgejo` task 4.3 reverts to its
previous state.

## Open Questions

- Whether the reusable workflow should also manage issue mirroring or
  releases later — deferred; refs-only for now.
- Whether other repos (`bootc`, `containers`, …) opt in after dotfiles —
  deferred to the owner.

## Addendum (implementation, 2026-11-27)

Decisions 3 and the secret-inheritance assumption were invalidated by what
this forgejo instance actually does. Findings and resulting design:

1. **Cross-repo reusable workflows do not run on this forgejo (15.0.12).**
   With `uses: kevindurb/gh-mirror/.forgejo/workflows/mirror.yml@main`,
   dispatch returned 500 while the repo was private
   ("failed to access repo ... repo does not exist"). After making the repo
   public and switching to the fully-qualified URL, the dispatch returned 204
   but the expanded job was created and immediately failed, with no usable
   error in logs or API. Same-repo reusable call (`./.forgejo/workflows/...`)
   also failed instantly. The forgejo docs (v15.0.12) do describe the
   cross-repo syntax and claim support, but empirically it does not work
   here, and the logs surface nothing actionable. **Resolution:** the mirror
   workflow is fully inline in the consuming repo (`dotfiles/.forgejo/workflows/mirror.yml`);
   `gh-mirror` remains only as a reference copy. Adopting another repo =
   copying one file.
2. **`actions/create-github-app-token` cannot run here.** Both
   `actions/create-github-app-token@v3` and the full-URL form make the job
   fail immediately at setup. `actions/checkout` works fine, and the runner
   reaches github.com for downloads, so this is specific to this action's
   resolution/runtime on this forgejo. **Resolution:** token minting is done
   inline in the workflow: RS256 JWT signed with openssl, exchanged at
   `POST /app/installations/{id}/access_tokens` with the installation id
   discovered via `GET /app/installations`. No third-party actions at all.
3. **Boolean `workflow_dispatch` inputs arrive as strings** (`"true"`/"`false"`),
   so `if: ${{ ! inputs.dry_run }}` mis-evaluated (`!"false" == false`, push
   silently skipped while the run reported green). **Resolution:** a first
   `Resolve push intent` step normalises the input and every mutating step is
   guarded by `if: steps.opts.outputs.push == 'true'`.
4. **`secrets:` is not a valid key under `on.workflow_call`** ("workflow_call
   only supports keys inputs and outputs") — the callee is rejected as
   invalid and silently never scheduled (runs stuck in `waiting`). Moot after
   (1), but recorded for whoever next reaches for cross-repo reuse here.
5. **User-level secrets ARE visible to repo workflows** — verified by the
   mint step succeeding with `MIRROR_APP_CLIENT_ID`/`MIRROR_APP_PRIVATE_KEY`
   set only at user level. `secrets: inherit` semantics cross-repo were never
   reached (moot after (1)).
6. Everything verified end-to-end: dry-run green, real push synced GitHub to
   forgejo's `main`, hourly schedule + push triggers active, a rogue commit
   planted directly on GitHub `main` was force-overwritten by the next run,
   bogus-secret run fails fast and pushes nothing.

## Addendum 2 (2026-11-27): composite action, not inline

After Addendum item 1 landed the mirror as an inline per-repo workflow, the
question of sharing the implementation was revisited: cross-repo reusable
workflows are broken on this instance, but a **composite action** is cloned
into the caller's job like any other action, and side-steps the
`workflow_call` expansion machinery entirely. Verified working:

- `kevindurb/gh-mirror/action.yml` defines `mirror-to-github` (inputs:
  `app_client_id`, `app_private_key`, `dry_run`); steps identical to the
  proven inline version, minus the workflow envelope.
- `dotfiles` calls it with ~6 lines (`uses: https://forgejo.beaver-cloud.ts.net/
  kevindurb/gh-mirror@main` with `secrets.MIRROR_APP_*` passed explicitly).
- Push-triggered run succeeded; dry-run dispatch succeeded; GitHub `main`
  matches forgejo `main` (`29430fa`).
- Reusable-but-unreferenced alternative kept minimal: `gh-mirror` must stay
  readable by the runner (tailnet-public) since anonymous clone is how the
  runner fetches the action.

Final shape: composite action in `gh-mirror`; per-repo caller with the
same triggers; everything else unchanged.
