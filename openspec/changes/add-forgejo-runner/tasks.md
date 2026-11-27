# Tasks

Depends on: `install-kubevirt` applied (VM needs KubeVirt) and `add-forgejo`
applied (needs a forgejo URL + registration token). Cross-repo: tasks marked
**(bootc)** happen in `kevindurb/bootc`; the rest here.

## 1. Runner image (kevindurb/bootc)

- [ ] 1.1 **(bootc)** Create `containers/ci-runner/Containerfile`: `FROM quay.io/fedora/fedora-bootc:stable` (pin digest), `dnf install` podman, buildah, git, git-lfs, make, jq; add `forgejo-runner` (pinned release from codeberg, checksummed) to `/usr/local/bin`; enable `forgejo-runner.service` (unit runs `daemon --config /etc/forgejo-runner/config.yaml`); `bootc container lint` clean
- [ ] 1.2 **(bootc)** Wire `containers/ci-runner` into `.github/workflows/build.yml` via the existing `reusable-build.yml` pattern (rename job `ci-runner`); confirm push of `ghcr.io/kevindurb/ci-runner:latest` + dated tag
- [ ] 1.3 **(bootc)** Add `.github/workflows/build-runner-disk.yml`: run `bootc-image-builder` (type `qcow2`) in a privileged step, then wrap the qcow2 as `FROM scratch / COPY *.qcow2 /disk/disk.img`, tag `ghcr.io/kevindurb/ci-runner-disk:<sha>`, cosign-sign both images (existing cosign flow), push
- [ ] 1.4 Verify: `skopeo inspect docker://ghcr.io/kevindurb/ci-runner-disk:<sha>` succeeds from a clean machine; image is public (or note the required pull secret for KubeVirt)

## 2. Runner VM (this repo)

- [ ] 2.1 Create `infrastructure/ci-runner/` app: `app.yml` (Argo Application, project `infrastructure`, namespace `ci-runner`, CreateNamespace), `kustomization.yml`, `vm.yaml`, `sealed-secret.yml`, gatus entry if a healthcheck makes sense (else skip — the VM's liveness signal is the runner status in forgejo)
- [ ] 2.2 `vm.yaml`: `VirtualMachine` `ci-runner` — 2 vCPU, 4 GiB, `containerDisk` source `ghcr.io/kevindurb/ci-runner-disk:<pinned tag>`, nodeSelector `kubernetes.io/hostname` in `[drone-01, drone-02, drone-03]`, no control-plane tolerations, masquerade networking, cloudInitNoCloud userData from secret `ci-runner-cloudinit`
- [ ] 2.3 `sealed-secret.yml` `ci-runner-cloudinit`: userData (from file, not literal) that (a) writes `/etc/forgejo-runner/config.yaml` — instance `https://forgejo.beaver-cloud.ts.net`, one runner, `capacity: 1`, labels `self-hosted,linux` — and (b) registers on first boot (`forgejo-runner register --no-interactive --token $(cat /run/secrets/ci-runner-token) ...` then `systemctl start forgejo-runner`)
- [ ] 2.4 Mint the registration token in forgejo (site administration → runners → create registration token); seal it INTO the cloud-init secret; delete local copy
- [ ] 2.5 `just check-kustomize`; push; Argo syncs; `kubectl -n ci-runner get vmi` shows `Running`; forgejo UI shows runner **Online**
- [ ] 2.6 Smoke job: add a temp workflow on a scratch repo that runs `podman info` and `podman run --rm hello-world`; confirm green in forgejo

## 3. Job sandbox verification

- [ ] 3.1 Confirm the runner pod is **not** privileged and the workflow job did not create any privileged pod: `kubectl get pods -A -o json | jq '..|.securityContext? //empty | select(.privileged==true)'` shows only known infra pods
- [ ] 3.2 Confirm podman storage works across steps (push a tag, then a second job reuses cache) — or document that each job starts cold; either is acceptable, record which

## 4. Migrate dotfiles CI

- [ ] 4.1 Add `.forgejo/workflows/ci.yml` to dotfiles: checkout → chezmoi (pinned to the version from the old Tekton pipeline) `execute-template --dry-run` render → `shellcheck` on all shell sources (same semantics as the Tekton task)
- [ ] 4.2 Delete `.github/workflows` content that duplicates it (dotfiles has none today — verify); open a PR/branch, watch it run, iterate to green
- [ ] 4.3 Negative test: branch with an unmatched `{{` fails the render step; capture the failure log; then revert
- [ ] 4.4 Merge to `main`; confirm `main` build green; confirm forgejo shows the commit status

## 5. Migrate image-building repositories

- [ ] 5.1 Enumerate candidates: `gh repo list kevindurb --json name,isPrivate | jq ...` cross-referenced with `gh search code 'podman build' --owner kevindurb` (or manual recall: confirm list with owner before starting)
- [ ] 5.2 For each repo: push history (already done in `add-forgejo`), rewrite workflow file(s) to `.forgejo/workflows/`, `runs-on: [self-hosted, linux]`, drop GH-hosted-specific steps (e.g. `actions/checkout` pins are fine — forgejo resolves them), set `REGISTRY` = `ghcr.io`, `IMAGE` = same name as before
- [ ] 5.3 Create per-repo or org-wide secret `REGISTRY_TOKEN` = fine-grained PAT (`packages: write` on GHCR) in forgejo secrets
- [ ] 5.4 For each repo: push a no-op commit, watch the build go green in forgejo, verify GHCR has the new tag/digest, verify the deployed consumers (renovate PR flow) still work
- [ ] 5.5 Delete `.github/workflows/*.yml` in each migrated repo in the same PR (no double runs from the mirror), or explicitly disable the GH workflow

## 6. Wrap-up

- [ ] 6.1 Extend `docs/forgejo.md` (created in `add-forgejo`): runner architecture, adding/replacing the VM, rotating the registration token, what happens on reboot, how to read a failed job log
- [ ] 6.2 Verify `gatus` shows forgejo healthy and the runner VM pod healthy; add a gatus check on the forgejo URL only (runner is visible via forgejo UI)
- [ ] 6.3 Hand off to `remove-tsgit-tekton` — do **not** delete Tekton/tsgit here

## Workflow follow-up

- Archive this change once `remove-tsgit-tekton` merges (it is the final proof the old path is disposable).
