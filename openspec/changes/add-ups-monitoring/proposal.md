# Proposal

## Why

The rack's UPS — a CyberPower OR2200PFCRT2U, USB-attached to `drone-03` — is completely
unmonitored. Nothing in the cluster can answer the three questions that actually matter for
a seven-node homelab on one circuit: how much power is the rack drawing, is the UPS on
battery, and is it approaching its 1540 W capacity? The device exposes a standard USB HID
Power Device interface and speaks NUT fluently (verified: `usbhid-ups`, CyberPower HID
subdriver 0.85, NUT 2.8.5), so the missing piece is purely integration work.

The cluster already has all the consumers — Prometheus, Alertmanager, and Home Assistant —
and all the primitives — Node Feature Discovery for hardware-based scheduling, annotation
based scraping, SealedSecrets. This change wires the UPS into them.

## What Changes

- **NFD learns to name the UPS.** A `NodeFeatureRule` matching the UPS's USB identifiers emits
  `hardware/ups: or2200pfcrt2u` on the node with the cable attached. This matches raw discovered
  features rather than the USB device-class whitelist, so `usb-ff_10c4_ea60.present` — which
  pins `zigbee2mqtt` to `drone-02` — is never at risk.
- **New `infrastructure/nut` app.** A single-replica privileged Deployment scheduled by the
  hardware label, running `usbhid-ups` + `upsd`, with a non-privileged `nut_exporter` sidecar
  serving `/ups_metrics`.
- **Home Assistant gets the UPS** through HA's official NUT integration, pointed at the
  `upsd` Service. Configuration happens in the HA UI (HA config lives on a PVC, not in git).
- **Prometheus gets the UPS** through the new Service's `prometheus.io/scrape` annotations,
  which the existing `kubernetes-service-endpoints` job already picks up. No change to
  `prometheus.yml` scrape configs.
- **Alertmanager gets UPS alerts**: on battery, low battery, replace battery, overload,
  capacity headroom, and exporter/driver down.
- **Watts are derived, and that derivation is documented.** This unit exposes no
  `ups.realpower` — only `ups.load` as a percentage and `ups.realpower.nominal: 1540` — so
  watts come from `ups.load * 15.4`. That multiplier is an unverified assumption, recorded
  as such.

### Out of scope

- Graceful cluster shutdown orchestration on battery. Explicitly deferred; a future project.
- Per-outlet control or metering. This UPS has one unswitched bank of eight outlets.
- Calibrating the `15.4` watts multiplier. Deferred until the UPS carries real load.

## Capabilities

### New Capabilities

- `power-monitoring`: the cluster's ability to observe the rack UPS — power draw, battery
  state, line status — and to expose that observation to both Home Assistant and Prometheus.

### Modified Capabilities

None.

## Impact

- `infrastructure/node-feature-discovery/rules/nodefeaturerule.yml` — UPS rule added.
- `infrastructure/nut/` — new app directory (`app.yml`, `kustomization.yml`,
  `deployment.yml`, `sealed secret`).
- `infrastructure/kustomization.yml` — registers the new app.
- `infrastructure/prometheus/config/rules/rules.yml` — new UPS alert group.
- Home Assistant — NUT integration added in the UI, plus a template sensor and a
  Riemann-sum helper for kWh.
- No changes to existing workloads. No API, schema, or BREAKING changes. The
  `zigbee2mqtt` scheduling contract is touched by configuration only and must be preserved.
