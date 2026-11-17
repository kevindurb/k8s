# Design

## Context

See `proposal.md` for motivation and `specs/rakazo/spec.md` + `specs/rakazo-computers/spec.md` for
the behavior contract. The constraints that shape the approach:

- **Delivery.** Argo CD app-of-apps, `apps/*` are Kustomize roots registered one line at a time in
  `apps/kustomization.yml`, every app has its own `Application` (`project: apps`, `prune: false`,
  `selfHeal: true`, `managedNamespaceMetadata` for pod security). There is no out-of-band apply step.
- **Routing.** Plain `Ingress` with `ingressClassName: tailscale`; `tailscale.com/proxy-group:
  ingress-proxy-group` puts two proxy Pods in the `tailscale` namespace, labelled
  `tailscale.com/parent-resource-type=ingress`. Tailnet suffix is `beaver-cloud.ts.net`.
- **Storage.** One StorageClass, `zfs-generic-nvmeof-csi` (zvols on drone-04, NVMe-oF, **RWO only**).
  `local-path` does not exist here, so the upstream example's storage class is not available.
- **Nodes.** drone-01/02/03 are 4 CPU workers with ~3 CPU and 10+ GiB free each; drone-04 (storage)
  and the control planes are tainted.
- **Network.** k3s enforces `NetworkPolicy` (kube-router). No app namespace has one yet
  (`docs/network-segmentation.md` is at phase 0), so this app is the first with real policy.
- **Models.** Aperture runs on the tailnet at `ai.beaver-cloud.ts.net`, serves an OpenAI-compatible
  `/v1`, authorizes by tailnet identity, and is reachable in-cluster through the CoreDNS rewrite to
  the `ai` ExternalName and the `ai-egress` ProxyGroup (`tag:k8s-ai`). Mealie already uses that path.
- **Identity.** Pocket ID (`platform/pocket-id`) is the cluster IdP at `https://idp.beaver-cloud.ts.net`,
  reachable in-cluster through the `idp` ExternalName and the `oidc-egress` ProxyGroup. It has no
  dynamic client registration (`AUTO_CREATE_OIDC_CLIENT_SECRET=false`): each app's client is created
  through its API with `STATIC_API_KEY` (`docs/tsidp-to-pocket-id.md`), its secret is sealed as
  `<app>-oidc`, and a fresh client admits nobody until its allowed user group is set.
- **Upstream.** Rakazo publishes a `docs/examples/kubernetes/` recipe (two namespaces, RBAC,
  NetworkPolicy, admission policy, quota, three workloads, three PVCs, migrate and bootstrap Jobs)
  written for a fresh single-node k3s with `kubectl apply -k -l rakazo.example/phase=...`. The
  manifests are the reference; the delivery model is not.

## Goals / Non-Goals

**Goals:**

- One `git push` deploys the app end to end, including schema migration and owner bootstrap.
- The computer boundary (namespace, RBAC, admission, quota, egress) exists from the first sync, so a
  bot cannot start a computer before the limits around it do.
- Every upstream-referenced digest is pinned, and the app/computer pair cannot drift apart.
- Nothing is exposed outside the tailnet, and the app namespace's reachability is written down.

**Non-Goals:**

- High availability. Every Rakazo process is a single replica, as upstream specifies; two API or two
  worker replicas need a shared-write storage design that does not exist on this class.
- An in-cluster mail relay (so no emailed sign-in codes, password reset, or welcome mail), Google or
  Apple sign-in, SCIM provisioning, mobile push, Telegram/WhatsApp/iMessage bridges, media
  generation, billing, or the ticket board. Each is an upstream opt-in that would add its own secret
  and network flow; the deployment ships with `EMAIL_PROVIDER=none`, signups closed, and Pocket ID as
  the only SSO provider.
- Backups. `docs/backups.md` already covers PVC snapshots; this change adds the app to it in
  `docs/rakazo.md` rather than building a new pipeline.
- A public or Funnel surface, and any change to `docs/network-segmentation.md`.

## Decisions

### Two Kustomize roots: `apps/rakazo` and `apps/rakazo-sandboxes`

