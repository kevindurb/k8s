# Rakazo (self-hosted AI bots)

Status: **added (2026-11-17)**. [Rakazo](https://rakazo.com/) is an Apache-2.0 platform for
persistent AI bots: each bot keeps routines, can drive a browser and a shell on its own disposable
"computer", and asks for approval before crossing a boundary the operator sets. This deployment keeps
its Postgres, bot files and audit log on the cluster and sends model traffic to the in-cluster
Aperture gateway instead of a hosted provider.

Managed by two Argo CD applications, because the app and its computer sandboxes are two namespaces:

| Application | Path | Namespace | Contents |
| --- | --- | --- | --- |
| `rakazo` | `apps/rakazo` | `rakazo` | Postgres, `api`, `worker`, `web`, the tailnet Ingress, the app's NetworkPolicy, the computer admission policy, migrate/bootstrap Jobs |
| `rakazo-sandboxes` | `apps/rakazo-sandboxes` | `rakazo-sandboxes` | the computers' Role/RoleBinding, ResourceQuota, LimitRange, NetworkPolicy, and the `tailscale` peer Service |

The admission policy lives in `apps/rakazo` on purpose: its pinned image is rendered from
`config.env` by a kustomize `replacements` rule, and replacements cannot cross roots. It is
cluster-scoped, so the `rakazo` namespace transformer does not touch it.

## Origin and exposure

One HTTPS origin, tailnet only: `https://rakazo.beaver-cloud.ts.net`, served by the shared
`ingress-proxy-group` ProxyGroup (`tailscale.com/proxy-group` on the Ingress). There is no Funnel
annotation, no LoadBalancer and no NodePort. `RAKAZO_HOST`, `BETTER_AUTH_URL`, `WEB_ORIGIN` and
`API_URL` are all that origin; changing one without the others breaks cookies, CORS and SSO.

`RAKAZO_ALLOWED_HOSTS` additionally lists `rakazo-web.rakazo.svc.cluster.local` and
`rakazo-web.rakazo` because the web server rejects any other `Host` header and Gatus checks the
ClusterIP Service. A missing entry there shows up as a blank computer screen, not as an error.

Mobile and desktop clients use **Existing instance** with the same origin.

## Accounts and sign-in

- **Signups are closed** (`SIGNUPS_ENABLED=false`). The bootstrap Job creates exactly one account,
  `OWNER_EMAIL`, with `OWNER_PASSWORD` from the sealed secret, and marks it verified.
- **Password sign-in stays enabled** (`AUTH_PASSWORD_ENABLED=true`). It is the recovery path when
  Pocket ID is unreachable; SSO-only mode would refuse to start without all OIDC credentials and
  would have no session to link from on a fresh install.
- **Pocket ID SSO** is app-native OIDC against `https://idp.beaver-cloud.ts.net`, client id `rakazo`,
  button label `Pocket ID`, redirect URI
  `https://rakazo.beaver-cloud.ts.net/api/auth/callback/oidc`. The client secret is sealed as
  `apps/rakazo/oidc-sealed-secret.yml` (`oidc` → `rakazo-oidc`) and mounted on the API only.
- Because registration is closed, SSO never creates an account. The owner links their identity from
  **Account settings → Link SSO** while signed in; matching verified email and a verified provider
  claim are required. Pocket ID runs with `EMAILS_VERIFIED=true`, so its addresses qualify.
- The Pocket ID client is restricted to the `members` user group. A fresh client admits nobody until
  its **Allowed user groups** are set, so re-check that after creating or replacing the client:

```sh
K=$(kubectl -n pocket-id get secret pocket-id-secret -o jsonpath='{.data.STATIC_API_KEY}' | base64 -d)
curl -fsS -H "X-API-KEY: $K" https://idp.beaver-cloud.ts.net/api/oidc/clients/rakazo \
  | jq '{id, callbackURLs, pkceEnabled, isGroupRestricted, groups: [.allowedUserGroups[]?.name]}'
```

- **No mail relay** (`EMAIL_PROVIDER=none`): no emailed sign-in codes, no password reset, no welcome
  mail. Forgotten owner password: recover it from the sealed secret, or re-run the bootstrap command
  below. Pocket ID's own recovery is an admin-issued login code.

## Configuration changes

Rakazo reads its settings at process start and `rakazo-config` has no name suffix hash, so editing
`config.env` changes the ConfigMap but does not restart anything. Roll the processes afterwards:

```sh
kubectl -n rakazo rollout restart deployment/rakazo-api deployment/rakazo-worker deployment/rakazo-web
```

`config.env` also carries the computer image and the sandbox limits; those only take effect for
computers started after the change (see [Computers](#computers)).

## Placement

`api`, `worker`, `migrate` and `bootstrap` carry `kubernetes.io/hostname: drone-03`
(`workloads.yml`, `migrate.yml`, `bootstrap.yml`). The pin exists because `api` and `worker` share one
RWO zvol and there is no RWX class here; the Jobs carry it because they run the same large image, and
a Job that lands on a node which cannot pull it sits in `ErrImagePull` while the sync stops at wave 1.

Moving the app means changing all four `nodeSelector` values together and confirming the new node can
pull the images. drone-01 has been observed failing `ghcr.io/elie222/rakazo/app` pulls with
`local error: tls: bad record MAC` while drone-02 and drone-03 pulled the same digest cleanly.

## Secrets and backups

| SealedSecret | Secret | Keys |
| --- | --- | --- |
| `secrets-sealed-secret.yml` | `rakazo-secrets` | `POSTGRES_PASSWORD`, `DATABASE_MIGRATION_URL`, `DATABASE_URL`, `ENCRYPTION_KEY`, `BETTER_AUTH_SECRET`, `SCREEN_PROXY_SECRET`, `OWNER_PASSWORD` |
| `oidc-sealed-secret.yml` | `rakazo-oidc` | `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` |

Seal against the **post-prefix** name: `kubectl create secret generic rakazo-secrets -n rakazo …`
then rewrite `metadata.name` to `secrets` in the committed file (strict-scope ciphertext is bound to
namespace + `rakazo-secrets`). This is the same rule as `docs/tsidp-to-pocket-id.md`.

Back up the database PVC **and** `ENCRYPTION_KEY` together. Losing `ENCRYPTION_KEY` makes every stored
credential (model keys, integrations, OAuth links) unreadable even with a perfect database dump:

```sh
kubectl -n rakazo exec deploy/rakazo-postgres -c app -- \
  sh -lc 'pg_dump -U rakazo rakazo' | gzip > rakazo-$(date +%F).sql.gz
kubectl -n rakazo get secret rakazo-secrets -o jsonpath='{.data.ENCRYPTION_KEY}' | base64 -d
```

Run `pg_dump` as the owner (`POSTGRES_PASSWORD`), not the app login: the app login cannot see rows
that row-level security hides.

Rotating the Pocket ID client secret without plaintext on disk:

```sh
NEW=$(openssl rand -hex 32)
curl -fsS -X POST https://idp.beaver-cloud.ts.net/api/oidc/clients/rakazo/secrets \
  -H "X-API-KEY: $(kubectl -n pocket-id get secret pocket-id-secret -o jsonpath='{.data.STATIC_API_KEY}' | base64 -d)" \
  -H 'content-type: application/json' -d "$(jq -n --arg s "$NEW" '{secret:$s}')"
kubectl -n rakazo get secret rakazo-oidc -o yaml \
  | yq 'del(.metadata.ownerReferences, .metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
            .metadata.managedFields, .metadata.labels, .metadata.annotations)
        | .data.OIDC_CLIENT_SECRET = "'"$(printf %s "$NEW" | base64 -w0)"'"' \
  | kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller -o yaml \
  | yq '.metadata.name = "oidc"' > apps/rakazo/oidc-sealed-secret.yml
```

then commit (Argo applies the new Secret; restart the API because it read the old one at start).

## Upgrading

The app image and the computer image are **one release**. Keep them paired:

- `image:` on `api`, `worker`, `web`, `migrate`, `bootstrap` — all the same digest.
- `KUBERNETES_SANDBOX_COMPUTER_IMAGE` in `config.env` — that release's computer digest.
- Renovate groups `ghcr.io/elie222/rakazo/app` with `.../computer` and disables automerge for the
  pair, so a PR has both or needs one added by hand.

Order for an upgrade:

1. Read the release notes and confirm the migration story.
2. Copy the running computer digest into `PREVIOUS_COMPUTER_IMAGE` (admission then permits both
   releases during the rollout and rollback window), bump the app digests and
   `KUBERNETES_SANDBOX_COMPUTER_IMAGE`, and merge.
3. Watch the sync: `rakazo-migrate` (wave 1) must complete before the workloads roll (wave 2).
4. Stop running computers before changing computer settings — an existing Pod keeps its
   creation-time image and limits.
5. After a fully verified rollout, record the release's migration inventory and clear
   `PREVIOUS_COMPUTER_IMAGE`:

```sh
python3 - <<'PY'
from pathlib import Path
import subprocess
script = ('const fs=require("node:fs");'
          'process.stdout.write(fs.readdirSync("/app/packages/db/prisma/migrations",'
          '{withFileTypes:true}).filter(e=>e.isDirectory())'
          '.map(e=>e.name).sort().join(","))')
inventory = subprocess.check_output([
    "kubectl", "-n", "rakazo", "exec", "deployment/rakazo-api", "--", "node", "-e", script
], text=True).strip()
Path("migration-inventory.txt").write_text(inventory + "\n")
print(inventory[:200], "...")
PY
```

Keep `RAKAZO_DEPLOYED_MIGRATIONS` empty until you trust that output; a wrong value makes the next
migration drop columns an older still-running release needs. Do not advance it after a migration
alone or a failed rollout.

Rolling back needs three things together: the old app digest, the matching computer digest (both in
the allowed list while `PREVIOUS_COMPUTER_IMAGE` is set), and the previous migration inventory.
Restoring only an image cannot undo a schema change.

`rakazo-bootstrap` is a `PostSync` hook, so it re-runs on every sync. It is safe on v0.12.0 (it
leaves an existing verified account unchanged); if a future release starts failing there, delete
`apps/rakazo/bootstrap.yml` from the root and run the same command once:

```sh
kubectl -n rakazo exec -it deployment/rakazo-api -- sh -lc \
  'OWNER_EMAIL=... OWNER_PASSWORD=... node dist/cli/bootstrap-owner.js'
```

## Computers

A bot computer is a Pod created on demand in `rakazo-sandboxes` by the API/worker, using the
`rakazo-controller` ServiceAccount and a namespaced Role limited to `pods` create/get/delete and
`pods/exec`. Admission (`ValidatingAdmissionPolicy rakazo-computers`) then pins the image, requires a
single container, and refuses volumes, host namespaces, host ports, service-account tokens,
Secret-sourced env, privilege escalation and added capabilities.

Capacity (all four must move together):

| Setting | Where | Value |
| --- | --- | --- |
| `pods`, `limits.cpu`, `limits.memory`, ephemeral-storage | `apps/rakazo-sandboxes/quota.yml` (ResourceQuota) | 2 pods, 4 CPU, 8Gi |
| per-container defaults | `quota.yml` (LimitRange) | 2 CPU / 4Gi |
| `KUBERNETES_SANDBOX_CPU_LIMIT`, `KUBERNETES_SANDBOX_MEMORY_LIMIT` | `apps/rakazo/config.env` | 2 / 4Gi |
| `SANDBOX_MAX_COMPUTERS_PER_USER` | `apps/rakazo/config.env` | 2 |

Two computers at 2 CPU each fit on the 4-CPU worker nodes only if they land on different nodes, so
raising the quota without raising the per-computer limits (or adding nodes) just moves the failure.

Computers get DNS and public 80/443 only; every private, CGNAT (tailnet), loopback, link-local,
metadata and multicast range is excluded. Ingress into a computer is limited to the app Pods on 6080
and 6100-6199. Files live in a per-bot checkpoint that is copied in on start and saved back on an
orderly stop — an abruptly lost Pod loses the changes since the last checkpoint, which is why no PVC
is ever mounted into a computer.

Canaries (run from a computer's own shell, e.g. through the app or
`kubectl -n rakazo-sandboxes exec -it <pod> -- sh`):

```sh
curl -sS -m 10 -o /dev/null -w 'public %{http_code}\n' https://example.com        # expect 200
curl -sS -m 5 -o /dev/null -w 'api %{http_code}\n' https://10.43.0.1:443 || echo "cluster API refused (expected)"
curl -sS -m 5 -o /dev/null -w 'db %{http_code}\n' http://rakazo-postgres.rakazo:5432 || echo "database refused (expected)"
```

And from an unrelated namespace, the database must be unreachable while Gatus stays green:

```sh
kubectl -n default run netpol-canary --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sS -m 3 http://rakazo-postgres.rakazo:5432     # must time out
```

The admission boundary is proven the same way — a hand-written Pod with a volume, a second container
or a different image must be rejected in `rakazo-sandboxes`:

```sh
kubectl -n rakazo-sandboxes apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: should-be-denied
spec:
  automountServiceAccountToken: false
  containers:
    - name: c
      image: ghcr.io/elie222/rakazo/computer:v0.12.0
      volumeMounts: [{name: v, mountPath: /v}]
  volumes: [{name: v, emptyDir: {}}]
EOF
```

## Models

Bots use the deployment default model, `deepseek-v4.1-flash`, served by Aperture at
`https://ai.beaver-cloud.ts.net/v1` through the `ai-egress` ProxyGroup (`tag:k8s-ai`). Aperture
authorizes by tailnet identity, so `RAKAZO_LOCAL_MODELS_API_KEY` is a placeholder it ignores. There is
no hosted model key anywhere in this repo.

The Aperture grant lives in `kevindurb/infra` (`tailnet/policy.hujson`). If model calls start
returning `403`/`404`, check that grant before touching this deployment. Screenshot computer tools
need a vision-capable model; add it to `RAKAZO_LOCAL_MODELS`/`RAKAZO_LOCAL_VISION_MODELS` and restart
`api` and `worker`.

`RAKAZO_LOCAL_MAX_TOKENS=8192` is deliberate: these are reasoning models, and with no cap the
reasoning trace consumes the server-side default and the reply comes back empty (the same failure
`docs/pr-agent.md` records).

## Health and observability

Gatus checks `https://rakazo.beaver-cloud.ts.net/api/auth/ok`: public, no session needed, and it
proves the whole path (tailnet ingress proxy -> web -> api). Two things forced that target, both
measured on 2026-11-17:

- `GET /rpc/health` answers `405`; it is not a GET endpoint, so a Gatus `[STATUS] == 200` there can
  never be green.
- A ClusterIP probe from another namespace does not work here even with the right policy. With
  `rakazo-allow-monitoring` in place, a pod in `gatus` (and one in `tailscale`, and a temporary rule
  for `default`, and a temporary `ipBlock` for `10.42.0.0/16`) all timed out against the web pod,
  while `default` -> `miniflux`, `default` -> `pocket-id` and the tailnet origin all returned `200`.
  Default-deny is enforced and same-namespace allows work (`web` -> `api`, `api` -> `postgres`), so
  the gap is specifically cross-namespace *allow* rules.

  This matters beyond this app: `docs/network-segmentation.md` phases 1-3 rely on `namespaceSelector`
  allows (`allow-monitoring`, `allow-ingress-proxies`) and would turn every Gatus check red. Verify
  the CNI behaviour on a throwaway namespace before rolling that out.

`api` and `worker` read the computer image out of `rakazo-config`, so a broken replacement shows up
first as a failed kustomize build, not at runtime.

## Retiring the app

`prune: false`, so nothing is deleted automatically. To remove it: drop the two `app.yml` lines from
`apps/kustomization.yml`, delete both Applications by hand, and delete the cluster-scoped objects the
Applications owned (`rakazo-computers` ValidatingAdmissionPolicy and its binding) plus the namespaces
and PVCs when you are sure the data is expendable. Deleting the namespace first orphans the PVCs'
data on drone-04 without warning.
