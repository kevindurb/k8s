# Tasks

## 1. GitHub App (manual, GitHub side)

- [x] 1.1 Create the GitHub App under the `kevindurb` account. **Actual name:
  `kevindurb-forgejo-mirror`** (the bare `forgejo-mirror` was taken);
  Client ID `Iv23liby7P8kjC22nKCZ`, App ID 5954313. Permissions:
  `contents: write`, `workflows: write`, metadata read. No others — verified
  via `/app` API response (`{"contents":"write","metadata":"read","workflows":"write"}`).
- [x] 1.2 Installed on **all** repositories (`repository_selection: all`,
  installation id 186530835 — verified via `/app/installations`).
- [x] 1.3 Private key generated. App ID/Client ID recorded above. Key stored
  only as forgejo secret `MIRROR_APP_PRIVATE_KEY`; temporary local copies
  shredded; original remains at `/tmp/opencode/uploads/.../kevindurb-forgejo-mirror.2026-11-27.private-key.pem`
  (user's copy — delete if unwanted).

## 2. forgejo-side secrets and repo

- [x] 2.1 User-level forgejo secrets `MIRROR_APP_CLIENT_ID` and
  `MIRROR_APP_PRIVATE_KEY` created via the API (`PUT /api/v1/user/actions/secrets/{name}`,
  both HTTP 201). Verified indirectly: the mirror run minted a token using
  them successfully.
- [x] 2.2 forgejo repo `kevindurb/gh-mirror` created (public on the tailnet).
  Hosts the shared `mirror-to-github` composite action. `git ls-remote` verified.
- [x] 2.3 User-level secrets ARE visible to repo workflows (proven: token
  mint succeeded). Inherited via explicit `with:` inputs in the caller, not
  `secrets: inherit`.

## 3. Workflow implementation

- [x] 3.1 **Deviation from plan:** forgejo 15.0.12 cannot execute cross-repo
  reusable workflows here — same-instance shorthand and full URL both produce
  runs that fail instantly (or hang "waiting"). `actions/create-github-app-token@v3`
  also fails instantly. Final implementation: a composite action
  (`kevindurb/gh-mirror/action.yml`, steps: fetch forgejo refs → mint app
  installation token inline with openssl+curl → existence check of the GitHub
  repo → force-push `refs/heads/*`+`refs/tags/*` → `ls-remote` verify both
  remotes match), called by a ~6-line `.forgejo/workflows/mirror.yml` in
  `dotfiles`. Triggers: push (branches+tags), hourly schedule, `workflow_dispatch`
  with `dry_run`.
- [x] 3.2 `gh-mirror/README.md` documents the composite action, caller
  snippet, prerequisites, GHCR limitation, and the workflow_call/create-github-app-token
  instance limitations.
- [x] 3.3 `actions/create-github-app-token` does NOT run on this runner
  (bisected: both ref styles fail instantly). Replaced with an inline
  openssl/curl mint (JWT RS256 → `POST /app/installations/{id}/access_tokens`,
  installation id discovered via `GET /app/installations`). "Mirror verified:
  GitHub refs identical to forgejo." appears in green runs.

## 4. dotfiles opt-in (GitHub side prep)

- [x] 4.1 `gh api repos/kevindurb/dotfiles/branches/main/protection` → 404
  (not protected) — nothing blocks the app's force-pushes. (GitHub copy is a
  mirror; forgejo is authoritative.)
- [x] 4.2 GitHub `kevindurb/dotfiles` exists; `main` was `84e6ed4` at check
  time, now mirrors forgejo exactly.

## 5. Verify end to end

- [x] 5.1 `dotfiles/.forgejo/workflows/mirror.yml` in place: pushes to
  branches/tags, hourly schedule, `workflow_dispatch` with `dry_run` input.
- [x] 5.2 Dry-run green: prints the ref diff, pushes nothing, exits 0.
- [x] 5.3 Real dispatch succeeded; GitHub `main` == forgejo `main`
  (`ccd90c7`). Push-triggered run (#43, on the commit enabling triggers) also green.
- [x] 5.4 Failure path checked: `MIRROR_APP_CLIENT_ID` swapped for a bogus
  value → run failed fast in the mint step, nothing pushed. Correct value
  restored (204) and re-verified green.
- [x] 5.5 Drift repair verified: planted a rogue commit on GitHub `main` via
  the contents API; next dispatch force-pushed forgejo's refs over it; the
  rogue file is gone from GitHub (404) and both remotes match.

## 6. Docs and housekeeping

- [x] 6.1 `docs/forgejo.md` updated: stale-mirror note replaced with the
  implemented mechanism, the forgejo-specific gotchas (workflow_call has no
  secrets key, no cross-repo reusable workflows, boolean inputs arrive as
  strings, `create-github-app-token` unusable), and the GHCR limitation.
- [x] 6.2 `openspec/changes/add-forgejo/tasks.md` 4.3 marked superseded by
  this change.
- [x] 6.3 `openspec validate add-github-mirror --strict` — run after artifact
  fixes (see below).

## Workflow follow-up

- Archive the change after implementation is verified (done above).
- `gh-mirror` on forgejo is the live source of the composite action — do not delete it.
- Each additional adopting repo adds the ~6-line caller from
  gh-mirror's README (docs/forgejo.md); no implementation is copied.