The app namespace and the sandbox namespace are two Argo CD Applications. This is forced by Kustomize:
a parent's `namespace:` field overrides any `namespace:` a resource already carries, including
resources from a nested base — verified with `kustomize build` on a two-level fixture. One root
therefore cannot render both namespaces unless we drop the global `namespace:` convention and hand-set
it on ~20 resources.

Alternatives considered: (a) one Application with two `sources` paths — works, but hides two
independently-synced namespaces behind one Application status and one sync button; (b) computers in
the `rakazo` namespace — rejected because the controller Role must grant `pods` create/delete in the
namespace it creates computers in, which would let it delete the API pod; (c) removing `namespace:`
from the app root — breaks the repo-wide convention for one app.

`apps/rakazo-sandboxes` sets no global `namespace:`; each resource names its namespace. It also holds
the one object that has to live in `tailscale` (see TRUSTED_PROXIES below), so the rule is simple: the
`rakazo-sandboxes` root owns everything outside the `rakazo` namespace.

### Names come from `namePrefix: rakazo-`

Resources are named for their role (`api`, `worker`, `web`, `postgres`, `secrets`, `config`) so the
prefix produces exactly the names upstream uses and documents (`rakazo-api`, `rakazo-postgres`,
`rakazo-config`, `rakazo-secrets`). The generated `Secret` keeps the SealedSecret's post-prefix name,
matching `docs/secrets.md`. `namePrefix` in `apps/rakazo-sandboxes` is `rakazo-` as well, which names
the Role `rakazo-computers` and the peers Service `rakazo-ingress-peers`.

### Sync waves plus hook-annotated Jobs instead of a phase sequence

`kubectl apply -k -l rakazo.example/phase=...` has no GitOps equivalent, so the ordering moves into
Argo CD:

| Wave | Resources |
| --- | --- |
| 0 | PVCs, ConfigMaps, SealedSecret, PostgreSQL Deployment + Service, `rakazo-api`/`rakazo-web` Services, headless `rakazo-web-peers`, `NetworkPolicy` |
| 1 | `rakazo-migrate` as `Sync` hook (`hook-delete-policy: BeforeHookCreation`) — Argo waits for the Job to complete |
| 2 | `rakazo-api`, `rakazo-worker`, `rakazo-web` Deployments, `Ingress`, `gatus` ConfigMap |
| 3 | `rakazo-bootstrap` as `PostSync` hook (`hook-delete-policy: BeforeHookCreation`) |

Waves work because Argo CD waits for the health of one wave before starting the next, and a Deployment
health check is pod-readiness — so the migrate Job cannot start before PostgreSQL is ready, and the
API cannot start before migrations are applied. Jobs are hooks, not plain resources, because Jobs are
immutable and a plain Job would fail to re-apply on the next sync; `BeforeHookCreation` deletes the
previous run each time.

Alternative considered: `PreSync` for migrate — rejected, because on a clean cluster PostgreSQL does
not exist yet at PreSync time.

`RAKAZO_DEPLOYED_MIGRATIONS` is kept in a dedicated ConfigMap (`rakazo-migration-state`) so the
Job's safety input has its own lifecycle instead of riding along with `rakazo-config`.

### PostgreSQL is bundled, version 18, on the zfs class

The cluster has no shared database to attach to (immich and miniflux each bundle their own), so
Rakazo bundles one: `postgres:18-alpine` pinned by tag+digest, `strategy: Recreate`, mounted at
`/var/lib/postgresql` (that is the volume root in the v18 image — not `/var/lib/postgresql/data`),
running as uid/gid 1000 with `fsGroup: 1000`. That is exactly `apps/miniflux/postgres.yml`, which has
run the same image family on the same storage class for months; the upstream example's `fsGroup: 999`
is a local-path assumption that would leave this zvol unwritable. Two logins come from the sealed secret: owner (`POSTGRES_PASSWORD`, also inside
`DATABASE_MIGRATION_URL`) and the restricted app login inside `DATABASE_URL`; only the migration Job
receives the owner URL.

Alternative considered: CloudNativePG or another operator — a new platform dependency for one
database, against a repo that vendors plain Postgres Deployments for the two existing ones.

### `api` and `worker` are pinned to one node

