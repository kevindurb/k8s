# Tasks

Depends on: nothing (parallel with `install-kubevirt`). Blocks: `add-forgejo-runner`.

## 1. Forgejo chart and namespace

- [x] 1.1 Create `platform/forgejo/kustomization.yml` + `app.yml` (Argo Application; official `forgejo` Helm chart, pinned version; project `platform`-tier like pocket-id — match pocket-id's project setting)
- [x] 1.2 Helm values: sqlite on a `zfs-local` PVC (10Gi), service ports http/22, resources ~500m/512Mi limit, `securityContext.runAsNonRoot`, `gitea.admin` disabled in values (admin created via CLI instead), metrics off
- [x] 1.3 SealedSecrets: `forgejo-oidc` (pocket-id client secret — created in step 2), `forgejo-admin` (break-glass password)
- [x] 1.4 Ingress for web+HTTPS git (`ingressClassName: tailscale`, host `forgejo.beaver-cloud.ts.net`) and `type: LoadBalancer` / `loadBalancerClass: tailscale` Service for SSH port 22; no MetalLB involvement
- [x] 1.5 `platform/kustomization.yml` registers the app; `just check-kustomize` passes

## 2. pocket-id OIDC

- [x] 2.1 In pocket-id admin: create client `forgejo` with redirect URI `https://forgejo.beaver-cloud.ts.net/user/oauth2/PocketID/callback` (confirm exact path from the running forgejo version); scopes: openid profile email
- [x] 2.2 Seal the client secret (`forgejo-oidc`); wire into chart values/oauth config (values key per chart docs — verify against the pinned chart's values.yaml)
- [x] 2.3 Verify SSO round-trip in a private window; only then disable local password sign-in (keep break-glass admin working); verify break-glass login works with the sealed password

## 3. Namespace, secrets, first boot

- [x] 3.1 Confirm the Argo app creates the `forgejo` namespace with baseline/restricted PSS labels (matching other apps in `platform/`)
- [x] 3.2 Sync via Argo CD; pod Running; `kubectl logs` shows forgejo ready; sqlite file present on the PVC (`kubectl exec` + `ls`)
- [x] 3.3 `docs/forgejo.md` stub created with URLs and the admin/SSH bootstrap steps taken (fill in at the end)

## 4. Repositories and migration

- [x] 4.1 Create repos in forgejo: `dotfiles` created (private). `ci` stays on tsgit per owner decision — no image-building repos existed on tsgit
- [x] 4.2 From a laptop: clone each from tsgit; `git push --mirror forgejo <url>`; verify SHA equality (`git rev-parse main` forgejo vs tsgit) for every migrated repo
- [x] 4.3 superseded by `add-github-mirror` (2026-11-27): instead of a static fine-grained PAT + forgejo push-mirror, `dotfiles` now mirrors to GitHub via a forgejo Actions workflow that mints a short-lived GitHub App installation token (app `kevindurb-forgejo-mirror`) and force-pushes branches/tags on every push + hourly. Verified: GitHub `main` == forgejo `main` (`ccd90c7`), and a rogue direct commit on GitHub was force-overwritten on the next run. See `docs/forgejo.md` → "GitHub mirror".
- [x] 4.4 Decide + record the mirror policy for the image-building repos (mirror vs GitHub-only-read mirror vs none); document in `docs/forgejo.md` (decision: dotfiles mirrors to GitHub; `ci` not migrated, no mirror)

## 5. Verification

- [ ] 5.1 Anonymous `curl https://forgejo.beaver-cloud.ts.net/` from outside the tailnet (e.g. phone on LTE) gets nothing; from a tailnet peer it returns the login page
- [x] 5.2 Fresh SSH clone + push of `dotfiles` from a tailnet laptop using only the user's SSH key; `git log` matches tsgit tip
- [ ] 5.3 Mirror sync observed for a second test commit; revert both test commits on forgejo
- [ ] 5.4 gatus endpoint configured and green; `docs/forgejo.md` complete (install, OIDC, mirror, admin recovery, where the PAT lives, upgrade procedure pointer)
- [x] 5.5 Leave `apps/tsgit` and the Tekton stack fully intact (removal is `remove-tsgit-tekton`); note in docs that CI still runs on Tekton until that change lands (see docs/forgejo.md → Migration from tsgit)

## Workflow follow-up

- Archive once the runner change proves out or the forge is otherwise stable; see `add-forgejo-runner`.
