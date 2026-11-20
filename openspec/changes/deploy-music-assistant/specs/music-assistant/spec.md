# Spec Delta

## Purpose

Run Music Assistant as the cluster's always-on audio control server: it indexes the local music
library, discovers and streams to networked players on the flat home LAN, and keeps its UI and API
tailnet-only while persisting its state across pod replacement.

## ADDED Requirements

### Requirement: Playback to players on the home LAN

The server SHALL discover networked players (AirPlay, Chromecast, Sonos, DLNA) over multicast on the
node's LAN interface and SHALL stream audio to them from the node's LAN address, so that a player on
the home LAN can be selected and played to without any player-side configuration.

#### Scenario: A speaker appears and plays

- **WHEN** an AirPlay or Chromecast speaker on `192.168.42.0/24` is powered on while the server runs
- **THEN** the speaker appears in the server's player list without manual address entry
- **AND** starting playback on it produces audio from the speaker

#### Scenario: The server advertises a LAN-reachable address

- **WHEN** the server is asked for its own address by a player or by its UI
- **THEN** it reports the LAN address of the node it runs on, not a cluster-internal or tailnet address
- **AND** players can open a connection back to it on the stream port and on ephemeral ports it opens

### Requirement: Minimal privilege for the host-network exemption

The server MAY use the node's network namespace, and SHALL NOT gain any further privilege for it:
the container SHALL run as a non-root user with a read-only root filesystem, drop all capabilities,
mount no host path, and run no privileged container.

#### Scenario: Rendered pod is host-networked but otherwise restricted

- **WHEN** the rendered Deployment for the server is inspected
- **THEN** it sets `hostNetwork: true` and no additional host access
- **AND** the container is non-root, read-only-root-filesystem, privilege-escalation-disabled, with `drop: [ALL]`
- **AND** the namespace carries the documented Pod Security exemption required by host networking

#### Scenario: A provider needs to write scratch data

- **WHEN** a provider writes to `/tmp`, `/var/tmp`, `/run`, `/var/cache` or `/var/log`
- **THEN** the write succeeds through ephemeral volumes
- **AND** writes that must persist land under `/data`

### Requirement: UI and API are tailnet-only

The web UI, API and WebSocket endpoint SHALL be reachable at `https://music-assistant.beaver-cloud.ts.net`
for tailnet peers holding the media tag, and MUST NOT be published to the public internet or through
a cluster `LoadBalancer`.

#### Scenario: Tailnet peer opens the UI

- **WHEN** a tailnet peer covered by `tag:media` opens `https://music-assistant.beaver-cloud.ts.net/`
- **THEN** the request is proxied to the server's web port and the UI loads

#### Scenario: No public surface exists

- **WHEN** the rendered manifests are inspected
- **THEN** the Ingress carries no Funnel tag and no `LoadBalancer` Service exposes the web port
- **AND** the only public-facing paths are those of other applications, untouched by this capability

### Requirement: State persists across pod replacement

The server's configuration, user database, provider configuration and analysis cache SHALL live on a
persistent node-local volume so that replacing the pod preserves the administrator account, every
configured music source and player, and the library index.

#### Scenario: Pod is recreated

- **WHEN** the pod is deleted and rescheduled on the same node
- **THEN** the existing administrator login still works
- **AND** previously configured sources, providers and library content are present without reconfiguration

#### Scenario: Volume is the only durable copy

- **WHEN** the server's data path is inspected
- **THEN** the database, configuration and cache directories reside on a persistent claim, not in the container image or an ephemeral volume
- **AND** the claim is expandable so a growing library or analysis cache can be accommodated without replacing it

### Requirement: The music library is mounted read-only and narrowly

The server SHALL read the local music library from the NAS export with a read-only mount scoped to the
music directory, and MUST NOT have write access to the share or visibility of unrelated share content.

#### Scenario: Library is visible

- **WHEN** the server scans its configured local-files path
- **THEN** the library's artist/album/track tree is present on the mounted path

#### Scenario: Library cannot be modified

- **WHEN** any process in the server container attempts to write inside the mounted music path
- **THEN** the write fails with a read-only filesystem error
- **AND** other top-level directories of the share are not mounted into the container

### Requirement: Scheduling co-locates the server with its storage

The server and its persistent volume SHALL be placed on the node that already mounts the NAS share and
hosts the media applications, so that a replacement pod lands where its claim is bound and the library
is served from the same node.

#### Scenario: Replacement pod lands on the media node

- **WHEN** the Deployment's pod is created
- **THEN** it is scheduled on the media node and its claim binds to a volume on that same node
- **AND** the pod does not run on the storage node or a control-plane node

### Requirement: Health is observable

The server SHALL expose an HTTP endpoint suitable for liveness, readiness and external checks, and the
cluster's monitoring SHALL report it as healthy while the UI is answering and detect a pod that stops
answering.

#### Scenario: Healthy server is green

- **WHEN** the server is running and its web interface responds
- **THEN** the in-cluster Service answers an HTTP request and the Gatus endpoint is green

#### Scenario: Unresponsive server is restarted

- **WHEN** the web interface stops responding past the probe thresholds
- **THEN** the kubelet restarts the container
- **AND** the Gatus check reports the failure instead of a false green

### Requirement: No credentials are stored in git

The first-run administrator account SHALL be created through the server's setup flow and stored in the
persistent volume, and no Music Assistant credential, provider token or API key SHALL appear in the
repository.

#### Scenario: First boot requires setup

- **WHEN** the server starts against an empty data volume
- **THEN** it offers the setup flow that creates the administrator account
- **AND** the resulting credentials live only in the persistent volume

#### Scenario: Provider credentials are entered at runtime

- **WHEN** a streaming provider or player is configured
- **THEN** its credentials are stored in the server's database on the persistent volume
- **AND** no sealed secret is required for this application
