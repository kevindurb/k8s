# Design

## Context

See `proposal.md` for motivation. The relevant current state:

- `bootc/Containerfile` builds `ghcr.io/kevindurb/k8s-node` from `ghcr.io/ublue-os/ucore:stable-nvidia-lts`, a Fedora/bootc derivative, and copies `bootc/overlay/` over `/` at build time.
- The base image ships `chronyd` and a `/etc/chrony.conf` that uses `2.fedora.pool.ntp.org`. Nothing in this repository currently manages time configuration, and the Containerfile's `systemctl enable` list does not mention `chronyd`.
- bootc performs a three-way merge of `/etc` when a node updates: a file edited locally on a node keeps winning over the image's version. This is documented in `AGENTS.md` as a known operational trap.
- There are seven nodes: `unimatrix-01..03` (servers) and `drone-01..04` (agents). `drone-04` is the ZFS/NVMe-oF storage node and must be rebooted only with `ansible/reboot-drone-04.yml`, never `ansible/upgrade.yml` (`node_reboot` refuses it).
- `.github/workflows/build-bootc.yml` rebuilds and signs the image on any change under `bootc/**`.

## Goals / Non-Goals

**Goals:**

- Make the NTP Pool the repository-owned, explicit time source for every node.
- Keep the configuration small and self-contained so a reviewer can compare it to the base image's file.
- Provide a rollout and verification sequence that catches a broken config on one node before touching the rest.

**Non-Goals:**

- Serving NTP to LAN devices or running an in-cluster time server.
- NTS/authentication, local GPS/stratum-1 hardware, or leap-second handling beyond what chrony provides by default.
- Changing node time zones or the image's default timezone.

## Decisions

### 1. Replace `/etc/chrony.conf` wholesale through the existing overlay

Add `bootc/overlay/etc/chrony.conf` with the NTP Pool as the source, mirroring the standard Fedora chrony directives:

```
pool 2.pool.ntp.org iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
```

**Why this over alternatives:**

- **`/etc/chrony.d/` drop-in:** Fedora's `chrony.conf` does not include a `confdir` directive, so a drop-in would be silently ignored unless the main file were also modified. Changing two files to express one setting is more fragile.
- **Editing via `sed`/`RUN` in the Containerfile:** hides the final content from review and depends on the base image's exact text, which Renovate/base updates can change.
- **Replacing the file in the overlay:** the overlay already exists for exactly this kind of node configuration, the resulting file is visible in git, and no base-image text matching is involved. The trade-off is that the file must be reviewed when the base image changes chrony defaults.

The file deliberately keeps `driftfile`, `makestep`, `rtcsync`, and `logdir` because they are Fedora's meaningful defaults; losing `makestep 1.0 3` would leave a badly skewed clock stepping only after chrony's normal settle period. Comments are omitted to keep the diff small; the rationale lives here.

### 2. Use one `pool 2.pool.ntp.org` line

- A single chrony `pool` line resolves to four upstream servers by default, satisfying the NTP Pool's "no more than four servers" request without listing four names.
- The `2.` prefix is the only variant that returns both IPv4 and IPv6 addresses. The cluster is dual-stack-capable at the network layer, and this gives chrony IPv6 sources where available without listing addresses.
- The global zone is used rather than a country zone. Country zones can be sparse or missing; the global pool picks nearby servers via DNS. Switching to a country zone later is a one-line change.

Alternatives considered: four `server 0..3.pool.ntp.org` lines (more addresses to maintain for no benefit with chrony); `pool.ntp.org` without the `2.` prefix (IPv4 only); the Fedora vendor zone (keeps distribution affiliation but defeats the purpose of making the source explicit and provider-neutral).

### 3. Enable `chronyd` explicitly in the Containerfile

Add `chronyd` to the existing `systemctl enable ...` invocation. The base image already enables it, but an explicit entry makes the dependency intentional and prevents a silent regression if the base image's preset changes. The operation is idempotent in `systemctl` and does not change the image's behaviour today.

### 4. Canary the image on one agent before the fleet

Build verification (`podman build`, inspect the file in the image) happens before merge, but the meaningful test is a real boot. Roll out to `drone-01` first with `ansible/upgrade.yml` limited to that host, verify synchronization, and only then upgrade the rest. `drone-04` is handled last and separately because of its storage role.

## Risks / Trade-offs

- **Locally edited `/etc/chrony.conf` on a node wins over the image** → the rollout verification explicitly reads `/etc/chrony.conf` on every node; if a node kept an old file, copy the image version from `/usr/etc/chrony.conf` over `/etc/chrony.conf` (or remove the local edit) and restart `chronyd`.
- **DNS failure for `2.pool.ntp.org` at boot** → chrony starts without blocking boot and retries; the RTC keeps time in the interim. This is the same failure mode as the current Fedora pool.
- **Rebooting nodes to apply the image affects cluster availability** → upgrades are serialized by `ansible/upgrade.yml` and `node_reboot`; the canary plus the dedicated `drone-04` play bound the blast radius. The task list sequences `drone-04` so the storage node is not rebooted by `upgrade.yml`.
- **We now own the whole chrony configuration** → upstream changes (e.g. a new required directive) will not arrive automatically. The file is five lines and appears in image diffs; review it when the base image is bumped.
- **The NTP Pool is volunteer-run** → acceptable for a homelab, per the pool's own guidance; it is not a hard real-time source.

## Migration Plan

1. Merge the image change; CI builds and signs a new `k8s-node` image.
2. Canary `drone-01`: `just playbook upgrade.yml --limit drone-01`, then verify `chronyd` is enabled/active, `/etc/chrony.conf` contains the pool line, and `chronyc tracking` reports synchronization.
3. Upgrade the remaining agents and servers, excluding `drone-04`.
4. Update and reboot `drone-04` with the dedicated storage-node play.
5. Verify all nodes and record the result in the change's task list.

Rollback: revert the commit, let CI rebuild, and re-run the upgrade. A single node can be restored immediately by copying its previous `/etc/chrony.conf` (or `/usr/etc/chrony.conf`) back and restarting `chronyd`.

## Open Questions

- Whether to pin a country zone (e.g. `2.us.pool.ntp.org`) instead of the global zone. Deferrable: it changes one line and no requirement or task ordering.
