# Forgejo

Self-hosted git forge at `https://forgejo.beaver-cloud.ts.net` (web UI and HTTPS
git), SSH at `forgejo-ssh.beaver-cloud.ts.net:22`. Tailnet-only, no LAN/public
listeners, no MetalLB addresses. Implemented by the `add-forgejo` change.

> Status: `dotfiles` CI runs on forgejo Actions (self-hosted runner, see
> below) since 2026-11-27. The Tekton/tsgit stack still serves anything that
> has not been migrated; its removal is `remove-tsgit-tekton`. See
> `openspec/changes/archive/2026-11-27-add-forgejo-runner/`.

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

## Push to create

Forgejo is configured with push-to-create (enabled 2026-11-27): pushing to a
repository path that does not exist yet creates the repository instead of
failing. Both user and organization namespaces are allowed
(`ENABLE_PUSH_CREATE_USER` / `ENABLE_PUSH_CREATE_ORG: true`). The created
repository is **private** by default (`DEFAULT_PUSH_CREATE_PRIVATE: true`);
opt out per push with `git push -o repo.private=false`.

```console
$ git remote add origin ssh://git@forgejo-ssh.beaver-cloud.ts.net/kevindurb/new-repo.git
$ git push -u origin main
```

Works over SSH and HTTPS remotes alike. In organizations, the push succeeds
if you may create repositories there; otherwise it is rejected and no
repository is created. Push-created repositories are **not** auto-mirrored to
GitHub — the mirror workflow is opt-in per repository (see "GitHub mirror"
below). Typo-created repositories can be deleted in the UI like any other.

## CI runner (`add-forgejo-runner`, since 2026-11-27)

Forgejo Actions runs on a self-hosted runner, **not** in pods: a single
`VirtualMachine` (`infrastructure/ci-runner`, Argo app `ci-runner`) in the
`ci-runner` namespace on drone-01..03 (2 vCPU / 4 GiB, ephemeral overlay
root — state does not survive VM recreation).

- **Image**: `ghcr.io/kevindurb/ci-runner` (bootc, Fedora 44): podman,
  buildah, podman-docker, skopeo, git, git-lfs, make, jq, nodejs,
  `forgejo-runner` v13.2.2 (pinned, sha256-verified at build), plus
  `cloud-init`. Built by `kevindurb/bootc` (`containers/ci-runner/`);
  cosign-signed (same key as the node image).
- **Disk**: the VM boots a KubeVirt containerDisk,
  `ghcr.io/kevindurb/ci-runner-disk:2026.11.27` — the fedora-bootc qcow2
  wrapped in a scratch image. cosign-signed. **The GH-hosted runners cannot
  build the qcow2** (osbuild needs nested user namespaces, which Ubuntu's
  `kernel.apparmor_restrict_unprivileged_userns=1` blocks; `/dev/kvm` exists
  but manifest generation itself dies in the sandbox). The qcow2 is therefore
  built on a Fedora host with `image-builder` (see the release notes on
  `kevindurb/bootc` → `ci-runner-disk/2026.11.27`) and published as a GitHub
  release asset; `build-runner-disk.yml` in that repo repacks the asset into
  the containerDisk and signs it. Rebuild: repeat the command in the release
  notes on any unrestricted Fedora/RHEL host, upload a new
  `ci-runner-disk/<date>` release (qcow2.xz + .sha256), and the workflow
  publishes+signs the images automatically.
  **Planned follow-up (owner, 2026-11-27):** move the repo to forgejo and run
  the disk build in Forgejo Actions — the runner VM itself has working
  namespaces/KVM, so `image-builder` can run there and the GHCR round-trip
  disappears. Until then, the release-asset flow above stands.