Both processes mount the same bot-data volume, and there is no RWX class here: two Pods on different
nodes cannot both attach the zvol. A `nodeSelector` on `kubernetes.io/hostname` in both Deployments is
the simplest guarantee, and node names survive rebuilds in this repo (`docs/drone-03-rebuild.md`).
`strategy: Recreate` keeps one writer per volume during a rollout.

Alternatives considered: `podAffinity` from worker to api — a reschedule of api to a new node leaves
the running worker holding the attachment on the old node, which deadlocks the pair; a
`ReadWriteMany` volume — no RWX provisioner exists; splitting bot data per process — the app requires
one shared `DATA_DIR`.

### Ingress: shared proxy group, no Funnel

`Ingress{ingressClassName: tailscale}` with `tailscale.com/proxy-group: ingress-proxy-group` and
`tailscale.com/tags: tag:apps`, `tls.hosts: [rakazo]`, no `tailscale.com/funnel`. `RAKAZO_HOST`,
`BETTER_AUTH_URL`, `WEB_ORIGIN` and `API_URL` are all `https://rakazo.beaver-cloud.ts.net`, which is
what upstream requires: cookies, CORS and the mobile client follow those values.

`RAKAZO_ALLOWED_HOSTS` additionally lists the in-cluster names (`rakazo-web.rakazo.svc.cluster.local`,
`rakazo-web.rakazo`) because the web server rejects any other `Host` header and Gatus probes the
ClusterIP Service, not the tailnet name — the failure mode is a blank screen, per upstream.

Alternatives considered: Funnel (the proposal's rejected option — agent code with a shell behind a
public login); a per-Ingress proxy instead of the shared group (one more proxy device, and its
generated Service name is hash-suffixed and unusable in config).

### TRUSTED_PROXIES gets real hop identities

The API must trust the actual forwarding chain or every request looks like it came from the web Pod
(shared rate-limit bucket, wrong client IP in security events). Two headless Services provide hop
identities, as upstream's example does:

- `rakazo-web-peers` (namespace `rakazo`, `clusterIP: None`) selecting the web Pods;
- `rakazo-ingress-peers` (namespace `tailscale`, `clusterIP: None`) selecting that namespace's Pods
  with `tailscale.com/parent-resource-type=ingress` and `tailscale.com/parent-resource-ns=rakazo`.

`TRUSTED_PROXIES` lists both DNS names. The `tailscale` one is the reason the sandbox root carries a
per-resource namespace: nothing else can express "an object in another namespace" without either a
second Application or a hand-namespaced app root. The alternative — trusting the pod CIDR — would let
any Pod forge a client IP.

### NetworkPolicy: full deny/allow in `rakazo`, upstream egress for computers

`rakazo` gets default-deny for ingress **and** egress plus named allow policies; `rakazo-sandboxes`
gets the upstream computer policy (DNS plus public 80/443 with every private range excepted, ingress
only from the app Pods on 6080 and 6100-6199).

One measured gap, recorded in `docs/rakazo.md`: this cluster's CNI enforces default-deny and
same-namespace allows but not a cross-namespace *allow* (a pod in `gatus`, `default` or even
`tailscale` is refused a connection to the web pod despite a matching `namespaceSelector` or
`ipBlock` rule). The policies are still written per spec; the Gatus check therefore uses the tailnet
origin, and `docs/network-segmentation.md` needs that verified before its phases 1-3 roll out.

This departs from `docs/network-segmentation.md`, which defers egress to phase 4: that deferral exists
because enumerating CDN endpoints for the browser-facing apps has poor cost/benefit. Here the flows
are few and known, and the code inside the namespace is agent-driven — the case the document says is
the realistic compromise. Ingress-side policy reuses the same shape as
`components/network-policy` (same-namespace, Gatus, ingress proxies) but is written inline: that
component's allow rules are namespace-wide, and `rakazo` needs port-level grants (5432 to Postgres
only, 5173 to web only, 3100 to api only).

The cluster-API egress rule uses the `kubernetes` Service endpoints (the three control-plane node
IPs on 6443), not `10.43.0.1`, because the CNI evaluates egress after Service DNAT — upstream says the
same and warns to test it; `docs/network-segmentation.md` already documents this "container port, not
Service port; post-DNAT address" class of mistake.

