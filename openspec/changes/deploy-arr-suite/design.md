# Design

## Context

See proposal.md for motivation. Current state, verified against the cluster and repo:

- Radarr (`radarr`) and Sonarr (`sonarr`) are running, root folders set (`/media/Movies`, `/media/TV Shows`), **zero indexers, zero download clients** configured. Both use the `develop` branch images from home-operations and mount `nas-media` (NFS RW from drone-04) plus a `zfs-local` PVC for config.
- qBittorrent is scaled to `0` since 2026-09-15. Its manifest already contains a hardened Tailscale sidecar (userspace networking, SOCKS5 on `127.0.0.1:1055`, torrent traffic proxied through a Mullvad exit node, `TS_AUTHKEY` from a sealed secret) and qBittorrent.conf wired to that proxy. `/media/Downloads` holds ~571 GB of historical content, organized `Movies/`, `TV Shows/`, `Music/`.
- Tailnet policy grants the `mullvad` node attribute to `group:admins` only; tagged devices (everything in-cluster, this dev box) cannot use Mullvad exit nodes. `100.117.167.110`, the exit node pinned in the qBittorrent manifest today, is no longer advertised on the tailnet.
- `nas-media` is a single NFS export mounted by Radarr/Sonarr/qBittorrent at `/media`, so all three see the same paths.
- New-app pattern: `apps/<name>/` via `just tmpl apps <name>`; Tailscale ingress (`tailscale` class, `tag:apps`); `gatus.yml` per app; `app-pod-hardening` + `app-tmp-dirs` components; `storage-home-drone-03` pin (arr stack lives on drone-03).

## Goals / Non-Goals

**Goals:**
- One working pipeline: Seerr request → Radarr/Sonarr → qBittorrent → import → Jellyfin library → Bazarr subtitles.
- Torrent egress only via Mullvad, enforced by topology (sidecar) not by app config alone.
- No raw secrets in git; all credentials sealed.
- Everything validated with existing tooling (`just check-kustomize`, gatus).

**Non-Goals:**
- Usenet support, private trackers, Lidarr/Readarr, autobrr, scraping/notification bots.
- VPN for Prowlarr — its traffic is indexer API queries; runs direct (see Decisions).
- Migrating or re-seeding the 571 GB historical `/media/Downloads` content — it stays as-is; fresh qBittorrent state does not adopt it.
- Preserving the old qBittorrent web UI password — config is reset.
- Argo CD pruning of anything already removed (prune is intentionally off).

## Decisions

**D1 — Dedicated `tag:qbittorrent` for the sidecar, not `tag:apps`.**
The `mullvad` node attribute goes on a fresh tag owned by `tag:k8s-operator` (same pattern as `tag:k8s-ai`/`tag:tekton`). Granting `mullvad` to `tag:apps` would let every ingress proxy and app egress through Mullvad — far broader than needed. The infra PR also extends `policy.hujson` tests so CI fails if the grant is widened or dropped. qBittorrent's TS auth key must be minted with this tag; the old key/state cannot be reused for the new tag.

**D2 — Exit node `100.84.2.120`, fresh ts-state.**
qBittorrent gets brand-new PVCs (config and ts-state), a new auth key sealed into `qbittorrent-ts-auth-key`, and `TS_EXTRA_ARGS` with `--exit-node=100.84.2.120`. Any previous tailscale identity is abandoned rather than retagged in place (retagging a stateful node is not supported cleanly; a fresh identity is deterministic). Old PVCs are deleted after verification; their contents are not migrated.

**D3 — Import = copy, then remove torrent.**
Per project decision: Radarr/Sonarr import with copy (hardlinks disabled); after a successful import the torrent and its files in `/media/Downloads/{radarr,sonarr}` are removed. Downloads dir is pure transit. This costs one copy's worth of duplicated space briefly and zero long-term, and avoids hardlink failures across the app boundary. Configured in Radarr/Sonarr (Media Management → use copy; Download Client → remove completed torrents), not in the manifests.

**D4 — Prowlarr as the only indexer source; egress direct.**
Public trackers, no credentials, and search API calls don't need anonymity at the library scale. Putting Prowlarr behind the Mullvad sidecar would add a second always-on tunnel for zero benefit and complicate its lifecycle. If a tracker starts blocking, revisit — moving it behind the same pattern is cheap.

**D5 — Seerr from upstream, not home-operations.**
`ghcr.io/seerr-team/seerr` (pin by digest at apply time; Renovate will track). No home-operations build exists. Runs with the house pattern otherwise: tailscale ingress, gatus check, `storage-home-drone-03`, `app-pod-hardening` (Seerr runs as uid 1000; verify at apply time — if it trips, drop to just `app-tmp-dirs` and note why). SQLite in its PVC; no external DB.

**D6 — Bazarr ships configured-for-later.**
Deployed with radarr/sonarr wiring left for the user (OpenSubtitles credentials, language profile). It deploys with zero providers enabled rather than shipping placeholder creds.

**D7 — Bazarr/Seerr/Prowlarr/Radarr/Sonarr all mount `nas-media` read/write? No.**
Only qBittorrent and the two *arr apps need `nas-media`. Bazarr writes subtitle files next to media, so it also needs `nas-media` (RW). Seerr and Prowlarr do not touch media; their PVCs are small (zetabyte-free: 1–2 Gi).