- **Registration**: first boot, cloud-init (`ci-runner-cloudinit`
  SealedSecret → NoCloud `userData`) writes `/etc/forgejo-runner/config.yaml`
  (capacity 1, labels `self-hosted,linux`), registers with
  `forgejo-runner register --no-interactive` using the token in
  `/run/secrets/ci-runner-token` (tmpfs, deleted after registration), and
  starts `forgejo-runner.service`. The `.runner` credentials live in
  `/var/lib/forgejo-runner/` on the VM's ephemeral root.
- **Draining/reboot**: the VM is recreated from the pinned image (a drain
  migrates or recreates it; containerDisk VMs are migratable, so KubeVirt
  default `LiveMigrate` applies). On recreation it registers again with the
  same token — the stale duplicate entry in Site administration → Actions →
  Runners can be deleted there, or rotate the token (below).
- **Job environment**: jobs run as root directly on the VM (host backend),
  not in containers. `podman`/`podman build` work unmodified. No
  privileged *pods* are involved anywhere; the podman socket is not exposed
  to jobs except as the local `/run/podman/podman.sock` inside the VM.
- **Capacity**: 1 job at a time; queue via forgejo. Podman cache survives
  normal VM reboots but is wiped by the hourly `podman system prune -f`
  systemd timer and by VM recreation (recreation is always a cold start).
- **Reading logs**: web UI → repo → Actions → job, or on the server:
  `kubectl exec -n forgejo deploy/forgejo -- ls /data/actions_log/<owner>/<repo>/`
  and `zstd -d` the `<run-id>.log.zst`.
- **Adding/replacing runners**: bump `infrastructure/ci-runner/vm.yaml`
  (`containerDisk` tag) and let Argo sync. For a *second* runner, copy the
  app with a new name and a fresh registration token sealed separately.
- **Rotating the registration token**:
  1. `kubectl exec -n forgejo deploy/forgejo -- forgejo actions generate-runner-token`
  2. Re-create the `ci-runner-cloudinit` secret with the new token
     (delete the `SealedSecret`, re-seal, commit, let Argo apply).
  3. `kubectl -n ci-runner delete vmi ci-runner` — it re-registers on boot.
  4. Delete the stale runner entry in Site administration → Actions → Runners.
- **No gatus check** is added for the VM (it has no HTTP endpoint); the
  existing gatus check on the forgejo URL is the availability signal, and
  runner presence is visible in the forgejo UI / `admin/actions/runners` API.
- Token rotation note: the registration token used at first boot is consumed
  at registration time only; the runner's long-lived credential is the
  `.runner` file inside the VM.

### Verifying the pipeline

`dotfiles` `main` is green (run on `c61358f`, 2026-11-27). `ci-negative-test`
(unbalanced `{{`) fails at the render step as expected. Smoke-tested with podman
(`hello-world`, `podman build`) on a scratch repo (since deleted). Context:
JS actions run on the VM's nodejs 22.

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

- `kevindurb/dotfiles` — migrated. **GitHub mirror is now CI-driven (since
  2026-11-27)**: `.forgejo/workflows/mirror.yml` on forgejo runs on every
  push to any branch/tag, hourly, and on demand. It mints a short-lived
  GitHub App installation token (app `kevindurb-forgejo-mirror`) and
  force-pushes `refs/heads/*` + `refs/tags/*` to `github.com/kevindurb/dotfiles`,
  then verifies both remotes match. Branches/tags deleted on forgejo are NOT
  deleted on GitHub. GitHub is otherwise read-only for this repo — commits land
  on forgejo and flow outward; anything pushed directly to GitHub is
  overwritten by the next mirror run. Its CI
  (`.forgejo/workflows/ci.yml`: chezmoi dry-run + shellcheck) runs on the
  forgejo runner; the Tekton `ci/pipeline.yaml` is kept for reference until
  `remove-tsgit-tekton` lands.
- The image-building repos (`bootc`, `containers`, `box`, `ts-forge`) were
  enumerated 2026-11-27 for migration to the forgejo runner; none are migrated
  yet (owner decision — runner is amd64-only and these build multi-arch). They
  keep building on GitHub Actions.
