# Design

## Context

See `proposal.md` - Why. The relevant constraints from the repo and from wger:

- wger's production entrypoint is a multi-step bootstrap: load fixtures and the
  default `admin` user on an empty database, `collectstatic`, migrate, set the
  Django site URL, then gunicorn. Startup is therefore slow on first boot and
  must not be interrupted.
- wger does not serve static files itself (`DEBUG=False`, no WhiteNoise), so a
  real web server must sit in front of gunicorn.
- Exercise video sync downloads a whole file into memory before writing it
  (largest current file is 423 MiB), and writes media into `MEDIA_ROOT`.
- `USE_CELERY=True` makes wger queue email through Celery automatically, so mail
  and background jobs share one worker.
- The repo's `app-pod-hardening` and `app-tmp-dirs` components only patch
  `containers/0` of Deployments labelled `app.kubernetes.io/component=app`;
  services also select on that label, so only the web pod may carry it.
- `apps/miniflux` is the reference for an in-namespace PostgreSQL on a ZFS
  NVMe-oF volume; `apps/immich` is the reference for extra Deployments carrying
  their own security contexts.

## Goals / Non-Goals

**Goals:**

- Reproduce wger's supported production topology in one Kustomize app, with
  every workload reconciled by Argo CD.
- Keep the app reachable only on the tailnet, with Pocket ID as the normal login
  and a local admin fallback.
- Keep the media volume sized so the full exercise video library fits with
  headroom, and keep the database on its own volume.

**Non-Goals:**

- PowerSync, the mobile app's offline sync, and JWT key generation.
- Splitting the exercise media or database onto shared/NAS storage, or running
  more than one replica of any workload.
- Changing Pocket ID, `smtp-relay`, tailnet policy, or platform components.
- Automating Pocket ID client creation; the client is created in Pocket ID by
  hand, as with other apps.

## Decisions

### 1. One web pod carrying gunicorn, nginx and the Celery worker

The web pod runs gunicorn (`app`, port 8000), nginx-unprivileged (`nginx`, port
8080) and the Celery worker (`celery-worker`), sharing an `emptyDir` for
collected static files and the `media` PVC. The Service and Ingress target the
nginx container's `http` port.

- Rationale: static and media must be readable by nginx from the same volume the
  app writes to. Separate nginx and web Deployments would require an RWX volume
  for static assets or a shared PVC across pods, and an extra network hop.
- The worker is a sidecar rather than a separate Deployment because it downloads
  media into the same `ReadWriteOnce` volume the app mounts. `zfs-generic-nvmeof-csi`
  attaches a volume to one node at a time, so two pods on different nodes cannot
  mount it; a sidecar guarantees both mount from the same node. This mirrors
  `apps/linkding`, whose background worker shares the pod with the app.
- The web container's port is named `gunicorn` instead of `http`: port names must
  be unique within a pod, and `http` belongs to the pod's actual HTTP entry
  point (nginx).
- PostgreSQL, Valkey and the Celery beat each get their own single-replica
  Deployment with `strategy: Recreate`.

### 2. Image selection

| Container | Image | Why |
|---|---|---|
| app | `docker.io/wger/server:2.7` | Only image that ships gunicorn + celery entrypoints; `latest` currently tracks the 2.8 dev line |
| nginx | `docker.io/nginxinc/nginx-unprivileged` | Non-root by default and listens on 8080, so it fits the read-only/non-root pod policy without privileged ports |
| postgres | `docker.io/library/postgres:18-alpine` | Same series as miniflux |
| redis | `docker.io/valkey/valkey:9` | Same as immich; Redis-compatible with a maintained image |

All four are pinned by tag + digest, and Renovate maintains the digests like the
rest of the repo. The wger release line is chosen deliberately: the `latest` tag
is a pre-release of the next minor.

### 3. Volume layout

- `static`: `emptyDir`, mounted at `/home/wger/static` in the app and at
  `/wger/static` read-only in nginx. It is rebuilt by `collectstatic` on every
  boot; persisting it would only risk stale assets after upgrades.
- `media`: 10 GiB PVC at `/home/wger/media` (app, worker) and `/wger/media`
  read-only (nginx). Current full library is ~3.3 GiB of video plus ~29 MB of
  images, so 10 GiB leaves roughly 3x headroom. democratic-csi supports later
  expansion if the library grows.
- `postgres-volume`: 5 GiB PVC at `/var/lib/postgresql` (the postgres 18 image
  uses that as its data root; this mirrors miniflux).
