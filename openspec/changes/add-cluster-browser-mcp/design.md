# Design

## Context

See `proposal.md` — Why. What shapes the approach:

- The repo is GitOps YAML only; Argo CD app-of-apps reconciles `apps/` with `selfHeal: true`
  and `prune: false`. Adding a directory plus one resource line is the whole deployment
  mechanism.
- The Tailscale operator serves every app through `ingressClassName: tailscale`. One Ingress
  becomes one tailnet device, named from `spec.tls.hosts[0]`, carrying the tag in
  `tailscale.com/tags`. `tag:apps` is already reachable by `group:app-users`, `group:admins`,
  and — importantly — by `tag:ai` over `tcp:443`, which is how the Aperture host will reach an
  MCP endpoint inside the cluster.
- Aperture on `ai` is an MCP aggregator: it dials upstream MCP servers with its tailnet HTTP
  client and re-publishes everything at `http://ai.beaver-cloud.ts.net/v1/mcp`, prefixing tool
  names with the connector id. `group:ai-admins` and `tag:dev` already hold
  `{"connectors": ["**"]}`, so a new connector needs no ACL change.
- The only StorageClass is `zfs-generic-nvmeof-csi` (democratic-csi zvols on `drone-04`,
  exported over NVMe-oF/TCP).
- The nodes have no GPU.
- `components/app-pod-hardening` assumes a non-root user and a read-only rootfs. LinuxServer.io
  images start as root, chown their volume and then drop to `PUID`/`PGID`, so they cannot use
  it. Several existing apps already skip it (`jellyfin`, `omada`, `scrypted`, `calibre`).

## Goals / Non-Goals

**Goals:**

- An agent can drive a real, JavaScript-capable browser using standard MCP tool calls.
- A person can watch that same browser live and take over input without coordinating
  anything, and without a second browser to keep in sync.
- Sessions survive pod replacement through a persistent profile.
- The MCP endpoint plugs into Aperture as one connector, reachable by every agent that
  already talks to the gateway.
- The credential surface stays small: the container that runs agent-chosen code never sees
  the browser profile.

**Non-Goals:**

- Per-agent or per-session browser isolation.
- Authentication or authorization stronger than tailnet identity.
- GPU acceleration, WebGL, video playback, or multi-viewer streaming quality.
- Backing up or migrating the browser profile.
- Replacing the user's own browser for personal browsing.

## Decisions

**Playwright MCP attached to a running Chrome over CDP, rather than a browser of its own.**
Playwright MCP can launch its own Chromium, but then nobody sees it, its profile is a
throwaway directory, and the "watch and control the same session" requirement is unmeetable.
`--cdp-endpoint` instead makes it attach to the browser the person is looking at, so both
share one set of tabs. Alternatives rejected: `browserless/chromium` (its `/live` view is a
screencast, not a usable desktop, and the image is not licence-clean), Selenium standalone
plus noVNC (no first-class MCP server), `n.eko` (WebRTC needs UDP media that does not survive
a single-TLS ingress, and it has no MCP story).

