# Design

## Context

See proposal.md for motivation. Current verified state (2026-11-27):

- The runner VM (`infrastructure/ci-runner`) has no tailnet identity. Its
  traffic reaches `forgejo.beaver-cloud.ts.net` (VIP `100.86.247.27`,
  `tag:apps`, served by the `ingress-proxy-group`) only because pod-network
  egress is SNAT'd to the node IP and hairpins through the LAN router
  (`192.168.1.1`, `tag:router`, granted `tag:apps:443`). Node-originated
  connections to the VIP time out; pod-originated ones work. The mechanism
  is incidental, undocumented, and grants nothing tailnet-specific to the VM.
- `tag:ci` exists in `tailnet/policy.hujson` (owner `group:admins`) with
  `svc:argocd:443`, `tag:ai:443` (Aperture, `ci-agents` bucket), and
  `tag:tsgit:443` (read, `cap/repo`), mirrored in the policy's `tests` block.
  GitHub Actions runners use it; nothing in-cluster does.
- `tag:router` grants include `tag:apps:443` (that is what the VM rides today).
- `kevindurb/infra` applies the policy with terraform: PR → plan, merge → apply.

## Goals / Non-Goals

**Goals:**
- The VM is a first-class tailnet device (`tag:ci`): MagicDNS, Tailscale SSH,
  grants scoped to what this workload needs.
- CI loses its dependency on the router hairpin; gains the same grants the
  GitHub Actions runners have.
- Inbound SSH for `group:admins` only.
- Nothing outside the three named repos changes; no new cluster-side proxies.

**Non-Goals:**
- Podman-in-VM → tailnet egress (no SNAT rule for `10.88.0.0/16` in this
  change; host-level jobs and host networking work out of the box). Revisit
  when a job needs it.
- Per-job egress isolation, tailnet egress from sibling pods/namespaces, or
  changing how Gatus probes forgejo (it uses its own path; unaffected).
- Non-forgejo ingresses beyond the shared `tag:apps` class.
- Removing the router hairpin grant (kept as incidental fallback; zero risk).

## Decisions

**1. `tailscaled` inside the VM (guest join), not an egress ProxyGroup.**
The VM is the workload; an in-cluster proxy would only cover host-impersonating
traffic it can't see anyway (it would work only for traffic that resolves to
the proxy's VIP, not for anything else the VM does), would add a second
network path to operate, and would not give the VM inbound SSH. The nodes do
exactly this (manual `tailscale up`); ephemeral-CI is a fine fit because the
root disk is already ephemeral.
*Alternative considered:* ProxyGroup + CoreDNS rewrite (the `idp`/`ai`/`tsgit`
pattern) — rejected: it tunnels only named FQDNs to chosen tags, cannot
originate VM-native connections to Aperture, and gives no inbound path.

**2. Reuse `tag:ci` rather than mint `tag:forgejo-runner`.**
User decision. GitHub Actions parity is the desired end state, the tag is
owned by `group:admins` with a small, reviewed grant set, and a second tag
would duplicate every grant without a distinct operational need. The shared
`ci-agents` Aperture bucket is explicitly accepted for now.

**3. Ephemeral, reusable, pre-authorized `tag:ci` auth key; reusable across
VM recreations.**
Ephemeral ⇒ device entries auto-clean when the VM is destroyed; reusable ⇒
no re-mint per image bump; pre-authorized ⇒ no manual admin step per boot.
The key lives only in a SealedSecret (`ci-runner-tailscale-key`, key
`authkey`), mounted by KubeVirt's `cloudInitNoCloud` alongside the existing
`ci-runner-cloudinit` secret (a second `secretRef` under `secrets:` is added;
cloud-init merges multiple cloud-init datasources only if combined — so the
key is instead copied *into* the existing cloud-init payload at authoring
time? No — see decision 4 for the actual shape).

**4. Key delivery: second `cloudInitNoCloud` secret, consumed by cloud-init's
`write_files` + `runcmd`.**
The VM spec gets a second `cloudInitNoCloud` volume? KubeVirt allows only one
`cloudInitNoCloud` volume — cloud-init supports multiple datasources only via
NoCloud with a single disk. So the `ci-runner-cloudinit` secret gains one
more key (or the existing userData grows a second write_files entry carrying
the auth key file referenced from the *same* secret). Simplest: put the key
in the **same** `ci-runner-cloudinit` SealedSecret as a new key `tailscale-authkey`, and
extend `userData` to write it to `/run/tailscale-authkey` (tmpfs) before
`tailscale up` consumes it, then `shred` it. The registration token already
follows the same pattern (written to tmpfs, consumed once, removed). One
secret, one lifecycle.

**5. `accept-dns=true` (MagicDNS).**
The VM then resolves tailnet names itself; `forgejo.beaver-cloud.ts.net`
resolves to the ingress VIP regardless of LAN DNS. Node-style
`--accept-dns=false` is deliberately not copied — nodes exclude DNS to keep
CoreDNS authoritative; a CI VM has no such constraint.

