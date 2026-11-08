# Tasks

## 1. Scaffold and register the app

- [x] 1.1 Run `just tmpl apps wger` to copy `apps/template`, then set `namespace: wger` / `namePrefix: wger-` and the `app.kubernetes.io/name: wger` label in `apps/wger/kustomization.yml`. Verify `kustomize build apps/wger` succeeds and every rendered object name starts with `wger-`.
- [x] 1.2 Update `apps/wger/app.yml`: project `apps`, source path `apps/wger`, destination namespace `wger`, the standard `pod-security.kubernetes.io/*` namespace labels, automated sync with `prune: false` and `selfHeal: true`. Verify `kustomize build apps` lists the new Application and `apps/kustomization.yml` contains `./wger/app.yml` exactly once.
- [x] 1.3 Replace the template's whoami deployment with a placeholder wger Deployment (`replicas: 1`, `strategy: Recreate`) and the standard Service/Ingress: Service port `http`, Ingress `ingressClassName: tailscale`, annotations `tailscale.com/proxy-group: ingress-proxy-group` and `tailscale.com/tags: tag:apps`, `tls.hosts: [wger]`. Verify the rendered Ingress host is `wger` and the Service targets a named `http` port.

## 2. Web pod and static/media serving

- [x] 2.1 Configure the `app` container on `docker.io/wger/server:2.7@<digest>`: environment for `TZ`, `SITE_URL=https://wger.beaver-cloud.ts.net`, `CSRF_TRUSTED_ORIGINS`, `X_FORWARDED_PROTO_HEADER_SET=True`, `DJANGO_DEBUG=False`, `ALLOW_REGISTRATION=False`, `ALLOW_GUEST_USERS=False`, database variables, and the database password from `wger-secrets`. Verify `kustomize build apps/wger` renders the env and the `secretKeyRef`.
- [x] 2.2 Add the `media` PVC (10 GiB, `storageClassName: zfs-generic-nvmeof-csi`, `ReadWriteOnce`) and mount it at `/home/wger/media`; mount an `emptyDir` at `/home/wger/static`. Verify the built Deployment has both volumes and that `media` is a PVC, not an emptyDir.
- [x] 2.3 Add the `wait-for-db` initContainer using the busybox image already pinned in `apps/romm` to wait for `wger-postgres-service:5432`. Verify the built pod spec has the initContainer and that it has no volume mounts.
- [x] 2.4 Add readiness/liveness probes and a `startupProbe` on `/api/v2/version/` (numeric port 8000, failure threshold covering ~5 minutes). Verify the built container has all three probes and that no probe targets a port name that another container also uses.
- [x] 2.5 Add `apps/wger/nginx-config.yml` with a ConfigMap containing the trimmed upstream nginx config: upstream `127.0.0.1:8000`, `listen 8080`, `/` proxy with `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host`; `/static/` from `/wger/static`; `/media/` from `/wger/media/`; `client_max_body_size 100M`. Verify it contains no `/ps/` block and that `kustomize build apps/wger` emits the ConfigMap.
- [x] 2.6 Add the `nginx` sidecar on `docker.io/nginxinc/nginx-unprivileged` with the ConfigMap mounted at `/etc/nginx/conf.d/default.conf`, an explicit container-level securityContext (non-root, read-only root filesystem, no escalation, drop ALL), port `http: 8080`, and emptyDirs at `/var/cache/nginx`, `/var/run`, `/tmp`; mount `static` read-only at `/wger/static` and `media` read-only at `/wger/media`. Register the ConfigMap with `configMapGenerator` and verify the built pod contains exactly two containers and that only the nginx container is named `http`.

## 3. Data layer

- [x] 3.1 Add `apps/wger/postgres.yml` modelled on `apps/miniflux/postgres.yml`: single-replica Deployment on `docker.io/library/postgres:18-alpine@<digest>`, `POSTGRES_USER=wger`, `POSTGRES_DB=wger`, password from `wger-secrets`, PVC at `/var/lib/postgresql`, tmp emptyDirs, `pg_isready` probes, and a `postgres-service`. Verify `kustomize build apps/wger` renders it and that after sync `kubectl -n wger exec deploy/wger-postgres-deployment -- pg_isready -U wger` succeeds.
- [x] 3.2 Add `apps/wger/redis.yml`: single-replica valkey Deployment with `args: ['valkey-server', '--save', '', '--appendonly', 'no']`, an `emptyDir` at `/data`, a tmp emptyDir, explicit hardening securityContext, readiness/liveness on `valkey-cli ping`, and a `redis-service` on 6379. Verify the built Deployment has no PVC and that after sync `kubectl -n wger exec deploy/wger-redis-deployment -- valkey-cli ping` returns `PONG`.

## 4. Celery worker and scheduler

- [x] 4.1 Add the `celery-worker` sidecar to the web pod in `deployment.yml` with `command: ['/start-worker']`, the same database and `CELERY_BROKER`/`CELERY_BACKEND` env as the app container, `USE_CELERY=True`, the four `SYNC_*_CELERY=True` flags, `CELERY_WORKER_CONCURRENCY=2`, the `media` PVC at `/home/wger/media`, the shared tmp emptyDirs, and an explicit hardening securityContext. It is a sidecar because the media volume is `ReadWriteOnce` and cannot be mounted by a second pod on another node. Verify `kustomize build apps/wger` shows `app`, `nginx` and `celery-worker` containers in `wger-app-deployment` and that the worker mounts `media` and `/tmp`.
- [x] 4.2 Add `apps/wger/celery-beat.yml`: one replica with `command: ['/start-beat']`, `workingDir: /home/wger/beat`, an emptyDir at `/home/wger/beat`, no media mount, and the same explicit hardening securityContext and component label `celery-beat`. Verify the built Deployment has the working directory and that after sync `kubectl -n wger logs deploy/wger-celery-beat-deployment` shows `beat: Starting` without a read-only filesystem error.
- [x] 4.3 Give the worker sidecar a 2 GiB memory limit (512 MiB request) and beat 128 MiB/256 MiB. Verify the built `wger-app-deployment` worker container and `wger-celery-beat-deployment` report those resources.
- [x] 4.4 After sync, verify the worker is connected and the periodic tasks are registered: `kubectl -n wger exec deploy/wger-app-deployment -c celery-worker -- celery -A wger inspect ping` and `celery -A wger inspect registered` list `sync_exercises_task`, `sync_images_task` and `sync_videos_task`.

