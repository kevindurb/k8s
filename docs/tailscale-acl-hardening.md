# Tailscale ACL hardening

Status: **proposal, not applied**. This document describes the current state of `tailscale/policy.hujson` and the ingress tags, the problems found, and a staged plan to move from a flat tailnet to a tag-scoped one.

The policy file is GitOps-applied by `.github/workflows/tailscale.yml` (`tailscale/gitops-acl-action`): PRs run `action: test`, pushes to `main` run `action: apply`. There is no in-cluster controller; the repo is the source of truth.

## Current state

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

### Findings

| # | Issue | Location |
| --- | --- | --- |
| 1 | Allow-all grant `* -> * -> *` | `policy.hujson:79` |
| 2 | tsidp cap granted to `*` (including tagged devices) with `isAdmin: true`, `users: ["*"]`, `resources: ["*"]` | `policy.hujson:85-95`, `policy.hujson:126-136` |
| 3 | Every ingress carries `tag:k8s`, so all Tailscale Services share one tag and the proxy pods' identity | all `deployment.yml` |
| 4 | Funnel attribute granted to `autogroup:member`, `tag:k8s`, `tag:work`; `consignment-app` is publicly reachable via Funnel | `policy.hujson:33-37`, `apps/consignment-app/deployment.yml:85` |
| 5 | `tag:k8s:monitoring` is not a legal tag name (colons are not allowed) - gatus silently ends up with only `tag:k8s` | `infrastructure/gatus/deployment.yml:104` |
| 6 | `argocd` is tagged `tag:ci`, and `tag:ci` is mintable by `tag:k8s-operator` | `infrastructure/argocd/ingress.yml:8`, `policy.hujson:13` |
| 7 | scrypted, semaphore, zigbee2mqtt have no semantic tag at all | see tag table |
| 8 | SSH: `autogroup:admin` gets root on all tagged devices; no check mode | `policy.hujson:59-64` |
| 9 | `drive:share` / `drive:access` on all tagged devices (dev-pod, CI, IoT) | `policy.hujson:38-41` |
| 10 | `autoApprovers.services` is `tag:k8s -> tag:k8s` (self-approval of any `tag:k8s` service) | `policy.hujson:183-188` |
| 11 | No `tests` block, although CI already runs the ACL tester on PRs | `.github/workflows/tailscale.yml:31-38` |

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
- The same `who.CapMap` drives the admin UI and DCR (`appcap.go:88-97`), extra claims (`token.go:582`), and STS/resource validation (`token.go:688`).
- `users` is not a login allowlist. It is only matched against the RFC 8707 `resource` / STS `audience` (`validateResourcesForUser`). `resources` is a list of audience URIs, not tags. Most apps here (linkding, miniflux, romm, donetick) never send `resource`.
- Per-app authorization is therefore **network layer (`dst: tag:<app>`) plus app-local accounts**, not a tsidp cap.

Because the current cap sits on `src: ["*"]`, every token tsidp issues carries `extraClaims.isAdmin: true` for every app, not just admins.

## Target tag model

`tag:k8s` becomes the identity of operator-created proxy pods only. No Ingress or Service sets it. Ingresses carry exactly one semantic tag (two for the funnel).

| Tag | Ingress / Service |
| --- | --- |
| `tag:media` | jellyfin, navidrome, audiobookshelf, romm, calibre, calibre-web |
| `tag:home` | home-assistant, scrypted, zigbee2mqtt |
| `tag:apps` | homer, searxng, kiwix, miniflux, linkding, donetick, dufs, makemkv, qbittorrent, radarr, sonarr, syncthing, pokesim, template |
| `tag:infra` | argocd, omada, semaphore |
| `tag:monitoring` | prometheus, alertmanager, gatus |
| `tag:games` | minecraft (`loadBalancerClass: tailscale`; TCP 25565 + UDP 19132, so it cannot share the HTTP `tag:apps`) |
| `tag:funnel` + `tag:apps` | consignment-app (dedicated tag so Funnel can be narrowed to one device) |
| `tag:apps` | `apps/template/deployment.yml` (keeps `just tmpl` output correct) |