**6. Tailscale SSH for inbound, `--ssh` on join.**
Mirrors the node pattern (`group:admins → tag:ci`, users `root` +
`autogroup:nonroot`), enforced by the tailnet policy, not by VM-local sshd
config; nothing listens on LAN ports. The VM keeps no long-lived password
auth of any kind.

**7. Policy change is additive; tests move, not loosen.**
`tag:ci` gains `tag:apps:443`. In `tests`, `tag:ci` flips `tag:apps:443`
from `deny` to `accept` (everything else stays denied). New `sshTests` entry:
`group:admins → tag:ci` accepts `kevindurb`/`root` (matching house style). A
new `ssh` grant rule mirrors the node rule. No existing grant is widened or
removed; `tag:router`'s `tag:apps` grant is left untouched as a fallback.

**8. Rollout order: infra → bootc → k8s, VM last.**
Policy lands first (inert until the VM joins), then the image, then the
secret + VM (recreate with the new pin). No window where the VM is broken:
it keeps using the router path until it reboots into the new image, and its
forgejo access via the router path keeps working regardless.

**Boot sequence in the VM (new image):**
`tailscaled.service` (enabled at image build) starts → `tailscale-up.service`
(oneshot, `After=tailscaled.service`) runs
`tailscale up --auth-key=file:/run/tailscale-authkey --advertise-tags=tag:ci
--ssh --accept-dns=true --reset` then `shred -u /run/tailscale-authkey`;
`forgejo-runner.service` is unchanged (registration flow untouched).
`--advertise-tags` must match the key's tag(s); with a tagged pre-auth key
the node comes up tagged `tag:ci`. (Node join experience showed
`--advertise-tags` is required to match and accepted on first up.)

**Image build path is unchanged**: `containers/ci-runner` gains `tailscale`
in the `dnf install` line, a `tailscale-up.service` + script in `overlay/`,
and `systemctl enable` for both units. The qcow2 rebuild is the existing
manual `image-builder` flow → `ci-runner-disk/<date>` release →
`build-runner-disk.yml` → new tag pinned in `vm.yaml`.

## Risks / Trade-offs

- **[Key reuse across recreations]** → reusable ephemeral key in a SealedSecret; compromise lets an attacker join as `tag:ci` until revoked. Mitigation: single-purpose secret, sealed, shared with no other system; revoke + re-seal on suspicion. Same exposure class as the existing runner registration token.
- **[Ephemeral churn]** every VM recreate = a new tailnet device entry. Accepted: matches "VM is cattle" and is actually desirable vs. stale permanent devices.
- **[Whole `tag:apps` class opened to `tag:ci`]** GitHub Actions runners gain the same access (intended parity); grants are ports 443 only, read-oriented web apps. If a future app needs tighter control, carve a narrower service name then.
- **[MagicDNS intercepts all resolution in the VM]** → all names (incl. public) resolve via Tailscale; standard behavior, matches nodes' trade-off in reverse. Acceptable for an ephemeral CI VM.
- **[Image rebuild is manual]** qcow2 requires the local Fedora/image-builder host; release cadence is manual. Same as today — no new burden, but the tailscale package only reaches the VM after a rebuild, so plan one rebuild.
- **[Router path remains]** not removed; if the tailnet path breaks, the VM still reaches forgejo the old way (silent fallback). Documented, intentional (no blast radius for a change in progress), revisit after bake-in.
- **[Aperture shared bucket]** forgejo CI and GitHub Actions share `ci-agents`; a noisy forgejo job can throttle GitHub Actions jobs. Accepted for now; split later by adding a dedicated bucket if it bites.

## Migration Plan

1. **infra**: PR to `kevindurb/infra` — policy grant, ssh rule, tests/sshTests update. CI plan on PR; merge applies. Verify: plan shows only the expected grant/ssh/test diffs.
2. **Secrets**: mint the reusable ephemeral `tag:ci` auth key (admin console); append it to the `ci-runner-cloudinit` SealedSecret as a new key (`kubeseal` re-seal, per `docs/secrets.md`); open a PR in this repo with the sealed secret only (no plaintext anywhere).
3. **bootc**: PR to `kevindurb/bootc` — `containers/ci-runner` gains tailscale; build runner-disk via the manual `image-builder` flow; publish `ci-runner-disk/<date>` release; note digest.
4. **k8s**: PR bumping `vm.yaml` `containerDisk` to the new tag + cloud-init `userData` changes (write key file, new `tailscale-up` oneshot stanza, shred) + `docs/forgejo.md`. Argo syncs; `kubectl -n ci-runner delete vmi ci-runner` to force recreate.
5. **Verify**: `tailscale status` on the VM shows `tag:ci` (via SSH); `curl` forgejo; `ssh root@ci-runner` from an admin machine; `forgejo-runner` shows Online; trigger a dotfiles CI run; `tofu`/admin console shows no stray devices.
6. **Rollback**: revert the `vm.yaml` tag bump (old image has no tailscaled; cloud-init ignores the extra secret key). Policy grants left in place are inert.

## Open Questions

- None blocking. (VM→podman-container tailnet egress and Aperture bucket split are deliberately deferred; see Non-Goals.)
