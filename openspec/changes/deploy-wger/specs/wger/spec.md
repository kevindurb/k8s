# Spec Delta

## Purpose

Run a self-hosted wger workout manager on the tailnet that stores workout,
measurement, nutrition and exercise-media data durably, authenticates through
Pocket ID, and keeps its exercise library and mail delivery working without
manual intervention.

## ADDED Requirements

### Requirement: Tailnet-only reachability

The wger web UI and HTTP API SHALL be reachable only at
`https://wger.beaver-cloud.ts.net` through the cluster's Tailscale `Ingress`,
and MUST NOT be exposed on the LAN, a node port, or a public load balancer.

#### Scenario: Tailnet peer opens the app

- **WHEN** a tailnet peer opens `https://wger.beaver-cloud.ts.net`
- **THEN** the wger web UI is served with its CSS and JavaScript assets loading
- **AND** the API responds under `/api/`

#### Scenario: No non-tailnet exposure exists

- **WHEN** the rendered manifests for the app are inspected
- **THEN** the only exposure is an `Ingress` with `ingressClassName: tailscale` and a cluster-internal `Service`
- **AND** no `LoadBalancer`, `NodePort` or host-network listener exists

### Requirement: Pocket ID login with break-glass admin

Users SHALL authenticate through Pocket ID using OpenID Connect, and the
instance SHALL keep a local password login for the `admin` account as
break-glass access. Account registration SHALL be open because wger uses the
same setting to gate OpenID Connect auto-signup; automatic guest-user creation
SHALL be disabled.

#### Scenario: Pocket ID user signs in

- **WHEN** a user selects the Pocket ID login option and completes the OIDC flow
- **THEN** the redirect URI used is `https://wger.beaver-cloud.ts.net/account/oidc/pocket-id/login/callback/`
- **AND** the user lands in wger authenticated with an account bound to that identity

#### Scenario: First Pocket ID login creates the account

- **WHEN** a Pocket ID user who does not exist in wger completes the OIDC flow
- **THEN** allauth creates the account with an unusable local password
- **AND** the user is signed in rather than shown a "sign up is closed" error

#### Scenario: Local admin signs in when the identity provider is unavailable

- **WHEN** Pocket ID is unreachable and the `admin` user submits valid local credentials
- **THEN** the login succeeds through wger's local password form

#### Scenario: Anonymous visitor does not get a guest account

- **WHEN** an unauthenticated visitor requests a protected page
- **THEN** no guest user is created automatically
- **AND** the visitor is asked to sign in

### Requirement: Exercise library available with images and videos

After initial setup, the instance SHALL hold the exercise library synchronized
from the configured remote wger instance, including exercise images and videos,
so that exercises render with their media in the web UI.

#### Scenario: Library is seeded

- **WHEN** the one-time synchronization commands have completed
- **THEN** exercises, categories, muscles, equipment, images and videos from the remote instance are present locally
- **AND** an exercise detail page shows its image or video

#### Scenario: Sync only fills gaps

- **WHEN** a media synchronization runs again over already-downloaded media
- **THEN** files whose remote identity is already present are skipped
- **AND** no duplicate media entries are created

### Requirement: Background synchronization and mail delivery

The deployment SHALL run Celery workers and a single scheduler so that exercise
and ingredient synchronization and outbound email happen without an operator
running commands, and it SHALL deliver account and password-reset email through
the cluster SMTP relay.

#### Scenario: Scheduled sync runs

- **WHEN** the scheduler fires a configured weekly synchronization
- **THEN** a worker executes it and updates the local exercise or ingredient data
- **AND** no operator action is required

#### Scenario: Password-reset mail is delivered

- **WHEN** a user requests a password reset and SMTP delivery is enabled
- **THEN** the message is handed to `smtp-relay-app-service.smtp-relay`
- **AND** the request does not block on the SMTP round trip

#### Scenario: Broker restart does not damage data

- **WHEN** the cache/broker or a worker is restarted or rescheduled
- **THEN** the database and media volumes are unaffected
- **AND** the next scheduled run still executes

### Requirement: Durable, right-sized storage

The PostgreSQL data directory and the media directory SHALL each live on their
own persistent volume on the cluster's ZFS NVMe-oF storage class, and the media
volume SHALL be large enough to hold the full exercise video library plus
headroom.

#### Scenario: Pod is rescheduled

- **WHEN** the web pod is deleted or moves to another node
- **THEN** previously uploaded media and all database content are still available
- **AND** the app serves the same workouts and exercise media as before

#### Scenario: Media volume has headroom

- **WHEN** the full exercise video library (~3.3 GiB at the time of writing) and images are downloaded
- **THEN** the media volume is at most roughly one third full

#### Scenario: Static assets are rebuilt, not persisted

- **WHEN** the web pod starts
- **THEN** collected static assets are regenerated into ephemeral storage
- **AND** no persistent volume is consumed by files that can be recollected

### Requirement: Secrets are sealed and stable

The Django secret key, database password and OpenID Connect client credentials
SHALL be supplied only from a committed `SealedSecret`; no plaintext value SHALL
appear in the repository or in change artifacts.

#### Scenario: Sessions survive a restart

- **WHEN** the web pod restarts
- **THEN** the Django secret key is unchanged
- **AND** existing sessions are not invalidated by the restart

#### Scenario: No plaintext secret is committed

- **WHEN** the change is reviewed in git
- **THEN** the only secret-bearing artifacts are `SealedSecret` manifests
- **AND** no database password, Django secret key or OIDC client secret appears in plaintext

### Requirement: Least-privilege runtime

The application containers SHALL run as non-root, with no privilege escalation
and all Linux capabilities dropped, and the main application container SHALL run
with a read-only root filesystem whose only writable paths are the media volume
and ephemeral directories.

#### Scenario: Pod is admitted under the namespace policy

- **WHEN** the pod is created in the `wger` namespace, which enforces the `baseline` Pod Security Standard and warns/audits on `restricted`
- **THEN** it is admitted without Pod Security violations

#### Scenario: Writes outside allowed paths fail

- **WHEN** the application container attempts to write outside the media volume and its ephemeral directories
- **THEN** the write fails rather than silently persisting

### Requirement: Health monitoring

The app SHALL publish a Gatus endpoint check that exercises an unauthenticated
application endpoint, so the status page reflects whether wger itself is serving
requests rather than only whether its database is reachable.

#### Scenario: Healthy instance

- **WHEN** wger is serving requests normally
- **THEN** the Gatus check for `wger-app-service.wger` against `/api/v2/version/` succeeds

#### Scenario: Broken instance is reported

- **WHEN** the web container or its nginx sidecar cannot serve requests
- **THEN** the Gatus check fails

### Requirement: GitOps-managed lifecycle

The app SHALL be delivered by Argo CD from this repository: an `Application` in
the `apps` project pointing at `apps/wger`, registered in
`apps/kustomization.yml`, with automated sync, self-healing, and pruning
disabled. The `wger` namespace SHALL be created by that `Application` with the
pod security labels used by the other apps.

#### Scenario: Sync from a clean cluster

- **WHEN** Argo CD syncs the `wger` application against a cluster without the namespace or workloads
- **THEN** it creates the namespace with the standard pod security labels, the sealed secret, the PVCs, and all workloads

#### Scenario: Drift is corrected

- **WHEN** a live workload is edited outside git
- **THEN** Argo CD reverts it on the next reconcile

#### Scenario: Image upgrade completes without manual steps

- **WHEN** a new wger image digest is merged and synced
- **THEN** the new pod runs database migrations before serving traffic
- **AND** the site returns to service with the new version
