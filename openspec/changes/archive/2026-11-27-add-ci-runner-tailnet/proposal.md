# Proposal

## Why

The Forgejo CI runner VM reaches `forgejo.beaver-cloud.ts.net` only incidentally: its pod-network traffic hairpins through the LAN router (`tag:router` → `tag:apps:443`), which is why CI works today. Nothing about that path is deliberate — the node itself cannot reach the VIP, the VM has no tailnet identity of its own, and the runner has none of the grants GitHub Actions' `tag:ci` runners have (Aperture gateway, tsgit read, argocd webhook). Joining the VM to the tailnet as `tag:ci` makes its connectivity intentional, least-privilege, and independent of the router's posture.

## What Changes

- **VM image (`kevindurb/bootc`)**: `containers/ci-runner` gains `tailscaled` (enabled) and a boot-time join step. Rebuilt image ships as a new `ci-runner-disk` release; the VM pins to it.
- **Auth**: a reusable, pre-authorized, ephemeral, `tag:ci` auth key, delivered via a new `SealedSecret` (`ci-runner-tailscale-key`) into cloud-init; the VM joins on first boot with `--ssh` and MagicDNS enabled. Ephemeral means VM recreation (image bumps) never accumulates stale device entries.
- **Tailnet policy (`kevindurb/infra`)**: new grant `tag:ci → tag:apps:443` (forgejo ingress); new SSH rule `group:admins → tag:ci` (`root` + `autogroup:nonroot`); policy test entries updated to match (`tag:ci` moves from `deny` to `accept` for `tag:apps:443`; new sshTest).
- **Runner retains** its existing `tag:ci` GitHub Actions grants (Aperture `ci-agents` bucket, tsgit read with `cap/repo`, `svc:argocd:443`) — forgejo CI gets parity with GitHub Actions for free, sharing the same quota.
- **DNS**: with `accept-dns`, the VM resolves MagicDNS names directly against the tailnet; forgejo access no longer depends on the LAN router hairpin.
- **Inbound**: SSH from `group:admins` via Tailscale SSH (mirrors the node pattern). No other inbound access is added.
- Not in scope (deferred): podman-in-VM → tailnet masquerade for jobs that need tailnet egress from inside containers (jobs are host-level today; base images come from public GHCR).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `forgejo-runner`: the runner VM becomes a first-class tailnet device (`tag:ci`) — it joins on boot via an ephemeral key, resolves MagicDNS, reaches forgejo (and Aperture/tsgit/argocd) through its own tag's grants instead of the router hairpin, and accepts Tailscale SSH from `group:admins`.

## Impact

- **This repo (`kevindurb/k8s`)**: `infrastructure/ci-runner/` — new SealedSecret, cloud-init `userData` gains the tailscale join step, `vm.yaml` pins the new `ci-runner-disk` tag; `docs/forgejo.md` updated.
- **`kevindurb/bootc`**: `containers/ci-runner/` gains `tailscale` package + `tailscaled.service` enablement (+ minimal join helper); new image build + `ci-runner-disk` release (out-of-band manual qcow2 build per the existing rebuild procedure).
- **`kevindurb/infra`**: `tailnet/policy.hujson` grant + SSH rule + `tests`/`sshTests` updates; applied via the repo's terraform CI on merge.
- **Tailnet**: one new device type (`ci-runner`, tagged `tag:ci`); no changes to existing tags' semantics. GitHub Actions runners' (`tag:ci`) grants are unchanged except the additive `tag:apps:443`.
- **Secrets**: one new SealedSecret (`ci-runner-tailscale-key`); existing runner registration flow unchanged.
- **Risk**: low. Runner egress to forgejo moves from an incidental path to an explicit one; if the tailnet join fails, jobs fail fast at connect time rather than silently depending on router state. Gatus monitoring is unchanged (it probes via its own path).
