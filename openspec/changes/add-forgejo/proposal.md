# Proposal

## Why

The owner wants out of tsgit's minimalism: a real forge with a web UI, pull
requests, issues, and standard clone/push UX — reachable from the tailnet and
nowhere else, with sign-on through the existing pocket-id instance. Tekton and a
CI runner are deliberately out of scope here: this change lands the forge
itself, so it is independently reviewable, deployable, and useful on day one.
`add-forgejo-runner` adds CI on top once this is solid.

## What Changes

- **Forgejo** deployed via its Helm chart (SQLite, zfs-local PVC), reachable
  only through the tailnet: web UI and HTTPS git via the shared Tailscale
  ingress (`forgejo.beaver-cloud.ts.net`), SSH git via a tailnet LoadBalancer
  Service. No LAN listeners, no MetalLB.
- **Authentication**: pocket-id OIDC for the web UI; SSH keys / personal access
  tokens for git and API access. No anonymous access; no open registration.
- **Repositories migrate off tsgit** (full history preserved): `dotfiles` plus
  the image-building repos (enumerated during implementation).
- **Push mirror** to `github.com/kevindurb/dotfiles` to keep GitHub as the
  public read path; other migrated repos get mirrors as decided during
  migration. GHCR remains the container registry.
- `docs/forgejo.md` added; Gatus check wired in.

## Capabilities

### New Capabilities
- `forgejo`: the self-hosted forge — tailnet-only exposure, OIDC SSO, git over
  HTTPS and SSH, private-by-default repositories with GitHub push-mirroring,
  and durable state on cluster storage.

### Modified Capabilities
- None.

## Impact

- New `platform/forgejo/` Argo app (chart + values + sealed secrets); new
  `forgejo` namespace; one Tailscale ingress, one Tailscale LoadBalancer
  Service; new SealedSecrets (OIDC client secret, break-glass admin, mirror
  PAT is stored in forgejo's DB, not in git).
- GitHub keeps `github.com/kevindurb/dotfiles` as a read mirror fed by forgejo.
- Tekton/tsgit are untouched here — they keep building what they build until
  `add-forgejo-runner` lands and `remove-tsgit-tekton` follows.
- The reserved MetalLB address `192.168.42.222` stays allocated but unused; it
  is dropped in `remove-tsgit-tekton`.
