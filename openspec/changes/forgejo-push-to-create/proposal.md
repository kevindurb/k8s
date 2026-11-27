# Proposal

## Why

Forgejo is the forge going forward (replacing the tsgit experiment), but it
launched without one of tsgit's behaviors: creating a repository by pushing
to a nonexistent path. Right now every new repository requires a detour through
the web UI or the API before the first `git push`. That parity gap was a planned
property of the old spec and is the remaining convenience loss from the
migration.

## What Changes

- Enable push-to-create in forgejo's `[repository]` config:
  `ENABLE_PUSH_CREATE_USER=true` and `ENABLE_PUSH_CREATE_ORG=true`, set in the
  Helm values (`gitea.config.repository`) in `platform/forgejo/app.yml`.
- Pin `DEFAULT_PUSH_CREATE_PRIVATE=true` (the upstream default) so
  push-created repositories are private unless the pusher explicitly opts out
  with `git push -o repo.private=false` — keeping the spec's "repositories are
  private by default" guarantee explicit rather than inherited.
- Document the workflow (and the `repo.private` push option) in
  `docs/forgejo.md`.
- Verify on the live instance after sync: a scratch push over SSH and over
  HTTPS creates a private repo; delete the scratch repos afterwards.

Non-goals:

- No change to `MAX_CREATION_LIMIT` (stays unlimited; single-user instance).
- No `FORCE_PRIVATE`; explicit public pushes stay possible as an intentional
  act.
- No change to the GitHub-mirror automation; push-created repositories remain
  un-mirrored unless a mirror workflow is added per repo.
- No new orgs, users, or tokens are created.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `forgejo`: add a "Repository creation on first push" requirement — a write-capable
  identity can create a private repository by pushing to a nonexistent path in
  its own namespace or in an organization it belongs to; push-created repositories
  are private unless the pusher explicitly opts out.

## Impact

- `platform/forgejo/app.yml` — three new keys under `gitea.config.repository`;
  Argo CD sync rolls the deployment (config is injected via `GITEA_APP_INI`).
- `docs/forgejo.md` — new short section documenting push-to-create and the
  `repo.private` push option.
- No new secrets, workloads, or RBAC. No data migration. Behavior change is
  limited to authenticated git users being able to create repositories they
  already had the right to create via the UI.
- Blast radius is bounded by existing authn/z: sign-up is disabled, only
  pocket-id-provisioned accounts can sign in, and today that is a single
  user. Visibility stays private by default.
