# Tasks

This change spans two repositories: this repo (GitOps + VM manifests) and
`kevindurb/bootc` (the runner image build). Cross-repo tasks are marked.
Depends on: `install-kubevirt` applied (its VM is the runner).

## 1. Forgejo chart and namespace

- [ ] 1.1 Choose and pin the official `forgejo` Helm chart version; vendor the values into `platform/forgejo/` (app.yml with Helm source, `values.yaml`: sqlite on zfs-local 10Gi PVC, resources ~250m/256Mi requests, `gitea.metrics.enabled` off, ingress off — tailscale ingress defined manually)
- [ ] 1.2 Create SealedSecret `forgejo-oidc` (pocket-id client secret) via `kubeseal`; namespace `forgejo` created by the Application with baseline PSS labels
- [ ] 1.3 Create SealedSecret `forgejo-admin` (break-glass admin password) — document both only as references, never plaintext
- [ ] 1.4 Create ingress: `forgejo.beaver-cloud.ts.net` via `ingressClassName: tailscale` (web+HTTPS git), and a `type: LoadBalancer`, `loadBalancerClass: tailscale` Service for SSH (`forgejo-ssh`, port 22) — no MetalLB, no LAN listener
- [ ] 1.5 gatus endpoint for `https://forgejo.beaver-cloud.ts.net/api/healthz`
- [ ] 1.6 `kustomize build platform/forgejo` passes; add to `platform/kustomization.yml`; sync via Argo CD

## 2. Pocket-ID OIDC wiring

- [ ] 2.1 In the pocket-id admin UI, create OIDC client `forgejo` with redirect URI `https://forgejo.beaver-cloud.ts.net/user/oauth2/PocketID/callback` (note exact callback path from forgejo docs); capture client ID/secret
- [ ] 2.2 Seal the client secret into the `forgejo-oidc` SealedSecret (1.3)
- [ ] 2.3 Add OAuth2/OpenID source in forgejo (config via helm values `gitea.oauth.pocketid` or via admin API on first boot — pick whichever the chart supports cleanly; document choice in design follow-ups); disable local password sign-in after OIDC verified (keep break-glass admin reachable)
- [ ] 2.4 Verify: incognito browser → forgejo → redirected to pocket-id → lands in forgejo logged in as your user; avatar/name correct

## 3. Repository hosting setup

- [ ] 3.1 Create orgs/repos structure (e.g. user namespace only — keep it simple: personal repos); disable public registration
- [ ] 3.2 Create initial admin/user account via `forgejo admin user` on first boot (or disable install page via env) — document exact steps
- [ ] 3.3 Create the forgejo SSH host key; verify `ssh -p 22 forgejo.beaver-cloud.ts.net` from a tailnet laptop authenticates with user key
- [ ] 3.4 Create fine-grained GitHub PAT for `kevindurb/dotfiles` (Contents: read/write) and store as the push-mirror credential in forgejo (via forgejo admin CLI or UI; never in git)
- [ ] 3.5 Push-mirror `dotfiles` forgejo→GitHub; verify a test commit on forgejo `main` appears on GitHub within minutes (watch the mirror job in forgejo admin → mirrors)

## 4. Runner image (repo: kevindurb/bootc)

- [ ] 4.1 In `containers/ci-runner/`: Containerfile FROM `quay.io/fedora/fedora-bootc:latest` (pinned digest) — `dnf install podman git git-lfs make`, install `forgejo-runner` (pinned release binary from codeberg.org, checksum-verified), systemd unit `forgejo-runner.service` enabled that runs `forgejo-runner daemon --config /etc/forgejo-runner/config.yaml`
- [ ] 4.2 Wire `ci-runner` into `.github/workflows/build.yml` using the existing `reusable-build.yml` pattern; confirm the build publishes `ghcr.io/kevindurb/ci-runner:latest` (and a dated tag); image must be **public** on GHCR so KubeVirt can pull without credentials (or create a SealedSecret + imagePullSecret — pick one, document)
- [ ] 4.3 Extend the pipeline (or add `build-disk.yml`) to run `bootc-image-builder` producing a qcow2, wrap it in a containerDisk (`FROM scratch`, `COPY ci-runner.qcow2 /disk/disk.img`), push as `ghcr.io/kevindurb/ci-runner-disk:<sametag>`, signed with the repo's existing cosign flow
- [ ] 4.4 Verify: pull the disk image manifest from a clean machine (`skopeo inspect`), note exact tag; record the chosen tag for the VM manifest

