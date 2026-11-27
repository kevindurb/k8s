# Forgejo

Self-hosted git forge at `https://forgejo.beaver-cloud.ts.net` (web UI and HTTPS
git), SSH at `forgejo-ssh.beaver-cloud.ts.net:22`. Tailnet-only, no LAN/public
listeners, no MetalLB addresses. Implemented by the `add-forgejo` change.

> Status: `dotfiles` CI runs on forgejo Actions (self-hosted runner, see
> below) since 2026-11-27. The Tekton/tsgit stack still serves anything that
> has not been migrated; its removal is `remove-tsgit-tekton`. See
> `openspec/changes/add-forgejo-runner/`.

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

- `kevindurb/dotfiles` — migrated. **The push-mirror to `github.com/kevindurb/dotfiles` is NOT active as of 2026-11-27** (verified: `push_mirrors` API returns `[]`, and GitHub's tip `84e6ed4` is an ancestor of forgejo's `main`, 15+ commits behind — the GitHub copy is stale). The mirror needs to be (re)created in repo Settings → Mirror Settings (or the docs corrected); see `add-forgejo` tasks 4.3/5.3. Until then, treat GitHub as read-only *and stale*. Its CI
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

## TODO before this doc is final

- [x] SSO round-trip verified in a private window
- [x] `ENABLE_INTERNAL_SIGNIN=false` flipped and local login confirmed disabled
- [x] Break-glass password login verified (before the flip)
- [x] Repo migration SHAs match tsgit
- [ ] Push mirror verified with a test commit
- [x] Mirror policy for non-dotfiles repos documented
- [x] Gatus green; runner/`add-forgejo-runner` handoff noted
