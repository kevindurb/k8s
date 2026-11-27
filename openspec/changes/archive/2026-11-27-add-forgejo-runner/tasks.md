# Tasks

Depends on: `install-kubevirt` applied (VM needs KubeVirt) and `add-forgejo`
applied (needs a forgejo URL + registration token). Cross-repo: tasks marked
**(bootc)** happen in `kevindurb/bootc`; the rest here.

## 1. Runner image (kevindurb/bootc)

- [x] 1.1 **(bootc)** Create `containers/ci-runner/Containerfile` — done: `quay.io/fedora/fedora-bootc:44@sha256:6b3262...` (no `stable` tag exists; `44` is current Fedora, matches fleet), dnf installs podman/buildah/podman-docker/skopeo/git/git-lfs/make/jq/nodejs/cloud-init, `forgejo-runner` v13.2.2 from code.forgejo.org pinned by sha256, `forgejo-runner.service` + hourly `podman-gc.timer` enabled, `bootc container lint` passes (warnings only, same class as other images)
- [x] 1.2 **(bootc)** `ci-runner` job added to `.github/workflows/build.yml` via `reusable-build.yml`; CI build succeeded 2026-11-27 and pushed `ghcr.io/kevindurb/ci-runner:latest` (+ `sha-4cd0994`). Note: dated `YYYY.MM.DD` tags are only produced by the weekly cron build; the push-path build emits `latest` + `sha-<short>`. Dated tag will appear after the next scheduled Build (or on any future scheduled run) — flagging in case the dated tag is wanted on every push (one-line change to reusable-build.yml, intentionally left alone since it tags every image in the repo)
- [x] 1.3 **(bootc)** `.github/workflows/build-runner-disk.yml` implemented **differently than planned**: GH-hosted runners cannot build the qcow2 (osbuild needs nested user namespaces; Ubuntu's `apparmor_restrict_unprivileged_userns=1` blocks them even with `--privileged`; `/dev/kvm` exists but the failure happens before the VM is used). The qcow2 is built locally on a Fedora 44 host with `image-builder-cli` (proven, 2026-11-27) and published as a release asset (`ci-runner-disk/2026.11.27`: `bootc-fedora-44-qcow2-x86_64.qcow2` → `ci-runner-disk.qcow2.xz`, sha256 published). The workflow repacks the asset into a `FROM scratch` containerDisk (`disk.img`), pushes `ghcr.io/kevindurb/ci-runner-disk:<tag>` + `:latest`, and cosign-signs **both** images (same key as the node image; verified locally with the repo's `cosign.pub`). Rebuild procedure documented in `docs/forgejo.md`. Release/asset flow is the supported path; the workflow triggers on `release: published` for tags `ci-runner-disk/*` or via `workflow_dispatch`
- [x] 1.4 Verify: `skopeo inspect docker://ghcr.io/kevindurb/ci-runner-disk:2026.11.27` succeeds anonymously (also `:latest`); KubeVirt pulled it and the VM booted from it, so KubeVirt needs no pull secret (image is public). Signed via `cosign verify --key kevindurb/bootc/cosign.pub`

## 2. Runner VM (this repo)

- [x] 2.1 Create `infrastructure/ci-runner/` app: `app.yml` (Argo Application, project `infrastructure`, namespace `ci-runner`, CreateNamespace), `kustomization.yml`, `vm.yaml`, `sealed-secret.yml` — committed and synced 2026-11-27 (one fix: `interfaces[].model` must be a string for the kubevirt webhook). Gatus entry deliberately skipped — the VM has no HTTP endpoint; forgejo URL gatus check covers reachability, runner visibility is via forgejo UI/API (see docs/forgejo.md)
- [x] 2.2 `vm.yaml`: `VirtualMachine` `ci-runner` — 2 vCPU, 4 GiB, `containerDisk` `ghcr.io/kevindurb/ci-runner-disk:2026.11.27` (pinned tag + digest recorded in a comment), nodeAffinity `kubernetes.io/hostname` in `[drone-01, drone-02, drone-03]` (affinity instead of nodeSelector — same semantics, no control-plane, drone-04 excluded), no control-plane tolerations, masquerade networking, cloudInitNoCloud `secretRef` (`ci-runner-cloudinit`), host/VM runs with no privileged pods
- [x] 2.3 `sealed-secret.yml` `ci-runner-cloudinit`: userData (from file, not literal) that (a) writes `/etc/forgejo-runner/config.yaml` — instance `https://forgejo.beaver-cloud.ts.net`, one runner, `capacity: 1`, labels `self-hosted:host,linux:host` (typed labels required by the runner; names match `runs-on: [self-hosted, linux]`) — and (b) registers on first boot (`forgejo-runner register --no-interactive --token $(cat /run/secrets/ci-runner-token) --labels self-hosted:host,linux:host`, then `rm` the token file, then `systemctl start forgejo-runner`)
- [x] 2.4 Registration token generated via `kubectl exec -n forgejo deploy/forgejo -- forgejo actions generate-runner-token` (global scope), sealed into `ci-runner-cloudinit` (name matches post-unseal name — no prefix in this app), local plaintext shredded (`/tmp` copies removed). Token is alive/needed only for first boot
- [x] 2.5 `just check-kustomize` ✓; pushed; Argo app `ci-runner` synced; `vmi/ci-runner` Running on drone-02; kubevirt `virt-launcher` pod not privileged; forgejo API shows runner `ci-runner` **active** v13.2.2 with labels self-hosted,linux
- [x] 2.6 Smoke job: `runner-smoke` scratch repo with `podman info`, `podman run hello-world`, and a `podman build` of a tiny image — all green (run id 7, then deleted the scratch repo)

