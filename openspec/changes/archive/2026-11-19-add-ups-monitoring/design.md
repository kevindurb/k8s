# Design

## Context

See `proposal.md` — Why. The constraints that shape the approach, established by inspecting
the cluster and probing the device:

- **The device.** CyberPower OR2200PFCRT2U, USB ID `0764:0601`, attached to `drone-03`. Its bus
  address has been `2-3`, then `4-2`, and is now `1-3` across moves and rebuilds. One HID
  interface, class `03`, bound to `usbhid`. The USB **serial descriptor is empty**. NUT 2.8.5
  with `usbhid-ups` and the `CyberPower HID 0.85` subdriver drives it cleanly.
- **What it reports.** `ups.load`, `battery.charge`, `battery.runtime`, `battery.voltage`,
  `input.voltage`, `output.voltage`, `ups.status`, `ups.realpower.nominal: 1540`.
  It does **not** report `ups.realpower`, `ups.power`, `input.current`, `output.current` or
  any temperature.
- **What it controls.** No per-outlet variables. It does expose global `load.off`, `load.on`
  and `shutdown.*`, gated by `driver.flag.allow_killpower: 0`. Out of scope here, but the
  existence of a one-command whole-rack power cut argues for never granting `instcmds`.
- **NFD is Helm-plus-rules** (`infrastructure/node-feature-discovery/app.yml`): the chart, with
  `worker.config.sources.pci.deviceLabelFields: [vendor, device]`, plus a second `sources[]`
  entry pointing at `infrastructure/node-feature-discovery/rules`, which already manages a
  `NodeFeatureRule` deriving `media/gpu: amd-vega` from raw PCI features.
- **USB discovery is unfiltered; only label emission is filtered.** The worker publishes every
  attached USB device into its `NodeFeature` object, while `deviceClassWhitelist` decides only
  which labels the worker emits itself. Observed directly: `drone-03`'s `NodeFeature` carries
  `{'class': '03', 'device': '0601', 'vendor': '0764'}` while the node has no `usb-03…` label,
  because the default whitelist `['0e','ef','fe','ff']` excludes HID.
- **`zigbee2mqtt` is pinned by `usb-ff_10c4_ea60.present`** on `drone-02`, where it is still
  running. That label comes from the same whitelist, which is why this design does not touch it.
- **Prometheus scrapes by annotation.** `kubernetes-service-endpoints` keeps targets carrying
  `prometheus.io/scrape`, honours `prometheus.io/path` and `prometheus.io/port`, and overwrites
  `instance` with the pod's node name.
- **Home Assistant** runs `hostNetwork` on `drone-01` with `dnsPolicy: ClusterFirstWithHostNet`;
  its configuration lives on a PVC, not in this repository.
- **Infra exporters follow a precedent**: `smartctl-exporter` and `zfs-exporter` are privileged
  single-purpose Deployments/DaemonSets with no `gatus.yml`.

## Goals / Non-Goals

**Goals:**

- One privileged workload owns the USB device; every consumer is an ordinary NUT client.
- Both consumers see the same UPS with no duplicated device access.
- The watts estimate exists in exactly one place.
- The change is additive: nothing existing stops working if it is reverted.

**Non-Goals:**

- Shutdown orchestration, `upsmon`, node-level NUT clients.
- Outlet or load switching; no `instcmds` permission is granted to any consumer.
- Calibrating the watts multiplier.
- Making Home Assistant's configuration GitOps-managed.

## Decisions

### Place the workload by a hardware label, not by hostname

`nodeSelector: hardware/ups: or2200pfcrt2u`.

The label means *the device is present*, which is what the workload actually requires. A
`kubernetes.io/hostname: drone-03` selector would encode a fact rather than a capability, and
would silently point at a machine with no UPS after a rebuild. The repo already does this with
`zigbee2mqtt`.

*Alternative rejected:* a hand-set node label. `apps/jellyfin` carried `media/gpu: amd-vega` as a
manually applied label precisely because nothing derived it from hardware, and the `amd-vega`
NodeFeatureRule exists to replace exactly that drift. Deriving the label from hardware is the
established pattern, not a new one.

### Match by class, vendor and product — never by serial

The rule matches `usb.device` on `class: 03`, `vendor: 0764`, `device: 0601`. The probe showed
the device's USB serial descriptor is empty, so anything keyed on serial would be malformed on
this exact unit and would collide with a second unit of the same model. Model identity is the
right granularity for one UPS.

### Label via a NodeFeatureRule, not the USB whitelist

