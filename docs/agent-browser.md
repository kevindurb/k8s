# Agent browser

Status: **added (2026-11-17)**. A headful Chrome runs in `apps/browser`, streamed to a
normal browser tab and driven by Microsoft's [Playwright MCP](https://github.com/microsoft/playwright-mcp)
over the Chrome DevTools Protocol. You watch and can take over the same session you are
watching, and agents reach the same browser through Aperture's aggregated MCP endpoint.

This is deliberately **not** the [Browse extension](https://opencode.ai/product/browse): that
is a Chrome extension plus a loopback relay plus a stdio MCP proxy, with no server mode, no web
UI and no HTTP MCP transport, so it cannot live in the cluster or behind Aperture. Browse still
belongs on the workstation, where it drives a browser that has your real logins.

## What runs

One pod, two containers, in namespace `browser`:

| Container | Image | Serves |
| --- | --- | --- |
| `browser` | `lscr.io/linuxserver/chrome` | a headful Chrome streamed by Selkies on port 3000, profile in `/config` on PVC `browser-data`; CDP on `127.0.0.1:9222` |
| `mcp` | `mcr.microsoft.com/playwright/mcp` | Streamable HTTP MCP on port 8931, attached to the browser with `--cdp-endpoint` |

The two containers share the pod network namespace, so the loopback-only CDP listener is
reachable by the MCP server without any proxy. The MCP container does not mount `/config` and
the pod sets `automountServiceAccountToken: false`, so code an agent talks the MCP server into
running cannot read the browser's cookies.

## Addresses

| URL | Who uses it |
| --- | --- |
| `https://browser.beaver-cloud.ts.net` | you: watch the browser, sign in, take over input |
| `https://browser-mcp.beaver-cloud.ts.net/mcp` | direct MCP clients, and Aperture's upstream |
| `http://ai.beaver-cloud.ts.net/v1/mcp` | agents: every Aperture connector, browser included |

Both Ingresses are `ingressClassName: tailscale` with `tailscale.com/tags: tag:apps`, so
reachability is whatever the tailnet policy already allows for `tag:apps`.

## The Aperture connector

Add this entry to `connectors.servers` in the gateway configuration (`/admin/settings/config`,
or the API):

```json
"Browser": {
  "protocol": "mcp",
  "url": "https://browser-mcp.beaver-cloud.ts.net/mcp",
  "provider": "Custom",
  "description": "Headful Chrome on the cluster. Watch it at https://browser.beaver-cloud.ts.net."
}
```

Connector IDs may contain only letters and digits, so the tool names appear prefixed:
`Browser_browser_navigate`, `Browser_browser_snapshot`, and so on. Aperture strips the prefix
before forwarding.

`tailnet/policy.hujson` grants `group:ai-admins`, `tag:dev` and (since PR #15) `tag:k8s-ai`
`{"connectors": ["**"]}`, the gateway configuration carries a matching grant, and
`{"src": ["tag:ai"], "dst": ["tag:apps", "tag:media"], "ip": ["tcp:443"]}` lets the gateway reach
the endpoint. `tag:pr-agent` and `tag:ci` hold no connector grants, so neither reaches it.

`tag:k8s-ai` is what in-cluster apps leave as (Rakazo, mealie's recipe AI), so that grant is what
lets a bot reach this browser through `http://ai.beaver-cloud.ts.net/v1/mcp`. It is also shared with
every other ai-egress caller, and `["**"]` covers Aperture's other connectors too - including
`TailnetSSH_run_command`. Narrow the list to the browser connector if a bot should not have a shell
on the tailnet.

## Apply the connector

Back up, then edit (same optimistic-concurrency procedure as `docs/pr-agent.md`):

```sh
curl -fsS http://ai.beaver-cloud.ts.net/api/config > aperture-config-backup.json
jq -r '.hash' aperture-config-backup.json
jq -r '.config' aperture-config-backup.json > aperture-config.hujson
# insert the "Browser" entry under connectors.servers in aperture-config.hujson
```

```sh
HASH=$(curl -fsS http://ai.beaver-cloud.ts.net/api/config | jq -r '.hash')
jq -n --rawfile config aperture-config.hujson --arg hash "$HASH" '{config: $config, hash: $hash}' \
  | curl -fsS -X PUT http://ai.beaver-cloud.ts.net/api/config \
      -H 'Content-Type: application/json' -d @-
```

## Verify

```sh
curl -fsS https://ai.beaver-cloud.ts.net/api/connectors | jq '.connectors[] | select(.id=="Browser")'
```

Expect a `"protocol": "mcp"` entry reporting `"status": "ready"`. Then, from an agent already
pointed at `http://ai.beaver-cloud.ts.net/v1/mcp`, list tools and confirm the `Browser_*`
names are present, and call `Browser_browser_navigate` with a URL. The page changes in the
streamed tab while you watch it.

If the connector reports `upstream error`, the MCP container is not answering: check
`kubectl -n browser logs deploy/browser-app-deployment -c mcp` for a CDP attach failure, and
`curl -s localhost:9222/json/version` through a port-forward.

If the Gatus check fails after a `gatus.yml` edit, look for a stale generated ConfigMap:
`kubectl -n browser get cm | grep gatus`. The app-of-apps has `prune: false`, so the previous
hash-suffixed copy survives and keeps defining the old endpoint alongside the new one. Delete
it by hand.

## Rollback

1. Remove the `Browser` connector from the gateway (or restore `aperture-config-backup.json`
   with the same `PUT` shape). Agents lose the tools on their next tool refresh.
2. Remove `./browser/app.yml` from `apps/kustomization.yml` and delete the Argo CD
   `Application` named `browser`. Because the app-of-apps has `prune: false`, the namespace,
   PVC and Ingresses survive; delete namespace `browser` explicitly.

## Cautions

- This profile is for **low-value accounts only**. A page can steer an agent, and the agent
  drives a browser you are signed into. Your real logins belong in Browse on your workstation.
- Anything that can reach `tag:apps:443` can drive the browser directly, bypassing Aperture's
  connector grants. Narrowing that needs a dedicated `tag:browser` in `kevindurb/infra`.
- Playwright MCP's code-execution tool is RCE-equivalent inside the `mcp` container. It has no
  profile volume and no service-account token, which is the mitigation in place.
- The streamed desktop includes a terminal with passwordless `sudo` inside the container, so
  the tailnet is the only lock. Never enable Funnel for this app.
- One viewer only: there is no GPU, so the stream is encoded in software, and WebGL is
  unavailable.
- A single replica is mandatory — one profile has one writer. A `clear-stale-profile-lock`
  init container removes `Singleton*` from the profile before each start, because a
  replaced pod otherwise leaves a lock naming the old host and Chrome refuses to start. If
  Chrome is still stuck, delete those files under `/config/profile` by hand.
