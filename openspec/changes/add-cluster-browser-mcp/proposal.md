# Proposal

## Why

Agents can reason about the web here but cannot act on it: the cluster has no browser, so
anything that needs a real browser session — a dashboard behind a login, a form that only
exists client-side, a page that requires JavaScript — stops exactly where a person would
click. A browser that lives in the cluster closes that gap for every agent at once, and
because it can be viewed and driven by a person in a tab, it also gives a place to hand off
a login or a 2FA prompt and then watch what the agent does next.

The obvious candidate, the [Browse extension](https://opencode.ai/product/browse), cannot
serve this purpose. It is a Chrome extension plus a relay bound to `127.0.0.1:19988` plus a
stdio MCP proxy: it has no server mode, no web UI and no HTTP MCP transport, and its whole
premise is driving the *user's own* signed-in Chrome, which a cluster container does not
have. This change implements the same intent a different way.

## What Changes

- New `apps/browser` Argo CD application: a single-replica Deployment running a headful
  Chrome streamed to a browser tab, with its profile on a persistent volume so sessions
  survive pod replacement.
- A second container in the same pod: Microsoft's Playwright MCP server attached to that
  running Chrome over the Chrome DevTools Protocol, serving Streamable HTTP MCP at `/mcp`.
  It attaches to the existing browser rather than launching its own, which is what makes
  the agent and the person share one session.
- Two Tailscale Ingresses: `browser` for the streamed view people watch and steer, and
  `browser-mcp` for the MCP endpoint agents call.
- An Aperture `Browser` MCP connector pointing at `https://browser-mcp.beaver-cloud.ts.net/mcp`,
  so every client already talking to `http://ai.beaver-cloud.ts.net/v1/mcp` sees the browser
  tools as `Browser_*` with no per-agent configuration. This is a configuration change on
  the `ai` host and is documented rather than performed by this change.
- A Homer dashboard entry and a Gatus check, like every other app.
- Non-goals: no GPU acceleration, no multi-user or per-agent browser isolation, no
  replacement for the user's own browser. The cluster browser deliberately holds only
  low-value accounts; real logins stay on the workstation.

No existing behavior is removed or changed, so nothing here is **BREAKING**.

## Capabilities

### New Capabilities

- `agent-browser`: an agent-drivable browser hosted in the cluster — the MCP surface agents
  call, the human-observable view of the same session, the persistence and isolation
  boundaries around the profile, and the constraints on reachability.

### Modified Capabilities

None. The only existing capability, `tsgit`, is unrelated and its requirements do not change.

## Impact

- New files under `apps/browser/`, a new resource line in `apps/kustomization.yml`, and a
  link in `apps/homer/config/config.yml`.
- Creates the `browser` namespace (baseline pod-security labels via the standard `app.yml`),
  a `data` PVC on `zfs-local`, two Services and two Ingresses.
- Depends on: the Tailscale operator's `ingress-proxy-group` and the `tag:apps` ACLs, plus
  the existing `{"src": ["tag:ai"], "dst": ["tag:apps"], "ip": ["tcp:443"]}` grant so the
  Aperture host can reach the MCP endpoint.
- Outside this repository: the Aperture configuration on `ai` (`connectors.servers`). No
  `tailnet/policy.hujson` change is needed, because `group:ai-admins` and `tag:dev` already
  hold `{"connectors": ["**"]}`.
- Cost: roughly 0.5 GiB of RAM idle and more while a stream is open; video is encoded in
  software because the nodes have no GPU, so one viewer is comfortable and several are not.
- Security posture: one MCP tool is code-execution-equivalent inside its container, and the
  streamed desktop includes a sudo-capable terminal. The mitigations are the tailnet
  boundary, no PVC and no service-account token in the MCP container, and a profile that
  never holds credentials worth stealing.
- Renovate can follow both image digests like every other app.
