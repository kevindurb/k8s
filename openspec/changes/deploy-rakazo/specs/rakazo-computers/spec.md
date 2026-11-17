# Spec Delta

## Purpose

Give Rakazo bots a disposable computer — a Kubernetes sandbox Pod with a browser and a shell — while keeping the controller's authority, the Pods' shape and their network reach inside a boundary the cluster enforces.

## ADDED Requirements

### Requirement: Computers are disposable Pods in a dedicated namespace

The deployment SHALL run bot computers as Pods in a namespace separate from the application, created on demand when a bot needs a computer and removed when the session ends. The application namespace MUST NOT host computer Pods.

#### Scenario: A bot starts a computer

- **WHEN** a signed-in user opens the computer for a bot or sends a message that needs it
- **THEN** a computer Pod is created in the sandbox namespace
- **AND** the app namespace contains no such Pod

#### Scenario: The session ends

- **WHEN** the computer is stopped, times out, or its run finishes
- **THEN** the computer Pod is deleted
- **AND** no NodePort, Service of type LoadBalancer, or host path survives it

### Requirement: Controller authority is limited to the sandbox namespace

The controller identity SHALL hold only a namespaced role that permits creating, reading and deleting Pods and opening exec sessions in the sandbox namespace. It MUST NOT hold cluster-wide Pod permissions, permissions in the application namespace, or any secret-reading permission in the sandbox namespace.

#### Scenario: Controller acts on a computer

- **WHEN** the controller creates a computer Pod and opens an exec session into it
- **THEN** the API server authorizes the request through the namespaced role

#### Scenario: Controller exceeds its role

- **WHEN** the controller attempts to read secrets, create Pods in another namespace, or delete application Pods
- **THEN** the API server denies the request

### Requirement: Admission pins the computer image and shape

Pod creation in the sandbox namespace SHALL be denied unless the Pod runs exactly one container with the configured computer image, carries no init or ephemeral containers, no volumes, no host namespaces, no host ports, no service-account token, no Secret-sourced environment, no privilege escalation, and all capabilities dropped under the default seccomp profile.

#### Scenario: Expected computer Pod is admitted

- **WHEN** the controller creates a Pod matching the configured computer image and shape
- **THEN** admission allows it

#### Scenario: Pod carrying a volume is denied

- **WHEN** a Pod in the sandbox namespace requests a volume or a host path
- **THEN** admission denies it and names the boundary

#### Scenario: Image is not the pinned one

- **WHEN** a Pod in the sandbox namespace requests any image other than the configured computer image
- **THEN** admission denies it

#### Scenario: Pod reads a Secret

- **WHEN** a Pod in the sandbox namespace references a `Secret` through an environment variable or `envFrom`
- **THEN** admission denies it

### Requirement: Capacity is bounded

The sandbox namespace SHALL cap concurrent computers and the resources each may request, and a request beyond the cap SHALL fail with a reported error rather than queueing without bound.

#### Scenario: Cap is reached

- **WHEN** the maximum number of computers is already running and another is requested
- **THEN** the extra Pod is refused
- **AND** the user sees a failure rather than a silently stuck session

#### Scenario: Resources are capped

- **WHEN** a computer Pod is scheduled
- **THEN** it receives at most the configured CPU and memory request and limit

### Requirement: Computer egress is public-web only

Computers SHALL resolve DNS and reach public HTTP(S) destinations, and MUST NOT reach node addresses, the cluster API, the application namespace, the database, or private, link-local and metadata address ranges. IPv6 egress SHALL NOT be allowed.

#### Scenario: Public site is reachable

- **WHEN** a bot browses a public website from its computer
- **THEN** the request succeeds

#### Scenario: Cluster API is unreachable

- **WHEN** a bot inside its computer connects to the cluster API address or a private-range address
- **THEN** the connection is refused or times out

#### Scenario: Application database is unreachable

- **WHEN** a bot inside its computer connects to the database port in the application namespace
- **THEN** the connection is refused

### Requirement: Screen access is limited to the application

A computer's screen and control ports SHALL accept connections only from the application workloads, and MUST NOT be reachable from the LAN, the tailnet directly, or unrelated namespaces.

#### Scenario: App renders the desktop

- **WHEN** the user opens the computer pane in the app
- **THEN** the web workload reaches the computer's screen port through the allowed path
- **AND** the resulting frame is authorized by the app, not by network position

#### Scenario: Unrelated pod connects to a screen port

- **WHEN** a pod outside the application namespace connects to a computer's screen or control port
- **THEN** the connection is refused

### Requirement: Unsaved computer state is not guaranteed

A computer's home SHALL be restored from the bot's saved checkpoint when a computer starts and saved back when it stops in an orderly way; changes made after the last checkpoint MAY be lost if the Pod disappears abruptly. The deployment SHALL NOT mount persistent volumes into computer Pods.

#### Scenario: Orderly stop preserves files

- **WHEN** a computer is stopped normally after writing files
- **THEN** the next computer for that bot starts with those files present

#### Scenario: Abrupt loss

- **WHEN** a computer Pod is deleted abruptly or its node fails
- **THEN** the bot's next computer starts from the last saved checkpoint
- **AND** changes since that checkpoint may be missing