The Aperture and Pocket ID paths are egress rules to the `tailscale` namespace on the egress
proxies' **container** ports, 10205 and 10837 — not the 443 their Services expose (`ts-ai-*` maps
443 to 10205, `ts-idp-*` to 10837). Written against 443 the rule looks right and denies every model
call, which is the same "container port, not Service port" trap `docs/network-segmentation.md`
records; measured here as `ECONNREFUSED` from the API pod while an unrestricted pod got `200`.

### Models through the deployment-local provider, not a UI connection

`RAKAZO_LOCAL_MODELS`, `RAKAZO_LOCAL_MODELS_URL=https://ai.beaver-cloud.ts.net/v1`,
`RAKAZO_LOCAL_MODELS_API_KEY=aperture-identity` (Aperture ignores the bearer token; the value exists
because the field is required), `PI_DEFAULT_PROVIDER=local`, `PI_DEFAULT_CREDENTIALS=host`, and
`PI_DEFAULT_MODEL` set to a model the `tag:k8s-ai` grant includes.

The alternative — an OpenAI-compatible *connection* added in the UI — runs into the app's private-host
validation (`RAKAZO_OPENAI_COMPAT_PRIVATE_HOSTS` plus `MCP_ALLOW_PRIVATE_ENDPOINT=true`), which also
opens private endpoints for every user and every bot. The deployment-local path is operator-controlled,
needs no key, and gives every bot a sane default while leaving per-bot overrides possible later.

Output/context limits are set explicitly (`RAKAZO_LOCAL_CONTEXT_WINDOW`,
`RAKAZO_LOCAL_MAX_TOKENS`, `RAKAZO_LOCAL_REASONING_MODELS`) because the gateway serves reasoning
models, and `docs/pr-agent.md` records what happens when output tokens are left to the server default:
the reasoning trace consumes them and the reply is empty.

### One `SealedSecret`, one generated `rakazo-config`

`secrets.env`-style values become one `SealedSecret` named `secrets` (post-prefix `rakazo-secrets`) in
the `rakazo` root; non-secret settings become a `configMapGenerator` entry from `config.env`, with
`disableNameSuffixHash: true` so the names the docs and probes reference stay stable. The cost of no
hash suffix is that a config-only change does not restart anything — Rakazo reads settings at process
start — so `docs/rakazo.md` states that a config change needs a rollout restart of `api`, `worker` and
`web` (Argo CD will not do it for you).

`SMTP_URL` is referenced with `optional: true` so the key may be absent while `EMAIL_PROVIDER=none`.

### SSO is Pocket ID OIDC, linked from the bootstrap account

`OIDC_ISSUER=https://idp.beaver-cloud.ts.net`, `OIDC_CLIENT_ID=rakazo`, `OIDC_NAME=Pocket ID`,
`OIDC_SCOPES=openid email profile`, client secret from `rakazo-oidc` referenced by the **API**
container only; `AUTH_PASSWORD_ENABLED=false` (SSO-only, see below), `SIGNUPS_ENABLED=false`,
`OIDC_ALLOW_SIGNUP_BYPASS` unset. The non-secret `OIDC_*` values sit in `config.env`, which `envFrom`s into all three workloads
(harmless — only the API reads them); the secret is never in that ConfigMap.

Upstream makes SSO signup follow closed registration, and `SIGNUPS_ENABLED=false` closes it, so SSO
cannot create an account here at all. The only path that gives the owner an SSO login is **Link SSO**
from an authenticated session; bootstrap creates a verified account, which is the precondition for
linking, and Pocket ID runs with `EMAILS_VERIFIED=true`, so the provider asserts `email_verified` and
the addresses match.

Sign-in is then reduced to Pocket ID alone (`AUTH_PASSWORD_ENABLED=false`), decided after the link was
verified in the live deployment. The order matters and is the whole safety argument: bootstrap first
(which needs a password), link second (which needs a session), disable the password last. Upstream
gates that mode on all three OIDC credentials being present, turns passkeys off, and keeps the
password hash in the database, so the credential row survives and setting the flag back to `true` is
a working recovery path.