- `beat`: `emptyDir` at `/home/wger/beat`. Losing the schedule file only
  re-randomizes weekly run times, and the sync tasks are idempotent.

### 4. Celery and Redis

Valkey runs without persistence (no PVC, `--save '' --appendonly no`) and serves
as broker/result backend at `redis://wger-redis-service.wger:6379/2`, and as the
Django cache at db 1. Putting the cache in Redis rather than locmem lets
django-axes share login lockout state across gunicorn workers.

The worker runs as a sidecar of the web pod with `CELERY_WORKER_CONCURRENCY=2`;
the beat runs as one separate replica. Multiple beats would double-fire every
scheduled task, which is why the schedule lives in exactly one process.

`SYNC_EXERCISES_CELERY`, `SYNC_EXERCISE_IMAGES_CELERY`,
`SYNC_EXERCISE_VIDEOS_CELERY` and `SYNC_INGREDIENTS_CELERY` are enabled, so the
library stays current weekly without operator action.

Alternative considered: a CronJob running the management commands with
`USE_CELERY=False`. Rejected because it loses asynchronous email and duplicates
wger's own scheduling, for the same number of workloads.

### 5. Hardening and writable paths

- The web pod uses `components/app-pod-hardening` and `components/app-tmp-dirs`.
  Its main container therefore runs as 1000:1000 with a read-only root filesystem;
  the only writable locations are `/home/wger/static`, `/home/wger/media` and the
  tmp emptyDirs.
- The nginx sidecar gets an explicit container-level `securityContext` (non-root,
  no escalation, capabilities dropped, read-only root filesystem) plus
  emptyDirs for `/var/cache/nginx`, `/var/run` and `/tmp`. It reads media
  read-only.
- The nginx and Celery worker sidecars get an explicit container-level
  `securityContext` (non-root, no escalation, capabilities dropped, read-only
  root filesystem). The worker mounts the `media` PVC and the same tmp
  emptyDirs the `app-tmp-dirs` component adds to the pod (video sync buffers
  through `/tmp` and writes to media).
- The Celery beat carries `app.kubernetes.io/component=celery-beat` so it does
  **not** match the Service selector, which means the shared components won't
  patch it. It gets the same explicit `securityContext` inline plus an emptyDir
  at `/home/wger/beat` and `workingDir: /home/wger/beat`, because `start-beat`
  runs `rm -f ./celerybeat.pid` and a read-only working directory would abort it
  under `set -o errexit`.

Alternative considered: opting out of hardening for the worker (the romm
pattern). Rejected because the worker only needs media and tmp, which are easy
to mount explicitly.

### 6. Startup ordering and probes

A `wait-for-db` initContainer (busybox `nc`) waits for PostgreSQL before the app
container starts, because the entrypoint exits when the database is unreachable.
The web container gets a `startupProbe` on `/api/v2/version/` with a generous
failure threshold (~5 minutes) to cover first-boot fixture loading and
migrations, then ordinary readiness and liveness probes. The worker and beat
depend on the database being ready implicitly through their own restart policy.

### 7. OIDC configuration and local break-glass

`WGER_SOCIAL_PROVIDERS=openid_connect` installs django-allauth's generic OIDC
provider. The provider row is seeded once with `provider_id=pocket-id`, the
client credentials from the sealed secret, `settings={'server_url':
'https://idp.beaver-cloud.ts.net'}` and the Site row created by
`manage.py set-site-url`.

- Callback registered in Pocket ID:
  `https://wger.beaver-cloud.ts.net/account/oidc/pocket-id/login/callback/`
- `SITE_URL=https://wger.beaver-cloud.ts.net`,
  `CSRF_TRUSTED_ORIGINS=https://wger.beaver-cloud.ts.net`,
  `X_FORWARDED_PROTO_HEADER_SET=True` so Django trusts the proxy's scheme.
- `ALLOW_REGISTRATION=True` and `ALLOW_GUEST_USERS=False`. Registration has to
  stay open: wger's account adapter answers allauth's social-signup check with
  this same setting, so closing it also rejects the first Pocket ID login. The
  service is tailnet-only, and allauth gives OIDC-created users an unusable
  local password.
- `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` are exposed as environment variables on
  the app container so the one-time seeding command can read them without
  printing secrets into shell history.
- The local `admin` account stays enabled and its bootstrap password is changed
  immediately after first login. A Pocket ID user is promoted to staff/superuser
  with a one-line shell command if administrative access is needed.

