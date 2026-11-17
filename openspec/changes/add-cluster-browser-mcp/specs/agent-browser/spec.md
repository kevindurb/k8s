# Spec Delta

## Purpose

Give agents a browser they can drive over MCP while a person watches and steers the same
session in a tab, with the browser's saved credentials kept out of reach of the MCP server
that drives it.

## ADDED Requirements

### Requirement: MCP browser surface

The deployment SHALL expose a Model Context Protocol endpoint over HTTP at the tailnet host
`browser-mcp` on path `/mcp`, offering tools to navigate, snapshot, click, type, screenshot,
and read console and network activity of the browser. A client SHALL need nothing beyond
tailnet reachability to use it.

#### Scenario: Client lists the browser tools

- **WHEN** an MCP client connects to `https://browser-mcp.beaver-cloud.ts.net/mcp`
- **THEN** the server returns the browser tool set, including navigation, snapshot, click, typing and screenshot tools

#### Scenario: Client connects through the public tailnet hostname

- **WHEN** a client connects using the tailnet hostname rather than `localhost`
- **THEN** the request is accepted instead of being refused by the server's host check

### Requirement: One browser, observable and steerable by a person

The MCP server MUST drive the same browser instance that is streamed to the human view, so a
person can watch every navigation, click and keystroke as it happens and can take over
input at any moment.

#### Scenario: Watching an agent work

- **WHEN** an agent navigates and clicks using the MCP tools
- **THEN** the streamed view shows the same page state within streaming latency
- **AND** tabs opened by the agent appear in that view

#### Scenario: A person intervenes mid-task

- **WHEN** a person types or clicks in the streamed view while the agent is idle on a page
- **THEN** the browser reflects the person's input
- **AND** the agent's next call operates on the state the person left behind

### Requirement: Profile persistence

The browser profile SHALL live on a persistent volume so that a replaced, rescheduled or
drained pod returns with its cookies, storage and signed-in sessions intact.

#### Scenario: Pod is replaced by an image update

- **WHEN** the Deployment rolls out a new revision
- **THEN** previously authenticated sites remain signed in without re-authentication

#### Scenario: Rendering shows durable storage

- **WHEN** the rendered manifests are inspected
- **THEN** the browser's profile directory is backed by a PersistentVolumeClaim

### Requirement: Credential boundary around the browser profile

The MCP server container SHALL NOT mount the browser profile volume and SHALL NOT receive a
Kubernetes service-account token, so that code the server executes cannot read the browser's
cookies or stored passwords.

#### Scenario: Rendering shows the boundary

- **WHEN** the rendered manifests are inspected
- **THEN** only the browser container mounts the profile volume
- **AND** the pod disables service-account token mounting

#### Scenario: Agent runs code inside the MCP server

- **WHEN** an agent invokes the code-execution tool against the MCP server
- **THEN** the browser profile is not present in that container's filesystem

### Requirement: Tailnet-only reachability

Both endpoints SHALL be published only through the Tailscale ingress, tagged for the
application ACLs, and MUST NOT be exposed on the LAN, on the cluster network, or publicly.

#### Scenario: Request from outside the tailnet

- **WHEN** a host that is not a member of the tailnet requests either hostname
- **THEN** the request never reaches the deployment

#### Scenario: Rendering shows the routing

- **WHEN** the rendered manifests are inspected
- **THEN** both Ingresses use the `tailscale` ingress class and carry the `tag:apps` annotation
- **AND** no other Ingress, LoadBalancer Service or Funnel configuration publishes these ports

### Requirement: Aggregation through Aperture

The browser tools SHALL be available through Aperture's aggregated MCP endpoint, prefixed
with the connector identifier, so that clients already pointed at the gateway gain the
browser without per-agent configuration, and so that access stays governed by the
gateway's connector grants.

#### Scenario: Granted client sees the tools

- **WHEN** a client holding a connector grant lists tools at `http://ai.beaver-cloud.ts.net/v1/mcp`
- **THEN** browser tools appear with the `Browser_` prefix
- **AND** invoking them drives the cluster browser

#### Scenario: Ungranted client is refused

- **WHEN** a client whose grants omit the browser connector lists tools or calls one of them
- **THEN** the tools are absent from its listing and calls are rejected

### Requirement: Single active browser instance

The Deployment SHALL run exactly one replica and SHALL stop the existing pod before starting
its replacement, because one profile can only be open by one browser process at a time.

#### Scenario: Rolling update

- **WHEN** a new revision is applied
- **THEN** the previous pod terminates before the replacement starts
- **AND** no second browser process opens the same profile concurrently

### Requirement: Operational visibility

The deployment SHALL be covered by the status page and the dashboard, so a broken browser or
a broken stream is noticed without reading logs.

#### Scenario: Status page reflects the stream

- **WHEN** the monitoring check for the browser endpoint runs
- **THEN** it reports healthy while the streamed view answers and unhealthy when it does not

#### Scenario: Dashboard links to the view

- **WHEN** the user opens the Homer dashboard
- **THEN** an entry links to the streamed browser view