The trade-off accepted: with no mail relay and no password form, an unreachable Pocket ID means no
interactive sign-in at all until the operator flips that flag in git (Argo sync, about three
minutes). The alternative — leaving the password form up — keeps a permanent second attack surface
for one account that never needed it.

Alternatives considered: `OIDC_ALLOW_SIGNUP_BYPASS=true` — admits any Pocket ID identity the client's
allowed group permits, without the allowlist, which turns the IdP's user list into this deployment's
account list; rejected for a one-account install. An `oauth2-proxy` gate in front of the origin (the
shape upstream suggests for a public host) — rejected: it puts a cookie check in front of the computer
screen capability path (`/novnc/session/*`) and needs its own `authenticated_emails_file`, while
app-native OIDC has no interaction with that path.

The client is created through Pocket ID's API with the existing `STATIC_API_KEY` and the `mk()` helper
in `docs/tsidp-to-pocket-id.md`, with redirect URI
`https://rakazo.beaver-cloud.ts.net/api/auth/callback/oidc` (derived from `BETTER_AUTH_URL`), and
sealed as `oidc` (post-prefix `rakazo-oidc`) exactly like `apps/mealie/oidc-sealed-secret.yml`. The
client also needs its **Allowed user groups** set: a fresh Pocket ID client admits nobody. The API
reaches the issuer in-cluster through the `idp` ExternalName and the `oidc-egress` ProxyGroup
(`tag:k8s-oidc`), which the namespace's `tailscale:443` egress rule already covers, so no tailnet
policy change is needed.

### Pod hardening: explicit, not the shared components

`components/app-pod-hardening` is not used: it sets `readOnlyRootFilesystem`, and the Rakazo images
write inside `/app` and `/data` at runtime. `components/app-tmp-dirs` is not used either, since nothing
needs a tmp emptyDir. Instead each container carries the upstream `securityContext` (uid/gid 1000,
`allowPrivilegeEscalation: false`, all capabilities dropped, `RuntimeDefault` seccomp, non-root) and
the Pod sets `fsGroup: 1000` with `fsGroupChangePolicy: OnRootMismatch`; the same reasoning `tsgit`
records in its `kustomization.yml`. Both namespaces enforce `baseline` and warn/audit `restricted`.

### The computer image has one source of truth

`KUBERNETES_SANDBOX_COMPUTER_IMAGE` lives in `config.env` and is copied into the admission policy's
expression by a Kustomize `replacements` rule (same trick as upstream), so the image the controller
uses and the image admission permits cannot disagree. `PREVIOUS_COMPUTER_IMAGE` is a second
ConfigMap key so both releases are permitted during a rollout, and it is empty on first install.

`.github/renovate.json` gets a `customManager` (regex, `apps/rakazo/config.env`) for the computer
digest plus a `packageRule` grouping `ghcr.io/elie222/rakazo/app` and `.../computer` with
`automerge: false`. Grouping keeps the pair in one PR; disabling automerge is a deliberate exception
to this repo's digest automerge, because upstream requires release-note review, a matching computer
image, and a migration-inventory update — none of which a bot can do on its own.

Starting pair: `v0.12.0`, the current stable (`app@sha256:0ede1404...`,
`computer@sha256:fceeee2f...`), not the older pair in the upstream example.

## Risks / Trade-offs

- **`bootstrap` hook may not be idempotent** → it runs as `PostSync` with `BeforeHookCreation`, so it
  re-runs on every sync. Verify against v0.12.0 during implementation; if it fails when the owner
  already exists, run it once and remove it from git (documented in `docs/rakazo.md`), keep the
  migration as the only hook.
- **Migrate Job re-runs on every sync** → acceptable: `prisma migrate deploy` is idempotent, and it
  is the safety net for digest bumps. `RAKAZO_DEPLOYED_MIGRATIONS` stays empty until the first
  verified release is recorded, which upstream defines as the conservative default.
- **Config changes do not restart Pods** (no name-suffix hash) → documented restart step; a stale
  process with old `RAKAZO_HOST` is the most likely self-inflicted failure.