## 5. Runner VM (this repo)

- [ ] 5.1 Create `infrastructure/ci-runner/` app (`app.yml`, target namespace `ci-runner`, automated sync): `VirtualMachine` `ci-runner` (2 vCPU, 4 Gi memory, 20 Gi containerDisk via `containerDisk` imageName `ghcr.io/kevindurb/ci-runner-disk:<tag>`), `nodeSelector: kubernetes.io/hostname: drone-01|drone-02|drone-03` (affinity terms), masquerade network, no tolerations for control-plane or drone-04
- [ ] 5.2 Cloud-init (cloudInitNoCloud with inline userData via SealedSecret): write `/etc/forgejo-runner/config.yaml` (instance `https://forgejo.beaver-cloud.ts.net`, one runner, `capacity: 1`, labels `self-hosted,linux`) and registration token; enable/start `forgejo-runner`
- [ ] 5.3 SealedSecret `runner-registration-token` (token minted in forgejo: site administration → runner registration token)
- [ ] 5.4 Register app in `infrastructure/kustomization.yml`; `kustomize build`; push; Argo syncs
- [ ] 5.5 Verify: VM `Running`, pod `virt-launcher-*` healthy; forgejo Settings → Runners shows `ci-runner-0` **Online**; a job lands and executes (next task proves it)

## 6. Migrate dotfiles (first repo)

- [ ] 6.1 From a laptop: fresh clone of tsgit `dotfiles`; create `dotfiles` in forgejo; `git push --mirror`; confirm SHAs match (`git rev-parse main` on both)
- [ ] 6.2 Add push mirror forgejo→GitHub for dotfiles; push a test commit; confirm GitHub `main` updates and mirror health is OK
- [ ] 6.3 Replace `ci/pipeline.yaml` usage with `.forgejo/workflows/ci.yml` implementing: checkout, chezmoi pinned (same version as before) `--dry-run` render of the repo, shellcheck on all `*.sh`/hooks (same semantics as the Tekton pipeline)
- [ ] 6.4 Push; confirm the workflow runs on forgejo and passes; deliberately break a template on a scratch branch, confirm red, then revert
- [ ] 6.5 Announce/note the new canonical remote for clones (`https://forgejo.beaver-cloud.ts.net/kevindurb/dotfiles.git`); update local remote on dev machines (`git remote set-url origin ...`)

## 7. Migrate the image-building repos

- [ ] 7.1 Enumerate the image-building repos (grep GitHub for `podman build` under kevindurb/*); confirm the list with owner before migrating any
- [ ] 7.2 For each repo: mirror-push to forgejo (same procedure as 6.1), rewrite workflows to forgejo syntax (`runs-on: [self-hosted, linux]`, keep `podman build/push` unchanged), move `.github/workflows/*` → `.forgejo/workflows/*` (or delete GH copies so builds don't double-run)
- [ ] 7.3 Add GHCR push credential to forgejo (org-level secret or per-repo Actions secret); ensure `packages:write` scope
- [ ] 7.4 Push and watch each build go green in forgejo; confirm the image lands in GHCR and Renovate (running on GitHub) can still see it (GHCR public or token works for Renovate as before)

## 8. Wrap-up

- [ ] 8.1 Write `docs/forgejo.md`: architecture, SSO, SSH setup, adding a repo, adding a runner/rotating its token, rebuilding the runner image, what to do when the VM dies
- [ ] 8.2 Remove `192.168.42.222/32 # forgejo ssh` from `infrastructure/metallb/address-pool.yml` (land with the `remove-tsgit-tekton` change instead if preferred — note in that change either way)
- [ ] 8.3 Final smoke: fresh private clone via SSH, push, see CI run, see mirror on GitHub; `just check-kustomize` green
- [ ] 8.4 Hand off to `remove-tsgit-tekton` (do not delete tekton/tsgit in this change)

## Workflow follow-up

- Archive this change after `remove-tsgit-tekton` is merged and the dust settles.
- Consider CDI-backed per-job ephemeral VMs as a follow-up if parallel builds or faster cold start ever matter (not now).