**LinuxServer.io `chrome` as the browser host, streamed with Selkies.** It runs a real
headful Chrome in an X session, streams it over a WebSocket to a normal tab, and accepts
extra Chrome flags through `CHROME_CLI`, which is what turns on the CDP port. This exact
combination (LSIO chrome + CDP + Playwright MCP) is what [exe.dev's cloud-browser
recipe](https://exe.dev/deploy/cloud-browser) ships, so the interaction is proven. The older
`linuxserver/chromium` image (KasmVNC) works too and is the fallback if Selkies misbehaves
behind the Tailscale proxy.

**One pod with two containers, not two Deployments.** Chromium has forced
`--remote-debugging-address` to loopback since M113, so the CDP port cannot be reached across
pods without a `socat`/nginx hop that rewrites the WebSocket URLs Chrome hands out. Containers
in one pod share a network namespace, so `127.0.0.1:9222` just works and no proxy is needed.

**Two Ingresses, one hostname each.** `/` and `/mcp` path-splitting on a single host would put
Selkies' WebSocket upgrade behind a path prefix, which its own documentation warns about.
Two tailnet devices also keep the ACL surface per endpoint.

**The profile PVC is mounted only in the browser container, and the pod mounts no
service-account token.** Playwright MCP exposes a code-execution tool that is RCE-equivalent
inside its own container. Denying that container the profile volume and the SA token is the
cheap way to keep the blast radius at "attacker controls a browser tab".

**`replicas: 1` with `strategy: Recreate` and a long grace period.** A Chrome profile is
single-writer; two pods would corrupt it. LSIO has shipped a graceful-shutdown script since
August 2025, so the 60 s grace period is enough to flush cookies instead of losing them to
SIGKILL.

**`--allowed-hosts` names the two real hostnames instead of `*`.** The Tailscale proxy
forwards the public `Host`, which the server's DNS-rebinding guard would otherwise reject, so
the hostnames must be listed — but listing them keeps the guard intact, unlike `*`.

**Aperture connector rather than per-agent MCP configuration.** It gives one endpoint, reuses
grants that already exist, and means any future agent pointed at the gateway inherits the
browser automatically.

**Image digests pinned in the manifests.** Renovate then tracks both images like every other
app, and a Chrome update cannot silently land without a matching MCP bump being reviewable.

Deliberate deviations from repo convention, all recorded so review does not flag them as
mistakes: two containers named `browser` and `mcp` instead of one named `app`, both Services
are named `ui-service`/`mcp-service` (prefixing yields `browser-ui-service` and
`browser-mcp-service`), and `app-pod-hardening` is not used.

## Risks / Trade-offs

- **A prompt-injected page steers an agent that is signed into something valuable** →
  low-value accounts only in this profile; real logins stay on the workstation; the profile
  is not mounted where agent code runs. Adding `CUSTOM_USER`/`PASSWORD` on the streamed view
  is a later hardening step.
- **The MCP code-execution tool is RCE inside its container** → no profile, no SA token; a
  NetworkPolicy restricting the namespace to the Tailscale proxies and Gatus is the next
  increment if this worries you.
- **Any identity that can reach `tag:apps:443` can drive the browser directly, bypassing
  Aperture's grants** → accepted for now; the fix is a dedicated `tag:browser` in
  `kevindurb/infra`, which is a separate repository.
- **The streamed web UI includes a sudo-capable terminal inside the container** → the tailnet
  is the lock, as with every other app here; do not enable Funnel for it.
- **Software video encode (no GPU)** → fine for one viewer, bad for several; no WebGL.
- **Profile writes are many and small, over NVMe-oF/TCP** → acceptable, but an ungraceful
  node failure can leave a stale profile lock, which shows up as "profile in use by another
  computer". Recovery is deleting the `SingletonLock` files in the profile directory.
- **Version skew between Chrome and the pinned MCP server** → both are digest-pinned, so a
  Chrome bump that breaks CDP behaviour is a reviewable change; the symptom would be the MCP
  container failing to attach, visible in its logs and absent from Gatus only indirectly.
- **The connector is unauthenticated within the tailnet** → intended; it relies on the same
  boundary as the rest of the cluster's apps.

## Migration Plan

Deploy: merge the manifests; Argo syncs the `browser` namespace. Verify in order — streamed
view answers, CDP answers on `127.0.0.1:9222`, MCP tool list returns — then add the Aperture
connector and confirm it lists as `ready` before telling agents about it. Ordering matters:
adding the connector first would give agents a tool that silently fails until the app is up.

Rollback: remove the connector from Aperture first so agents stop seeing `Browser_*` tools,
then drop the resource line from `apps/kustomization.yml` and delete the Argo CD Application
manually. Because `prune: false`, the namespace, PVC and Ingresses survive and must be
deleted explicitly. There is no data to migrate; the profile starts empty.

## Open Questions

- The exact profile directory name inside the LSIO image, for automating stale-lock cleanup.
  Deferrable: recovery stays a documented manual step, and LSIO's shutdown script handles the
  common case.
- Whether the current LSIO entrypoint parses `CHROME_CLI` flags before a start URL. Deferrable:
  confirm at apply time; the fallback is a bookmark or a separate start-page argument.
