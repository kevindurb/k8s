# Spec Delta

## Purpose

Run Rakazo — a self-hosted platform for persistent AI bots — inside the homelab cluster behind the tailnet, with its database, bot state and model traffic staying on infrastructure the operator controls.

## ADDED Requirements

### Requirement: Tailnet-only HTTPS origin

The deployment SHALL serve the web application at exactly one HTTPS origin, `https://rakazo.beaver-cloud.ts.net`, reachable only through the Tailscale ingress proxies. It MUST NOT expose a public Funnel listener, a LAN listener, a NodePort, or an unauthenticated cluster listener.

#### Scenario: Tailnet device opens the app

- **WHEN** a tailnet device requests `https://rakazo.beaver-cloud.ts.net`
- **THEN** the request is served by the web workload through the shared Tailscale ingress proxy group
- **AND** the certificate is the tailnet certificate for that hostname
- **AND** the rendered manifests contain no Funnel annotation, NodePort, LoadBalancer, or hostPort

#### Scenario: Cluster-internal client reaches the app namespace

- **WHEN** a pod outside the `rakazo` namespace, other than a Tailscale ingress proxy or Gatus, requests the web workload
- **THEN** the connection is denied by policy

### Requirement: Single owner account with closed signups

The deployment SHALL keep public registration disabled and SHALL create exactly one owner account, for the address configured as the owner email, during deployment. That account SHALL be able to sign in with its sealed password or, once linked, with Pocket ID. No other account SHALL be created by any path, including SSO.

#### Scenario: Owner account exists after deploy

- **WHEN** the bootstrap step completes
- **THEN** an account exists for the configured owner email
- **AND** it can sign in with the sealed owner password

#### Scenario: Signup is refused

- **WHEN** an unauthenticated visitor attempts to register a new account with a password
- **THEN** registration is refused
- **AND** the app still serves its sign-in page

#### Scenario: SSO does not create an account

- **WHEN** a Pocket ID identity that no Rakazo account is linked to signs in
- **THEN** no Rakazo account is created or linked
- **AND** the sign-in fails

#### Scenario: Unauthenticated request to an application path

- **WHEN** a client without a session requests an application page or API path
- **THEN** it is refused or redirected to sign-in rather than served application data

### Requirement: Pocket ID single sign-on

The deployment SHALL offer OpenID Connect sign-in against Pocket ID at `https://idp.beaver-cloud.ts.net`
as its only SSO provider, using authorization code with PKCE and the redirect URI
`https://rakazo.beaver-cloud.ts.net/api/auth/callback/oidc`. The client secret MUST come from a sealed
secret and MUST be mounted on the API only.

#### Scenario: Linked owner signs in through Pocket ID

- **WHEN** the owner, whose account is linked to their Pocket ID identity, chooses the `Pocket ID` button and authenticates at the provider
- **THEN** the browser returns to the app's callback URI and the session is signed in as the owner
- **AND** no password is requested

#### Scenario: Provider identity is not linked

- **WHEN** an authenticated Pocket ID user whose identity is not linked to any account completes the provider flow
- **THEN** the app refuses the sign-in instead of creating or silently linking an account

#### Scenario: Provider is unavailable

- **WHEN** Pocket ID discovery or its token endpoint is unreachable
- **THEN** the SSO sign-in reports a temporary error
- **AND** password sign-in with the sealed owner password still works

#### Scenario: Secret placement

- **WHEN** the rendered manifests are inspected
- **THEN** the OIDC client secret is referenced only by the API workload
- **AND** the worker and web workloads carry no OIDC client secret value

#### Scenario: Discovery matches the configured issuer

- **WHEN** the app loads `https://idp.beaver-cloud.ts.net/.well-known/openid-configuration`
- **THEN** the document's issuer equals the configured issuer
- **AND** the signing keys it advertises validate the ID tokens the app receives

### Requirement: Anonymous health probe

The deployment SHALL expose an unauthenticated health probe that reports both the web proxy and the API as reachable, and the status page SHALL check it.

#### Scenario: Health probe answers without a session

- **WHEN** the status page requests the health path from inside the cluster
- **THEN** the response is `200` and carries a JSON body
- **AND** the check does not require a session or a bearer capability

#### Scenario: API is down

- **WHEN** the API workload is unavailable
- **THEN** the health probe fails and the status page reports the app unhealthy

### Requirement: GitOps delivery with ordered database steps

The app SHALL be delivered by Argo CD from this repository, with automated sync and self-healing and with pruning disabled. The schema migration MUST complete before the application workloads are started, and owner bootstrap MUST run only after the workloads are healthy.

#### Scenario: Sync from a clean cluster