## 3. Job sandbox verification

- [x] 3.1 Confirmed: `kubectl get pods -A` privileged list contains only known infra pods (kubevirt virt-handler, openebs, smartctl-exporter, zfs-exporter, tailscale, nut/jellyfin/makemkv/zigbee2mqtt, pod-pinned DaemonSets). The runner job runs inside the VM, not in a pod; the `virt-launcher` pod runs as uid 107, not privileged; no pods were created by the smoke workflow
- [x] 3.2 Recorded: each job effectively starts cold w.r.t. podman cache — the VM persists between jobs but the image ships an hourly `podman system prune -f` timer, and VM recreation wipes everything. Observed cold behavior on first smoke run (hello-world pulled from docker.io). Persistent per-job cache is out of scope; jobs must not rely on it. No podman socket is exposed to pods — it is only the in-VM local socket

## 4. Migrate dotfiles CI

- [x] 4.1 Add `.forgejo/workflows/ci.yml` to dotfiles: checkout → chezmoi (`anz/chezmoi` v2.74.2, glibc build, sha256-verified — same version as the Tekton task, which used the musl build) `execute-template --dry-run` render → `shellcheck` (v0.11.0, same as Tekton's koalaman/shellcheck-alpine v0.11.0) on all shell sources, same semantics as the Tekton task. Deployed via PR #1 (merged 2026-11-27), with a follow-up fix: run steps need `HOME` set (forgejo runner doesn't export it — first runs failed on `chezmoi: $HOME is not defined`)
- [x] 4.2 Verified dotfiles has no `.github/workflows` (nothing to delete). PR #1 opened, ran, iterated to green; PR body documents the change. Note: the first runs all failed on a workflow bug unrelated to the runner (missing `HOME` for run steps — fixed in `c61358f`), not because of runner availability
- [x] 4.3 Negative test: branch `ci-negative-test` with an unbalanced `{{` failed the render step (`unclosed action ... broken_negative_test.sh.tmpl`); branch deleted afterwards, nothing merged
- [x] 4.4 `main` is green (commit `c61358f`, run at 2026-11-27T07:49); `forgejo` commit status on `main` reports `success`. One intermediate empty commit (`47d32f6`) was pushed to retrigger after the runner came online; it failed only on the missing `HOME` in run steps, fixed in `c61358f`

## 5. Migrate image-building repositories

> Closed 2026-11-27 by owner decision: no image repos migrate. Enumeration (5.1) was done:
> candidates with image-build workflows on GitHub are `kevindurb/bootc` (push-triggered multi-arch
> builds), `kevindurb/containers` (buildah multi-arch matrix), `kevindurb/box` and
> `kevindurb/ts-forge` (buildah multi-arch + manifest step), all pushing to ghcr.io.
> None of them exist on forgejo yet (add-forgejo migrated only dotfiles), and a forgejo-runner
> build there is amd64-only, so arm64 builds would either drop or stay on GitHub.
> GHCR also rejects GitHub App installation tokens for package writes, so per-run App tokens
> cannot push images; image builds stay on GitHub Actions (see docs/forgejo.md → "GitHub mirror").

- [x] 5.1 Enumerate candidates: `gh repo list kevindurb --json name,isPrivate | jq ...` cross-referenced with `gh search code 'podman build' --owner kevindurb` (or manual recall: confirm list with owner before starting) — done 2026-11-27: candidates are `bootc`, `containers`, `box`, `ts-forge`; owner decision: none migrate
- [x] 5.2–5.5 Image-repo CI migration — closed by decision 2026-11-27: none migrate; image builds remain on GitHub Actions (see docs/forgejo.md). Original tasks retained for the record (not planned):
  > - [ ] 5.2 For each repo: push history (already done in `add-forgejo`), rewrite workflow file(s) to `.forgejo/workflows/`, `runs-on: [self-hosted, linux]`, drop GH-hosted-specific steps (e.g. `actions/checkout` pins are fine — forgejo resolves them), set `REGISTRY` = `ghcr.io`, `IMAGE` = same name as before
  > - [ ] 5.3 Create per-repo or org-wide secret `REGISTRY_TOKEN` = fine-grained PAT (`packages: write` on GHCR) in forgejo secrets
  > - [ ] 5.4 For each repo: push a no-op commit, watch the build go green in forgejo, verify GHCR has the new tag/digest, verify the deployed consumers (renovate PR flow) still work
  > - [ ] 5.5 Delete `.github/workflows/*.yml` in each migrated repo in the same PR (no double runs from the mirror), or explicitly disable the GH workflow

## 6. Wrap-up

- [x] 6.1 Extended `docs/forgejo.md`: runner architecture (VM, containerDisk, build/signing path), rebuild/replace steps, token rotation, reboot behavior, reading job logs (web UI + `/data/actions_log/...` via `kubectl exec`), cold-cache caveat, why no gatus runner check
- [x] 6.2 gatus shows forgejo healthy (verified `api/v1/endpoints/statuses` → forgejo `success=true`; the forgejo URL check already exists in `platform/forgejo/gatus.yml`). No runner-specific gatus check added, per spec — the VM has no HTTP endpoint and runner presence is visible in the forgejo UI/API (`admin/actions/runners` → `ci-runner` idle/online)
- [x] 6.3 Hand-off to `remove-tsgit-tekton` noted in docs/forgejo.md; Tekton/tsgit untouched by this change

## Workflow follow-up

- Archive this change once `remove-tsgit-tekton` merges (it is the final proof the old path is disposable).
