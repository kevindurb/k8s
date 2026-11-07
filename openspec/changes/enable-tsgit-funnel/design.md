# Design

## Context

See `proposal.md` for motivation and `specs/tsgit/spec.md` for the behavior
contract.

State observed while planning (2026-11-07):

- `origin/main` of this repo pins `ghcr.io/kevindurb/tsgit:main@sha256:973d24ec…`,
  and the live pod reports `tsgit version` = `sha-e381cc147ef7`. That build is
  from the Funnel **proposal** commit, before the implementation: running
  `tsgit serve --funnel` in the pod returns `flag provided but not defined`.
  The local checkout is older still (`sha-bbce23e68432`, `main@sha256:dc24b4d8…`).
- The newest published `main` build is index digest
  `sha256:e34206b9c9d94bd61b04ff10886576cf7053fe95c32b321f7ebcf46232bf1641`,
  version label `sha-590b7d924fd0` (2026-11-07T21:42Z). Its commit chain includes
  "implement read-only Funnel access" and the Funnel documentation. It is the
  only published build that implements Funnel.
- `latest` and `v0.0.1` are the same image, published 17:15Z, before Funnel.
- `kevindurb/infra` `main` already has `tag:tsgit` in `tagOwners`, a `nodeAttrs`
  entry giving `tag:tsgit` the `funnel` attribute with
  `github.com/kevindurb/tsgit/cap/funnel: [{"repos": ["public/*"]}]`, and
  `cap/repo` grants for `group:admins`/`tag:dev` (write) and `tag:ci` (read).
- The node already serves HTTPS for `tsgit.beaver-cloud.ts.net` (pod log:
  `serving git smart HTTP over HTTPS hostname=tsgit.beaver-cloud.ts.net port=443`),
  so MagicDNS and certificate domains exist.
- The repository volume contains no repositories (only `lost+found` and the
  staging directory), so the public surface will start empty.

Constraints from the image contract: `TSGIT_FUNNEL` is the documented switch for
Funnel, the listener is created inside tsnet (no host port), Funnel needs port
443 (the default), and the image runs as `10001:10001` with a read-only root
filesystem.

## Goals / Non-Goals

**Goals:**

- Get the Funnel-capable build running through Argo CD with no new cluster
  mechanisms, PVCs, secrets or routing objects.
- Make the public surface an explicit deployment switch, so it can be turned off
  by removing one environment variable.
- Keep the public allowlist in the tailnet policy, where it already lives.

**Non-Goals:**

- Creating or publishing any repository as part of this change. The public
  surface stays empty until an operator pushes a repository under `public/`.
- Changing the tailnet policy, tags, auth key, GHCR visibility or Tailscale
  settings (all already in place).
- Adding in-cluster monitoring or a Gatus endpoint for the public URL.
- Reworking the pod security context, volumes, image user, or single-instance
  strategy. Those are unchanged and still correct.

## Decisions

### Pin the newest `main` build by index digest

Change the container image to
`ghcr.io/kevindurb/tsgit:main@sha256:e34206b9c9d94bd61b04ff10886576cf7053fe95c32b321f7ebcf46232bf1641`.

`latest`/`v0.0.1` cannot satisfy the request because they predate Funnel; using
them would deploy a build that rejects `--funnel`. `main` is what the app already
tracks, and the digest pin keeps the deploy reproducible and lets Renovate bump
it as it has before. When the project publishes a `v0.0.2` release, the tag can
move to `v0.0.2`/`latest` at the equivalent digest without changing anything
else.

Alternative considered: pull a per-architecture manifest digest. The repo pins
index digests elsewhere (and Renovate produced one for this image), so the
multi-arch index digest is the consistent choice and still resolves per node
architecture.

### Enable Funnel with `TSGIT_FUNNEL=true`, not a command override

The image's default command is `tsgit serve`. Funnel can be enabled by appending
`--funnel` to that command or by setting the documented environment variable.
The environment variable is used because:

- it is the image's documented, stable configuration surface (flags and env are
  both supported; env avoids overriding the entrypoint/command);
- the deployment already configures the app entirely through `env`, so no new
  pattern is introduced;
- removing the variable is an obvious, reviewable kill switch.

No other Funnel settings are overridden. The defaults from the image apply:
public listener on 443, `TSGIT_FUNNEL_MAX_CONCURRENT=4`, bounded header/body/
timeouts.

### No `Service`, `Ingress`, or NetworkPolicy