- **Two writers on one zvol is fragile** → the node pin plus `Recreate` is the whole mitigation; a
  manual reschedule of api while the worker holds the attachment surfaces as a `Multi-Attach` warning
  and a Pending Pod, not as data loss.
- **Sandbox capacity vs 4-CPU nodes** → quota allows two computers at 2 CPU / 4 GiB each; drone-01/02/03
  each have ~3 CPU free, so two can schedule but a third would not. The knobs
  (`KUBERNETES_SANDBOX_CPU_LIMIT`, `KUBERNETES_SANDBOX_MEMORY_LIMIT`, quota, LimitRange) must move
  together.
- **Aperture grant is outside this repo** → without a `tag:k8s-ai` role+models grant the app starts
  fine and every run fails at the model call. Verification is a task, and `docs/rakazo.md` names the
  other repo.
- **Model capability gaps** → `deepseek-v4.1-flash` is text-first; if no granted model accepts images,
  screenshot computer tools stay unavailable. The model list is one line to change, so this is
  verified after deploy rather than designed around.
- **SSO misconfiguration is indistinguishable from a lockout** → password sign-in stays enabled and
  `OWNER_PASSWORD` stays sealed, and the SSO link is created from an existing session, so a broken
  provider or an unset allowed-group leaves the deployment reachable. Verify from a signed-out browser
  before relying on the button.
- **Pocket ID client secret rotation needs a re-seal** → the procedure (re-seal the live `rakazo-oidc`
  secret with the new value, no plaintext on disk) goes into `docs/rakazo.md`; the client id is not a
  secret and stays in `config.env`.
- **`EMAIL_PROVIDER=none` leaves no password reset and no emailed sign-in code** → the owner password
  lives in the sealed secret, password sign-in works, and Pocket ID's own admin-issued login code is
  the recovery path for the IdP itself. Both are recorded in `docs/rakazo.md`.
- **`ENCRYPTION_KEY` loss makes stored credentials unreadable** → called out in `docs/rakazo.md` next
  to the existing backup procedure; it must be backed up with the database.
- **Prune is off** → retiring the app means deleting both parent kustomization lines *and* both
  Argo CD Applications, plus the cluster-wide admission policy, which is cluster-scoped and therefore
  shared-looking in `kubectl get validatingadmissionpolicy`.

## Migration Plan

1. Pre-merge: set the owner email in `config.env`; generate the eight secret values with
   `openssl rand`/`python3 -c 'secrets.token_hex'`, seal them with `kubeseal` into
   `apps/rakazo/secrets-sealed-secret.yml`, and record `ENCRYPTION_KEY` in the password manager.
2. Pre-merge: create the `rakazo` Pocket ID client with the redirect URI above, set its allowed user
   group, and seal its id and secret into `apps/rakazo/oidc-sealed-secret.yml` as `rakazo-oidc`.
3. Merge. Argo CD syncs `rakazo-sandboxes` and `rakazo`; the `rakazo` sync runs PostgreSQL, migration,
   workloads, then bootstrap. First image pulls take minutes.
4. Verify: sign in at `https://rakazo.beaver-cloud.ts.net` as the owner with the password, link Pocket
   ID from account settings, sign out and sign in again with the `Pocket ID` button, confirm Gatus
   green, start a computer and drive its desktop, run a bot turn against the gateway, and run the
   network canaries (a Pod in `rakazo` cannot reach an unrelated namespace; a computer cannot reach
   the API or the database; a computer reaches a public site).
5. Rollback: revert the commit. Do not delete namespaces or PVCs — `prune: false` means a revert
   never removes data, and the volumes are the app's state. For a bad release, restore the previous
   app digest *and* the previous `migration.env` inventory together (upstream: an old image against a
   new schema is not a rollback), then re-apply the foundation wave.

## Open Questions

- Which granted model is vision-capable (browser/screenshot tools) — answered by listing what the
  gateway serves to `tag:k8s-ai` after deploy and updating `RAKAZO_LOCAL_MODELS` +
  `RAKAZO_LOCAL_VISION_MODELS`.
- Whether the owner bootstrap accepts an existing owner (see risks) — resolved on first re-sync.
