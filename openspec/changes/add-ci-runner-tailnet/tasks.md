# Tasks

## 1. Tailnet policy (kevindurb/infra)

- [x] 1.1 Add grant `{"src": ["tag:ci"], "dst": ["tag:apps"], "ip": ["tcp:443"]}` to `tailnet/policy.hujson` and update the `tests` block: move `tag:apps:443` from `tag:ci`'s `deny` list into `accept`. Verify: `just plan tailnet` shows only that grant + test diff; CI plan on the PR matches.
- [x] 1.2 Add SSH rule: `{"action": "accept", "src": ["group:admins"], "dst": ["tag:ci"], "users": ["root", "autogroup:nonroot"]}` plus a matching `sshTests` entry (`group:admins` → `tag:ci` accepts `kevindurb` and `root`). Verify: policy test suite in the PR passes (`terraform plan` applies; `tests`/`sshTests` are evaluated by Tailscale on apply).
- [x] 1.3 Merge the infra PR; confirm CI applies it and the tailnet policy includes the new grant (spot-check via the admin console or a no-op `tailscale policy test` if available).

## 2. Runner image (kevindurb/bootc)

- [x] 2.1 Add `tailscale` to the `dnf install` list in `containers/ci-runner/Containerfile`; add `tailscale-up.service` (oneshot, `After=tailscaled.service`, runs once per boot) plus its helper script in `overlay/` that runs `tailscale up --auth-key=file:/run/tailscale-authkey --advertise-tags=tag:ci --ssh --accept-dns=true --reset` and `shred -u /run/tailscale-authkey`; enable `tailscaled.service` and `tailscale-up.service`. Verify: `podman build` (or CI) succeeds and `bootc container lint` stays clean.
- [x] 2.2 Build and publish the new disk: rebuild the qcow2 locally with `image-builder-cli` on a Fedora host per the existing `ci-runner-disk/<date>` release procedure; push the `ci-runner-disk/<date>` release; let `build-runner-disk.yml` repack and push `ghcr.io/kevindurb/ci-runner-disk:<date>` (+ `cosign` sign). Verify: `skopeo inspect` shows the new tag; release notes reference it.

## 3. Secrets (this repo)

- [x] 3.1 Mint a reusable, ephemeral, pre-authorized auth key tagged `tag:ci` in the Tailscale admin console (no expiry or max allowed; generate in a single admin session, never paste into shell history or files).
- [x] 3.2 Re-seal `ci-runner-cloudinit` with a new `tailscale-authkey` key added alongside the existing one (per `docs/secrets.md` workflow: `kubectl create secret --dry-run=client -o yaml` piped through `kubeseal`, commit the `SealedSecret`). Verify: `kubeseal` round-trip succeeds and no plaintext lands in the repo (`git diff` shows only ciphertext).
- [x] 3.3 Extend the cloud-init `userData` in `infrastructure/ci-runner/sealed-secret.yml` (or the source file used to build it) to write `/run/tailscale-authkey` from the new key and remove it after `tailscale-up.service` runs. Keep the existing `forgejo-runner` sections untouched. Verify: `kustomize build infrastructure/ci-runner` renders.

## 4. VM wiring and rollout (this repo)

- [x] 4.1 Bump `infrastructure/ci-runner/vm.yaml` `containerDisk` to the new `ci-runner-disk:<date>` tag (update the digest comment). Verify: `kustomize build infrastructure/ci-runner` and `just check-kustomize` pass.
- [x] 4.2 Open PR, merge, let Argo CD sync; force-recreate the VM (`kubectl -n ci-runner delete vmi ci-runner`); verify `vmi/ci-runner` is Running on a drone node.
- [x] 4.3 From this workstation: `tailscale ping ci-runner` succeeds; `ssh root@ci-runner` (Tailscale SSH) works; `tailscale status` in the VM shows `tagged-devices ci-runner tagged-devices tag:ci`. Verify: all three succeed.
- [x] 4.4 In the VM: `cat /etc/resolv.conf` points at MagicDNS (100.100.100.100); `curl -sS https://forgejo.beaver-cloud.ts.net/` returns 200 via the tailnet path; `curl -sS https://forgejo.beaver-cloud.ts.net/ -o /dev/null -w '%{remote_ip}\n'` shows the VIP.

## 5. End-to-end verification

