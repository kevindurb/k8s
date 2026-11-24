# Proposal

## Why

The media automation pipeline is broken end to end. Radarr and Sonarr are deployed but have no indexers and no download client, qBittorrent has been scaled to zero since 2026-09-15, the Mullvad exit node its sidecar pins is no longer reachable, and household members have no way to request content for Jellyfin. The pieces that exist were each fine at some point, but nothing connects them into a working request-to-playback path.

## What Changes

- Re-enable **qBittorrent** with fresh state: new config and ts-state PVCs, new tailscale auth key tagged `tag:qbittorrent`, exit node `100.104.110.13` (Mullvad) via the tailscale sidecar, qBittorrent categories `radarr` and `sonarr` writing to `/media/Downloads/{radarr,sonarr}` on the shared `nas-media` NFS export.
- **Prowlarr** deployed as the indexer manager for public trackers, syncing indexers into Radarr and Sonarr.
- **Radarr / Sonarr** wired to Prowlarr (indexers) and qBittorrent (download client). Imports use **copy** (not hardlink), and the torrent is **automatically removed** once the import completes — `/media/Downloads` is a transit area, not a seedbox.
- **Seerr** deployed (`ghcr.io/seerr-team/seerr`) as the request front-end: Jellyfin authentication, household use, manual approval, creates requests in Radarr/Sonarr.
- **Bazarr** deployed for subtitle management; providers/languages configured after the fact.
- **homer**: add Seerr, Prowlarr, Bazarr links; fix the stale Radarr URL.
- **gatus**: re-enable the qBittorrent check; add checks for the new apps.
- **Prerequisite (separate repo)**: a PR to `~/projects/infra` adding `tag:qbittorrent` (owner `tag:k8s-operator`) with the `mullvad` node attribute and policy tests. Without it the sidecar cannot use any Mullvad exit node. This change must not apply the qBittorrent half before that lands.

## Capabilities

### New Capabilities
- `media-automation`: the end-to-end pipeline — Jellyfin-authenticated requests, arr-managed acquisition via public trackers, Mullvad-confined torrent egress, copy-on-import with automatic torrent removal, and monitoring of the pipeline.

### Modified Capabilities

_None — no existing specs cover the media stack._

## Impact

- **New manifests**: `apps/prowlarr/`, `apps/seerr/`, `apps/bazarr/` (new apps via the template pattern), plus `apps/kustomization.yml`, `apps/project.yml` wiring is unchanged (existing apps pattern), `clusters/borg` needs nothing new (apps are auto-discovered via `apps/kustomization.yml`).
- **Modified**: `apps/qbittorrent/` (fresh PVCs, exit node, re-enabled replicas), `apps/radarr/`, `apps/sonarr/` (runtime configuration via their APIs — no manifest changes expected), `apps/homer/`, `apps/gatus` ConfigMaps, `justfile`-driven kustomize checks.
- **Cluster state**: three new namespaces (prowlarr, seerr, bazarr); old qBittorrent config/ts-state PVCs become stale and are deleted after verification. Argo CD self-heals; pruning stays off.
- **External (prerequisite, separate repo/PR)**: `~/projects/infra` tailnet policy — `tag:qbittorrent` in `tagOwners` and `nodeAttrs` with `attr: ["mullvad"]`, plus policy tests. A new tag-scoped auth key must be minted by an operator and sealed into the cluster.
- **Secrets**: new sealed secrets — qBittorrent TS auth key (`tag:qbittorrent`), Seerr/Bazarr if they need any at deploy time. No raw values committed.
- **Out of scope**: Usenet, Bazarr provider configuration (OpenSubtitles credentials), Seerr notification agents, Lychee-style photo flows, Lidarr (music stays with beets/Navidrome).
