# Proposal

## Why

The house has a curated music library (beets layout under `/media/Music`, served by Navidrome) and
networked speakers on the flat `192.168.42.0/24` LAN, but nothing that turns the two into
"play this album on that speaker". Navidrome is a browser player; Jellyfin does video. Every
automation idea (a Home Assistant button, a Gatus-checked always-on service) needs a server that
owns the playback session, not just the files.

Music Assistant is that server: it indexes local files plus streaming providers, discovers
AirPlay/Chromecast/Sonos/DLNA players over mDNS/uPnP, and holds queues, groups and playback state
for its API and the Home Assistant integration. Deploying it in-cluster is the missing half of the
media stack, and the prerequisite pieces already exist — the NAS library is mounted on drone-01,
the `nas-media` component and per-app static NFS PV are in place, and four apps already carry the
`hostNetwork` exemption needed for LAN device discovery.

## What Changes

- Add `apps/music-assistant/` as a new Argo CD application (namespace `music-assistant`,
  `namePrefix: music-assistant-`), following the `navidrome` + `home-assistant` shapes.
- Run it with **`hostNetwork: true`** on **drone-01** so mDNS/uPnP discovery and the stream server
  (`8097`, plus ephemeral ports) sit on the node's LAN address `192.168.42.21`, the address players
  are told to connect back to.
- Declare the required Pod Security exemption in `app.yml` (`enforce: privileged`, with the
  host-network rationale comment), matching `home-assistant`/`omada`/`scrypted`/`syncthing`.
- Persist config, database and audio-analysis cache on a new `zfs-local` PVC (`data`, 10Gi,
  expandable) pinned to drone-01 with the `storage-home-drone-01` component.
- Mount the NAS share read-only, narrowed to the music library: `nas-media` with
  `subPath: Music` at `/music`.
- Keep the container-level hardening components (`app-pod-hardening`, `app-tmp-dirs`) and add
  `HOME=/data` so stray writes stay on the persistent volume.
- Expose the UI at `https://music-assistant.beaver-cloud.ts.net` with the standard tailscale
  `Ingress` (`ingress-proxy-group`, `tag:media`), and register a `gatus.yml` check.
- Register the app in `apps/kustomization.yml` and record the new volume in
  `docs/storage-placement.md`.

Not in scope: Home Assistant integration/HACS wiring, streaming-service credentials, backups of the
new PVC, and any NetworkPolicy work — none of it is a manifest change in this repo's Argo path
beyond what is listed (HA integration and provider credentials are done in the running UIs).

## Capabilities

### New Capabilities

- `music-assistant`: the cluster runs Music Assistant as an always-on, persistent, LAN-visible
  audio control server — it discovers and streams to players on the flat home LAN, serves its UI
  and API to the tailnet only, indexes the local library read-only from the NAS, and survives pod
  replacement without losing its database or its node address.

### Modified Capabilities

None. No existing capability's requirements change; `power-monitoring` and `tsgit` are untouched.

## Impact

- **New**: `Music Assistant` 2.10.12 application, namespace `music-assistant`, `Deployment`, `Service`,
  `Ingress`, PVC `music-assistant-data`, static PV/PVC `music-assistant-nas-media`.
- **Changed**: `apps/kustomization.yml` (new resource line), `docs/storage-placement.md` (drone-01
  volume table and node total).
- **Cluster effects**: a privileged-PSS namespace (host-network exemption) and a node-level
  listener on drone-01 at `8095` (UI/API), plus `8097` and ephemeral ports for player streams.
  NetworkPolicy cannot constrain this pod, same as the other four host-network apps.
- **Operational**: Argo CD `selfHeal` keeps it running; `prune: false` means removal needs the
  parent line and the Application deleted by hand. Upstream does not officially support
  Kubernetes deployments, so bugs would have to be reproduced in a plain container.
