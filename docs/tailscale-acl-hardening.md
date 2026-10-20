# Tailscale ACL hardening

Status: **applied (2026-10-20)**. All four steps are live: the tailnet is tag- and group-scoped, the allow-all grant is gone. This document records the state before the work, the problems found, and what was done.

The policy file is GitOps-applied by `.github/workflows/tailscale.yml` (`tailscale/gitops-acl-action`): PRs run `action: test`, pushes to `main` run `action: apply`. There is no in-cluster controller; the repo is the source of truth.

## State before the work

### The tailnet is flat

`tailscale/policy.hujson` has no `acls` block and exactly one network grant:

```json
// policy.hujson:79-95
{
  "src": ["*"],
  "dst": ["*"],
  "ip":  ["*"],
  "app": { "tailscale.com/cap/tsidp": [ ... ] }
}
```

Every user device and every tagged device can reach every other device, every Tailscale Service, and every port. The tags below `tagOwners` and the `ssh` section are the only things doing any work today.

### Ingress tags are effectively decorative

- HA ingresses (`tailscale.com/proxy-group: ingress-proxy-group`) tag the **Tailscale Service (VIPService)**, not the proxy pods. The two `ingress-proxy-group-*` pods keep `tag:k8s`.
- Standalone ingresses and `loadBalancerClass: tailscale` Services (`minecraft`, the `consignment-app` funnel) tag the **proxy device** itself.
- Devices and services draw from the same tag namespace, so a grant to a tag matches both.

Every ingress currently carries `tag:k8s` in addition to a semantic tag, and `tag:k8s` is also the identity of the operator's proxy pods (including the `borg-cluster` kube-apiserver proxy). One grant to `tag:k8s` therefore opens all ~28 apps plus the proxy devices.

### In-cluster traffic to the tailnet was `tag:k8s-node` (fixed in step 3)

CoreDNS forwards to the node's `/etc/resolv.conf`, so a pod that calls `https://<x>.beaver-cloud.ts.net` leaves through the node's `tailscale0` and the peer sees the node (`tag:k8s-node`), not the app. Two things depend on this today:

- **OIDC back-channel**: donetick, linkding, miniflux, romm call `idp.beaver-cloud.ts.net/token` and `/userinfo` server-side.
- **Gatus**: most `gatus.yml` files check `https://<app>.beaver-cloud.ts.net` instead of the in-cluster Service.
- **miniflux -> linkding**: miniflux's "save to linkding" integration is set (in miniflux's UI/DB, not git) to `https://linkding.beaver-cloud.ts.net`.