**D8 — Images and pinning.**
home-operations images (radarr/sonarr already, plus prowlarr/bazarr) are digest-pinned like existing apps; Renovate keeps them fresh. Seerr is pinned by digest to `seerr-team/seerr` latest at apply time.

**D9 — Secrets.**
New sealed secrets: `qbittorrent-ts-auth-key` (replaced — new tag), and Seerr/Bazarr needs nothing at deploy; Radarr/Sonarr API keys are generated in-app and pasted into Seerr/Bazarr/Prowlarr UIs at setup time (stored in their app DBs, not in git).

**D10 — Homer and gatus** are static edits; homer gains seerr/prowlarr/bazarr and the radarr link drops the stale `/radarr` path. Gatus re-enables qbittorrent and gains three new endpoints.

## Risks / Trade-offs

- **[Risk] Infra PR lag** → qBittorrent can't egress to Mullvad until `tag:qbittorrent` + `mullvad` nodeAttr land and the new auth key is minted. → Order the work: infra PR first; qBittorrent rollout is gated on it; everything else can proceed in parallel. The apply plan treats the infra PR merge as a hard gate for the qBittorrent stage only.
- **[Risk] Fresh qBittorrent state loses the 571 GB library relationship** → Accepted by decision; old PVCs retained until manual verification, then deleted. Old downloads stay on disk untracked.
- **[Risk] Public-tracker credentials / soft blocks** (rate limits, blocks of datacenter/VPN IPs for some trackers) → qBittorrent is on Mullvad; Radarr/Sonarr/Prowlarr aren't, which is fine for API queries; if a tracker blocks the egress IP, swap the exit node or exclude that tracker.
- **[Risk] Copy import doubles I/O per import** → Sequential single imports, NFSv4.2 with 1024 MB r/wsize; acceptable for household volume. (User-chosen over hardlinks with full awareness of the trade.)
- **[Risk] `app-pod-hardening` breaks upstream images** (e.g. uid mismatch, read-only rootfs) → verify each pod starts clean under the component at apply time; fall back to tmp-dirs-only for the offending app and note it in the PR.
- **[Risk] Seerr upstream is young (v3.x)** → pin digest; Renovate handles bumps; SQLite keeps blast radius to its own PVC.
- **[Trade-off] gatus qBittorrent check uses the unauthenticated LAN UI** → gatus checks run from inside the cluster (private range), so the WebUI subnet whitelist covers them.

## Migration Plan

1. **Infra PR (separate repo, `~/projects/infra`)**: add `tag:qbittorrent` to `tagOwners` (owner `tag:k8s-operator`); add `{"target": ["tag:qbittorrent"], "attr": ["mullvad"]}` to `nodeAttrs`; extend `policy.hujson` tests (assert `tag:qbittorrent` may use Mullvad, and still cannot reach `tag:apps`/`tag:idp` except nothing it doesn't already). CI applies policy; verify in the admin panel / `tailscale exit-node list` from an admin device shows `100.84.2.120`.
2. Mint a **new auth key** for `tag:qbittorrent` (tagged, non-reusable concerns aside, ephemeral=false fine), kubeseal it into `qbittorrent-ts-auth-key`.
3. **k8s repo**: deploy qBittorrent with fresh PVCs (`config`, `ts-state`), exit node `100.84.2.120`, WebUI defaults from `config/qBittorrent.conf` (updated: categories not needed in file; categories are created via API at wiring time). Verify: sidecar healthy, `curl --socks5 127.0.0.1:1055 https://ifconfig.me` returns a Mullvad IP (via a debug exec, then remove any such tooling), gatus green.
4. Deploy **Prowlarr**; add public indexers; add Radarr/Sonarr as apps in Prowlarr (sync) — verify indexers appear in both.
5. In Radarr/Sonarr: disable hardlinks (use copy); add qBittorrent as download client with categories `radarr`/`sonarr`; enable "remove completed download" + "remove file after import" semantics; verify with a movie search → grab → import → torrent removed.
6. Deploy **Seerr**; point it at Jellyfin (`https://jellyfin.beaver-cloud.ts.net` or in-cluster service) and at Radarr/Sonarr by service DNS; set manual-approval; verify a test request flows radarr↔sonarr.
7. Deploy **Bazarr**; leave providers unconfigured (documented for later).
8. Update **homer** links (+ fix radarr URL) and **gatus** endpoints; `just check-kustomize`; commit; let Argo CD converge; verify all checks green.
9. Rollback: `kubectl scale deploy --replicas=0` per app, or revert the commit — Argo CD self-heals to the last good state. qBittorrent rollback = scale to 0 (pre-change state).

## Open Questions

- Exact tag name (`tag:qbittorrent` vs something shorter) and whether the infra PR should also let `tag:qbittorrent` resolve Mullvad DNS (it rides on exit-node DNS either way; no extra attr needed).
- Whether to delete the legacy qBittorrent PVCs in the same change or defer to a follow-up (PVC deletion is destructive; propose manual follow-up).
- Seerr notification target for approvals (own SMTP via the in-cluster relay, or none initially) — answerable any time; default is none.
