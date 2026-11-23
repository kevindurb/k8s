# Node time synchronization

Cluster nodes synchronize their clocks with the [NTP Pool](https://www.ntppool.org/en/use.html) using `chronyd`. The configuration ships in the bootc node image rather than on the nodes, so a freshly provisioned node needs no manual time setup.

## Configuration

`bootc/overlay/etc/chrony.conf` is copied to `/etc/chrony.conf` when `ghcr.io/kevindurb/k8s-node` is built:

```
pool 2.pool.ntp.org iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
```

- A single chrony `pool` line uses at most four upstream servers, which is the NTP Pool's requested maximum.
- The `2.` prefix makes the pool return both IPv4 and IPv6 servers. A country zone (for example `2.us.pool.ntp.org`) can replace the global zone if the default selection is poor.
- There is no `allow` directive, so nodes act only as NTP clients and do not serve time to the LAN.

`bootc/Containerfile` also lists `chronyd` in its `systemctl enable` invocation, so the service starts on boot even if the base image's presets change.

## Verifying a node

From a node (for example `ssh core@drone-01`):

```sh
systemctl is-enabled chronyd
systemctl is-active chronyd
grep -x 'pool 2.pool.ntp.org iburst' /etc/chrony.conf
sudo chronyc tracking
sudo chronyc sources -v
timedatectl
```

`systemctl is-enabled` must print `enabled`, `is-active` must print `active`, the `grep` must match, `chronyc tracking` must report `Leap status : Normal` with a non-zero reference ID, and `timedatectl` must show `System clock synchronized: yes`. In `chronyc sources -v`, at least one source should be marked with `*` (the currently selected source).

To confirm the node is not serving time to the LAN, check that no `allow` directive exists:

```sh
grep -c '^allow' /etc/chrony.conf
```

The command must print `0`.

## Updating the time source

Changing the pool, adding options, or changing the other directives is a change to `bootc/overlay/etc/chrony.conf`. CI rebuilds and signs the image on changes under `bootc/**` (`.github/workflows/build-bootc.yml`), then nodes pick it up through `ansible/upgrade.yml`:

```sh
cd ansible
just playbook upgrade.yml --limit drone-01   # canary
just playbook upgrade.yml --limit 'all:!drone-04'
```

`drone-04` reboots like any other node now (`just playbook upgrade.yml`); the only effect is a brief drop of the `/media` NFS export. See `AGENTS.md`.

## bootc `/etc` merge caveat

bootc three-way merges `/etc` on update, and a file edited locally on a node wins over the image's copy. If a node was ever hand-edited, `/etc/chrony.conf` will stay stale after an upgrade. Detect it with:

```sh
sudo ostree admin config-diff | grep chrony
```

If that prints `/etc/chrony.conf`, restore the image version and restart the service:

```sh
sudo cp /usr/etc/chrony.conf /etc/chrony.conf
sudo systemctl restart chronyd
```

Then re-run the verification commands above.
