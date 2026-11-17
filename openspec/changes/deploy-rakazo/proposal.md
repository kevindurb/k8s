# Proposal

## Why

[Rakazo](https://rakazo.com/) is an Apache-2.0, self-hostable platform for persistent AI "bots" that
keep routines, drive a browser and a shell, and ask for approval before crossing a boundary. Every
part of it that holds state — Postgres, bot homes, browser profiles, the audit log — is meant to run
on hardware the operator owns, and this cluster already has the pieces it needs: k3s, the Tailscale
ingress operator for HTTPS on the tailnet, SealedSecrets for credentials, and the in-cluster Aperture
gateway (`ai.beaver-cloud.ts.net`) for models. Today the alternative is the hosted beta, which moves
bot data off the homelab. Deploying it here keeps prompts and bot state on Kevin's hardware and gives
the tailnet an agent surface without a new internet-facing service.

## What Changes

- Add `apps/rakazo`: a Kustomize root plus Argo CD `Application` (namespace `rakazo`) running the
  three Rakazo processes — `api`, `worker`, `web` — against an in-cluster PostgreSQL 18, with three
  PVCs on the `zfs-generic-nvmeof-csi` class, a `SealedSecret` for all deployment secrets, and two
  generated ConfigMaps (`rakazo-config`, `rakazo-migration-state`).
- Serve the app on the tailnet only: plain `Ingress{ingressClassName: tailscale}` with the shared
  `ingress-proxy-group`, `https://rakazo.beaver-cloud.ts.net`, no Funnel and no public listener.
  `BETTER_AUTH_URL`, `WEB_ORIGIN` and `API_URL` are all that one origin.
- Sign in through Pocket ID: Rakazo's app-native OpenID Connect support pointed at
  `https://idp.beaver-cloud.ts.net` with a `rakazo` client (id `rakazo`, secret in a committed
  `SealedSecret`), a `Pocket ID` button label, and the redirect URI
  `https://rakazo.beaver-cloud.ts.net/api/auth/callback/oidc` registered on that client. Password
  sign-in stays enabled and registration stays closed, so the owner account from the bootstrap step
  links its Pocket ID identity from an authenticated session and SSO never creates accounts.
- Run the schema migration and the owner-bootstrap Jobs from Argo CD itself, ordered by sync waves, so
  a git push is the whole deploy and there is no manual `kubectl apply` sequence.
- Add `apps/rakazo-sandboxes`: the boundary for bot "computers" (the sandbox Pods bots use for browser
  and shell work) — a dedicated namespace, a scoped `ServiceAccount`/`Role`/`RoleBinding` for Pod
  create/get/delete and exec, a `ResourceQuota` and `LimitRange` capping concurrent computers, an
  egress-restricted `NetworkPolicy`, and a `ValidatingAdmissionPolicy` that pins the computer image,
  refuses host mounts, extra containers and Secret-sourced env vars. `SANDBOX_PROVIDER=kubernetes`.
- Wire models to the in-cluster Aperture gateway instead of an external API: `RAKAZO_LOCAL_MODELS*`
  pointed at `https://ai.beaver-cloud.ts.net/v1` with Aperture identity auth, `PI_DEFAULT_PROVIDER=local`,
  so no model key is committed and prompts stay on owned hardware.
- Add explicit `NetworkPolicy` for the `rakazo` namespace: default-deny in both directions, with the
  allowed flows written out (Tailscale proxies and Gatus to `web`, `web` to `api`, all three to
  PostgreSQL and to the sandbox namespace, public HTTP(S) and the Aperture egress path, and the k3s
  API endpoint for the sandbox controller).
- Pin `ghcr.io/elie222/rakazo/app` and `ghcr.io/elie222/rakazo/computer` to the matching `v0.12.0`
  digests, keep the computer digest as the single source of truth in `config.env` (rendered into the
  admission policy by a Kustomize replacement), and teach Renovate to update it and to keep the pair
  in one PR.
- Add `docs/rakazo.md` for the operational parts the manifests cannot show: origin and tailnet
  expectations, `ENCRYPTION_KEY` backup, the app/computer image pairing and migration-inventory
  procedure, and how to verify the computer boundary.
- **BREAKING**: none. Nothing existing is modified; no HTTPRoute/Gateway resources are introduced.

## Capabilities

### New Capabilities

- `rakazo`: the deployed application surface — tailnet-only HTTPS origin with a single-owner account,
  closed signups and Pocket ID single sign-on, GitOps delivery and sync ordering, persisted state on
  cluster storage, the Aperture-backed model default, health checking, and the guarantee that no
  public or LAN listener exists.
- `rakazo-computers`: the bot computer boundary — Kubernetes-scheduled sandbox Pods, the narrow RBAC
  the controller holds, image and shape admission, capacity limits, and the egress rules that let a
  computer reach the public web while keeping node, cluster, database and private-network traffic
  out of reach.

### Modified Capabilities

None. `tsgit` and the other existing apps are untouched.

## Impact

- New Kustomize roots `apps/rakazo` and `apps/rakazo-sandboxes`, each with its own `app.yml`,
  registered in `apps/kustomization.yml`.
- New namespaces `rakazo` and `rakazo-sandboxes`, both created by their `Application` with the
  standard `baseline` enforce / `restricted` warn+audit labels.
- Three new PVCs on `zfs-generic-nvmeof-csi` (database 20Gi, bot data 30Gi, web assets 2Gi). That class
  is the one `ansible/reboot-drone-04.yml` already discovers and scales down, so the drone-04 reboot
  procedure covers this app with no playbook change.
- New `SealedSecret` in `rakazo` (Postgres owner and app logins, `DATABASE_URL`,
  `DATABASE_MIGRATION_URL`, `ENCRYPTION_KEY`, `BETTER_AUTH_SECRET`, `SCREEN_PROXY_SECRET`,
  `OWNER_PASSWORD`) created with the existing kubeseal flow; nothing plaintext is committed.
- A second `SealedSecret` (`oidc` → `rakazo-oidc`) holding `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET`
  for the Pocket ID client, mounted on the API only. `platform/pocket-id` itself is unchanged: the
  client is created through its API with the existing `STATIC_API_KEY`, per
  `docs/tsidp-to-pocket-id.md`.
- One operational step on Pocket ID that the repo cannot express: the new `rakazo` client gets its
  allowed user group (a fresh client admits nobody). The browser already reaches
  `idp.beaver-cloud.ts.net` for the other SSO apps, so no tailnet policy change is expected; the API
  reaches it in-cluster through the same `idp` ExternalName and `oidc-egress` proxies that the
  existing OIDC apps use, which the app namespace's existing `tailscale:443` egress rule covers.
- `api` and `worker` share one RWO zvol, so both are pinned to a single node with a `nodeSelector`
  rather than being free to schedule.
- New cluster-wide `ValidatingAdmissionPolicy`/`Binding` (`rakazo-computers`) and the first
  egress-restricting `NetworkPolicy` in a user namespace — a deliberate exception to
  `docs/network-segmentation.md`'s "egress stays open until phase 4", justified by computers running
  agent-controlled code.
- External prerequisite outside this repo: the tailnet policy in `kevindurb/infra` must grant
  `tag:k8s-ai` (the `ai-egress` ProxyGroup identity) a role plus models on `tag:ai`, and the grant must
  include the model IDs listed in `RAKAZO_LOCAL_MODELS`; without it model calls return `404`/`403`.
- `config.env` (owner email, origins) must be edited before the first sync; the proposal ships a
  placeholder so the manifests are complete.
- `.github/renovate.json` gains one `customManager` and one grouping `packageRule` for the
  app/computer digest pair.
- No change to existing apps, components, the bootc image, or Ansible.
