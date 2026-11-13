# Spec Delta

## Purpose

Provide an always-on, tailnet-only storage endpoint that Obsidian LiveSync clients replicate a vault to, so desktop and mobile devices stay consistent even when they are never online at the same time.

## ADDED Requirements

### Requirement: Tailnet-only HTTPS endpoint

The service SHALL be reachable by tailnet peers over HTTPS at its tailnet DNS name, and SHALL NOT be reachable from the public internet, the LAN, or the cluster network except through cluster-internal `Service` traffic. No Funnel listener, NodePort, or host port SHALL be published.

#### Scenario: Tailnet peer reaches the endpoint

- **WHEN** a peer on the tailnet requests `https://<host>.<tailnet>.ts.net/`
- **THEN** the request is answered by the vault service over TLS with a certificate valid for that tailnet name

#### Scenario: No public listener exists

- **WHEN** the rendered manifests are inspected
- **THEN** they contain no Funnel configuration, no NodePort, no hostPort, and no annotation that publishes the service publicly
- **AND** the only external entry point is a tailnet `Ingress`

#### Scenario: Off-tailnet request fails

- **WHEN** a client that is not on the tailnet resolves and requests the tailnet name
- **THEN** the request does not reach the vault service

### Requirement: Authentication is mandatory

Every request to the database SHALL require valid credentials. Requests without them MUST be rejected with `401`, and MUST NOT reveal whether a database exists.

#### Scenario: Unauthenticated root request is refused

- **WHEN** a client requests `/` without credentials
- **THEN** the response status is `401`

#### Scenario: Unauthenticated database request is refused

- **WHEN** a client requests a vault database path without credentials
- **THEN** the response is `401`
- **AND** the response does not include any vault document

#### Scenario: Authenticated client is served

- **WHEN** a client supplies valid credentials for the vault database
- **THEN** the request is answered according to its method

### Requirement: One database per vault with a scoped user

Each vault SHALL have its own database, and client devices SHALL authenticate as a non-admin user whose access is limited to that database. Administrative credentials MUST NOT be distributed to clients.

#### Scenario: Vault database exists and is writable

- **WHEN** a client authenticates as the vault user and replicates into the vault database
- **THEN** documents are accepted and readable back

#### Scenario: Vault user cannot perform admin operations

- **WHEN** the vault user requests an administrative endpoint or another database
- **THEN** the request is refused

#### Scenario: Additional vault uses a separate database

- **WHEN** a second vault is configured against the same service
- **THEN** it uses a different database name
- **AND** neither vault's documents appear in the other vault

### Requirement: CORS for Obsidian client origins

The service SHALL return cross-origin headers that allow replication from the Obsidian desktop and mobile origins, and SHALL NOT grant those headers to any other origin.

#### Scenario: Desktop origin is allowed

- **WHEN** a request carries `Origin: app://obsidian.md`
- **THEN** the response allows that origin

#### Scenario: Mobile origin is allowed

- **WHEN** a request carries `Origin: capacitor://localhost`
- **THEN** the response allows that origin

#### Scenario: Unknown origin is not granted

- **WHEN** a request carries an origin outside the allowed set
- **THEN** the response does not grant cross-origin access to it

### Requirement: Durable vault storage

Vault data SHALL live on a persistent volume that survives pod deletion, rescheduling, and replacement of the pod's container image, so that no acknowledged document is lost across a restart.

#### Scenario: Pod is recreated

- **WHEN** the pod is deleted and rescheduled
- **THEN** the vault database is present with the same documents
- **AND** clients can replicate without reinitialising

#### Scenario: Image update

- **WHEN** the deployment is updated to a new image
- **THEN** the volume is reused and the documents remain readable

#### Scenario: Storage-node downtime

- **WHEN** the storage node hosting the volume reboots and the pod is stopped and later rescheduled
- **THEN** the service returns and previously committed documents remain present

### Requirement: Single active instance

The deployment SHALL run at most one vault service pod at any time, so that two processes never write the same database volume concurrently.

#### Scenario: Rolling update or reschedule

- **WHEN** the pod is replaced by a rollout, a manual restart, or a node drain
- **THEN** the previous pod terminates before the replacement starts
- **AND** the rendered deployment does not allow two replicas to overlap

### Requirement: Idempotent initialisation

Database creation, the vault user, and CORS configuration SHALL be applied on every pod start in a way that is safe to repeat, without resetting existing data or failing when the objects already exist.

#### Scenario: First start on empty storage

- **WHEN** the pod starts with an empty volume
- **THEN** the vault database and vault user are created
- **AND** the service is ready to replicate

#### Scenario: Restart with existing data

- **WHEN** the pod restarts with an initialised volume
- **THEN** initialisation succeeds without error
- **AND** existing documents are unchanged

### Requirement: Secrets only from sealed secrets

Administrative credentials and the vault user password SHALL reach the pod only from cluster `Secret`s unsealed from committed `SealedSecret`s. No plaintext credential SHALL appear in the repository or in rendered manifests.

#### Scenario: Fresh deployment unseals credentials

- **WHEN** the application is synced to a cluster where the `SealedSecret` has not been applied before
- **THEN** the controller unseals it into the expected `Secret`
- **AND** the pod authenticates with those credentials

#### Scenario: No plaintext secret in git

- **WHEN** the change and the rendered manifests are reviewed
- **THEN** the only credential artifacts are `SealedSecret` resources
- **AND** no password value appears in any committed file

### Requirement: Least-privilege runtime

The container SHALL run as a non-root user with no privilege escalation, all Linux capabilities dropped, and a read-only root filesystem whose only writable paths are the data volume and a temporary directory.

#### Scenario: Pod admitted under the namespace policy

- **WHEN** the pod is created in a namespace that enforces the baseline Pod Security Standard
- **THEN** it is admitted without violations

#### Scenario: Writes outside the volume fail

- **WHEN** the process attempts to write outside the data volume and temporary directory
- **THEN** the write fails rather than persisting

### Requirement: GitOps-managed lifecycle

The service SHALL be delivered by Argo CD from this repository through an `Application` in the `apps` project that points at the app directory and is registered in the parent kustomization, with automated sync, self-healing, and pruning disabled.

#### Scenario: Sync to a clean cluster

- **WHEN** Argo CD syncs the application against a cluster without the namespace or workload
- **THEN** it creates the namespace with the standard pod security labels, the sealed secrets, the volume claim, the deployment, the service, and the tailnet `Ingress`

#### Scenario: Drift is corrected

- **WHEN** the live deployment is edited outside git
- **THEN** Argo CD reverts it on the next reconcile

#### Scenario: App is removed from git

- **WHEN** the app's `app.yml` line is removed from the parent kustomization
- **THEN** Argo CD stops managing the application but does not delete its resources, matching the repo-wide no-prune policy

### Requirement: Health monitoring reflects authentication state

A Gatus endpoint SHALL report the service healthy only when it answers and unauthenticated access is refused, so that a service accepting anonymous access is reported as unhealthy rather than healthy.

#### Scenario: Healthy and locked

- **WHEN** Gatus probes the in-cluster service and receives the expected refusal for an unauthenticated request
- **THEN** the endpoint is reported healthy

#### Scenario: Service is down

- **WHEN** the pod is not serving requests
- **THEN** the endpoint is reported unhealthy

#### Scenario: Authentication is misconfigured

- **WHEN** the service answers an unauthenticated request with success instead of a refusal
- **THEN** the endpoint is not reported healthy
