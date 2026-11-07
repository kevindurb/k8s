# Proposal

## Why

`apps/tsgit` runs the tsnet git forge, but the pod is pinned to a build from
before Funnel was implemented: the live image reports `sha-e381cc147ef7` and
rejects `serve --funnel` with `flag provided but not defined`. The newest
published build (`main`, build `sha-590b7d924fd0`) implements read-only Funnel
access, and the tailnet policy in `kevindurb/infra` already grants `tag:tsgit`
the `funnel` node attribute with a `cap/funnel` payload scoped to `public/*`.
So the forge can publish a curated, read-only subset of repositories to the
internet today, but nothing in this repo asks it to.

Deploying that build and turning Funnel on gives the homelab a public clone
surface for deliberately chosen repositories without accounts, a second forge,
or any new in-cluster listener.

## What Changes

- Bump `apps/tsgit/deployment.yml` from `ghcr.io/kevindurb/tsgit:main@sha256:dc24b4d8…`
  (local checkout) / `sha-e381cc14…` (live) to the newest published build,
  `ghcr.io/kevindurb/tsgit:main@sha256:e34206b9c9d94bd61b04ff10886576cf7053fe95c32b321f7ebcf46232bf1641`
  (index digest, `org.opencontainers.image.version=sha-590b7d924fd0`), which is
  the only build that contains the Funnel implementation.
- Add `TSGIT_FUNNEL: "true"` to the container environment so the pod opens the
  public read-only listener in addition to the tailnet listeners.
- Leave every other app setting unchanged: no `Service`, no `Ingress`, no
  `NetworkPolicy`, no new PVC, no secret change, and no Gatus endpoint.
- Record the Funnel behavior in the `tsgit` capability spec: the existing
  "Tailnet-only reachability" requirement becomes "Tailnet access plus an
  opt-in public read-only Funnel surface", and a new requirement covers what
  the public listener may serve and what it must refuse.

**Assumption (material, stated explicitly):** `latest` currently resolves to
`v0.0.1` (published 17:15Z) and predates the Funnel implementation, so
"latest tsgit" is read as the newest published `main` build. `main@sha256:e34206b9…`
is that build. When the project publishes a `v0.0.2` release, a follow-up can
switch to `latest`/`v0.0.2` at its digest without any other change.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `tsgit`: the deployment is no longer strictly tailnet-only. Tailnet access is
  unchanged, but the pod may now expose a policy-selected, read-only public
  subset of repositories over Tailscale Funnel, and the image must be a build
  that supports Funnel.

## Impact

- Modified file: `apps/tsgit/deployment.yml` (image digest and one environment
  variable).
- Argo CD: the `tsgit` Application reconciles a `Recreate` rollout; the pod is
  its own tailnet node, so the public surface comes up when the replacement pod
  starts. `prune: false` and the PVCs are untouched, so repositories and node
  state survive.
- Public surface: Funnel publishes only repositories matching the node's
  `github.com/kevindurb/tsgit/cap/funnel` payload (`public/*` as currently
  configured) at `https://tsgit.beaver-cloud.ts.net/`. Clone/fetch and the
  filtered index are public; receive-pack, push-to-create and every mutation
  return the same `404` as an unreadable repository.
- External dependencies (already in place, verified during planning, called out
  in tasks): `kevindurb/infra` main has `tag:tsgit` in `tagOwners`, the `funnel`
  node attribute and `cap/funnel: public/*`; the tailnet has MagicDNS and HTTPS
  certificates enabled, and the node already serves
  `tsgit.beaver-cloud.ts.net` over HTTPS.
- Data: no repository is public until one is pushed under the `public/`
  namespace; the repository volume currently holds no repositories.
- Validation: `kustomize build apps/tsgit` and `just check-kustomize`; manual
  verification of a public clone from outside the tailnet.
