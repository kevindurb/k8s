# Tasks

## 1. Tailnet policy (kevindurb/infra)

- [x] 1.1 Add grant `{"src": ["tag:ci"], "dst": ["tag:apps"], "ip": ["tcp:443"]}` to `tailnet/policy.hujson` and update the `tests` block: move `tag:apps:443` from `tag:ci`'s `deny` list into `accept`. Verify: `just plan tailnet` shows only that grant + test diff; CI plan on the PR matches.
- [x] 1.2 Add SSH rule: `{"action": "accept", "src": ["group:admins"], "dst": ["tag:ci"], "users": ["root", "autogroup:nonroot"]}` plus a matching `sshTests` entry (`group:admins` → `tag:ci` accepts `kevindurb` and `root`). Verify: policy test suite in the PR passes (`terraform plan` applies; `tests`/`sshTests` are evaluated by Tailscale on apply).
- [x] 1.3 Merge the infra PR; confirm CI applies it and the tailnet policy includes the new grant (spot-check via the admin console or a no-op `tailscale policy test` if available).

## 2. Runner image (kevindurb/bootc)

- [ ] 2.1 Add `tailscale` to the `dnf install` list in `containers/ci-runner/Containerfile`; add `tailscale-up.service` (oneshot, `After=tailscaled.service`, runs once per boot) plus its helper script in `overlay/` that runs `tailscale up --auth-key=file:/run/tailscale-authkey --advertise-tags=tag:ci --ssh --accept-dns=true --reset` and `shred -u /run/tailscale-authkey`; enable `tailscaled.service` and `tailscale-up.service`. Verify: `podman build` (or CI) succeeds and `bootc container lint` stays clean.
- [ ] 2.2 Build and publish the new disk: rebuild the qcow2 locally with `image-builder-cli` on a Fedora host per the existing `ci-runner-disk/<date>` release procedure; push the `ci-runner-disk/<date>` release; let `build-runner-disk.yml` repack and push `ghcr.io/kevindurb/ci-runner-disk:<date>` (+ `cosign` sign). Verify: `skopeo inspect` shows the new tag; release notes reference it.

## 3. Secrets (this repo)

- [x] 3.1 Mint a reusable, ephemeral, pre-authorized auth key tagged `tag:ci` in the Tailscale admin console (no expiry or max allowed; generate in a single admin session, never paste into shell history or files).
- [x] 3.2 Re-seal `ci-runner-cloudinit` with a new `tailscale-authkey` key added alongside the existing one (per `docs/secrets.md` workflow: `kubectl create secret --dry-run=client -o yaml` piped through `kubeseal`, commit the `SealedSecret`). Verify: `kubeseal` round-trip succeeds and no plaintext lands in the repo (`git diff` shows only ciphertext).
- [x] 3.3 Extend the cloud-init `userData` in `infrastructure/ci-runner/sealed-secret.yml` (or the source file used to build it) to write `/run/tailscale-authkey` from the new key and remove it after `tailscale-up.service` runs. Keep the existing `forgejo-runner` sections untouched. Verify: `kustomize build infrastructure/ci-runner` renders.

## 4. VM wiring and rollout (this repo)

- [ ] 4.1 Bump `infrastructure/ci-runner/vm.yaml` `containerDisk` to the new `ci-runner-disk:<date>` tag (update the digest comment). Verify: `kustomize build infrastructure/ci-runner` and `just check-kustomize` pass.
- [ ] 4.2 Open PR, merge, let Argo CD sync; force-recreate the VM (`kubectl -n ci-runner delete vmi ci-runner`); verify `vmi/ci-runner` is Running on a drone node.
- [ ] 4.3 From this workstation: `tailscale ping ci-runner` succeeds; `ssh root@ci-runner` (Tailscale SSH) works; `tailscale status` in the VM shows `tagged-devices ci-runner tagged-devices tag:ci`. Verify: all three succeed.
- [ ] 4.4 In the VM: `cat /etc/resolv.conf` points at MagicDNS (100.100.100.100); `curl -sS https://forgejo.beaver-cloud.ts.net/` returns 200 via the tailnet path; `curl -sS https://forgejo.beaver-cloud.ts.net/ -o /dev/null -w '%{remote_ip}\n'` shows the VIP.

## 5. End-to-end verification

- [ ] 5.1 Confirm the runner is Online in forgejo (`admin/actions/runners` or the API) and a dotfiles CI run goes green on the new VM. Verify: run id + green check visible.
- [ ] 5.2 Confirm Aperture parity from inside the VM: `curl -sS https://ai.beaver-cloud.ts.net/v1/models -H "Authorization: Bearer <token from a test secret>"` per the existing Aperture test procedure (or at minimum, confirm the VM can TCP-connect to `ai.beaver-cloud.ts.net:443`). Decide the token source at apply time (a CI job that prints the model list is sufficient).
- [ ] 5.3 Negative checks: a non-admin tailnet identity cannot SSH to `ci-runner`; the VM reaches forgejo even with the node's router path "absent" conceptually (no dependency shown — validated by 5.1/5.4 succeeding while node→VIP remains unroutable).
- [ ] 5.4 Confirm gatus still reports forgejo green (it probes independently; no change expected) and the CI runner shows Online after a full VM recreation cycle.

## 6. Docs

- [ ] 6.1 Update `docs/forgejo.md`: VM now joins as `tag:ci` (MagicDNS, Tailscale SSH for admins, grant references, key handling + rotation: mint new key → re-seal → delete VMI). Note the router hairpin is no longer load-bearing and may be removed later.
- [ ] 6.2 Note in the change (via PR description or a commit trailer) that the Aperture `ci-agents` bucket is shared with GitHub Actions and the podman→tailnet SNAT question remains open (deferred).

## Workflow follow-up

- Archive the change once merged and verified in both other repos (`/opsx-archive`).
