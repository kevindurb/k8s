# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo purpose

Kevin's homelab GitOps repo: Kubernetes manifests, Ansible playbooks, and a bootc/butane node image, all reconciled by Argo CD from this git repo. There is no application source code here — changes take effect by editing YAML and letting Argo CD sync (or by running the `just`/`ansible-playbook` commands below).

## Cluster hardware

Single k3s cluster (`clusters/borg`), 7 Fedora CoreOS/bootc nodes, all `amd64`:
- `unimatrix-01/02/03` — control-plane + etcd (tainted `NoSchedule`), 2 CPU / 16Gi each.
- `drone-01/02/03/04` — workers, untainted (general app + media workloads). `drone-01`, `02`, `04` expose `nvidia.com/gpu` capacity (GPU-operator managed, e.g. for Jellyfin/transcoding); `drone-02` has less RAM (8Gi) than the others (16Gi); `drone-04` has 8 CPUs vs 4 on the other drones. `drone-03` has no GPU.

Get current live details with `kubectl get nodes -o wide` / `kubectl describe node <name>`; don't assume the numbers above stay accurate — hardware gets added/changed over time.

## Common commands

Root `justfile`:
- `just check-kustomize` — builds every `kustomization.y*ml` under `apps`, `platform`, `infrastructure`, `clusters` with `kustomize build`. This is the main validation step and mirrors CI (`.github/workflows/check-kustomize.yml`).
- `just check-kustomize-changed <files...>` — same check, but scoped to the kustomization dirs owning the given changed files (used by the pre-commit hook).
- `just tmpl <type> <name>` — scaffold a new app: copies `apps/template` to `<type>/<name>` (e.g. `apps/<name>`) and rewrites `kustomization.yml`, `app.yml`, `gatus.yml`, `deployment.yml` via `yq`, then registers the new `app.yml` in the parent `kustomization.yml` via `kustomize edit add resource`. Use this instead of hand-copying an existing app when adding a new one.
- `just drain <node>` — `kubectl drain --delete-emptydir-data --ignore-daemonsets <node>`.
- `just get-kubeconfig` — pulls kubeconfig from `unimatrix-01` over SSH.
- `just pre-commit-install` — installs the pre-commit hooks (see below).

Validating a single app after editing it (faster than the full `check-kustomize`):
```
kustomize build apps/<name>
```

Pre-commit (`.pre-commit-config.yaml`): trailing-whitespace/EOF/merge-conflict/large-file/private-key checks, `yamllint` (config in `.yamllint.yml` — document-start required, 150-char line length), `ansible-lint`, and the kustomize-changed check above scoped to `apps|platform|infrastructure|clusters`.

Ansible (`ansible/justfile`, run from `ansible/`): `just ansible <args>` / `just playbook <args>` wrap `ansible`/`ansible-playbook -i ./inventory/prod.yml`. Shortcuts: `just ping [filter]`, `just reboot [filter]`, `just shutdown [filter]`, `just adhoc <module> [filter]`, `just sudo-adhoc <module> [filter]`.

## Architecture

### Argo CD app-of-apps, three top-level trees

`clusters/borg/kustomization.yml` is the entrypoint applied to the (single) cluster and includes three Argo CD `Application` manifests, each pointing at a top-level directory in this repo via `sources[].path`:
- `infrastructure/` — cluster plumbing: networking (metallb, kube-vip, tailscale, cloudflared, external-dns), storage (longhorn), observability (prometheus, alertmanager, kube-state-metrics, node-exporter, gatus), argocd itself, pihole, gpu-operator, node-feature-discovery.
- `platform/` — shared platform services apps depend on: cert-manager, bws-operator (Bitwarden Secrets Manager operator), smtp-relay, mosquitto, zigbee2mqtt. `envoy-gateway` also lives here but is deprecated (see Ingress/routing note below).
- `apps/` — user-facing applications (jellyfin, nextcloud, radarr/sonarr, syncthing, home-assistant, etc.), plus an `AppProject` (`apps/project.yml`) and one Argo CD `Application` per app (each app dir has its own `app.yml`).

Each subdirectory under these three trees is a Kustomize root with its own `kustomization.yml`; the parent dir's `kustomization.yml` just lists them as resources (see `apps/kustomization.yml`). Argo CD auto-syncs everything (`automated.enabled: true`, `selfHeal: true`, `prune: false`) — pruning is intentionally off, so removing an app requires deleting its resource line from the parent kustomization *and* removing the Argo CD Application manually (or letting it go orphaned) rather than relying on prune.

### Anatomy of one app (`apps/<name>/`)

Every real app follows the layout in `apps/template/` (copy this, or use `just tmpl apps <name>`):
- `app.yml` — the Argo CD `Application` (project: `apps`, source path `apps/<name>`, destination namespace `<name>`).
- `kustomization.yml` — sets `namespace`/`namePrefix` to `<name>`/`<name>-`, lists `deployment.yml` (and any extra manifests like `postgres.yml`), pulls in shared `components/` (see below), a `gatus` ConfigMap generator for healthcheck config, and a top-level label `app.kubernetes.io/name: <name>`.
- `deployment.yml` — multi-doc YAML: `Deployment` + `Service` + `Ingress`, using YAML anchors (`&labels`/`*labels`) to keep selector/template labels in sync. Container is always named `app`, component container port always named `http`.
- `gatus.yml` — a Gatus endpoint check (`http://<name>-app-service.<name>`), wired in via the `gatus` ConfigMap generator with label `gatus.io/enabled: 'true'` for Gatus's config-reloader to pick up.

