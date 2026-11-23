# UPS monitoring

The rack UPS is a **CyberPower OR2200PFCRT2U** (2000 VA / 1540 W, line-interactive,
sine wave, 8 unswitched outlets), USB-attached to a cluster node. This document covers
how the cluster reads it, what the numbers mean, and the things that will waste your
time if you forget them.

Home Assistant configuration lives on its PVC and is not in this repository; see the
"Home Assistant" section for the steps.

## Architecture

```
UPS --USB--> node (labelled hardware/ups=or2200pfcrt2u)
                 |
                 +-- nut-app-deployment (privileged, 1 replica)
                       app:      usbhid-ups -> upsd :3493
                       exporter: nut_exporter :9199 /ups_metrics
                 |
                 +-- Service nut-app-service
                       :3493  -> Home Assistant (official NUT integration)
                       :9199  -> Prometheus (prometheus.io/scrape annotations)
```

Only the `app` container is privileged. Both consumers are ordinary NUT clients and
never touch the device.

## Node selection

`infrastructure/node-feature-discovery/rules/nodefeaturerule.yml` matches the raw
`usb.device` feature on class `03`, vendor `0764`, device `0601` and emits
`hardware/ups: or2200pfcrt2u`.

Two reasons it works this way rather than through NFD's `deviceClassWhitelist`:

- **Matching features needs no whitelist change.** `deviceClassWhitelist` governs only
  the labels the worker emits itself, and adding `03` to it would *replace* the default
  list — dropping `ff` and with it `usb-ff_10c4_ea60.present` on `drone-02`, which is
  what pins `zigbee2mqtt`. That breaks silently and only on the next reschedule.
- **This unit reports no USB serial.** `iSerial` is empty, so any label keyed on serial
  would be malformed. Model identity is the right granularity for one UPS.

### Moving the cable

Node labels gate **scheduling, not liveness**. After moving the UPS to another node the
label follows within about a minute, but the running pod does not move and keeps
pointing at a `/dev/bus/usb/...` path that no longer exists. Restart the Deployment:

```bash
kubectl -n nut rollout restart deployment/nut-app-deployment
```

The device's bus address has already been `2-3`, `4-2` and `1-3` across moves, which is
why the whole `/dev/bus/usb` tree is mounted rather than a single device node.

## Power: it is an estimate, not a measurement

This UPS does **not** report real power. `ups.realpower`, `ups.power`, `input.current`
and `output.current` are all absent; only `ups.realpower.nominal: 1540` exists. So watts
are derived:

```
watts = ups.load * 15.4        (1540 W nameplate / 100)
```

The multiplier is an **assumption**, and it lives in exactly one place: the Home
Assistant template sensor. Do not re-derive it in Prometheus — alerts use load percent
directly, which needs no conversion.

How wrong could it be? Reading `ups.load` as a percentage of 2000 VA instead of 1540 W
gives 19% = 380 VA, which at the rated 0.8 power factor is ~304 W against ~293 W for the
watts reading. The nameplate ratio (0.77) is close to the rated PF, so the two readings
converge; the real spread is the load's own power factor. Treat it as ±10%, which is
fine for "how much is the rack drawing" and for kWh on the Energy dashboard.

To tighten it later, plug in a load with a known draw and compare — the multiplier is
then a single edit.

## Configuration worth knowing

`ups.conf` sets `pollonly` and `pollinterval = 15`. Neither is arbitrary: the driver
itself logs *"You may want to set 'pollonly' flag on CPS devices"*, and this model has a
documented history of silently losing the USB connection after hours or days when driven
by USB interrupt reads. Polling is the mitigation. The metrics-absent alert is the
backstop for the case where it wedges anyway.

`upsd` needs an `upsd.users` file to serve at all. The monitor user is read-only and is
deliberately **not** granted `instcmds`; see the safety section for why that matters.

The Deployment bypasses the image entrypoint on purpose — the entrypoint starts `upsmon`
with a shutdown command, and this app only observes.

**Image pin:** `2.8.5-1` ships without `/bin/sh`, so the wrapper that starts the driver
and execs `upsd` cannot run there. The deployment pins `2.8.5-r1`, the build verified
against this device. Check for a shell before bumping past it.

## Safety: what not to run

`upscmd -l` lists `load.off`, `load.on`, `shutdown.stayoff` and `test.battery.start.*`.
These are real. `load.off` cuts power to **everything** plugged into the UPS, including
the node running the command.

- `instcmds` is not granted to any user, so nothing in the cluster can reach these.
- `driver.flag.allow_killpower` stays `0`, so the driver will not act on a shutdown
  sequence even if asked.

**Do not run a battery self-test while the battery is weak.** A quick test transfers the
load to the battery, and on a nearly flat pack that drops the rack. As of 2026-11-19 the
UPS was at 2% charge / 50 s runtime and recovering (4% / 96 s a short while later);
wait for a healthy charge before testing anything.

## Inspecting it

```bash
# raw variables, through the Service
kubectl -n nut exec deploy/nut-app-deployment -c app -- \
  upsc ups@nut-app-service.nut

# a single value
kubectl -n nut exec deploy/nut-app-deployment -c app -- \
  upsc ups@nut-app-service.nut ups.load

# exporter over localhost (same pod network namespace)
kubectl -n nut exec deploy/nut-app-deployment -c app -- \
  wget -qO- http://127.0.0.1:9199/ups_metrics

# from a machine on the tailnet
kubectl -n nut port-forward svc/nut-app-service 19199:9199 &
curl -s http://127.0.0.1:19199/ups_metrics | grep network_ups_tools_ups_load
```

Prometheus picks the exporter up from the Service's `prometheus.io/scrape` annotations;
`prometheus.yml` needs no UPS-specific job. The `instance` label resolves to the node the
UPS is attached to.

## Home Assistant

1. Settings -> Devices & services -> Add integration -> **Network UPS Tools (NUT)**.
2. Host `nut-app-service.nut`, port `3493`, username `monitor` and its password
   (`kubectl -n nut get secret nut-upsd-users -o jsonpath='{.data.upsd\.users}' | base64 -d`).
3. A UPS device appears with load, battery charge, runtime, input/output voltage and
   status sensors.
4. Add a template sensor for watts — the **only** place `15.4` appears:

   ```jinja
   {{ (states('sensor.ups_load') | float(0) * 15.4) | round(0) }}
   ```

   Name it something that says it is an estimate.
5. Add an Integration (Riemann sum) helper over that sensor, in hours, and add it to the
   Energy dashboard.

## Known gaps

- No temperature, no current, no real power — the device does not report them.
- No per-outlet metering or control; one unswitched bank of eight.
- `battery.mfr.date` returns the manufacturer string, not a date.
- `battery.status` reports 100% while `battery.charge` was 2% — trust `charge`.
- No graceful shutdown orchestration. Out of scope; see the archived change
  `add-ups-monitoring`.
- The `UpsMetricsMissing` alert was only verified by expression, not by a live
  fire-and-clear cycle: scaling the Deployment to zero is reverted by Argo's
  `selfHeal` before the 5m `for:` elapses. To test it for real, stop
  `argocd-application-controller` first, then scale the app and watch the alert fire.