A node has one tailnet identity, so per-pod identity has to come from a separate tailnet device. See [In-cluster identity](#in-cluster-identity).

### Findings

| # | Issue | Location |
| --- | --- | --- |
| 1 | Allow-all grant `* -> * -> *` | `policy.hujson:79` |
| 2 | tsidp cap granted to `*` (including tagged devices) with `isAdmin: true`, `users: ["*"]`, `resources: ["*"]` | `policy.hujson:85-95`, `policy.hujson:126-136` |
| 3 | Every ingress carries `tag:k8s`, so all Tailscale Services share one tag and the proxy pods' identity | all `deployment.yml` |
| 4 | Funnel attribute granted to `autogroup:member`, `tag:k8s`, `tag:work`; `consignment-app` is publicly reachable via Funnel | `policy.hujson:33-37`, `apps/consignment-app/deployment.yml:85` |
| 5 | `tag:k8s:monitoring` is not a legal tag name (colons are not allowed) - gatus silently ends up with only `tag:k8s` | `infrastructure/gatus/deployment.yml:104` |
| 6 | `argocd` is tagged `tag:ci` (a leftover way to give CI a path to it), and `tag:ci` is mintable by `tag:k8s-operator` | `infrastructure/argocd/ingress.yml:8`, `policy.hujson:13` |
| 7 | scrypted, semaphore, zigbee2mqtt have no semantic tag at all | see tag table |
| 8 | SSH: `autogroup:admin` gets root on all tagged devices; no check mode | `policy.hujson:59-64` |
| 9 | `drive:share` / `drive:access` on all tagged devices (CI, IoT, routers) | `policy.hujson:38-41` |
| 10 | `autoApprovers.services` is `tag:k8s -> tag:k8s` (self-approval of any `tag:k8s` service) | `policy.hujson:183-188` |
| 11 | No `tests` block, although CI already runs the ACL tester on PRs | `.github/workflows/tailscale.yml:31-38` |
| 12 | In-cluster callers of tailnet names all appear as `tag:k8s-node` | see above |
| 13 | dev-pod is dead but still has a tag, group, SSH rule, and a `cluster-admin` binding for `dev-pod.beaver-cloud.ts.net` | `policy.hujson:6,19,72-76`, `infrastructure/tailscale/resources.yml` |
| 14 | Access is granted to `autogroup:member` / `autogroup:admin` directly, so there is no way to give someone app access without admin | `policy.hujson` |

Findings 1, 2, 4, 8-11 and 14 describe the policy before step 4 and are fixed by the step 4 swap. Fixed already: 3 and 7 (step 2 tags), 5 (gatus is now `tag:monitoring`), 12 (step 3 egress identity), 13 (step 1); 6 is split (argocd is `tag:infra` since step 2, `tag:ci` stops being mintable by the operator in step 4).

### How tsidp caps actually resolve

This matters because the per-app `dst` idea does not work. tsidp calls `WhoIs` on the **browser -> tsidp** connection and stores that response on the auth request:

```go
// tsidp server/authorize.go:100-103
who, err = s.lc.WhoIs(r.Context(), remoteAddr)   // connection to idp.<tailnet>.ts.net
ar := &AuthRequest{ RemoteUser: who, ... }
```

`WhoIs` returns the caps for that `(src, dst)` pair, where `dst` is the node answering the request - `idp` (`tag:tsidp`):

```go
// tailscale ipn/ipnlocal/local.go:1806
// PeerCaps returns the capabilities that remote src IP has to ths current node.
func (b *LocalBackend) PeerCaps(src netip.Addr) tailcfg.PeerCapMap
```

Consequences:

- `tailscale.com/cap/tsidp` must be attached to a grant with `dst: ["tag:tsidp"]`. A grant with `dst: ["tag:media"]` is never returned to tsidp, so `includeInUserInfo` / `extraClaims` silently stop applying.
- `/authorize` does not consult the cap at all (it only rejects tagged source nodes, `authorize.go:112`). Caps cannot express "group X may log in only to app Y".
- `/token` and `/userinfo` do not reject tagged callers, so the back-channel can come from a tagged egress proxy.
- The same `who.CapMap` drives the admin UI and DCR (`appcap.go:88-97`), extra claims (`token.go:582`), and STS/resource validation (`token.go:688`).
- `users` is not a login allowlist. It is only matched against the RFC 8707 `resource` / STS `audience` (`validateResourcesForUser`). `resources` is a list of audience URIs, not tags. Most apps here (linkding, miniflux, romm, donetick) never send `resource`.
- Per-app authorization is therefore **network layer (group -> `tag:<category>`) plus app-local accounts**, not a tsidp cap.

Because the current cap sits on `src: ["*"]`, every token tsidp issues carries `extraClaims.isAdmin: true` for every app, not just admins.

## Target model

### Groups

Grants name groups, never `autogroup:member` / `autogroup:admin`. Adding someone means adding them to the groups for what they should reach.

| Group | Reaches |
| --- | --- |
| `group:admins` | everything; SSH to nodes, both routers and the travel lab; tsidp admin UI / DCR / `isAdmin`; Drive; Mullvad |
| `group:app-users` | `tag:apps` on 443, tsidp login |
| `group:media-users` | `tag:media` on 443, tsidp login |
| `group:home-users` | `tag:home` (home-assistant) on 443, tsidp login |
| `group:game-players` | `tag:games` on the Minecraft ports |
| `group:travel-users` | `tag:travel-lab` on 443 |

**Masquerading routers.** `tag:router` (home) and `tag:travel-router` SNAT LAN clients that cannot run Tailscale into the tailnet, so those clients show up as the router's tag. Groups cannot contain tags, so both tags are listed next to the groups in the regular-user grants (apps, media, home, games; the travel router also gets the travel lab). They are not travel users and not admins. tsidp's `/authorize` rejects tagged sources, so clients behind a router reach tsidp-backed apps (linkding, miniflux, romm, donetick) on the network but cannot log in through tsidp. They get no tsidp grant, and need an app-local login.

The only autogroups left are ones with no group equivalent: `autogroup:self` ("the requester's own devices", for SSH and Drive) and `autogroup:nonroot` (an SSH login-user selector).

### Tags

`tag:k8s` becomes the identity of operator-created ingress / API-server proxy pods only. No Ingress or Service sets it. Ingresses carry exactly one semantic tag (two for the funnel).

| Tag | Device / Service |
| --- | --- |
| `tag:media` | jellyfin, navidrome, audiobookshelf, romm, calibre, calibre-web |
| `tag:home` | home-assistant (the user-facing home app) |
| `tag:bridges` | scrypted, zigbee2mqtt (device bridges Home Assistant integrates with; admin-only UIs) |
| `tag:apps` | homer, searxng, kiwix, miniflux, linkding, donetick, dufs, makemkv, qbittorrent, radarr, sonarr, syncthing, pokesim, template |
| `tag:infra` | argocd, omada, semaphore |
| `tag:monitoring` | prometheus, alertmanager, gatus |
| `tag:games` | minecraft (`loadBalancerClass: tailscale`; TCP 25565 + UDP 19132) |
| `tag:apps` + `tag:funnel` | consignment-app (dedicated tag so Funnel can be narrowed to one device) |
| `tag:k8s-oidc` | `oidc-egress` ProxyGroup pods: the in-cluster identity for calls to tsidp |
| `tag:bastion` | the jump host: admins get in through check mode, and it can SSH out to the nodes, both routers and the travel lab on 22 |
| `tag:travel-lab` | the standalone travel lab's devices and the Tailscale Services they publish (self-approved; no tsidp, no cluster access) |
| `tag:bastion` | the jump host: admins get in through check mode, and it can SSH out to the nodes, both routers and the travel lab on 22 |

The bastion (`tag:bastion`) is an admin-only jump host. Admins reach it through the `* -> *` grant plus an inbound SSH rule in check mode, so entering it prompts a re-authentication. The hop out is its own rule: `src: ["tag:bastion"]` over tcp:22 to the cluster nodes, both routers and the travel lab. Two limits apply: Tailscale does not allow check mode when the SSH source is a tagged device, so the hop out is `accept`, and a custom `checkPeriod` (anything other than the default 12h) is a premium-plan feature, so the inbound check uses the 12h default. Tagging the device removes it from `autogroup:self`, and the tag is now its only identity: anything else it must reach needs an explicit grant.

Exact annotation changes. Every line drops `tag:k8s`; jellyfin, navidrome, home-assistant and omada also drop `tag:apps`:

```yaml
# infra
infrastructure/argocd/ingress.yml:8          tailscale.com/tags: tag:infra
infrastructure/gatus/deployment.yml:104      tailscale.com/tags: tag:monitoring   # was tag:k8s,tag:k8s:monitoring
infrastructure/prometheus/prometheus.yml:85  tailscale.com/tags: tag:monitoring
infrastructure/alertmanager/alertmanager.yml:85 tailscale.com/tags: tag:monitoring

# apps
apps/jellyfin/deployment.yml:87              tailscale.com/tags: tag:media
apps/navidrome/deployment.yml:77             tailscale.com/tags: tag:media
apps/audiobookshelf/deployment.yml:152       tailscale.com/tags: tag:media
apps/romm/deployment.yml:271                 tailscale.com/tags: tag:media
apps/calibre/deployment.yml:82               tailscale.com/tags: tag:media
apps/calibre-web/deployment.yml:82           tailscale.com/tags: tag:media

apps/home-assistant/deployment.yml:78        tailscale.com/tags: tag:home
apps/scrypted/deployment.yml:76              tailscale.com/tags: tag:bridges
platform/zigbee2mqtt/deployment.yml:66       tailscale.com/tags: tag:bridges

apps/omada/deployment.yml:78                 tailscale.com/tags: tag:infra
platform/semaphore/deployment.yml:139        tailscale.com/tags: tag:infra

apps/minecraft/deployment.yml:75             tailscale.com/tags: tag:games   # Service, L3
apps/consignment-app/deployment.yml:84       tailscale.com/tags: tag:apps,tag:funnel

# everything else: tag:apps
apps/{donetick,dufs,homer,kiwix,linkding,makemkv,miniflux,
      pokesim,qbittorrent,radarr,searxng,sonarr,syncthing,
      template}/deployment.yml               tailscale.com/tags: tag:apps
```

### In-cluster identity

Rule: app-to-app calls use in-cluster Services; only calls that need a tailnet identity, or a target only reachable on the tailnet, go through an egress ProxyGroup. tsidp is the only such target today (it listens only on tsnet).

**OIDC back-channel -> egress ProxyGroup.** An egress ProxyGroup is a tailnet device with its own tag; pods reach a tailnet target through an `ExternalName` Service that the operator wires to it. A CoreDNS rewrite points the existing `idp.beaver-cloud.ts.net` name at that Service, so app configs do not change and TLS still validates (the proxy forwards TCP; the cert and SNI are tsidp's). The tsidp gatus check rides the same path.

```yaml
# infrastructure/tailscale/resources.yml (namespace: tailscale)
---
apiVersion: tailscale.com/v1alpha1
kind: ProxyGroup
metadata:
  name: oidc-egress
spec:
  type: egress
  replicas: 2
  tags:
    - tag:k8s-oidc
---
apiVersion: v1
kind: Service
metadata:
  name: idp
  annotations:
    tailscale.com/tailnet-fqdn: idp.beaver-cloud.ts.net
    tailscale.com/proxy-group: oidc-egress
spec:
  type: ExternalName
  externalName: placeholder   # rewritten by the operator
  ports:
    - name: https
      port: 443
      protocol: TCP
```

```yaml
# infrastructure/coredns/coredns-custom.yml (namespace: kube-system)
# k3s's CoreDNS imports /etc/coredns/custom/*.override from this optional ConfigMap.
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  tailnet.override: |
    rewrite stop {
      name exact idp.beaver-cloud.ts.net idp.tailscale.svc.cluster.local
      answer auto
    }
```

The ConfigMap needs its own kustomization root, because `infrastructure/tailscale` forces `namespace: tailscale`.

**Gatus -> in-cluster URLs.** Routing 30 health checks through egress would need one `ExternalName` + rewrite per FQDN and would give gatus reach into every service tag. Instead, point each `gatus.yml` at `http://<name>-app-service.<name>`, as `apps/template/gatus.yml` already does, keeping existing paths (e.g. donetick `/api/v1/health`). Gatus then needs no tailnet access at all. What you lose is the end-to-end check through the Tailscale ingress. If you want that back, add a `monitoring-egress` ProxyGroup (`tag:k8s-probe`) for a handful of canary FQDNs later.

Two exceptions were found when this was applied:

- **pokesim** rejects requests whose `Host` is not in its trusted-host allowlist (it derives them from `PUBLIC_URL`). The in-cluster check needs `headers: {Host: pokesim.beaver-cloud.ts.net}`; Gatus sets `request.Host` for a `Host` header, so no app change is needed.
- **golink** is a tsnet app: it listens only on its own tailnet device (`go`, `tag:golink`) and nothing listens on its pod IP or Service. There is no in-cluster URL to check, so `apps/golink/gatus.yml` is `enabled: false`. Re-enable it only together with a `monitoring-egress` proxy (or check it from a device on the tailnet).

**miniflux -> linkding -> in-cluster URL.** Linkding's API authenticates with a token, so the caller's tailnet identity adds nothing. The integration URL in miniflux (Settings -> Integrations -> Linkding) was already `http://linkding-app-service.linkding` when step 3 was applied, so no change was needed. No egress, no grant.

After these, nothing legitimate uses `tag:k8s-node` as a source, and the policy gives it no grants.

## Proposed policy

The full file is in the [Appendix](#appendix-proposed-policy). The important pieces:

### Grants

| Source | Destination | Ports |
| --- | --- | --- |
| `group:admins` | `*` | all |
| `group:app-users`, `tag:router`, `tag:travel-router` | `tag:apps` | tcp:443 |
| `group:media-users`, `tag:router`, `tag:travel-router` | `tag:media` | tcp:443 |
| `group:home-users`, `tag:router`, `tag:travel-router` | `tag:home` | tcp:443 |
| `group:game-players`, `tag:router`, `tag:travel-router` | `tag:games` | tcp:25565, udp:19132 |
| `group:travel-users`, `tag:travel-router` | `tag:travel-lab`, `svc:travel-jellyfin` | tcp:443 |
| `tag:travel-lab` | `tag:travel-lab` | tcp:443 |
| `tag:bastion` | `tag:k8s-node`, `tag:router`, `tag:travel-router`, `tag:travel-lab` | tcp:22 |
| app/media/home users | `tag:tsidp` | tcp:443 + tsidp login cap |
| `group:admins` | `tag:tsidp` | tsidp admin cap |
| `tag:k8s-oidc` | `tag:tsidp` | tcp:443 |
| `tag:ci` | `svc:argocd` | tcp:443 |

Nobody but admins reaches `tag:infra`, `tag:monitoring`, `tag:bridges`, `tag:bastion`, `tag:k8s`, `tag:k8s-node`, or the operator. `tag:k8s-node`, `tag:work`, `tag:personal` and `tag:golink` get no network grants as sources (see [Open decisions](#open-decisions)).

`svc:travel-jellyfin` is listed by name because that service was defined without a tag (its six siblings on the travel-lab Pi all carry `tag:travel-lab`), so a tag grant never matched it and only admins (who have `* -> *`) could reach it. Assign `tag:travel-lab` to the service in the admin console and the explicit destination can be dropped. The operator's OAuth client cannot do it: it is not an owner of `tag:travel-lab`, so the API update is rejected.

### tsidp capabilities

`includeInUserInfo` for every login group. `allow_admin_ui`, `allow_dcr`, `users: ["*"]`, `resources: ["*"]` and `extraClaims.isAdmin` for `group:admins` only. Both grants have `dst: ["tag:tsidp"]` (see above for why).

### nodeAttrs / ssh / autoApprovers

- Funnel only for `tag:funnel`; consignment-app is deliberately public, nothing else is.
- Drive share/access and Mullvad only for `group:admins`, and Drive sharing only between an admin's own devices. The `autogroup:admin -> autogroup:tagged` and `tag:travel-router -> *` Drive grants are dropped.
- `cache-network-maps` for `*`.
- SSH: `group:admins` -> `tag:k8s-node`, `tag:router`, `tag:travel-router`, `tag:travel-lab`, `tag:bastion`, and their own devices. All are `accept` except the bastion, which is `check` (12h default; custom `checkPeriod` needs a premium plan). `tag:bastion` itself is also a source: tcp:22 to the nodes, both routers and the travel lab, as an `accept` rule - Tailscale rejects check mode for tagged sources, so the re-authentication happens on entry to the bastion. The blanket "admins -> all tagged devices" rule is removed, which ends SSH to `tag:golink` and `tag:tsidp` (neither advertises SSH).
- `tag:pve` is dropped from `tagOwners`: the host is gone and no device carries the tag (checked 2026-10-20).
- `autoApprovers.services` maps each cluster service tag to `tag:k8s` (the ingress proxy devices). `tag:k8s -> tag:k8s` is removed. `tag:travel-lab -> tag:travel-lab` lets the lab publish its own services.
- `tests` asserts the matrix so PRs fail if it regresses.
- All dev-pod entries are removed.

## Rollout

Order matters. Tags and approvals must exist before access is removed. Service tags must be in `autoApprovers` before annotation changes take effect, or the VIPServices go unapproved. The egress path must work before the node identity loses access.

### Step 1 - policy prerequisites (no access change) - applied 2026-10-20 (`15482bc6`)

PR to `tailscale/policy.hujson`:

- add the new groups (including `group:travel-users`);
- add `tag:bridges`, `tag:games`, `tag:funnel` and `tag:k8s-oidc` to `tagOwners`;
- add the new `autoApprovers.services` entries, including `tag:travel-lab`;
- remove `group:dev-pod-users`, `tag:dev-pod` and the dev-pod SSH rule.

Leave the allow-all grant in place. In the same PR, drop the `dev-pod.beaver-cloud.ts.net` subject from the `kevindurb-masters` ClusterRoleBinding in `infrastructure/tailscale/resources.yml`.

Applied differently: `group:k8s-admins` was renamed to `group:admins` (same member, and its only reference was the `tag:k8s-node` SSH rule) instead of keeping two identical admin groups until step 4.

### Step 2 - ingress tags (no access change, allow-all still on) - applied 2026-10-20 (`915b2688`)

PR changing every annotation per the table above.

For HA ingresses, tags are applied to the Tailscale Service. If the VIPService does not pick up the change, recreate the Ingress (Argo CD recreates it immediately):

```sh
kubectl delete ingress -n <namespace> <ingress-name>
```

The two standalone devices (`minecraft` Service, `consignment-app` Ingress) must be recreated, because the operator applies tags only at provisioning:

```sh
kubectl -n minecraft delete svc app-service
kubectl -n consignment-app delete ingress consignment-app-funnel-ingress
```

Verify:

```sh
kubectl get ingress -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,TAGS:.metadata.annotations.tailscale\.com/tags,PG:.metadata.annotations.tailscale\.com/proxy-group'
tailscale status --json | jq -r '.Peer[]? | [.HostName, (.Tags // [] | join(","))] | @tsv'
```

### Step 3 - in-cluster identity (no access change, allow-all still on) - applied 2026-10-20 (`7cbb1a73`, `1777b4d1`)

PR adding the `oidc-egress` ProxyGroup, the `idp` ExternalName Service and `coredns-custom`, and switching `gatus.yml` URLs to in-cluster Services. Separately (not in git), change miniflux's linkding integration URL to `http://linkding-app-service.linkding` and save an article to confirm.

```sh
kubectl -n tailscale get proxygroup oidc-egress            # Ready
kubectl run -it --rm dnstest --image=busybox --restart=Never -- \
  nslookup idp.beaver-cloud.ts.net                          # expect a cluster IP, not 100.x
```

Then log in to linkding and donetick. The tsidp device's peer list (or `tailscale whois` on tsidp) should show the token call coming from an `oidc-egress-*` device.

Applied notes:

- The egress `ExternalName` Service's `externalName` is rewritten by the operator to `ts-idp-<hash>.tailscale.svc.cluster.local`, so Argo CD sees perpetual drift and self-heals the placeholder back. `infrastructure/tailscale/app.yml` carries an `ignoreDifferences` block for `/spec/externalName` on that Service; without it the OIDC path flaps every sync.
- `prune: false` means every `gatus.yml` edit leaves the previous hashed ConfigMap behind. The config-sync sidecar writes both, so gatus can end up running stale tailnet URLs. 29 superseded ConfigMaps were deleted when this step was applied; check for duplicates (`kubectl get cm -A -l gatus.io/enabled=true`) after any future gatus change.
- The `tailscale` kustomization now uses `includeSelectors: false`, because the common label would otherwise be injected into the egress Service's (meaningless) selector.
- Verified: `idp.beaver-cloud.ts.net` resolves to the egress ClusterIP, `https://idp.beaver-cloud.ts.net/.well-known/openid-configuration` returns 200 with a valid certificate from a pod, the egress proxy logs the connection to idp, an OIDC login to linkding/donetick works, and gatus is all green with only tsidp (via the rewrite) and the disabled golink check left on tailnet names.

### Step 4 - lock down - applied 2026-10-20 (PR [#524](https://github.com/kevindurb/k8s/pull/524), `e0f99bde`)

PR replacing `policy.hujson` with the Appendix. CI ran `action: test` on the PR, so the matrix was validated before merge; the push applied it.

Applied notes (what was checked after the apply):

- Admin: `https://argocd.beaver-cloud.ts.net` 200, `https://gatus.beaver-cloud.ts.net` 200, jellyfin 302.
- SSH: `root@drone-01` and `core@drone-01` work, `root@router` works. `kevindurb@drone-01` is permitted by policy (`autogroup:nonroot`) but fails because the node has no such OS user - use `core@` (bootc) or `root@`.
- Nodes are cut off: from `drone-01`, `curl -m8 https://jellyfin.beaver-cloud.ts.net` returns 000 (curl exit 28, timeout).
- Router LAN path: from the OpenWrt box (`tag:router`), a TCP connect to jellyfin:443 succeeds while argocd:443 and gatus:443 hang (silently dropped, no RST).
- CI: a `workflow_dispatch` run of `ci.yml` passed `Connect to tailnet` (tags `tag:ci`, `ping: argocd`) and the Argo CD webhook, so the `svc:argocd` grant works.
- `gatus` was all green after the apply, including the `tsidp` check, so `tag:k8s-oidc -> tag:tsidp` still carries the OIDC back-channel.
- The travel lab was offline (last seen two days earlier) during verification, so admin SSH to it is rule-verified only. Recheck with `tailscale ssh root@travel-lab uptime` once it is back.

### Verification

From an admin device:

```sh
tailscale ssh core@drone-01 'uptime'     # nodes are bootc: core, or root
tailscale ssh root@router 'uptime'
tailscale ssh root@travel-lab 'uptime'
curl -fsS -o /dev/null -w '%{http_code}\n' https://argocd.beaver-cloud.ts.net
curl -fsS -o /dev/null -w '%{http_code}\n' https://jellyfin.beaver-cloud.ts.net
```

- OIDC login to linkding, miniflux, romm, donetick still works. (Covered during step 3: linkding and donetick logins work through the egress identity.)
- SSH still works to cluster nodes, `router`, `travel-router` and `travel-lab` (all four advertise SSH today); it no longer works to any other tagged device.
- Gatus is all green, including the tsidp check. golink has no check (see step 3).
- miniflux "save to linkding" still works.
- From a client behind the home router and one behind the travel router, jellyfin loads; argocd, gatus and the travel lab's services time out.
- From a travel-users device, the travel lab's services load. From a client behind the travel router, a travel-lab service also loads on 443.
- From a node (`ssh core@drone-01`), `curl -m5 https://jellyfin.beaver-cloud.ts.net` times out.
- GitHub Actions: the `Deploy` job in `.github/workflows/ci.yml` must still reach `argocd`. Push to `main` and confirm the `ping: argocd` and the webhook POST succeed.

### Rollback

`git revert e0f99bde` (the Step 4 policy commit); the next push re-applies the previous policy. That alone restores access. Steps 1-3 are access-neutral and only need reverting if you want the old tags or DNS back; reverting Step 2 also requires recreating the affected Ingresses.

## Risks and things to check

- **Host-networked pods** (`home-assistant`, `scrypted`, `syncthing`, `omada`) speak to the tailnet as `tag:k8s-node`. Accepted for now: no known calls, and Home Assistant's config is in a PVC so a hidden `*.ts.net` integration would only surface after lockdown. If one does, it needs its own egress Service, or a narrow `tag:k8s-node` grant for that one target.
- **Other app-to-app calls over `*.ts.net`** that live in app UIs/databases rather than git (like the miniflux one) only show up after lockdown. Before Step 4, check the tailnet logs or the admin console for `tag:k8s-node` source connections.
- **Egress port mapping**: the operator maps each `ExternalName` port to a random port on the proxy pods; the ClusterIP Service keeps port 443. Confirm with `kubectl -n tailscale get svc` after Step 3.
- **`tag:ci` -> `svc:argocd`**: `tailscale ping` needs argocd in CI's netmap, which the grant provides. If `ping: argocd` fails while the webhook works, drop the `ping` input rather than widening the grant.
- **Tests and `svc:`**: the ACL tester's support for `svc:` destinations is unverified, so the tests only deny tags for `tag:ci` and rely on the CI job for the positive check.
- **`autogroup:self` with group sources** in the SSH and Drive rules: if the tester rejects it, the Step 4 PR fails before apply. Fall back to listing users.
- **`tag:work` / `tag:personal`**: a tagged laptop is not in any group, so it loses app access. Intended for now (both tags are unused); add the tag to a grant's sources if that changes.
- **Router LANs are trusted wholesale**: every client on the home router's or travel router's LAN, including guests and IoT, gets regular-user access. If either LAN has guest/IoT segments, masquerade only the trusted one.
- **Subnet routes**: `tag:router` / `tag:travel-router` advertise routes; those are approved separately (`autoApprovers.routes` is intentionally not added). Only admins can use them under `*`.
- **`tag:travel-lab` is both device and service tag** (same pattern this plan removes from `tag:k8s`): `group:travel-users` reaches the lab devices themselves on 443, not just their services, and the lab devices can reach each other on 443 (explicit self-grant). Fine for a standalone lab; split off a `tag:travel-lab-svc` if that changes.
- **The egress `ExternalName` Service drifts from git.** The operator rewrites `spec.externalName`; without `ignoreDifferences` Argo CD self-heals it back on every sync (`infrastructure/tailscale/app.yml`).
- **Stale gatus ConfigMaps.** `prune: false` keeps every previous hashed `gatus.io/enabled` ConfigMap, and the config-sync sidecar writes files for all of them, so gatus may run old URLs. Delete superseded ones after changing a `gatus.yml`.
- **golink has no health check** while it stays a tsnet-only app. It is only visible on `go.beaver-cloud.ts.net`; monitoring it again needs an egress proxy.
- **ProxyGroup device tags** are immutable. Splitting the ingress proxies off `tag:k8s` into `tag:k8s-proxy` requires recreating `ingress-proxy-group` (short outage on every ingress) - optional, not part of this plan.
- **API server proxy** runs in `mode: auth`; a future non-admin kubectl user needs a `tailscale.com/cap/kubernetes` grant plus RBAC.
- **Ansible role**: `ansible/roles/tailscale/tasks/main.yml` runs `tailscale up --accept-dns=false --ssh` without `--advertise-tags`. On a tagged node, `tailscale up` with partial flags can error; add `--advertise-tags=tag:k8s-node` if you re-provision.

## Open decisions

1. ~~Is `consignment-app` intentionally public?~~ **Decided:** yes, it stays public. Keep `tailscale.com/funnel: 'true'` and `tag:funnel`; no other tag gets the funnel attribute.
2. ~~Should `tag:work` / `tag:personal` devices reach `tag:apps` / `tag:media` / `tag:home`?~~ **Decided:** keep the tags in `tagOwners` for now, but they are unused and get no grants - they stay locked out.
3. ~~Is `extraClaims.isAdmin` consumed by any app outside this repo?~~ **Decided:** nothing consumes it. It stays confined to the `group:admins` tsidp cap (harmless if unused) and is not granted to anyone else.
4. ~~Does any host-networked pod call a tailnet device?~~ **Decided:** no known calls, accept the risk. Home Assistant's config lives in a PVC, so if an integration silently points at a `*.ts.net` name it will only show up after lockdown; add a narrow `tag:k8s-node` grant or egress Service for that one target if so.
5. Was the `tag:travel-router -> *` Drive grant used? It is dropped in the proposal.
6. ~~Which non-node tagged devices (pve, routers, travel-lab) do you still SSH into?~~ **Decided:** routers (`tag:router`, `tag:travel-router`) and the travel lab keep admin SSH; `tag:pve` is removed entirely.
7. ~~Should a future `group:home-users` member also get `tag:bridges` (e.g. to pair a Zigbee device), or does that stay admin-only?~~ **Decided:** stays admin-only.
8. ~~Should clients behind the travel router also reach the travel lab (add `tag:travel-router` to that grant)?~~ **Decided:** yes, `tag:travel-router` is a source for `tag:travel-lab` on tcp:443.
9. ~~Do travel-lab devices talk to each other over the tailnet? If so, add `tag:travel-lab -> tag:travel-lab`.~~ **Reversed 2026-10-20 on request:** the lab gets `tag:travel-lab -> tag:travel-lab` on tcp:443. The services are all on one Pi and talk locally, but the devices also need to reach each other's HTTPS endpoints.

## Related cleanup (done 2026-10-20 unless noted)

- Root `null.yml`: deleted (`ed7caf04`). It was an unreferenced, invalid duplicate of the zigbee2mqtt Ingress (`kind+:`).
- Duplicate minecraft Service: the leftover was **`minecraft/app-service`**, not `minecraft-app-service`. It had no Argo tracking-id and no `namePrefix`, so its hostname collided into `minecraft-1`; `minecraft-app-service` is the GitOps-managed one and was left alone. After deleting `app-service` the operator garbage-collected `ts-app-service-vhthc` and `tailscale status` shows a single `minecraft` device.
- `tag:pve` is gone from `tagOwners` in step 4: the host no longer exists and no device carries the tag. `tag:router`, `tag:travel-router` and `tag:travel-lab` keep admin SSH and get their grants from step 4.
- `qbittorrent` has a Service and Ingress but no pods; its gatus check is disabled. Worth deciding whether the app should still be deployed.

## Appendix: proposed policy

`tailscale/policy.hujson` (hujson; comments and trailing commas allowed):

```json
// vim: set ft=hjson:

{
	"groups": {
		"group:admins":       ["kevindurb@github"],
		"group:app-users":    ["kevindurb@github"],
		"group:media-users":  ["kevindurb@github"],
		"group:home-users":   ["kevindurb@github"],
		"group:game-players": ["kevindurb@github"],
		"group:travel-users": ["kevindurb@github"],
	},

	"hosts": {},

	"tagOwners": {
		"tag:ci":              ["group:admins"],
		"tag:work":            ["group:admins"],
		"tag:personal":        ["group:admins"],
		"tag:k8s-node":        ["group:admins"],
		"tag:bastion":         ["group:admins"],
		"tag:golink":          ["group:admins"],
		"tag:router":          ["group:admins"],
		"tag:travel-router":   ["group:admins"],
		"tag:travel-lab":      ["group:admins"],
		"tag:border0-managed": ["group:admins"],
		"tag:tsidp":           ["group:admins"],
		"tag:k8s-operator":    ["group:admins"],
		"tag:k8s":             ["tag:k8s-operator"],
		"tag:k8s-oidc":        ["group:admins", "tag:k8s-operator"],
		"tag:apps":            ["group:admins", "tag:k8s-operator"],
		"tag:media":           ["group:admins", "tag:k8s-operator"],
		"tag:home":            ["group:admins", "tag:k8s-operator"],
		"tag:bridges":         ["group:admins", "tag:k8s-operator"],
		"tag:infra":           ["group:admins", "tag:k8s-operator"],
		"tag:monitoring":      ["group:admins", "tag:k8s-operator"],
		"tag:games":           ["group:admins", "tag:k8s-operator"],
		"tag:funnel":          ["group:admins", "tag:k8s-operator"],
	},

	"nodeAttrs": [
		{"target": ["tag:funnel"],   "attr": ["funnel"]},
		{"target": ["group:admins"], "attr": ["drive:share", "drive:access", "mullvad"]},
		{"target": ["*"],            "attr": ["cache-network-maps"]},
	],

	"ssh": [
		{
			"action": "accept",
			"src":    ["group:admins"],
			"dst":    ["tag:k8s-node"],
			"users":  ["root", "autogroup:nonroot"],
		},
		{
			"action": "accept",
			"src":    ["group:admins"],
			"dst":    ["tag:router", "tag:travel-router", "tag:travel-lab"],
			"users":  ["root", "autogroup:nonroot"],
		},
		{
			// bastion: check mode (default 12h; a custom checkPeriod is a premium feature)
			"action": "check",
			"src":    ["group:admins"],
			"dst":    ["tag:bastion"],
			"users":  ["root", "autogroup:nonroot"],
		},
		{
			// check mode cannot apply to a tagged source, so the hop out is accept
			"action": "accept",
			"src":    ["tag:bastion"],
			"dst":    ["tag:k8s-node", "tag:router", "tag:travel-router", "tag:travel-lab"],
			"users":  ["root", "autogroup:nonroot"],
		},
		{
			"action": "accept",
			"src":    ["group:admins"],
			"dst":    ["autogroup:self"],
			"users":  ["root", "autogroup:nonroot"],
		},
	],

	"grants": [
		{"src": ["group:admins"],       "dst": ["*"],         "ip": ["*"]},

		// tag:router / tag:travel-router masquerade LAN clients that cannot run Tailscale; treat them as regular users
		{"src": ["group:app-users",    "tag:router", "tag:travel-router"], "dst": ["tag:apps"],  "ip": ["tcp:443"]},
		{"src": ["group:media-users",  "tag:router", "tag:travel-router"], "dst": ["tag:media"], "ip": ["tcp:443"]},
		{"src": ["group:home-users",   "tag:router", "tag:travel-router"], "dst": ["tag:home"],  "ip": ["tcp:443"]},
		{"src": ["group:game-players", "tag:router", "tag:travel-router"], "dst": ["tag:games"], "ip": ["tcp:25565", "udp:19132"]},

		// travel-lab devices and the services they host may reach each other
		{"src": ["tag:travel-lab"], "dst": ["tag:travel-lab"], "ip": ["tcp:443"]},
		{"src": ["group:travel-users", "tag:travel-router"], "dst": ["tag:travel-lab", "svc:travel-jellyfin"], "ip": ["tcp:443"]},

		// a tagged bastion is its own identity: it needs a network path for the SSH hops
		{"src": ["tag:bastion"], "dst": ["tag:k8s-node", "tag:router", "tag:travel-router", "tag:travel-lab"], "ip": ["tcp:22"]},

		// tsidp back-channel from in-cluster apps via the oidc-egress ProxyGroup
		{"src": ["tag:k8s-oidc"], "dst": ["tag:tsidp"], "ip": ["tcp:443"]},

		// GitHub Actions -> Argo CD webhook
		{"src": ["tag:ci"], "dst": ["svc:argocd"], "ip": ["tcp:443"]},

		// caps must target tag:tsidp: tsidp reads them from WhoIs on the browser's connection to itself
		{
			"src": ["group:app-users", "group:media-users", "group:home-users"],
			"dst": ["tag:tsidp"],
			"ip":  ["tcp:443"],
			"app": {
				"tailscale.com/cap/tsidp": [{"includeInUserInfo": true}],
			},
		},
		{
			"src": ["group:admins"],
			"dst": ["tag:tsidp"],
			"app": {
				"tailscale.com/cap/tsidp": [
					{
						"allow_admin_ui":    true,
						"allow_dcr":         true,
						"users":             ["*"],
						"resources":         ["*"],
						"includeInUserInfo": true,
						"extraClaims":       {"isAdmin": true},
					},
				],
			},
		},

		{
			"src": ["group:admins"],
			"dst": ["autogroup:self"],
			"app": {
				"tailscale.com/cap/drive": [{"shares": ["*"], "access": "rw"}],
			},
		},

		// Automatically added by enabling PAM.
		{
			"src": ["group:admins"],
			"dst": ["tag:border0-managed"],
			"ip":  ["*"],
			"app": {
				"tailscale.com/cap/pam": [
					{
						"version": "v1",
						"permissions": {
							"ssh":        {"shell": {}, "exec": {}, "sftp": {}},
							"database":   {},
							"http":       {},
							"rdp":        {},
							"vnc":        {},
							"tcp":        {},
							"kubernetes": {},
							"aws_s3":     {},
						},
					},
				],
			},
		},
	],

	"autoApprovers": {
		"services": {
			"tag:apps":            ["tag:k8s"],
			"tag:media":           ["tag:k8s"],
			"tag:home":            ["tag:k8s"],
			"tag:bridges":         ["tag:k8s"],
			"tag:infra":           ["tag:k8s"],
			"tag:monitoring":      ["tag:k8s"],
			"tag:games":           ["tag:k8s"],
			"tag:funnel":          ["tag:k8s"],
			"tag:travel-lab":      ["tag:travel-lab"],
			"tag:border0-managed": ["tag:border0-managed"],
		},
	},

	"tests": [
		{
			"src":    "kevindurb@github",
			"accept": ["tag:apps:443", "tag:media:443", "tag:home:443", "tag:bridges:443", "tag:infra:443",
			           "tag:monitoring:443", "tag:k8s:443", "tag:tsidp:443", "tag:games:25565",
			           "tag:travel-lab:443"],
		},
		{
			"src":    "tag:k8s-oidc",
			"accept": ["tag:tsidp:443"],
			"deny":   ["tag:apps:443", "tag:media:443", "tag:bridges:443", "tag:infra:443", "tag:k8s:443"],
		},
		{
			"src":  "tag:k8s-node",
			"deny": ["tag:apps:443", "tag:bridges:443", "tag:tsidp:443", "tag:monitoring:443", "tag:k8s:443"],
		},
		{
			"src":  "tag:ci",
			"deny": ["tag:apps:443", "tag:monitoring:443", "tag:tsidp:443"],
		},
		{
			"src":    "tag:router",
			"accept": ["tag:apps:443", "tag:media:443", "tag:home:443", "tag:games:25565"],
			"deny":   ["tag:infra:443", "tag:monitoring:443", "tag:bridges:443", "tag:tsidp:443",
			           "tag:travel-lab:443", "tag:k8s:443"],
		},
		{
			"src":    "tag:travel-router",
			"accept": ["tag:apps:443", "tag:media:443", "tag:home:443", "tag:games:25565", "tag:travel-lab:443"],
			"deny":   ["tag:infra:443", "tag:monitoring:443", "tag:bridges:443", "tag:tsidp:443",
			           "tag:k8s:443"],
		},
		{
			"src":    "tag:travel-lab",
			"accept": ["tag:travel-lab:443"],
			"deny":   ["tag:apps:443", "tag:media:443", "tag:tsidp:443", "tag:k8s:443"],
		},
		{
			"src":    "tag:bastion",
			"accept": ["tag:k8s-node:22"],
			"deny":   ["tag:apps:443", "tag:infra:443", "tag:monitoring:443", "tag:tsidp:443"],
		},
		{
			"src":  "tag:work",
			"deny": ["tag:apps:443", "tag:infra:443"],
		},
	],
}
```
