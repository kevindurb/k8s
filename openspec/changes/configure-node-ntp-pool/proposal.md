# Proposal

## Why

The cluster nodes ship with the uCore/Fedora default time source (`2.fedora.pool.ntp.org`) and no repository-managed chrony configuration. Time accuracy underpins TLS certificate validation, Argo CD/etcd operation, log correlation, and every scheduled job in the homelab, yet the source is implicit in the base image and can change without any change here. Pinning node time sync to the NTP Pool in the bootc image makes the time source explicit, versioned, and consistent across all nodes.

## What Changes

- Add an `/etc/chrony.conf` overlay file to the bootc node image that synchronizes from the NTP Pool (`pool 2.pool.ntp.org iburst`), keeping the standard drift file, `makestep`, and `rtcsync` settings. `2.pool.ntp.org` is used because it returns both IPv4 and IPv6 servers; a single `pool` line yields at most four upstream servers, matching the NTP Pool's request not to configure more than four.
- Explicitly enable `chronyd` in the image's systemd enable list so the setting is intentional rather than inherited silently from the base image.
- Validate the rendered config and verify synchronization on nodes after the image is rolled out.
- No Kubernetes manifests, Argo CD applications, or app services change.

## Capabilities

### New Capabilities

- `node-time-sync`: how cluster nodes obtain and maintain system time, including the configured NTP source and the expected synchronization state.

### Modified Capabilities

None.

## Impact

- `bootc/Containerfile` — add `chronyd` to `systemctl enable`.
- `bootc/overlay/etc/chrony.conf` — new file, baked into `ghcr.io/kevindurb/k8s-node`.
- `.github/workflows/build-bootc.yml` — rebuilds, signs, and pushes the node image automatically on `bootc/**` changes; no workflow edit expected.
- Node rollout — `ansible/upgrade.yml` pulls the new image and reboots nodes serially, including `drone-04` (only its NFS export drops briefly).
- Outage risk — a misconfigured chrony file could stop time sync after reboot; verification is required on the first upgraded node before rolling out to the rest.
- Not in scope: running an NTP server in the cluster, serving time to LAN devices, changing node time zones, or NTP authentication/NTS.
