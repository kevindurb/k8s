# Tasks

## 1. NFD hardware label

- [ ] 1.1 Add a `cyberpower.ups` rule to
      `infrastructure/node-feature-discovery/rules/nodefeaturerule.yml`, matching `usb.device` on
      `class: 03`, `vendor: 0764`, `device: 0601` and emitting `hardware/ups: or2200pfcrt2u`;
      verify the file still parses with `yq` and `just check-kustomize` passes.
- [ ] 1.2 Confirm the rule matches raw features rather than labels, so that no
      `deviceClassWhitelist` change is needed: verify `infrastructure/node-feature-discovery/app.yml`
      is unmodified in this change (`git diff` shows no edit to that file) and that the rule has no
      dependency on `usb-03_…` label text.
- [ ] 1.3 After Argo CD syncs, verify `drone-03` carries `hardware/ups: or2200pfcrt2u`, and that
      `drone-02` still carries `feature.node.kubernetes.io/usb-ff_10c4_ea60.present` and the minis
      still carry `media/gpu: amd-vega`
      (`kubectl get node <name> -o jsonpath='{.metadata.labels}'`). If the `amd-vega` label is
      gone, the rule file was damaged — revert this group before continuing.

## 2. NUT application

- [ ] 2.1 Create the `upsd.users` monitor credential as a SealedSecret at
      `infrastructure/nut/upsd-users-sealed-secret.yml` (read-only monitor user, no `instcmds`);
      verify no plaintext password is present in the committed file and that `kubeseal`
      round-trips against the cluster key.
- [ ] 2.2 Write `infrastructure/nut/deployment.yml`: single-replica `Recreate` Deployment,
      `privileged`, `nodeSelector` on `hardware/ups: or2200pfcrt2u`,
      `hostPath` volumes for `/dev/bus/usb` (writable), `/sys/bus/usb` and `/run/udev`
      (read-only). Container `app` runs the NUT driver + `upsd` in the foreground; verify
      `kustomize build infrastructure/nut` renders and the manifest contains no `hostNetwork`
      and exactly one privileged container.
- [ ] 2.3 Add the `ups.conf` and `upsd.conf` ConfigMap generator entries with
      `driver=usbhid-ups`, `port=auto`, `vendorid=0764`, `pollinterval=15`, `pollonly`, and a
      `LISTEN` directive; verify the generated ConfigMap contains both keys with those values.
- [ ] 2.4 Add the `nut_exporter` sidecar container (`exporter`) on port `9199`, path
      `/ups_metrics`, pointed at `127.0.0.1`, with `--nut.vars_enable` covering
      `ups.load,ups.status,battery.charge,battery.runtime,input.voltage,output.voltage,battery.voltage`;
      verify the default variable list is extended so `battery.runtime` is not omitted.
- [ ] 2.5 Add the Service exposing the NUT port plus the exporter's `http` port, annotated
      `prometheus.io/scrape: 'true'`, `prometheus.io/port: '9199'`,
      `prometheus.io/path: '/ups_metrics'`; verify the annotations match what the
      `kubernetes-service-endpoints` job in `infrastructure/prometheus/config/prometheus.yml`
      relabels on.
- [ ] 2.6 Write `infrastructure/nut/kustomization.yml` (`namespace`/`namePrefix` `nut`) and
      `infrastructure/nut/app.yml` following the `apps/template` shape, then register
      `nut/app.yml` in `infrastructure/kustomization.yml`; verify `just check-kustomize` passes.
- [ ] 2.7 Deploy and verify scheduling and service: the pod is `Running` on `drone-03`, and
      `kubectl -n nut exec` into the exporter resolves UPS variables from the Service, and
      `/ups_metrics` on the exporter port returns `network_ups_tools_ups_load`.
- [ ] 2.8 Write `docs/ups-monitoring.md` covering the `watts = ups.load * 15.4` assumption, the
      empty-USB-serial constraint, the `pollonly` rationale, and the replug caveat (node labels
      do not evict pods). Verify the documented `upsc`, `kubectl` and URL examples run as
      written.

## 3. Home Assistant consumption

- [ ] 3.1 Add the official NUT integration in the HA UI pointing at the `nut` Service on 3493;
      verify a UPS device appears with load, battery charge, runtime, input voltage, output
      voltage and status sensors reporting values.
- [ ] 3.2 Add the template sensor deriving watts from `sensor.ups_load` and the `15.4`
      constant; verify its state is a plausible number and that the constant appears only once
      in the HA configuration.
- [ ] 3.3 Add a Riemann-sum (integration) helper over the watts sensor and attach it to the
      Energy dashboard as an energy source; verify the helper shows a `total_increasing`
      kWh sensor and that it appears as a selectable energy source.
- [ ] 3.4 Verify the derivation is honestly labelled: the watts sensor is named and documented
      as an estimate (not a measurement), matching `docs/ups-monitoring.md`.

## 4. Prometheus alerting

- [ ] 4.1 Confirm the live metric names and label shapes for `ups.status` flags and load by
      querying Prometheus before writing rules; verify the load metric is present and that the
      exporter emits every status flag as `0`/`1` rather than omitting unset ones. Note that the
      UPS currently asserts `LB` (battery charge 2%), so the low-battery series must be expected
      to read `1` — that is real state, not a malformed exporter.
- [ ] 4.2 Add a UPS alert group to `infrastructure/prometheus/config/rules/rules.yml` covering
      on-battery, low-battery, replace-battery, overload, load above the capacity threshold, and
      UPS metrics absent; verify the file still satisfies yamllint's document-start and line
      length rules and that the expressions reference the names confirmed in 4.1.
- [ ] 4.3 Verify the rules load without parse errors in the Prometheus UI and that the
      metrics-absent alert fires when the `nut` pod is scaled to zero, then clears when it is
      restored. Expect the low-battery alert to be firing throughout, since the battery sits at
      2%: use it as live proof that the `LB` expression works, and do not mistake it for this
      test leaking.

## 5. Integration verification

- [ ] 5.1 Verify both consumers agree: the load value in HA's `sensor.ups_load` matches the
      `network_ups_tools_ups_load` series for the same moment, and the `instance` label on that
      series is `drone-03`.
- [ ] 5.2 Verify the rollback path is recorded and reversible: removing `nut/app.yml` from
      `infrastructure/kustomization.yml` plus reverting the NFD rule still leaves
      `just check-kustomize` passing.

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied.
- Record the outcome of the deferred watts calibration in `docs/ups-monitoring.md` once the UPS
  carries real load.