The rule lives beside the existing one in
`infrastructure/node-feature-discovery/rules/nodefeaturerule.yml`:

```yaml
- name: cyberpower.ups
  matchFeatures:
    - feature: usb.device
      matchExpressions:
        class:  {op: In, value: ["03"]}
        vendor: {op: In, value: ["0764"]}
        device: {op: In, value: ["0601"]}
  labels:
    hardware/ups: or2200pfcrt2u
```

This works because `nfd-master` evaluates rules against the published `NodeFeature` features, and
those are unfiltered by device class — the whitelist only governs the labels the worker emits
itself. The UPS is therefore already visible to a rule, with the whitelist untouched.

The first draft of this design did the opposite: add `03` to `deviceClassWhitelist`. That option
**replaces** the default list rather than extending it, so a list without `ff` removes
`usb-ff_10c4_ea60.present` from `drone-02`. Node labels gate scheduling and not liveness, so
`zigbee2mqtt` would keep running until its next reschedule and then fail to schedule at all, with
no obvious cause. Breaking an unrelated workload silently and on a delay, to obtain a label the
repo can already produce another way, is not a trade worth making.

The rule also reads better at the point of use — `hardware/ups: or2200pfcrt2u` rather than
`usb-03_0764_0601.present` — and follows the `media/gpu` precedent for hardware-derived labels.

### Privileged Deployment, not DaemonSet and not a bootc image change

Single replica, `strategy: Recreate`, privileged, on the node the label selects. A DaemonSet
would put a privileged USB-scanning container on all seven nodes to serve one device. Building
NUT into the node image (`bootc/`) would cost a rebuilt image and a rolling reboot of the
cluster for a purely observational workload, and would place it outside Argo CD's reconcilers.

*Alternative rejected for now:* host-level NUT via a `bootc` systemd unit. It is the right
answer if this ever grows into shutdown orchestration, because `upsmon` must talk to systemd
rather than to the API server. That is explicitly a separate project.

### Mount the whole `/dev/bus/usb` tree

Volumes: `hostPath /dev/bus/usb`, `hostPath /sys/bus/usb` (read-only), `hostPath /run/udev`
(read-only).

Unlike the Zigbee dongle, a HID device gets **no `/dev/serial/by-id` or `/dev/hidraw/by-id`
symlink** — verified on the host. A `hostPath` naming a single device node is doubly wrong:
`hidraw0`/`hiddev0` numbering depends on probe order, and the bus path moved from `2-3`
(`/dev/bus/usb/002/004`) to `4-2` (`/dev/bus/usb/004/002`) when the cable was moved between
machines. libusb enumerates the tree and identifies the unit by vendor ID; `/sys/bus/usb` is
required for that enumeration.

### `usbhid-ups` + `upsd`, polling, with an explicit user file

`ups.conf`: `driver = usbhid-ups`, `port = auto`, `vendorid = 0764`, `pollinterval = 15`,
`pollonly`.

`pollonly` is not a guess — the driver itself logs *"You may want to set 'pollonly' flag on CPS
devices"*, and this model has a documented history of silently losing the USB connection after
hours or days. Polling instead of USB interrupt reads is the recommended mitigation, and a
slower `pollinterval` reduces the traffic that triggers it.

Both daemons run in the **foreground** (the driver as PID 1 via the image entrypoint, `upsd`
with `-D`); a daemonising `upsd` exits immediately in a container. An `upsd.users` file must
exist or `upsd` does not serve — observed directly, and it means a monitor credential and
therefore a SealedSecret. That credential grants read-only access; `instcmds` is deliberately
**not** granted, keeping `load.off` unreachable.

### `nut_exporter` as a sidecar

Both consumers are NUT clients over the Service; neither touches the device.

The exporter runs in the same pod, configured with `--nut.server=127.0.0.1`, so the pod's
`prometheus.io/*` annotations describe one object and the existing relabel sets `instance` to
the node with the cable attached — semantically correct for a UPS metric. A separate Deployment
would label the UPS with whatever node the exporter happened to land on and would have nothing
to scrape while the NUT container restarted.

*Exporter choice:* `DRuggeri/nut_exporter`, served at `/ups_metrics` on 9199. It is a configured-server
exporter, so it fits `prometheus.io/path` cleanly, and it forces every `ups.status` flag to
`0`/`1`, so `{flag="OB"} == 1` is a valid alert even when the flag is absent.
`HON95/prometheus-nut-exporter` uses the multi-target pattern and would require smuggling a
`?target=…` query string into an annotation — workable, but fragile.