- **WHEN** Argo CD syncs the app against a cluster with neither namespace nor workload
- **THEN** it creates the namespace with the standard pod security labels, the secret, the volumes, the database, then the migration step, then the workloads, then bootstrap

#### Scenario: Migration fails

- **WHEN** the migration step fails
- **THEN** the application workloads of that sync are not started
- **AND** the failure is visible on the Argo CD application

#### Scenario: Drift is corrected

- **WHEN** a live resource owned by the application is edited outside git
- **THEN** Argo CD reverts it on the next reconcile

#### Scenario: App is removed from git

- **WHEN** the application's line is removed from the parent kustomization
- **THEN** Argo CD stops managing it without deleting its resources

### Requirement: Durable state on cluster storage

The database, bot data and web assets SHALL each live on their own persistent volume so that replacing or rescheduling a pod preserves them, and the volumes SHALL survive pod deletion and node reboots. The two processes that write bot state MUST never run as two active writers against different copies of that state.

#### Scenario: Pod is rescheduled

- **WHEN** a workload pod is deleted and recreated, possibly on another node
- **THEN** it reattaches its existing volume
- **AND** previously stored bots, files and chat history are still present

#### Scenario: Database volume is retained

- **WHEN** the database pod is replaced through an image update or a restart
- **THEN** it reuses the existing database volume
- **AND** no migration or bootstrap is required again

### Requirement: Model traffic goes to the in-cluster gateway

The deployment's default model provider SHALL be an OpenAI-compatible endpoint served by the in-cluster Aperture gateway over the tailnet egress path, and the deployment SHALL NOT contain a hosted model credential.

#### Scenario: A bot run uses the gateway

- **WHEN** a bot answers a message using the deployment default model
- **THEN** the model request is sent to the gateway's OpenAI-compatible endpoint
- **AND** the gateway authorizes it by the caller's tailnet identity
- **AND** no model API key is required in the request

#### Scenario: Gateway refuses the model

- **WHEN** the gateway does not grant the configured model to the deployment's egress identity
- **THEN** the run reports a model error naming that failure
- **AND** no hosted provider is used as a fallback

#### Scenario: Gateway is unreachable

- **WHEN** the gateway cannot be reached
- **THEN** the run fails with a connection or timeout error
- **AND** the app itself stays healthy

### Requirement: Credentials only from sealed secrets

Every deployment secret SHALL be supplied from a cluster `Secret` unsealed from a committed `SealedSecret`; no plaintext password, encryption key or session secret SHALL appear in the repository.

#### Scenario: Secrets are unsealed

- **WHEN** the sealed secret is applied to the cluster
- **THEN** the controller unseals it into the secret the workloads reference
- **AND** the app, the database, the migration step and the bootstrap step read their values from it

#### Scenario: No plaintext secret is committed

- **WHEN** the change is reviewed in git
- **THEN** the only secret artifacts are `SealedSecret` objects and generated configuration
- **AND** the change artifacts contain no secret values

### Requirement: Separated database logins

The migration step SHALL connect with the database owner login, while the API and worker SHALL connect only with a restricted application login that cannot bypass row-level security or create objects.

#### Scenario: Runtime login is restricted

- **WHEN** the API or worker queries the database
- **THEN** it uses the application login
- **AND** that login cannot bypass row-level security, create objects, or act as superuser

#### Scenario: Migration uses the owner login

- **WHEN** the migration step runs
- **THEN** it connects with the owner login
- **AND** the application logins do not receive that credential

### Requirement: Bounded reachability for the app namespace

The app namespace SHALL deny ingress and egress by default. Only these flows are allowed: Tailscale ingress proxies and Gatus to the web workload, the web workload to the API and to the computer namespace, the workloads to the database, the API and worker to DNS, the gateway egress path, public HTTP(S), and the cluster API for the computer controller.

#### Scenario: Allowed flow works

- **WHEN** the web workload calls the API, or the API calls the database
- **THEN** the connection succeeds

#### Scenario: Unrelated namespace is refused

- **WHEN** a pod in an unrelated application namespace connects to the database port
- **THEN** the connection is refused

#### Scenario: Rendered policy matches the flows in use

- **WHEN** the rendered manifests are inspected
- **THEN** the namespace has a default-deny policy plus named allow policies for exactly the flows above

### Requirement: Digest-pinned matching release

Every Rakazo container SHALL run an image referenced by both tag and content digest, and the application image SHALL come from the same release as the configured computer image.

#### Scenario: Rendered image references

- **WHEN** the rendered workloads are inspected
- **THEN** each Rakazo container reference carries a tag and a `sha256:` digest
- **AND** the application release and the configured computer image release are the same version

#### Scenario: Digest update is unpaired

- **WHEN** an upgrade PR changes the application digest without the matching computer digest, or the reverse
- **THEN** the change is rejected in review rather than deployed
