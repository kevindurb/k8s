# Tasks

## 1. Node image configuration

- [x] 1.1 Add `bootc/overlay/etc/chrony.conf` containing `pool 2.pool.ntp.org iburst`, `driftfile /var/lib/chrony/drift`, `makestep 1.0 3`, `rtcsync`, and `logdir /var/log/chrony`; verify with `chronyd -p -f bootc/overlay/etc/chrony.conf` (exits 0 and echoes the parsed directives).
- [x] 1.2 Add `chronyd` to the `systemctl enable` list in `bootc/Containerfile`; verify with `grep -w chronyd bootc/Containerfile`.
- [ ] 1.3 Add `docs/node-time.md` describing the NTP Pool source, the verification commands, and the bootc `/etc` three-way-merge caveat; verify each command in the doc runs as written on a node during the canary step.

## 2. Image build and static validation

- [x] 2.1 Build the image with `podman build -t k8s-node:ntp-test bootc/`; verify the build completes and `bootc container lint` passes.
- [x] 2.2 Inspect the built image: `podman run --rm k8s-node:ntp-test cat /etc/chrony.conf` matches the overlay file, `podman run --rm k8s-node:ntp-test chronyd -p -f /etc/chrony.conf` exits 0, and `podman run --rm k8s-node:ntp-test systemctl is-enabled chronyd` prints `enabled` (fall back to checking the `multi-user.target.wants` symlink if `systemctl` cannot run in the container).
- [x] 2.3 Run `pre-commit run --files bootc/Containerfile bootc/overlay/etc/chrony.conf docs/node-time.md`; verify it passes. Changed files pass every applicable hook; repo-wide `ansible-lint` failures are pre-existing (missing collections in its venv, `document-start` on generated `.openspec.yaml` files) and `ansible-lint` was excluded.

## 3. Canary rollout (drone-01)

- [ ] 3.1 Confirm the `.github/workflows/build-bootc.yml` run for the merged commit succeeded and the `ghcr.io/kevindurb/k8s-node` image was pushed and signed.
- [ ] 3.2 From `ansible/`, run `just playbook upgrade.yml --limit drone-01`; verify the play exits 0 and `kubectl get node drone-01` reports `Ready`.
- [ ] 3.3 On drone-01, verify `systemctl is-enabled chronyd` is `enabled`, `systemctl is-active chronyd` is `active`, `grep -x 'pool 2.pool.ntp.org iburst' /etc/chrony.conf` matches, `chronyc tracking` reports `Leap status : Normal` with a non-zero reference, and `timedatectl` reports `System clock synchronized: yes`.
- [ ] 3.4 On drone-01, confirm no local override survived the update by checking `sudo ostree admin config-diff | grep chrony`; if `/etc/chrony.conf` was locally modified, copy the image file (`sudo cp /usr/etc/chrony.conf /etc/chrony.conf && sudo systemctl restart chronyd`) and repeat 3.3.
- [ ] 3.5 On drone-01, confirm `grep -c '^allow' /etc/chrony.conf` returns 0, so the node does not serve time to the LAN.

## 4. Remaining nodes except the storage node

- [ ] 4.1 From `ansible/`, run `just playbook upgrade.yml --limit 'all:!drone-04'`; verify the play exits 0 and `kubectl get nodes` shows every targeted node `Ready`.
- [ ] 4.2 For each of `unimatrix-01..03` and `drone-01..03`, repeat the checks in 3.3 and 3.5; verify all six report an enabled, active `chronyd`, the pool line, synchronized time, and no `allow` directive.

## 5. Storage node (drone-04)

- [ ] 5.1 Stage the image without rebooting: from `ansible/`, run `just ansible drone-04 -b -m community.general.bootc_manage -a 'state=latest'`; verify it exits 0.
- [ ] 5.2 Preview the drone-04 reboot with `just playbook upgrade.yml --limit drone-04 --check`; verify the drain list is expected and nothing is changed.
- [ ] 5.3 Run `just playbook upgrade.yml --limit drone-04`; verify it exits 0, `drone-04` is `Ready`, the `rust` pool imports, the NFS export serves, and all pods return to `Running`.
- [ ] 5.4 On drone-04, repeat the checks in 3.3, 3.4, and 3.5; verify time sync, the pool line, and no `allow` directive.

## 6. Cluster integration check

- [ ] 6.1 Verify all seven nodes report `System clock synchronized: yes` and that `chronyc tracking` offsets are below 100 ms when checked after the rollout settles.
- [ ] 6.2 Verify Argo CD and the cluster control plane show no clock-related errors after the rollout: `kubectl -n argocd get pods` is healthy and applications report `Synced`/`Healthy`.
- [ ] 6.3 Run `openspec validate configure-node-ntp-pool --strict`; verify it passes.