### Ingress / routing

Standard, current pattern: plain `Ingress` with `ingressClassName: tailscale` (see `apps/template/deployment.yml`), served by the Tailscale Kubernetes operator (`infrastructure/tailscale`, Helm chart `tailscale-operator`), which owns that IngressClass and exposes services on the tailnet.

`platform/envoy-gateway` (Gateway API `HTTPRoute`/`Gateway`) and the `components/http-route-refs` component are **deprecated** — a leftover from before the move to the Tailscale operator + plain `Ingress`. Don't use `HTTPRoute` or `http-route-refs` for new apps; only `apps/jellyfin` still has a leftover `HTTPRoute` resource pending cleanup. Prefer removing `http-route-refs` from an app's `components:` list when you touch it, unless it's still routing something real.

### Shared Kustomize components (`components/*`)

These are `kind: Component` (not plain kustomizations) mixed into apps via each app's `components:` list — they patch or add resources rather than being applied standalone. Key ones:
- `app-pod-hardening` / `pod-hardening` — JSON-patch adds a restrictive `securityContext` (runAsNonRoot, uid/gid 1000, readOnlyRootFilesystem, drop ALL caps) to Deployments/CronJobs selected by `app.kubernetes.io/component=app`.
- `app-tmp-dirs` / `tmpdirs` — emptyDir tmp mounts (paired with the read-only-root-fs hardening above).
- `http-route-refs` — registers `nameReference` rules so `kustomize` correctly renames `Service`/`Gateway` refs inside `HTTPRoute` when `namePrefix` is applied. Deprecated along with `envoy-gateway`/`HTTPRoute` (see Ingress/routing note above); most apps still list it in `components:` but it's inert once there's no `HTTPRoute` resource left in the app.
- `bitwarden-secret-name-reference` — same idea for Bitwarden `BitwardenSecret` name references.
- `nas-media` / `nas` — patches in a shared NAS-backed PVC volume/mount (`nas-media` claim mounted at `/media`) for media apps like jellyfin/radarr/sonarr.
- `app-env`, `app-http-service`/`service`, `app-volume`, `host-networking`, `prometheus-scrape-app-service` — smaller composable patches/resources for env vars, extra Services, extra volumes, hostNetwork pods, and Prometheus scrape annotations respectively.

Components are additive/patch-only; always check whether an existing component covers what you need before writing new inline patches in an app's `kustomization.yml`.

### Secrets

Secrets are managed via the Bitwarden Secrets Manager operator (`platform/bws-operator`) using `BitwardenSecret` CRs that sync a Bitwarden Secrets Manager project into a native k8s `Secret`. Pattern documented in `docs/secrets.md`: define a `BitwardenSecret` (with `argocd.argoproj.io/sync-options: Replace=true` and an `authToken` secretRef), then consume the generated Secret via normal `env[].valueFrom.secretKeyRef` or `envFrom.secretRef`. Never commit raw secret values — only `bwSecretId` references.

### Node OS / provisioning (outside the k8s tree)

- `bootc/` — Containerfile + `overlay/` building the bootc (rpm-ostree/bootc) image used for cluster nodes (`ghcr.io/kevindurb/k8s-node`), including k3s systemd units, sysctl/module config for k8s and ZFS/longhorn, and a tuned profile. Built/pushed/signed (cosign) by `.github/workflows/build-bootc.yml` on changes under `bootc/**`.
- `butane/node.bu.j2` — Jinja2-templated Butane config (Ignition) for node first-boot config, rendered per-host presumably via the ansible inventory.
- `ansible/` — provisioning/upgrade playbooks (`provision.yml`, `upgrade.yml`, `pull-upgrade.yml`, `check-zfs.yml`) run against `inventory/prod.yml`; also has its own `Containerfile` building `ghcr.io/kevindurb/k8s-ansible`, built by `.github/workflows/build-ansible.yml` on changes under `ansible/**`.
- `tailscale/policy.hujson` — Tailscale ACL policy for the tailnet the cluster/ingress sits on.

### CI

GitHub Actions workflows (`.github/workflows/`) rebuild `bootc` and `ansible` container images on path-scoped pushes plus a weekly schedule, and run `check-kustomize.yml` (same command as `just check-kustomize`) on pushes touching `apps|platform|infrastructure|clusters`. Renovate (`.github/renovate.json`) auto-updates image digests/versions across the k8s manifests and Argo CD `app.yml` files, and auto-merges digest/lint/patch/minor bumps.

## Conventions to follow when adding/editing an app

- Container name is always `app`; HTTP container port is always named `http`; Service port name matches (`http`).
- Use YAML anchors for label pairs shared between a Deployment's `spec.selector.matchLabels` and `spec.template.metadata.labels` (see `apps/template/deployment.yml`).
- `namespace`/`namePrefix` in `kustomization.yml` match the app directory name.
- Always add a `gatus` ConfigMap generator entry pointing at that app's `gatus.yml` with label `gatus.io/enabled: 'true'`, so it shows up in the Gatus status page.
- Ingress uses `ingressClassName: tailscale` with `tailscale.com/proxy-group`/`tailscale.com/tags` annotations, served by the Tailscale operator. Do not use `HTTPRoute`/envoy-gateway for new apps — that path is deprecated.
- Run `kustomize build apps/<name>` (or `just check-kustomize`) before considering a manifest change done.