Alternatives considered: auth-proxy headers (requires an auth proxy in front,
which this cluster does not run) and local-only accounts (rejected in the
proposal). A seeding Job was rejected for now because it would race the
migrations that only run in the app container on first boot; a one-time exec
after bootstrap is simpler and matches how other apps are brought up.

### 8. Mail through smtp-relay

`ENABLE_EMAIL=True`, `EMAIL_HOST=smtp-relay-app-service.smtp-relay`,
`EMAIL_PORT=25`, `EMAIL_USE_TLS=False`, empty `EMAIL_HOST_USER` /
`EMAIL_HOST_PASSWORD`, and a `FROM_EMAIL` for the instance. Because
`USE_CELERY=True`, wger switches `EMAIL_BACKEND` to its Celery email backend
automatically, so the request path never blocks on SMTP.

### 9. Secrets layout

One `SealedSecret` named so that after `namePrefix: wger-` it becomes
`wger-secrets`, holding `SECRET_KEY`, `POSTGRES_PASSWORD`, `OIDC_CLIENT_ID` and
`OIDC_CLIENT_SECRET`. The app, postgres and the seeding command reference that
single Secret. A stable `SECRET_KEY` is required for sessions to survive pod
restarts; it is not regenerated per boot.

### 10. Static/media serving and observability

- The nginx ConfigMap is the upstream `config/nginx.conf` trimmed to the app:
  upstream `127.0.0.1:8000`, `listen 8080`, `/` proxy with the standard
  forwarded headers, `/static/` from `/wger/static`, `/media/` from
  `/wger/media`, `client_max_body_size 100M`. The `/ps/` PowerSync block and the
  JSON log format are dropped.
- Gatus checks `http://wger-app-service.wger/api/v2/version/` with status 200.
  That endpoint is unauthenticated and fails when gunicorn or nginx is not
  serving, and it does not require the database, so it avoids flapping on
  PostgreSQL restarts.
- `pod-security.kubernetes.io/enforce: baseline` on the namespace, matching every
  other app.

## Risks / Trade-offs

- **Worker OOM during the first video sync** → the client buffers whole files in
  memory and the largest is 423 MiB; give the worker a 2 GiB limit and run the
  first sync manually rather than at startup, so a failure is visible and
  retryable.
- **First boot is slow and may look dead** → generous `startupProbe`, an init
  container that waits for the database, and a single replica so two pods never
  fight over migrations.
- **Default `admin`/`adminadmin` exists after bootstrap** → change the password
  as the first post-boot step; until then the service is tailnet-only.
- **The OIDC provider row is a manual step** → without it only local login works.
  The exact command and callback URL live in `tasks.md`; the app stays usable
  while it is missing.
- **Beat schedule is re-randomized on restart** → harmless because syncs are
  idempotent and skip existing media; an extra sync is cheap after the first
  pass.
- **Storage lives on drone-04** → if that node is down, the app is down like
  every other ZFS-backed stateful app. No new mitigation; follow the
  `reboot-drone-04.yml` playbook rather than rebooting freely.
- **External dependency on wger.de** → sync failures leave the local library
  usable; they only delay new exercises/media.
- **nginx and media permissions** → nginx must read files written by uid 1000.
  `fsGroup: 1000` on the pod plus world-readable collectstatic output covers it;
  verify `/media/` and `/static/` return 200 after first boot.

## Migration Plan

1. Write `apps/wger` and register it in `apps/kustomization.yml`; validate with
   `kustomize build apps/wger` and `just check-kustomize`.
2. Seal the secret against the `wger` namespace after Argo has created it, then
   commit the `SealedSecret`; Argo syncs the rest.
3. Wait for the bootstrap to finish, then verify the UI loads CSS/JS and
   `/media/` resolves.
4. Change the `admin` password, run the one-time library sync (exercises, images,
   videos; ingredients can be left to the weekly job), and seed the Pocket ID
   provider row.
5. Confirm the Pocket ID login and the Gatus check.

Rollback: remove `./wger/app.yml` from `apps/kustomization.yml` and delete the
Argo CD Application by hand (pruning is disabled), then delete the namespace if
the data is no longer wanted. The PVCs survive an Application removal, so a
rollback to an earlier commit keeps the data.

## Open Questions

None that change the approach; ingredient-dump sync volume and worker tuning are
observable after the first weekly run and can be adjusted without new artifacts.
