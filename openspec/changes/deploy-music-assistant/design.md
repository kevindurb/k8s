# Design

## Context

See `proposal.md` — Why. The deployment must fit the repo's existing app-of-apps pattern and the
cluster's actual constraints, which were verified before writing this:

- `apps/navidrome` already mounts the same NAS export (`192.168.42.24:/media`) with `subPath: Music`
  at `/music`, read-only-free; the beets library lives at that export's `Music/` root.
- `apps/home-assistant`, `omada`, `scrypted` and `syncthing` already run `hostNetwork: true` on
  drone-02 and carry `pod-security.kubernetes.io/enforce: privileged` with an exemption comment.
  `docs/network-segmentation.md` finding 3 records that NetworkPolicy cannot constrain them.
- `components/storage-home-drone-01`, `app-pod-hardening`, `app-tmp-dirs` and `nas-media` exist and
  are used by the media apps; `nas-media` creates a per-app static NFS PV/PVC and the app declares
  its own volume/mount (no app uses the component's `beaver-cloud.xyz/nas-media` patch label).
- Ports `8095` and `8097` are unused cluster-wide and on drone-01's host network; the node's LAN
  address is `192.168.42.21`. drone-01 is the media node and is the only place the NAS share is
  read from for playback.
- Upstream Music Assistant 2.10.12 (stable, published 2026-11-14) requires host networking for
  player discovery/streaming, writes to `/data` (`--data-dir`), caches under `/data/.cache`,
  exposes `/` (onboarding-aware) and `/info`, serves the UI on 8095 and streams on 8097 by default,
  and builds its image to run as an arbitrary non-root user (`chmod 777 /app`).
- The speakers and the nodes are on the same flat `192.168.42.0/24` L2 segment (confirmed by the
  user), so mDNS crosses the pod's host network.

## Goals / Non-Goals

**Goals:**

- One Argo CD application that is identical in shape to the other media apps, so an operator can
  read it without new concepts.
- Full LAN player discovery and streaming while keeping every container-level restriction the
  other apps have.
- A first deploy that needs no manual secret creation and no manual volume provisioning.

**Non-Goals:**

- Home Assistant / HACS integration, provider credentials, backups, and NetworkPolicy egress
  work. These are UI/runtime follow-ups or separate changes.
- Making the app reachable from the public internet; there is no Funnel surface.
- Making Music Assistant a dependency of Navidrome or Jellyfin. They keep serving files; this app
  owns playback sessions only.

## Decisions

### Host networking on a pinned node, not bridge or macvlan

`hostNetwork: true` with `dnsPolicy: ClusterFirstWithHostNet`. This is the only supported upstream
mode for LAN players, and it is what makes the server's own address the node's LAN address, which is
what players must be able to open a connection back to. The pod is pinned to drone-01 with
`storage-home-drone-01` so its claim, its NFS mount and its LAN address stay together.

Alternatives considered: a ClusterIP Service behind the tailscale Ingress (rejected — no mDNS, no
back-connection, upstream-unsupported); macvlan via Multus (rejected — Multus is not installed and
would be new cluster plumbing for one app); a `LoadBalancer` with `loadBalancerClass: tailscale`
(rejected — tailnet-only, players cannot reach it).

### Privileged Pod Security namespace, with the exemption documented in `app.yml`

Baseline forbids host networking, so the namespace carries `enforce/warn/audit: privileged` and the
same `# exemption: hostNetwork …` comment the other four apps use. The container itself keeps
`runAsNonRoot`, uid/gid 1000, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false` and
`drop: [ALL]` from `app-pod-hardening`; only the namespace-level exemption is added.

### `zfs-local` PVC for `/data`, pinned with the app

A 10Gi `data` claim (expandable) on the node-local ZFS storage class, matching `navidrome`'s
`data` claim. The volume holds sqlite, provider config, the admin account and `/data/.cache`
(audio analysis for smart fades grows here, not in the library). Chosen over NFS: the database is
write-heavy and latency-sensitive; chosen over democratic-csi: that stack is being retired and no
new volumes go on it.

The `storage-home-drone-01` pin and the claim must land together; `zfs-local` is
`WaitForFirstConsumer`, so the volume is created on exactly the pinned node.

### Library via the `nas-media` component with `subPath: Music`, mounted read-only

The app declares `claimName: nas-media` and mounts it at `/music` with `subPath: Music` and
`readOnly: true` (same shape as navidrome's `/music`). This narrows the pod to the only share
content it needs and makes the mount structurally unwritable.

Alternatives considered: the container mounting the SMB/NFS share itself (rejected — upstream
requires `SYS_ADMIN`, `DAC_READ_SEARCH` and `apparmor:unconfined`, which breaks the minimal-privilege
requirement and is worse than the host-side NFS mount already in place); mounting the whole export
at `/media` (rejected — the pod has no business seeing `/media/immich` or the rest of the share).

### Retained container hardening, with `HOME=/data`

`app-pod-hardening` + `app-tmp-dirs` are kept. The upstream image is explicitly built for non-root
(`/app` is 777, data/cache are CLI flags on `/data`), and the PVC gets `fsGroup: 1000` from the
component. `HOME=/data` is added so subprocesses that write a dotfile land on the volume instead of
failing against the read-only root or an unwritable `/root`.

### Probes and Gatus target the onboarding-aware UI root

`startupProbe` on `/` with 30 × 10 s covers the first-boot database migration; readiness and
liveness follow on `/`. The kubelet and Gatus both follow the pre-setup redirect to `/setup`
(HTTP 200), so a fresh pod is healthy before the admin account exists. Gatus checks
`http://music-assistant-app-service.music-assistant` — the in-cluster Service, per the repo
convention, which routes to the host-networked pod's node IP and port.

### Version pinned by digest, updates via Renovate

`ghcr.io/music-assistant/server:2.10.12@sha256:7eb272e2…7cfafb` — the manifest-list digest for the
multi-arch image. The repo's `kubernetes` Renovate manager bumps digest and minor/patch releases
like every other app; majors stay review-only.

### No Service port for streaming

Only the UI port is published through the Service/Ingress. Stream traffic rides the pod's host
network straight to players on the LAN; adding a 8097 Service would imply a tailnet/proxy path that
players do not use.

## Risks / Trade-offs

- **A provider writes outside `/data` and the read-only root filesystem breaks it** → First
  mitigation is a targeted extra `emptyDir`; if a provider genuinely needs a writable image path,
  drop only the `readOnlyRootFilesystem` field in this app's kustomization with a comment, leaving
  non-root and dropped capabilities intact. Watch container logs on first deploy.
- **Namespace is privileged and the pod is outside NetworkPolicy coverage** → Unavoidable with
  host networking. Contained by running everything else on the pod restricted, and by the server
  requiring authentication. Recorded in `docs/network-segmentation.md`'s existing finding class.
- **A player discovery failure if the LAN stops being flat** (new IoT VLAN, firewall between
  drones and speakers) → The server reports the players it sees; a future VLAN would need an mDNS
  reflector or moving the app. No manifest change can hide this.
- **Port collision on drone-01's host network** (`8095`/`8097` or an ephemeral range) → Both are
  free today and only this app claims them; a collision shows as a bind error in the logs and a
  failing Gatus check, not as silent breakage.
- **Upstream does not support Kubernetes** → The container is the supported docker image, only the
  orchestration wrapper is unsupported. Any upstream bug report must be reproduced with
  `docker run --network host`.
- **`subPath` pins the mount to a directory of the export** → If the library is ever restructured,
  the mount path (not the PV) changes; the PV stays valid.
- **10Gi may fill with analysis cache** → `zfs-local` volumes are expandable (verified in the
  openebs canary), so the claim can grow without recreation.

## Migration Plan

1. Land the manifests; Argo CD creates the namespace, claim, Deployment, Service, Ingress at the
   first sync (`CreateNamespace=true`).
2. Wait for the pod to become ready on drone-01 with the node IP; verify `/music` is mounted
   read-only and `curl http://192.168.42.21:8095/` responds.
3. Create the administrator account at `https://music-assistant.beaver-cloud.ts.net/setup`, add the
   Filesystem provider at `/music`, confirm speakers appear.
4. Confirm the Gatus endpoint is green.

Rollback: remove `./music-assistant/app.yml` from `apps/kustomization.yml` and delete the Argo CD
`Application` (the app-of-apps has `prune: false`). The namespace, claim and PV remain until
deleted by hand; deleting the claim destroys the server database, so export or accept the loss
before doing so.

## Open Questions

None that affect the specs or task breakdown. The Home Assistant integration, streaming-provider
accounts and PVC backups are deliberate follow-ups outside this change.