Exact annotation changes (drop `tag:k8s`, add the semantic tag):

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
apps/scrypted/deployment.yml:76              tailscale.com/tags: tag:home
platform/zigbee2mqtt/deployment.yml:66       tailscale.com/tags: tag:home

apps/omada/deployment.yml:78                 tailscale.com/tags: tag:infra
platform/semaphore/deployment.yml:139        tailscale.com/tags: tag:infra

apps/minecraft/deployment.yml:75             tailscale.com/tags: tag:apps   # Service, L3
apps/consignment-app/deployment.yml:84       tailscale.com/tags: tag:apps,tag:funnel

# everything else: tag:apps
apps/{donetick,dufs,homer,kiwix,linkding,makemkv,miniflux,
      pokesim,qbittorrent,radarr,searxng,sonarr,syncthing,
      template}/deployment.yml               tailscale.com/tags: tag:apps
```

`apps/minecraft/deployment.yml:75` is a `Service` with `loadBalancerClass: tailscale`, not an Ingress; the tags are on the proxy device and it serves raw TCP/UDP.

## Proposed policy

The full proposed file is in the [Appendix](#appendix-proposed-policy). The important pieces:

### Grants

```json
// admins can reach everything (single-admin tailnet; keeps kubectl, SSH, UIs working)
{ "src": ["group:k8s-admins"], "dst": ["*"], "ip": ["*"] },

// user-owned devices can reach each other
{ "src": ["autogroup:member"], "dst": ["autogroup:self"], "ip": ["*"] },

// shared user-facing services: HTTPS only
{ "src": ["autogroup:member"], "dst": ["tag:apps", "tag:media", "tag:home"], "ip": ["tcp:443"] },

// minecraft is layer 3
{ "src": ["autogroup:member"], "dst": ["tag:games"], "ip": ["*"] },

// network path to the IdP (required before app caps apply)
{ "src": ["autogroup:member"], "dst": ["tag:tsidp"], "ip": ["tcp:443"] },

// GitHub Actions -> Argo CD only (ping + /api/webhook)
{ "src": ["tag:ci"], "dst": ["svc:argocd"], "ip": ["*"] }
```

Non-admins lose access to `tag:infra`, `tag:monitoring`, `tag:k8s`, `tag:k8s-node`, `tag:dev-pod`, `tag:tsidp` (except 443), and the operator itself. `tag:work`, `tag:personal`, `tag:travel-lab`, `tag:golink`, `tag:pve`, `tag:router` get no network grants (see [Open decisions](#open-decisions)).

### tsidp capabilities

```json
// login identity for everyone
{ "src": ["autogroup:member"], "dst": ["tag:tsidp"],
  "app": { "tailscale.com/cap/tsidp": [{ "includeInUserInfo": true }] } },

// admins: UI, DCR, isAdmin claim
{ "src": ["autogroup:admin"], "dst": ["tag:tsidp"],
  "app": { "tailscale.com/cap/tsidp": [{
      "allow_admin_ui": true, "allow_dcr": true,
      "users": ["*"], "resources": ["*"],
      "includeInUserInfo": true,
      "extraClaims": { "isAdmin": true } }] } }