The public listener is created by tsnet inside the pod, exactly like the tailnet
listener. The pod therefore still needs no cluster-reachable socket. The repo's
standard Tailscale-operator `Ingress` path would create a second tailnet node in
front of the app and would not produce a Funnel listener for tsgit's own policy
payload, so it is both unnecessary and wrong here.

Egress is unchanged: the pod already reaches the control plane, DERP relays and
peer endpoints; Funnel adds relay traffic over the same outbound path.

### Public allowlist remains in `kevindurb/infra`

The deployment does not encode which repositories are public. The node reads its
own `cap/funnel` payload on each public request, so `public/*` is the operative
selection today, and editing the policy changes the public surface without a
restart. Keeping the list out of this repo preserves the single authorization
source and avoids two places to get wrong.

The consequence is deliberate: no repository is public until one is pushed under
the `public/` namespace, and a push to any other namespace stays private even
when Funnel is on.

### No Gatus endpoint

Gatus in this repo only checks in-cluster service URLs; there are no external
URL checks, and the one tsnet app with a public hostname (`golink`) ships a
disabled endpoint noting the same limitation. The public Funnel URL is reachable
from the internet, but adding an egress-dependent public check is a monitoring
change with its own failure modes, not part of enabling Funnel. The pod keeps no
readiness probe for the same reason as before: there is no cluster-reachable
socket to probe.

### Keep the single-instance `Recreate` deployment and both PVCs

Funnel does not change the identity or storage model. The pod remains the sole
owner of the tsnet node key and both `ReadWriteOnce` volumes, and the
`Recreate` strategy keeps a rollout from running two nodes with the same
identity. Argo CD's sync replaces the pod once; the state volume keeps the
registration and the repository volume keeps the data.

## Risks / Trade-offs

- **`main` is a moving tag, even though the digest is pinned.** → The digest pin
  prevents surprises; Renovate proposes bumps, and the release-tag switch is a
  small follow-up once `v0.0.2` exists.
- **The newest build is a pre-release `main` build.** → It is the only build with
  Funnel; the project's CI gates publication on `just ci`, and the deployment is
  easily rolled back by reverting the digest.
- **A policy typo can publish private code.** `cap/funnel` currently selects
  `public/*`; a change to `*/*` would expose every repository read-only. → The
  payload is in the infra repo under review, the deployment flag is a second
  independent key, and the public index is filtered. Removing the payload closes
  the public surface on the next request.
- **Funnel is beta and plan-gated.** If the tailnet lacks the `funnel` attribute,
  HTTPS certificates, or a certificate domain, the app logs an error and keeps
  serving the tailnet only, so the failure is quiet from the tailnet's point of
  view. → Verify the pod log for the public-listener line after rollout and
  verify a public clone from outside the tailnet.
- **The public surface is empty at first.** No repository matches `public/*`,
  so a public client sees an empty index. → That is the intended default; the
  verification step pushes a throwaway `public/` repository or documents the
  empty index as the expected initial state.
- **Public bandwidth and disk I/O are now reachable anonymously.** A large public
  clone consumes node resources and the default cap is four concurrent pack
  exchanges. → Accept for a homelab; raise or lower
  `TSGIT_FUNNEL_MAX_CONCURRENT` only if needed.
- **Node attribute propagation delay.** The `funnel` attribute is delivered by
  the control plane; the first request after rollout may still see it missing. →
  The app reads the payload per request, so a retry after propagation succeeds
  without a restart; the policy is already on infra `main`.
- **Existing local checkout is behind `origin/main`.** Editing the stale file
  would revert the Renovate digest bump. → Task 1 starts by updating the
  checkout to `origin/main`, then changes the digest from `973d24ec…` to
  `e34206b9…`.

## Migration Plan

1. Update the checkout to `origin/main` so the Renovate digest bump is the
   baseline, then edit `apps/tsgit/deployment.yml`: image digest to
   `sha256:e34206b9…`, and add `TSGIT_FUNNEL: "true"`.
2. Validate with `kustomize build apps/tsgit` and `just check-kustomize`.
3. Commit and let Argo CD sync; the `Recreate` rollout replaces the single pod
   and reuses the state and repository PVCs.
4. Confirm the pod log reports the public listener (or, if a prerequisite is
   missing, the named error and a still-working tailnet).
5. From outside the tailnet, open `https://tsgit.beaver-cloud.ts.net/` and
   attempt `git clone https://tsgit.beaver-cloud.ts.net/public/<name>.git`.
   Verify receive-pack and push-to-create return `404`.
6. Rollback: remove `TSGIT_FUNNEL` (or revert the commit). The pod restarts with
   the tailnet listeners only; repositories and node identity are untouched. The
   old image digest can be restored independently if the build itself is at
   fault.
