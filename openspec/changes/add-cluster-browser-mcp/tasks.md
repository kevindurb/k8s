# Tasks

## 1. Scaffold the app

- [x] 1.1 Run `just tmpl apps browser` and confirm `apps/browser/` contains `app.yml`, `kustomization.yml`, `deployment.yml` and `gatus.yml`, and that `kustomize build apps/browser` succeeds before any edits
- [x] 1.2 Register the app with `kustomize edit add resource browser/app.yml` in `apps/kustomization.yml` and confirm `kustomize build apps` output contains an Application named `browser` pointing at path `apps/browser`
- [x] 1.3 Resolve current digests for `lscr.io/linuxserver/chrome` and `mcr.microsoft.com/playwright/mcp` with `skopeo inspect --format '{{.Digest}}' docker://<ref>` (or the registry API) and confirm each digest resolves to a manifest

## 2. Deployment, services and storage

- [x] 2.1 Rewrite `apps/browser/deployment.yml`'s Deployment as a two-container pod: `replicas: 1`, `strategy: Recreate`, `terminationGracePeriodSeconds: 60`, `automountServiceAccountToken: false`, and a 1Gi memory-backed `emptyDir` named `shm`; verify `kustomize build apps/browser` renders one Deployment with these fields
- [x] 2.2 Configure the `browser` container — pinned digest, `PUID=1000`, `PGID=1000`, `TZ=America/Denver`, `CHROME_CLI` enabling `--remote-debugging-port=9222`, `/config` on the `data` claim, `shm` at `/dev/shm`, `http` port 3000 with a TCP readiness probe, requests 200m/512Mi and limits 1/2Gi; verify the rendered container shows each value and mount
- [x] 2.3 Configure the `mcp` container — pinned digest, args `--cdp-endpoint http://127.0.0.1:9222 --port 8931 --host 0.0.0.0 --allowed-hosts browser-mcp.beaver-cloud.ts.net,browser-mcp.browser`, `mcp` port 8931 with a TCP readiness probe, no `/config` mount and no `--isolated`; verify the rendered args and that the profile volume appears in exactly one container
- [x] 2.4 Declare the `data` PVC (5Gi, `zfs-generic-nvmeof-csi`) and the two Services — `ui-service` on 3000 and `mcp-service` on 8931, both with port name `http`; verify the rendered names are `browser-ui-service` and `browser-mcp-service` with the expected ports

## 3. Routing and observability

- [x] 3.1 Add both Ingresses with `ingressClassName: tailscale`, `tailscale.com/proxy-group: ingress-proxy-group`, `tailscale.com/tags: tag:apps`, and `tls.hosts` of `browser` and `browser-mcp` respectively; verify the rendered Ingresses carry those annotations and backends, and that `kustomize build apps/browser` still succeeds
- [x] 3.2 Point `apps/browser/gatus.yml` at `http://browser-ui-service.browser` with `[STATUS] == 200`, keeping the generator entry labelled `gatus.io/enabled: 'true'`; verify the rendered ConfigMap carries that label and a `browser.yml` key
- [x] 3.3 Add a `Browser` item to `apps/homer/config/config.yml` linking to `https://browser.beaver-cloud.ts.net`; verify the item renders in `kustomize build apps/homer` and that `just check-kustomize` passes for the whole repo
- [x] 3.4 Run `just check-kustomize` and `yamllint` over the changed files and confirm both are clean (documents start with `---`, lines under 150 characters, no trailing whitespace)

## 4. Deploy and verify on the cluster

- [x] 4.1 Merge so Argo syncs, then confirm `kubectl -n browser get deploy,pod,svc,ing,pvc` shows a ready Deployment, a Running single pod, both Ingresses with tailnet addresses, and a Bound claim
- [ ] 4.2 Open `https://browser.beaver-cloud.ts.net` from the workstation and confirm the Selkies client loads and shows a Chrome window, which verifies the streamed view
- [x] 4.3 Port-forward 9222 from the pod and confirm `curl -s localhost:9222/json/version` returns Chrome's version, proving CDP is listening on loopback
- [x] 4.4 List tools against `https://browser-mcp.beaver-cloud.ts.net/mcp` from the workstation and confirm the browser tool set is returned; confirm `kubectl -n browser logs -c mcp` shows no CDP attach errors
- [x] 4.5 Drive a page from that client and confirm the same navigation appears in the streamed view, verifying that both share one browser session
- [ ] 4.6 Sign into one low-value site in the streamed view, delete the pod, and confirm the new pod restores the signed-in session, verifying profile persistence across replacement
- [x] 4.7 Confirm the Gatus status page reports the browser endpoint healthy and the Homer entry opens the streamed view

## 5. Aperture connector (documented, operator-applied)

- [x] 5.1 Write `docs/agent-browser.md` covering the connector JSON (`Browser`, protocol `mcp`, url `https://browser-mcp.beaver-cloud.ts.net/mcp`, provider `Custom`), the `/api/config` backup and optimistic-concurrency `PUT` procedure, the verification commands, and rollback; verify each documented command is copy-pasteable and that the `jq` selector matches the shape returned by `https://ai.beaver-cloud.ts.net/api/connectors`
- [ ] 5.2 Apply the connector on `ai` following that document, then confirm `curl -fsS https://ai.beaver-cloud.ts.net/api/connectors | jq '.connectors[] | select(.id=="Browser")'` reports `"status": "ready"`
- [ ] 5.3 From an agent already using `http://ai.beaver-cloud.ts.net/v1/mcp`, call `Browser_browser_navigate` and confirm the page changes in the streamed view, verifying the aggregation and prefixing requirement
- [ ] 5.4 From an identity whose grants omit the browser connector (for example a `tag:pr-agent`-scoped credential, or by inspecting the tool list of a non-granted client), confirm `Browser_*` tools are absent, verifying the grant boundary

## Workflow follow-up

- Review the rendered manifests and the Aperture document with the user before archiving.
- Archive the change with `/opsx-archive` once verification tasks 4.1–4.7 and 5.2–5.4 are complete.
