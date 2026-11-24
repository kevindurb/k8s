# Tasks

## 1. Prerequisite: tailnet Mullvad access (infra repo)

- [x] 1.1 In `~/projects/infra`, add `tag:qbittorrent` to `tagOwners` (owner `tag:k8s-operator`) in `tailnet/policy.hujson`; verify with the policy test suite (`terraform test` / CI as configured in that repo) — done in kevindurb/infra#20; owners are `group:admins` + `tag:k8s-operator` (an admin-console-minted key needs the user to own the tag)
- [x] 1.2 Add `{"target": ["tag:qbittorrent"], "attr": ["mullvad"]}` to `nodeAttrs` in `tailnet/policy.hujson`; extend `tests` in the same file to assert `tag:qbittorrent` has no tailnet grants (the `mullvad` attr is not assertable in policy tests — verify post-apply); PR #20 opened, terraform fmt/validate clean, policy parses; CI pending
- [x] 1.3 Merge the infra PR (#20, merged 2026-11-24; `terraform apply` succeeded) — Mullvad reachability itself is verified from the pod at 2.4, since tag:dev cannot enumerate Mullvad nodes
- [x] 1.4 Mint a new auth key (user-minted 2026-11-24; sealed under final name `qbittorrent-ts-auth-key`; verified in-cluster) tagged `tag:qbittorrent` in the tailnet admin console (user-operated); seal it with kubeseal into `qbittorrent-ts-auth-key` in the `qbittorrent` namespace; verify the sealed secret decodes in-cluster (`kubectl get secret qbittorrent-ts-auth-key -n qbittorrent -o jsonpath='{.data}'`)

## 2. qBittorrent re-enable (fresh state)

- [x] 2.1 Update `apps/qbittorrent/deployment.yml`: `replicas: 1`, new `ts-state` and `config` PVC names/sizes, `TS_EXTRA_ARGS` with `--exit-node=100.104.110.13`, keep SOCKS5 proxy wiring; verify `kustomize build apps/qbittorrent` renders (done; landed on `main` via c6cbabdb)
- [x] 2.2 Delete the stale `qbittorrent-config` and `qbittorrent-ts-state` PVCs (or let them linger unused and record them; do not reuse) — chose to let them linger; pod now uses `config-v2` / `ts-state-v2`, old PVCs left untouched for manual deletion
- [x] 2.3 Commit, push, wait for Argo CD sync; verify `kubectl get pods -n qbittorrent` is 1/1 Ready and gatus qBittorrent endpoint is green (after re-enabling its check in gatus.yml)
- [x] 2.4 Verify egress (SOCKS5 path exits via Mullvad zurich node, 77.243.184.37 / AS9009; direct egress differs as expected): exec into the pod (or an ephemeral sibling) and confirm traffic exits via Mullvad (`curl --socks5 127.0.0.1:1055 ifconfig.me` or equivalent); confirm the pod's startup probe gates on exit-node health
- [x] 2.5 In the qBittorrent UI (categories `radarr`/`sonarr` + dirs created, writable), create categories `radarr` (`/media/Downloads/radarr`) and `sonarr` (`/media/Downloads/sonarr`); verify both directories exist and are writable on the NAS mount
- [x] 2.6 Set the qBittorrent WebUI password (random value set via API; shared with user out-of-band) to a non-default value (sealed-secret or in-app generated), since CGNAT clients are outside the subnet whitelist

## 3. Prowlarr

- [x] 3.1 Scaffold `apps/prowlarr` with `just tmpl apps prowlarr`; adapt to the stack pattern (image `ghcr.io/home-operations/prowlarr` pinned by digest, `storage-home-drone-03`, `app-pod-hardening`, `app-tmp-dirs`, PVC for config, tailscale Ingress `prowlarr`, gatus check, `app.yml`); verify `kustomize build apps/prowlarr` passes
- [x] 3.2 Wire into `apps/kustomization.yml` and confirm `just check-kustomize` passes
- [ ] 3.3 After sync, open Prowlarr UI, add public indexers, and add Radarr and Sonarr as "sync apps" with their API keys; verify indexers appear in both (Settings → Indexers shows Prowlarr-sourced entries)

## 4. Radarr / Sonarr wiring

- [x] 4.1 In Radarr and Sonarr: disable "Use Hardlinks instead of Copy" (Media Management); verify setting persisted
- [x] 4.2 Add qBittorrent as download client in both via API (host `qbittorrent-app-service.qbittorrent`, port 80, categories `radarr`/`sonarr`, remove-completed + remove-files enabled); connection test returned 200 on both
- [ ] 4.3 Verify one end-to-end grab per app on a small free release: search → grab → download via Mullvad IP → copy into `/media` → torrent auto-removed

## 5. Seerr

- [x] 5.1 Scaffold `apps/seerr` (image `ghcr.io/seerr-team/seerr` pinned to `latest`'s current digest, `containerPort` per upstream (5055), tailscale Ingress `seerr`, gatus, `storage-home-drone-03`, `app-pod-hardening` — drop or adjust hardening flags if the upstream image fails them, noting what and why); `just check-kustomize`
- [ ] 5.2 Wire Seerr to Jellyfin (in-cluster URL `http://jellyfin-app-service.jellyfin`) with a Jellyfin API key (sealed or entered at setup); verify login with a Jellyfin account succeeds and the library scans
- [ ] 5.3 Wire Seerr to Radarr and Sonarr (service DNS names, API keys); enable manual approval; verify a test request transitions pending → approved → appears in Radarr/Sonarr as wanted

## 6. Bazarr

- [x] 6.1 Scaffold `apps/bazarr` (image `ghcr.io/home-operations/bazarr` pinned by digest, same component set as siblings, Ingress `bazarr`, gatus, `nas-media` mounted RW for subtitle writes); verify kustomize build
- [ ] 6.2 Point Bazarr at Radarr and Sonarr (API keys entered at setup); leave subtitle providers unconfigured and note it in the PR/README for follow-up; verify the UI loads and shows both "connected" statuses

## 7. Polish and convergence

- [x] 7.1 Homer: add Seerr/Prowlarr/Bazarr entries; fix the Radarr URL (drop the stale `/radarr` path); verify homer renders the changes after sync
- [x] 7.2 Gatus: re-enable qBittorrent endpoint, add prowlarr/seerr/bazarr endpoints; confirm all show healthy on the status page
- [ ] 7.3 `just check-kustomize` clean; yamllint clean; commit in logical chunks; after merge, verify Argo CD converges all new apps and `kubectl get applications -n argocd` is Healthy/Synced
- [ ] 7.4 End-to-end acceptance from the spec: a household Jellyfin user requests something in Seerr → approved → downloaded through the Mullvad tunnel → copied (not hardlinked) into the library → torrent auto-removed → appears in Jellyfin → gatus green across the pipeline

## Workflow follow-up

- Delete the legacy `qbittorrent-config` / `qbittorrent-ts-state` PVCs once the new deployment is verified (destructive; confirm at the time)
- Configure Bazarr subtitle providers (OpenSubtitles.com account + API key) as a follow-up
- Consider Seerr notification agent (in-cluster SMTP via `smtp-relay`) as a follow-up
- Archive this change once merged and verified (`/opsx-archive`)
