# Forgejo

Self-hosted git forge at `https://forgejo.beaver-cloud.ts.net` (web UI and HTTPS
git), SSH at `forgejo-ssh.beaver-cloud.ts.net:22`. Tailnet-only, no LAN/public
listeners, no MetalLB addresses. Implemented by the `add-forgejo` change.

> Status: migration in progress. CI still runs on the Tekton/tsgit stack until
> `remove-tsgit-tekton` lands; forgejo is the new source of truth for repos,
> not yet for CI. See `openspec/changes/add-forgejo/`.

## Access

| Thing        | URL / endpoint                                   |
| ------------ | ------------------------------------------------ |
| Web UI       | https://forgejo.beaver-cloud.ts.net              |
| HTTPS git    | `https://forgejo.beaver-cloud.ts.net/owner/repo` |
| SSH git      | `ssh://git@forgejo-ssh.beaver-cloud.ts.net/owner/repo.git` |
| Health       | `https://forgejo.beaver-cloud.ts.net/api/healthz` |

SSH uses a separate MagicDNS name (`forgejo-ssh`) because `forgejo` is the
HTTPS ingress VIP and a tailnet device and VIP service cannot share a name.
`SSH_DOMAIN` in forgejo's config points at `forgejo-ssh.beaver-cloud.ts.net`,
so the clone URLs shown in the UI are correct.

## Sign-in

- Interactive web sign-in is **pocket-id only**; local password sign-in is
  disabled (`[service] ENABLE_INTERNAL_SIGNIN = false`).
- pocket-id group membership maps to forgejo site admin: the `admins` group
  is passed through via the `groups` scope and matched by
  `--group-claim-name groups --admin-group admins` on the PocketID auth source.
  Users in `admins` become forgejo admins at next login.
- The pocket-id client is `forgejo` (callback
  `https://forgejo.beaver-cloud.ts.net/user/oauth2/PocketID/callback`), stored
  in the `forgejo-oidc` SealedSecret (`platform/forgejo/forgejo-oidc-sealed-secret.yml`).
- New users are auto-provisioned from OIDC claims on first login
  (`[oauth2_client] ENABLE_AUTO_REGISTRATION = true`). Username comes from the
  pocket-id `preferred_username`/nickname claim.
- Git over SSH uses SSH keys registered on the forgejo account; git over HTTPS
  uses personal access tokens. pocket-id is not involved in git operations.

## Break-glass admin

The chart-managed admin is disabled (`gitea.admin.username: ''`). A local
`forgejo-admin` account exists instead, created out-of-band:

```
kubectl exec -n forgejo deploy/forgejo -- \
  forgejo admin user create --admin --username forgejo-admin \
  --password "<password>" --email forgejo-admin@beaver-cloud.ts.net \
  --must-change-password=false
```

Its password lives in the `forgejo-admin` SealedSecret
(`platform/forgejo/forgejo-admin-sealed-secret.yml`, keys `username`/`password`).
Use it to recover from a broken SSO deployment. Local password sign-in is
disabled (`[service] ENABLE_INTERNAL_SIGNIN = false`), so break-glass means:
flip that value back to `true` in `platform/forgejo/app.yml`, let Argo CD roll
the pod, log in as `forgejo-admin`, fix the problem, flip it back. Do not
leave internal sign-in enabled. OIDC-provisioned site admins (see above) are
the normal path for administrative access; this account is only for
catastrophic SSO failure.

## Operations

- App: `platform/forgejo/` (Argo CD app `forgejo`, project `apps`, chart
  `forgejo` 17.3.3 from `code.forgejo.org/forgejo-helm`, OCI).
- Namespace `forgejo`, PSS `baseline` enforce / `restricted` warn+audit.
- Data: sqlite + repos on the `gitea-shared-storage` PVC (10Gi, `zfs-local`,
  replicated by zrepl) at `/data`.
- Image: `code.forgejo.org/forgejo/forgejo:15.0.12-rootless` (chart appVersion).
  Upgrade by bumping `targetRevision` in `platform/forgejo/app.yml`; read the
  chart's Upgrading notes before major bumps.
- Logs: `kubectl logs -n forgejo deploy/forgejo`.
- OIDC source is (re)applied on every pod start from the `forgejo-oidc`
  secret (init container runs `gitea admin auth add-oauth`).

## Migration from tsgit

Status as of 2026-11-27: `kevindurb/dotfiles` was migrated with full history
(`git push --mirror`); tip SHA matches tsgit (`be37d6c`). SSH clone/push from a
tailnet peer verified.

- `kevindurb/dotfiles` — migrated. Push-mirrors to `github.com/kevindurb/dotfiles`
  (mirror configured in forgejo → repo → Settings → Mirror Settings; the PAT is
  a fine-grained GitHub token with Contents: Read/Write on that one repo, stored
  only in forgejo). Treat GitHub as read-only for this repo.
- `kevindurb/ci` — **stays on tsgit** for now (owner decision, 2026-11-27). It is
  not migrated and gets no mirror. Revisit when `remove-tsgit-tekton` lands.
- No other repos exist on tsgit, so the "image-building repos" scope item resolved
  to exactly these two.
- CI still runs on the Tekton/tsgit stack; forgejo is a git host only until
  `add-forgejo-runner` lands and `remove-tsgit-tekton` follows. Nothing in
  forgejo builds or tests code yet.

## TODO before this doc is final

- [x] SSO round-trip verified in a private window
- [x] `ENABLE_INTERNAL_SIGNIN=false` flipped and local login confirmed disabled
- [x] Break-glass password login verified (before the flip)
- [x] Repo migration SHAs match tsgit
- [ ] Push mirror verified with a test commit
- [x] Mirror policy for non-dotfiles repos documented
- [ ] Gatus green; runner/`add-forgejo-runner` handoff noted