- [x] 5.1 Confirm the runner is Online in forgejo (`admin/actions/runners` or the API) and a dotfiles CI run goes green on the new VM. Verify: run id + green check visible.
- [x] 5.2 Confirm Aperture parity from inside the VM: `curl -sS https://ai.beaver-cloud.ts.net/v1/models -H "Authorization: Bearer <token from a test secret>"` per the existing Aperture test procedure (or at minimum, confirm the VM can TCP-connect to `ai.beaver-cloud.ts.net:443`). Decide the token source at apply time (a CI job that prints the model list is sufficient).
- [x] 5.3 Negative checks: a non-admin tailnet identity cannot SSH to `ci-runner`; the VM reaches forgejo even with the node's router path "absent" conceptually (no dependency shown — validated by 5.1/5.4 succeeding while node→VIP remains unroutable).
- [x] 5.4 Confirm gatus still reports forgejo green (it probes independently; no change expected) and the CI runner shows Online after a full VM recreation cycle.

## 6. Docs

- [x] 6.1 Update `docs/forgejo.md`: VM now joins as `tag:ci` (MagicDNS, Tailscale SSH for admins, grant references, key handling + rotation: mint new key → re-seal → delete VMI). Note the router hairpin is no longer load-bearing and may be removed later.
- [x] 6.2 Note in the change (via PR description or a commit trailer) that the Aperture `ci-agents` bucket is shared with GitHub Actions and the podman→tailnet SNAT question remains open (deferred).

## Workflow follow-up

- Archive the change once merged and verified in both other repos (`/opsx-archive`).
## Verification notes (2026-11-27)

- 1.2: `group:admins` as sshTests `src` fails Tailscale policy validation with an
  opaque `test(s) failed; [{unknown [unknown error occurred]}]` (reproduced 3x in CI);
  the committed sshTests entry uses `kevindurb@github`. Follow-up #23 added `tag:dev`
  to the SSH rule src + an sshTests entry, after the first live SSH attempt from the
  tagged workstation was (correctly) refused.
- 1.3: applied by CI (`production` environment approval granted for both matrix legs).
- 2.1: local `podman build` clean; merged bootc PR #69; rebuilt image on CI.
- 2.2: `ci-runner-disk/2026.11.27.2` release (qcow2 from bootc@367ac19 /
  ghcr.io/kevindurb/ci-runner@sha256:a0caa9bc…), repacked + cosign-signed by
  build-runner-disk.yml; digest 8ae021c32c3f752200793b05747c888ccf6f1675d36f52e999d544338b9f8b40.
- 3.2/3.3: NoCloud exposes only `userData` to the guest, so the auth key travels inside
  `userData` (`/run/tailscale-authkey`, 0600); the separate `tailscale-authkey` key in the
  same SealedSecret is kept for rotation. Plaintext never entered the repo.
- 4.3: `tailscale ping ci-runner` OK; `ssh root@ci-runner` OK (after #23); VM shows
  `tagged-devices ... tag:ci`, backend Running.
- 4.4: `/etc/resolv.conf` is the systemd-resolved stub; MagicDNS lives on the
  `tailscale0` link (`resolvectl` shows 100.100.100.100, domain `~.`). `curl` forgejo
  returned 200 via IPv4 VIP 100.86.247.27 (and via forgejo's AAAA).
- 5.1: runner id 2 "ci-runner" (v13.2.2) status `idle` after recreation; stale
  duplicate (id 1, current VM's predecessor) deleted. Test CI run for
  kevindurb/dotfiles (push + PR, run 84/86, branch ci/verify-tailnet-runner):
  green; PR #2 closed unmerged, branch deleted. Two permanently-`waiting`
  mirror.yml jobs from before the outage left in place (API has no delete).
- 5.2: no bearer token needed — VM authenticates to Aperture with its tag:ci
  identity. `GET /v1/models` 200; `POST /v1/chat/completions` with
  `deepseek-v4.1-flash` (the ci-agents bucket model) returned 200.
- 5.3: node (tag:k8s-node) -> ci-runner:22 times out (no network grant);
  node->forgejo VIP also still times out (pre-existing). tag:ci -> tag:ci hairpin
  hits the VM's plain sshd (pubkey-only, no authorized keys) — tailnet SSH policy
  was validated via CI tests instead. Administrative SSH from the workstation
  (tag:dev) works per the new rule.
- 5.4: gatus `apps/forgejo` green throughout; gatus probed independently of the
  runner recreation.
- 6.2: see PR #659 body — Aperture `ci-agents` bucket shared with GitHub Actions;
  podman→tailnet SNAT still open (deferred per design Non-Goals).