- `kevindurb/ci` — **stays on tsgit** for now (owner decision, 2026-11-27). It is
  not migrated and gets no mirror. Revisit when `remove-tsgit-tekton` lands.
- No other repos exist on tsgit, so the "image-building repos" scope item resolved
  to exactly these two.
- CI runs on forgejo for `dotfiles` only; the other migrated repo (`ci`) does
  not exist on forgejo. Image-building repos remain on GitHub Actions.

## GitHub mirror (forgejo → github.com)

Since 2026-11-27, `dotfiles` carries `.forgejo/workflows/mirror.yml`, which
mirrors it to `github.com/kevindurb/dotfiles` on every push (branches and
tags), hourly, and on manual dispatch. Git is force-pushed from forgejo, so
forgejo is authoritative; refs are never deleted on GitHub.

Design (see `openspec/changes/archive/2026-11-27-add-github-mirror/` in this repo for the full
change):

- Auth comes from the GitHub App **kevindurb-forgejo-mirror** (app id 5954313,
  client id `Iv23liby7P8kjC22nKCZ`), installed on all repos of the `kevindurb`
  account with `contents: write` + `workflows: write` only. Per-run the
  workflow signs a 10-minute RS256 JWT with the app private key (openssl),
  exchanges it for a 1-hour installation token via the GitHub API, and pushes
  with `git`. No long-lived GitHub credential exists anywhere in forgejo;
  the app key lives only in forgejo user-level secrets
  `MIRROR_APP_CLIENT_ID` / `MIRROR_APP_PRIVATE_KEY`.
- A GitHub App cannot push packages, so **GHCR pushes are impossible from
  this setup**; image builds stay on GitHub Actions.
- forgejo 15.0.12 quirks that shaped the implementation (all verified
  2026-11-27):
  - Cross-repo reusable **workflows** (`uses: owner/repo/.forgejo/workflows/x.yml@main`,
    and the full-URL form) do not run on this instance — the expanded job
    fails immediately or sits in `waiting` forever; the logs show nothing
    actionable. A composite **action** (`uses: <repo>@ref`, steps inlined
    into the caller's job) works fine — this is the reuse mechanism.
  - `actions/create-github-app-token` cannot be used (job fails at setup with
    both the shorthand and the full URL). Token minting is done inline with
    openssl + curl against `api.github.com`.
  - Boolean workflow inputs arrive as the *strings* `"true"`/`"false"`, so
    `if: ${{ inputs.dry_run }}`-style gating is unreliable; the action
    normalises via a `Resolve push intent` step instead.
  - `secrets:` is not a supported key of `on.workflow_call`.
- The mirror logic lives in the composite action `kevindurb/gh-mirror`
  (`action.yml`); each consumer repo calls it with ~6 lines of caller YAML,
  passing `MIRROR_APP_CLIENT_ID` / `MIRROR_APP_PRIVATE_KEY` from secrets.
- The forgejo-side runner must be up for the mirror to run; a push missed
  while it is down is repaired by the hourly run.
- Adopting another repo: create the private GitHub repo of the same name and
  copy the ~6-line caller workflow from `kevindurb/gh-mirror`'s README
  (`.forgejo/workflows/mirror.yml`) — the logic lives in the shared
  `kevindurb/gh-mirror` composite action; no copying of the implementation.
  Confirm a `workflow_dispatch` dry-run goes green, then push.


## TODO before this doc is final

- [x] SSO round-trip verified in a private window
- [x] `ENABLE_INTERNAL_SIGNIN=false` flipped and local login confirmed disabled
- [x] Break-glass password login verified (before the flip)
- [x] Repo migration SHAs match tsgit
- [x] Push mirror verified with a test commit (2026-11-27 — see "GitHub mirror" above; stray direct push to GitHub was force-overwritten by the mirror)
- [x] Mirror policy for non-dotfiles repos documented
- [x] Gatus green; runner/`add-forgejo-runner` handoff noted
