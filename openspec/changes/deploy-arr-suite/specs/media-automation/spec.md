# Spec Delta

## Purpose

Defines the end-to-end media request-and-acquisition pipeline: Jellyfin-authenticated requests, indexer-fed search, Mullvad-confined torrent egress, and automatic import into the Jellyfin library — so a household request becomes playable media without operator involvement.

## ADDED Requirements

### Requirement: Torrent traffic is confined to the Mullvad VPN

The qBittorrent workload SHALL route all peer traffic exclusively through a Mullvad exit node reachable over the tailnet. If the tunnel is unavailable, the app SHALL NOT send or receive torrent traffic. The pod SHALL NOT be reachable for torrent traffic on any other path.

#### Scenario: Exit node unavailable at startup
- **WHEN** the configured Mullvad exit node cannot be reached or fails the exit-node health check
- **THEN** qBittorrent does not process torrent traffic until the tunnel is healthy, and the pod does not report ready

#### Scenario: Tunnel drops while running
- **WHEN** the Mullvad exit node becomes unreachable while torrents are active
- **THEN** the sidecar is restarted and torrent traffic resumes only over the tunnel, never in the clear

### Requirement: Releases are imported by copy, not hardlink

Radarr and Sonarr SHALL import completed downloads by copying files into the library (`/media/Movies`, `/media/TV Shows`). The import SHALL NOT rely on filesystem hardlinks between the download directory and the library.

#### Scenario: Movie import after download completes
- **WHEN** qBittorrent reports a Radarr-category download as complete
- **THEN** Radarr copies the file into `/media/Movies` and leaves the library file independent of the download copy

#### Scenario: Show import after download completes
- **WHEN** qBittorrent reports a Sonarr-category download as complete
- **THEN** Sonarr copies the file(s) into `/media/TV Shows` and leaves the library files independent of the download copies

### Requirement: Torrents are removed automatically after import

After Radarr or Sonarr successfully imports a completed download, the corresponding torrent and its downloaded files SHALL be removed from the download client and `/media/Downloads`.

#### Scenario: Download removed after successful import
- **WHEN** Radarr or Sonarr finishes importing a completed download
- **THEN** the matching torrent is removed from qBittorrent along with its files in `/media/Downloads`, and the library copy remains

### Requirement: Indexers are managed centrally in Prowlarr

Prowlarr SHALL be the single place where indexer definitions are configured, and Radarr and Sonarr SHALL consume their indexers via Prowlarr sync rather than independently maintained per-app indexer config.

#### Scenario: Indexer added in Prowlarr
- **WHEN** an indexer is added or updated in Prowlarr
- **THEN** the indexer appears in Radarr and Sonarr automatically via sync without editing either app by hand

#### Scenario: Search uses synced indexers
- **WHEN** Radarr or Sonarr performs an interactive or automatic search
- **THEN** results come from the Prowlarr-synced indexers

### Requirement: Requests are made through Seerr with Jellyfin authentication

Household members SHALL request movies and shows through Seerr, authenticating with their Jellyfin accounts. Requests SHALL require manual approval, and approved requests SHALL create the corresponding movie/series in Radarr or Sonarr.

#### Scenario: Unauthenticated access
- **WHEN** a visitor without a Jellyfin account opens Seerr
- **THEN** they cannot browse requestable content or submit requests without authenticating

#### Scenario: Request approval creates the item
- **WHEN** an admin approves a request in Seerr
- **THEN** Radarr or Sonarr gains the corresponding movie or series and begins monitoring it

### Requirement: Download categories map to isolated directories

qBittorrent SHALL use separate categories for Radarr and Sonarr, saving into `/media/Downloads/radarr` and `/media/Downloads/sonarr` respectively, and each app SHALL only consume content from its own category.

#### Scenario: Download lands in the right category
- **WHEN** Radarr grabs a release
- **THEN** qBittorrent downloads it under the `radarr` category into `/media/Downloads/radarr`

### Requirement: Pipeline components are observable

Every app in the pipeline (qBittorrent, Prowlarr, Radarr, Sonarr, Seerr, Bazarr) SHALL have a Gatus health check, and the qBittorrent check SHALL be enabled whenever the deployment is running.

#### Scenario: qBittorrent healthy check
- **WHEN** qBittorrent is running and serving its UI
- **THEN** the Gatus endpoint for qBittorrent reports healthy
