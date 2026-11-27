# Proposal

## Why

Forgejo is the primary forge now, but the GitHub copies of repositories still
matter (the `github.com/kevindurb/*` mirrors that Renovate, outside readers, and
historical links point at). The planned mechanism — forgejo's built-in push
mirror — was never switched on (`push_mirrors` is empty and the GitHub copy of
`dotfiles` is 15+ commits stale as of 2026-11-27) and requires a long-lived
static GitHub PAT stored in forgejo. We want a mirror that

- holds no long-lived GitHub credential anywhere,
- is defined as code, reviewable in git, and observable in the forgejo UI, and
- works uniformly for dotfiles today and for any future forgejo repository
  that opts in.

A per-repo GitHub App installation token minted at job time is the mechanism:
short-lived, scoped to the repos the app is installed on, and mintable from a
workflow without human interaction.

## What Changes

- A new GitHub App (**`kevindurb-forgejo-mirror`**, App ID 5954313), owned by
  the `kevindurb` account, installed on **all** repositories, with
  `contents: write` and `workflows: write` and nothing else. App ID +
  private key are stored as **user-level secrets** in forgejo
  (`MIRROR_APP_CLIENT_ID` / `MIRROR_APP_PRIVATE_KEY`).
- A mirror workflow in the adopting repository
  (`dotfiles/.forgejo/workflows/mirror.yml`) mints an installation token at
  run time (inline openssl+curl exchange — this forgejo cannot run
  `actions/create-github-app-token`), force-updates `refs/heads/*` and
  `refs/tags/*` on the corresponding GitHub repo, and verifies both remotes
  agree (`git ls-remote` comparison) before succeeding. It never deletes refs.
  The GitHub repository must already exist (App installation tokens cannot
  create repositories); a missing repo fails the run with a clear message.
  **The mirror logic ships as a composite action** in `kevindurb/gh-mirror`
  (cross-repo reusable *workflows* do not run on forgejo 15.0.12 — composite
  actions do); consumer repos call it with a ~6-line workflow.
- `dotfiles` adopts the mirror via that workflow, triggered on push to any
  branch, on tags, hourly, and on demand; a `dry-run` input computes the ref
  diff without pushing.
- `docs/forgejo.md` is updated: the stale-mirror note is replaced with the
  new mechanism; the manual PAT creation planned in `add-forgejo` task 4.3 is
  superseded (that change's task list is updated to point at this one).
- Explicitly out of scope: pushing images to GHCR from forgejo CI (GitHub App
  installation tokens are rejected by GHCR for package writes — upstream
  limitation, tracked in octo-sts#840; image builds stay on GitHub Actions per
  the 2026-11-27 decision), OIDC/WIF via tsiam (rejected: disproportionate
  complexity for this use case), and migrating any additional repos to the
  mirror (dotfiles is the pilot).

BREAKING: none. The GitHub mirror moves from "not configured" to "CI-driven".

## Capabilities

### New Capabilities
- `github-mirror`: mirroring forgejo repositories to GitHub via a per-repo
  CI workflow that mints GitHub App installation tokens at run time —
  what gets mirrored (branches/tags, never deletes), how authentication works,
  how failure is detected, and how a repo opts in.

### Modified Capabilities
- None. (`add-forgejo`'s task 4.3 is updated to reference this change, but no
  requirement in an existing spec changes.)

## Impact

- New repository on `forgejo.beaver-cloud.ts.net`: `gh-mirror` (public to
  the tailnet; hosts the `mirror-to-github` composite action).
- New GitHub App on `kevindurb`; new user-level Actions secrets in forgejo.
- `kevindurb/dotfiles` gains `.forgejo/workflows/mirror.yml` (on forgejo) and
  its GitHub copy starts receiving forced branch/tag updates after the first
  run.
- Docs: `docs/forgejo.md` in this repo; `add-forgejo` tasks.md note.
- GitHub-side main branches must tolerate force-pushes from the app (GitHub
  branch protection, if any, must allow the app — verified during rollout).
- No change to cluster manifests, Argo CD, or the runner VM image.