### Home Assistant consumes the official NUT integration

HA's built-in `nut` integration is official, Platinum quality, and talks to `upsd` directly over
the Service name. `nut2mqtt` was considered and rejected: six competing single-maintainer
projects exist, and the MQTT route buys nothing except avoiding one click in the HA UI.

HA-side setup (add integration, add template sensor, add kWh helper) is a **manual step**,
because HA configuration is not in this repository. That is a deliberate non-goal, not an
oversight.

### Derive watts only in Home Assistant

Prometheus alerts on **percent** load, so it never needs watts. The single watts derivation —
`watts = ups.load * 15.4` (1540 W nameplate ÷ 100) — lives in one HA template sensor, and a
Riemann-sum helper turns it into kWh for the Energy dashboard.

This keeps the unverified multiplier in exactly one editable place, and avoids two independent
derivations disagreeing later.

*Alternative rejected:* a Prometheus recording rule for `rack_power_watts` plus an HA sensor
reading it. HA has no native Prometheus client, so this would need a third component and would
make Prometheus a dependency of the Energy dashboard.

### No `gatus.yml`

Matching `smartctl-exporter` and `zfs-exporter`, not the `apps/` convention. A Gatus probe of
`/ups_metrics` would duplicate the Prometheus exporter-down alert and would add a second
independent thing to silence during maintenance.

## Risks / Trade-offs

- **`ups.load` was unconfirmed when this was drafted; it does report.** Measured 18–19% with the
  rack attached, so metering works as designed. Retained as a note because it is the only power
  signal the device offers: a flat zero while the rack is up would be a real fault, not an idle
  UPS.
- **The `15.4` multiplier is an estimate, but a tighter one than first assumed.** The nameplate
  ratio (1540 W / 2000 VA = 0.77) is close to the rated power factor, so reading `ups.load` as a
  percentage of VA instead of W lands within roughly 4% of the same answer; the residual spread
  is the load's actual power factor, about 290–340 W at the observed 19%. → Still expressed in
  one place and labelled an estimate, so recalibration is a single edit.
- **The label now depends on published features.** Rules are evaluated against the `NodeFeature`
  objects, so adding `usb.device` to `core.noPublishFeatures` — a plausible way to shrink those
  objects later — would silently stop the rule matching. → Recorded here; a vanished label after
  such a change is the symptom.
- **Documented CyberPower USB flakiness** (the driver silently losing the device). → `pollonly`
  + `pollinterval=15`, plus an explicit metrics-absent alert and the container restart policy.
- **Node labels do not evict running pods.** Moving the cable relabels the nodes but leaves the
  pod running against a stale `/dev` path until something forces a reschedule. → Accepted;
  recorded here so a future replug isn't misdiagnosed. Restarting the Deployment is the remedy.
- **Privileged pod with USB access.** → Single replica, no `instcmds`, read-only `/sys` and
  `/run/udev` mounts, and the only writable host path is `/dev/bus/usb` itself.
- **Third-party image.** `instantlinux/nut-upsd` is not official NUT. → Renovate tracks it; the
  image is env-configured and pinned by digest like every other image here.
- **HA runs `hostNetwork` on `drone-01`.** If `drone-01` or the switch is not on the UPS, the
  HA feed disappears during exactly the outage being monitored. → Documented; acceptable while
  the goal is metering, and it resolves itself when the power distribution is finalised.

## Migration Plan

Additive and independently revertible at each step:

1. **NodeFeatureRule only.** Sync, then confirm `hardware/ups: or2200pfcrt2u` appears on
   `drone-03` and that `usb-ff_10c4_ea60.present` on `drone-02` and `media/gpu` on the minis are
   unchanged. Adding a rule cannot remove the Zigbee label, but this is still the cheapest place
   to notice a malformed rule.
2. **NUT app.** Deploy, confirm the pod lands on `drone-03` by label, confirm variables are
   served over the Service.
3. **Home Assistant.** Manual integration + template sensor + kWh helper.
4. **Prometheus alert rules.** Last, once the metric names in the live cluster are confirmed.

Rollback: remove `infrastructure/nut/app.yml` from `infrastructure/kustomization.yml` and delete
the Argo CD Application by hand (prune is off); revert the rule. Steps 3 and 4 are independent of
1 and 2 and can be undone in the UI or by reverting the rules file.

## Open Questions

- Whether Home Assistant's configuration should eventually be brought into this repository
  rather than living on its PVC. Deferrable: it changes no requirement, approach, or task
  ordering, only where the HA steps are executed.
