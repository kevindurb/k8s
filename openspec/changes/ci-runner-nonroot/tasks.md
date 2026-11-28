# Tasks

Depends on: nothing (runnable independently). Cross-repo: tasks marked
**(bootc)** happen in `kevindurb/bootc`; the rest here.

## 1. Runner image (kevindurb/bootc)

- [x] 1.1 **(bootc)** Add a `runner` user to `containers/ci-runner/Containerfile` (uid 1000, home `/var/lib/forgejo-runner`, shell `/bin/bash`), add `/etc/subuid` + `/etc/subgid` entries (`runner:165536:65536`), linger via `/var/lib/systemd/linger/runner`, setuid `newuidmap`/`newgidmap` **and strip their file capabilities** — the base image ships effective fcaps which grant nothing here and suppress the setuid path (kernel: "has both setuid-root and effective capabilities ... not raising all capabilities"); verified rootless id-mapping works after the fix.
- [x] 1.2 **(bootc)** Switch `forgejo-runner.service` and `podman-gc.service` to run as `runner` (`User=`/`Group=`, `Environment=XDG_RUNTIME_DIR=/run/user/<uid>` on the runner unit), and `chown -R runner:runner /var/lib/forgejo-runner` in the image. Verify: `systemctl cat` output shows the directives; unit still passes lint/boot (verified in 1.4).
- [x] 1.3 **(bootc)** Verify rootless podman inside the image: as `runner`, `podman run --rm docker.io/library/hello-world`, `podman build` of a scratch Containerfile, and `podman run -v /tmp/x:/work:Z` all succeed. Verify via a throwaway VM boot (see 1.4) — not on a developer machine.
- [x] 1.4 **(bootc)** Rebuild and publish: `ci-runner` image builds green in CI; build the qcow2 via the documented local Fedora path; publish `ci-runner-disk/<date>` release; `build-runner-disk.yml` repacks and cosign-signs; verify signature with `cosign verify --key cosign.pub`. Verify: GHCR shows the new tag + signature before any pin bump.

## 2. Pre-flight secret hygiene (this repo)

- [x] 2.1 Mint a fresh runner registration token (`kubectl exec -n forgejo deploy/forgejo -- forgejo actions generate-runner-token`), re-seal into a new `ci-runner-cloudinit` SealedSecret (additive change; keep the old secret's contents recoverable until cutover is verified). Verify: `kubeseal` round-trips and `kubectl get sealedsecret -n ci-runner` shows the new `last-applied` annotation after sync — do not print secret values.

## 3. Cutover (this repo)

- [x] 3.1 Bump the pinned `containerDisk` in `infrastructure/ci-runner/vm.yaml` to the new tag; update the pinned-digest comment. Verify: `kustomize build infrastructure/ci-runner` renders the new tag; `just check-kustomize` passes.
- [x] 3.2 Update `docs/forgejo.md`: "Job environment" section — jobs run as `runner` (uid, non-root), rootless podman, no sudo, tailscaled stays root, pip-in-container warnings are out of scope; rebuild/re-register steps unchanged except the fresh-token note. Verify: doc reads accurately against the merged image.
- [x] 3.3 Merge; let Argo sync; VM recreates. Verify: `kubectl -n ci-runner get vmi` shows Running on the new image; in forgejo, `ci-runner` shows Online (delete the stale runner entry if it duplicated).
- [x] 3.4 Smoke jobs: re-run `kevindurb/networking` CI (exercises rootless podman + `:Z` bind mount) and `kevindurb/dotfiles` CI (pure userland). Verify: both green; a job-step `id -u` prints the `runner` uid, not 0; `podman images` inside a job shows the rootless store.
- [x] 3.5 Negative check: confirm a job step attempting `sudo -n true` or writing to `/etc` fails with permission denied (run ad-hoc via a scratch repo or workflow_dispatch). Verify: step exits non-zero.
- [x] 3.6 Rollback readiness: confirm the previous `ci-runner-disk` tag is still pullable and document (in the merge commit message or PR) that reverting the pin restores rootful root jobs. Verify: tag resolves via `skopeo inspect`.

## Workflow follow-up

- Archive this change once the VM runs the new image green through at least one full `networking` CI run.
- Optional follow-ups (not this change): tightening `tag:ci` tailnet grants in `kevindurb/infra`; `PIP_ROOT_USER_ACTION=ignore` (or `--user`) in job workflows to silence in-container pip warnings.