## 5. Secrets

- [x] 5.1 Create a plain Secret locally with `SECRET_KEY`, `POSTGRES_PASSWORD`, `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET`, then seal it with `kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller` and write `apps/wger/secrets-sealed-secret.yml`. Set `metadata.name: secrets` so the `wger-` prefix produces `wger-secrets`. Verify with `kubeseal --validate` against the post-prefix name and `grep -r "SECRET_KEY" apps/wger` finds no plaintext.
- [x] 5.2 Reference `wger-secrets` from the web, postgres and worker deployments (`secretKeyRef` for the database password and Django secret key; env-level client id/secret on the web container for the OIDC seed). Verify `kustomize build apps/wger` renders no literal secret values and that after sync `kubectl -n wger get secret wger-secrets` exists.

## 6. Pocket ID login and mail

- [x] 6.1 In Pocket ID, create an OIDC client whose callback is `https://wger.beaver-cloud.ts.net/account/oidc/pocket-id/login/callback/`, and record its client id/secret in `wger-secrets` (re-seal if needed). Verify the client id/secret are present only in the sealed secret.
- [x] 6.2 Set `WGER_SOCIAL_PROVIDERS=openid_connect` and expose `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET` on the web container. Verify `kustomize build apps/wger` contains the env and that `kubectl -n wger exec deploy/wger-app-deployment -c app -- env | grep WGER_SOCIAL_PROVIDERS` reports `openid_connect`.
- [x] 6.3 Seed the provider row once the database is migrated: `kubectl -n wger exec deploy/wger-app-deployment -c app -- python3 manage.py shell -c "..."` performing an idempotent `update_or_create` of `SocialApp(provider='openid_connect', provider_id='pocket-id', name='Pocket ID', client_id=..., secret=..., settings={'server_url': 'https://idp.beaver-cloud.ts.net'})` and attaching `Site.objects.get(id=1)`. Verify the login page offers Pocket ID and a full login redirects back authenticated.
- [x] 6.4 Configure mail: `ENABLE_EMAIL=True`, `EMAIL_HOST=smtp-relay-app-service.smtp-relay`, `EMAIL_PORT=25`, `EMAIL_USE_TLS=False`, empty `EMAIL_HOST_USER`/`EMAIL_HOST_PASSWORD`, `FROM_EMAIL`. Verify with `kubectl -n wger exec deploy/wger-app-deployment -c app -- python3 manage.py sendtestemail <address>` and a password-reset request that an SMTP relay log entry exists and the request returns promptly.
- [x] 6.5 Change the bootstrap `admin` password and verify the old `adminadmin` credential is rejected while the new one authenticates. Record the one-time steps (admin password, library seed, provider seed, callback URL) as comments in `apps/wger/kustomization.yml` and confirm the commands there match the ones actually run.

## 7. First boot and exercise library

- [x] 7.1 Sync the app and wait for the web, postgres, redis, worker and beat pods to become Ready. Verify `kubectl -n wger get pods` shows all five Running/Ready and that the bootstrap logs show migrations, `collectstatic` and `Set site URL to wger.beaver-cloud.ts.net`.
- [ ] 7.2 Verify static and media serving: `curl` through the tailnet URL returns 200 for a hashed CSS/JS asset and for `/static/`, and an image request under `/media/` returns 200 after the library seed.
- [ ] 7.3 Run the one-time library seed in order: `sync-exercises`, `download-exercise-images`, `download-exercise-videos`. Verify the exercise list is populated, an exercise page shows its image or video, and the media PVC usage is under ~4 GiB (`kubectl -n wger exec deploy/wger-postgres-deployment -- df -h` is not applicable; check `kubectl -n wger exec deploy/wger-app-deployment -c app -- du -sh /home/wger/media`).
- [ ] 7.4 Confirm the weekly sync remains scheduled after the seed: the worker reports the sync tasks as registered and beat logs no errors, and a second manual `download-exercise-videos` run reports videos already present rather than re-downloading.

## 8. Integration checks

- [ ] 8.1 Confirm the Gatus check is picked up: `kubectl -n wger get configmap` contains the gatus ConfigMap labelled `gatus.io/enabled: 'true'`, and the status page shows `wger` healthy.
- [ ] 8.2 Confirm Pod Security admission: `kubectl -n wger get pod -o jsonpath` shows `runAsNonRoot: true`, `readOnlyRootFilesystem: true` for the app and nginx containers, and no pod has a privileged container; there are no `restricted` warnings in the namespace events.
- [ ] 8.3 Confirm self-healing: scale a deployment away from git, wait for Argo to reconcile, and verify it is restored to the git-defined replica count.
- [x] 8.4 Run `just check-kustomize` and the pre-commit hooks over the changed files; verify both pass with no yamllint findings and no trailing whitespace.
- [ ] 8.5 Smoke-test the full path end to end: log in through Pocket ID, open a workout, load an exercise with video, and confirm the Gatus check stays green.
