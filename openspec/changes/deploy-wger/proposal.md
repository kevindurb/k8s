# Proposal

## Why

There is no self-hosted workout/fitness tracker in the cluster, and wger is the
one worth running: it tracks workouts, routines, body measurements and nutrition
and ships a usable web UI. Deploying it here keeps the data on the tailnet under
this repo's GitOps, backup and secret-management model instead of a third-party
service.

## What Changes

- Add a new app at `apps/wger`, registered in `apps/kustomization.yml`, with an
  Argo CD `Application` in the `apps` project that creates the `wger` namespace.
- Run wger's production shape rather than a reduced one:
  - `wger-app` pod with the `wger/server` gunicorn container and an nginx
    sidecar that serves `/static/` and `/media/` and proxies everything else.
  - In-namespace PostgreSQL, following the existing `apps/miniflux` pattern.
  - Valkey (Redis-compatible) as the Celery broker/cache.
  - Celery worker and a single Celery beat for the weekly exercise/ingredient
    sync and asynchronous email.
- Store exercise media (including the full exercise video library, ~3.3 GiB
  today) on a 10 GiB `media` PVC; store PostgreSQL data on its own PVC.
- Expose the app on the tailnet at `wger.beaver-cloud.ts.net` through the
  standard Tailscale `Ingress`, with a Gatus check against
  `/api/v2/version/`.
- Authenticate through Pocket ID using django-allauth's generic
  `openid_connect` provider (`provider_id=pocket-id`), with the local `admin`
  account kept as a break-glass login. The `SocialApp` row is seeded once after
  first boot; no runtime configuration of a new identity provider is added to
  the cluster.
- Send password-reset and account mail through the existing `smtp-relay`.
- Add a `SealedSecret` holding the Django secret key, the PostgreSQL password and
  the Pocket ID client credentials. No plaintext secret is committed.
- Explicitly out of scope: the PowerSync service and the mobile app's offline
  sync, JWT key generation, and any change to Pocket ID, `smtp-relay` or
  Tailscale policy (the `tag:apps` tag and the ingress proxy group already
  exist).

## Capabilities

### New Capabilities

- `wger`: the deployed wger workout manager — tailnet-only reachability, OIDC
  login through Pocket ID, durable exercise media and database storage,
  background sync/email workers, secret handling, and GitOps-managed lifecycle.

### Modified Capabilities

None.

## Impact

- New: `apps/wger/` (Application, Kustomization, web deployment, nginx config,
  PostgreSQL, Valkey, Celery worker/beat, secrets, Gatus check).
- Modified: `apps/kustomization.yml` (one resource line).
- New storage: `media` PVC (10 GiB) and `postgres-volume` PVC (5 GiB) on
  `zfs-generic-nvmeof-csi`, which lives on drone-04.
- New images: `docker.io/wger/server`, `docker.io/nginxinc/nginx-unprivileged`,
  `docker.io/library/postgres`, `docker.io/valkey/valkey`. Renovate manages
  their digests like every other app image.
- Runtime dependencies: `platform/smtp-relay` and the Pocket ID instance; both
  already exist.
- No infrastructure, platform or cluster entrypoint changes. `tag:apps` and the
  `ingress-proxy-group` already exist in tailnet policy.