```

`isAdmin` is scoped to admins. If an app needs a per-app claim/hook, it has to be expressed as extra claims on the `tag:tsidp` grant (all apps see the same claim set) or enforced by the app itself.

### nodeAttrs / ssh / autoApprovers

- Funnel only for `tag:funnel` (drop `autogroup:member`, `tag:k8s`, `tag:work`).
- Tailscale Drive share/access only for user-owned devices (`autogroup:member`), not all tagged devices.
- SSH: admins -> `tag:k8s-node` only (not all tagged devices). Optional: change to `"action": "check", "checkPeriod": "12h"` after enabling check mode in the admin console.
- `autoApprovers.services` maps each service tag to `tag:k8s` (the proxy devices). `tag:k8s -> tag:k8s` is removed.
- `tests` asserts the matrix so PRs fail if it regresses.

## Rollout

The order matters: tags and approvals must exist before access is removed, and service tags must be in `autoApprovers` before the annotation changes take effect or the VIPServices go unapproved.

### Step 1 - policy prerequisites (no access change)

PR adding `tag:games` / `tag:funnel` to `tagOwners` and the new `autoApprovers.services` entries (apps/media/home/monitoring/infra/games/funnel -> `tag:k8s`). Leave the allow-all grant in place. Merge and let CI apply.

### Step 2 - ingress tags (no access change, allow-all still on)

PR changing every annotation per the table above.

For HA ingresses, tags are applied to the Tailscale Service; if the VIPService does not pick up the change, recreate the Ingress (Argo CD recreates it immediately):

```sh
kubectl delete ingress -n <namespace> <ingress-name>
```

For the two standalone devices (`minecraft` Service, `consignment-app` Ingress) the proxy device must be recreated, because the operator applies tags only at provisioning:

```sh
kubectl -n minecraft delete svc app-service
kubectl -n consignment-app delete ingress consignment-app-funnel-ingress
```

Verify with the admin console or:

```sh
kubectl get ingress -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,TAGS:.metadata.annotations.tailscale\.com/tags,PG:.metadata.annotations.tailscale\.com/proxy-group'
tailscale status --json | jq -r '.Peer[]? | [.HostName, (.Tags // [] | join(","))] | @tsv'
```

### Step 3 - lock down

PR removing the allow-all grant, adding the grant matrix, scoping the tsidp caps, tightening `nodeAttrs`/`ssh`, and adding `tests`. CI runs `action: test` on the PR, so the matrix is validated before merge; the push applies it.

### Verification

From a personal device:

```sh
tailscale ping argocd
tailscale ssh drone-01 'uptime'
curl -fsS -o /dev/null -w '%{http_code}\n' https://argocd.beaver-cloud.ts.net
curl -fsS -o /dev/null -w '%{http_code}\n' https://jellyfin.beaver-cloud.ts.net
```

From an untrusted tagged device (e.g. `dev-pod`), expect timeouts:

```sh
tailscale ping gatus        # must fail
tailscale ping 100.x.y.z    # a tag:infra service
```

GitHub Actions: the `Deploy` job in `.github/workflows/ci.yml` must still reach `argocd`, so run a push to `main` and confirm the `tailscale/github-action` `ping: argocd` and the webhook POST succeed.

### Rollback

`git revert` the policy commit; the next push re-applies the previous policy. Tag changes are reverted the same way, then the affected Ingresses are recreated.

## Risks and things to check

- **Host-networked pods** (`home-assistant`, `scrypted`, `syncthing`, `omada`) speak to the tailnet as `tag:k8s-node`, not as their ingress tag. If you reach any of them directly on a node IP/port (for example Syncthing 22000), add a narrow `autogroup:member -> tag:k8s-node` grant for that port.
- **`tag:work` / `tag:personal`**: a tagged work laptop is not `autogroup:member`, so it loses app access under the proposal. Add `tag:work` / `tag:personal` to the apps grant source list if that is desired.
- **Tailscale SSH** rules are independent of grants; port 22 does not need an `ip` grant.
- **Subnet routes**: `tag:router` / `tag:travel-router` devices advertise routes; those are approved separately (`autoApprovers.routes` is intentionally not added).
- **ProxyGroup device tags** are immutable. Splitting `tag:k8s` into a dedicated `tag:k8s-proxy` requires deleting and recreating `ingress-proxy-group` (short outage on every ingress) - optional, not part of this plan.
- **Operator limitation**: tags are applied at provisioning; annotation edits on existing standalone Services/Ingresses need a recreate.
- **Ansible role**: `ansible/roles/tailscale/tasks/main.yml` runs `tailscale up --accept-dns=false --ssh`, omitting `--advertise-tags`. `tailscale up` requires the complete flag set when any flag is given, so on a tagged node this can error; add `--advertise-tags=tag:k8s-node` if you re-provision. Existing nodes are already tagged.

## Open decisions

1. Is `consignment-app` intentionally public on the internet? If not, drop `tailscale.com/funnel: 'true'` - it is the largest exposure in this plan. If yes, `tag:funnel` limits which device can enable Funnel.
2. Should `tag:work` / `tag:personal` devices reach `tag:apps` / `tag:media` / `tag:home`?
3. Is `extraClaims.isAdmin` consumed by any app outside this repo? Nothing under `apps/` reads it.
4. Do you reach any host-networked app directly on its node IP/port?
5. Split proxy device tags into `tag:k8s-proxy` now (requires recreating the ProxyGroup) or later?

## Related cleanup (not required for the ACL change)

- Root `null.yml` is an unreferenced, invalid duplicate of the zigbee2mqtt Ingress (`kind+:`). Delete it.
- The cluster has both `minecraft/app-service` and a leftover `minecraft/minecraft-app-service` (plus `ts-app-service-vhthc-0` in the `tailscale` namespace), which produces the duplicate `minecraft` device in `tailscale status`. Delete the stale Service.
- `tag:pve`, `tag:router`, `tag:golink` are defined but unused; `tag:golink` is used by the `go` device. Either keep them deliberately or remove them once their devices are retagged.

## Appendix: proposed policy

`tailscale/policy.hujson` (hujson; comments and trailing commas allowed):

```json
// vim: set ft=hjson:

{
	"groups": {
		"group:k8s-admins":    ["kevindurb@github"],
		"group:dev-pod-users": ["kevindurb@github"],
	},

	"hosts": {},

	"tagOwners": {
		"tag:pve":             ["autogroup:admin"],
		"tag:ci":              ["autogroup:admin", "tag:k8s-operator"],
		"tag:infra":           ["autogroup:admin", "tag:k8s-operator"],
		"tag:work":            ["autogroup:admin"],
		"tag:personal":        ["autogroup:admin"],
		"tag:k8s-operator":    ["autogroup:admin"],
		"tag:k8s":             ["tag:k8s-operator"],
		"tag:dev-pod":         ["autogroup:admin"],
		"tag:k8s-node":        ["autogroup:admin"],
		"tag:golink":          ["autogroup:admin"],
		"tag:router":          ["autogroup:admin"],
		"tag:travel-router":   ["autogroup:admin"],
		"tag:travel-lab":      ["autogroup:admin"],
		"tag:media":           ["autogroup:admin", "tag:k8s-operator"],
		"tag:monitoring":      ["autogroup:admin", "tag:k8s-operator"],
		"tag:apps":            ["autogroup:admin", "tag:k8s-operator"],
		"tag:home":            ["autogroup:admin", "tag:k8s-operator"],
		"tag:games":           ["autogroup:admin", "tag:k8s-operator"],
		"tag:funnel":          ["autogroup:admin", "tag:k8s-operator"],
		"tag:border0-managed": ["autogroup:admin"],
		"tag:tsidp":           ["autogroup:admin"],
	},

	"nodeAttrs": [
		{
			"target": ["tag:funnel"],
			"attr":   ["funnel"],
		},
		{
			"target": ["autogroup:member"],
			"attr":   ["drive:share", "drive:access"],
		},
		{
			"target": ["autogroup:admin"],
			"attr":   ["mullvad"],
		},
		{
			"target": ["autogroup:member", "autogroup:tagged"],
			"attr":   ["cache-network-maps"],
		},
	],

	"ssh": [
		{
			"action": "accept",
			"src":    ["autogroup:member"],
			"dst":    ["autogroup:self"],
			"users":  ["root", "autogroup:nonroot"],
		},
		{
			"action": "accept",
			"src":    ["group:k8s-admins"],
			"dst":    ["tag:k8s-node"],
			"users":  ["root", "autogroup:nonroot"],
		},
		{
			"action": "accept",
			"src":    ["group:dev-pod-users"],
			"dst":    ["tag:dev-pod"],
			"users":  ["root", "autogroup:nonroot"],
		},
	],

	"grants": [
		{
			"src": ["group:k8s-admins"],
			"dst": ["*"],
			"ip":  ["*"],
		},
		{
			"src": ["autogroup:member"],
			"dst": ["autogroup:self"],
			"ip":  ["*"],
		},
		{
			"src": ["autogroup:member"],
			"dst": ["tag:apps", "tag:media", "tag:home"],
			"ip":  ["tcp:443"],
		},
		{
			"src": ["autogroup:member"],
			"dst": ["tag:games"],
			"ip":  ["*"],
		},
		{
			"src": ["autogroup:member"],
			"dst": ["tag:tsidp"],
			"ip":  ["tcp:443"],
		},
		{
			"src": ["tag:ci"],
			"dst": ["svc:argocd"],
			"ip":  ["*"],
		},
		{
			"src": ["autogroup:member"],
			"dst": ["tag:tsidp"],

			"app": {
				"tailscale.com/cap/tsidp": [
					{
						"includeInUserInfo": true,
					},
				],
			},
		},
		{
			"src": ["autogroup:admin"],
			"dst": ["tag:tsidp"],

			"app": {
				"tailscale.com/cap/tsidp": [
					{
						"allow_admin_ui": true,
						"allow_dcr":      true,
						"users":          ["*"],
						"resources":      ["*"],
						"includeInUserInfo": true,
						"extraClaims": {
							"isAdmin": true,
						},
					},
				],
			},
		},
		{
			"src": ["autogroup:member"],
			"dst": ["autogroup:self"],

			"app": {
				"tailscale.com/cap/drive": [
					{
						"shares": ["*"],
						"access": "rw",
					},
				],
			},
		},
		{
			"src": ["autogroup:admin"],
			"dst": ["autogroup:tagged"],

			"app": {
				"tailscale.com/cap/drive": [
					{
						"shares": ["*"],
						"access": "rw",
					},
				],
			},
		},
		{
			"src": ["tag:travel-router"],
			"dst": ["*"],

			"app": {
				"tailscale.com/cap/drive": [
					{
						"shares": ["*"],
						"access": "rw",
					},
				],
			},
		},
		{
			"src": ["autogroup:admin"],
			"dst": ["tag:border0-managed"],
			"ip":  ["*"],

			"app": {
				"tailscale.com/cap/pam": [
					{
						"version": "v1",

						"permissions": {
							"ssh": {
								"shell": {},
								"exec":  {},
								"sftp":  {},
							},

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
			"tag:monitoring":      ["tag:k8s"],
			"tag:infra":           ["tag:k8s"],
			"tag:games":           ["tag:k8s"],
			"tag:funnel":          ["tag:k8s"],
			"tag:border0-managed": ["tag:border0-managed"],
		},
	},

	"tests": [
		{
			"src":    "kevindurb@github",
			"accept": ["tag:apps:443", "tag:media:443", "tag:home:443", "tag:infra:443", "tag:k8s:443"],
		},
		{
			"src":  "tag:dev-pod",
			"deny": ["tag:apps:443", "tag:infra:443", "tag:tsidp:443", "tag:k8s-node:22"],
		},
		{
			"src":    "tag:ci",
			"accept": ["svc:argocd:443"],
			"deny":   ["tag:infra:443", "tag:apps:443"],
		},
	],
}
```
