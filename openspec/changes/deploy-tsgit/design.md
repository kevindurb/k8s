# Design

## Context

See `proposal.md` for motivation and `specs/tsgit/spec.md` for the behavior contract.

Constraints taken from the image's own contract (`docs/deployment.md`, `docs/configuration.md`, `Containerfile` in `kevindurb/tsgit`):

- Runs as UID/GID `10001:10001` (`tsgit`), not `1000`.
- `TSGIT_STATE_DIR=/var/lib/tsgit/state` (mode `0700`) and `TSGIT_REPO_ROOT=/var/lib/tsgit/repos` (mode `0750`) are set by the image; both are declared `VOLUME`s.
- `HOME=/var/lib/tsgit` and `TMPDIR=/var/lib/tsgit/tmp`, both on the image's root filesystem.
- Listeners (`443`, `80`) live in tsnet's userspace network stack, so nothing outside the pod can dial them and no ports need publishing.
- The auth key is read from `TS_AUTHKEY` (or `TS_AUTHKEY_FILE`) only until the node key lands in the state directory.
- Repo conventions: `apps/<name>/{app.yml,kustomization.yml,deployment.yml}`, namespace/namePrefix equal to the directory name, `zfs-generic-nvmeof-csi` for app data, `Recreate` for stateful single-instance apps, sealed secrets, PSS `baseline` enforce with `restricted` warn/audit.

## Goals / Non-Goals

**Goals:**

- Render and sync `apps/tsgit` through the existing app-of-apps with no new cluster-wide mechanism.
- Preserve the node identity across pod replacement so existing tailnet grants keep matching.
- Keep repository data independent of node state for backup purposes.
- Keep the pod compatible with the namespace's Pod Security labels without weakening them.

**Non-Goals:**

- Provisioning tailnet policy, tags, auth keys or the GHCR package from this repo (they live in `kevindurb/infra`, Tailscale admin, and GitHub package settings).
- Exposing tsgit to the cluster, LAN, or public internet by any second path.
- In-cluster monitoring of tsgit (see Decisions).
- Repository backups, mirroring or migration of existing repos.

## Decisions

### Deployment with `strategy: Recreate`, not a StatefulSet

A `Deployment` with `replicas: 1` and `strategy: Recreate` gives everything needed: a stable pod that can be rolled, and a hard guarantee that the old pod is gone before the new one starts, so two instances never hold the same tsnet node key or the same `ReadWriteOnce` volumes.

`StatefulSet` was considered and rejected: its stable network identity is irrelevant (there is no headless Service, and the app's identity is the tailnet node, not the pod name), and it would add `volumeClaimTemplates` complexity without changing behavior. `minecraft` and other stateful apps in this repo already use the `Recreate` pattern.

### No `Service`, no `Ingress`, no Tailscale operator resources

tsgit already embeds tsnet, so the pod is its own tailnet node and terminates its own listeners. The repo's standard `ingressClassName: tailscale` path would require a cluster-reachable port and would put a *second* tailnet node (the operator proxy) in front of the first, adding a hop, a tag, and a policy entry for no benefit.

The alternative — a Tailscale sidecar plus a normal Service — was rejected: it needs `NET_ADMIN`/`/dev/net/tun`, splits the identity used by the app from the identity that owns the listeners, and contradicts the image's documented deployment model.

### Inline `securityContext` instead of the `app-pod-hardening` component

`components/app-pod-hardening` hardcodes `runAsUser/runAsGroup/fsGroup: 1000`. tsgit's image is `10001` and its state directory is created `0700` for that user, so applying the component would break startup. The component is not parameterizable, and adding a second near-identical component for one app is worse than four lines of explicit context. `apps/immich` sets an explicit precedent for the same situation.

The pod gets `runAsNonRoot: true`, `runAsUser/runAsGroup/fsGroup: 10001`, `seccompProfile: RuntimeDefault`, and the container gets `privileged: false`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`.

`components/app-tmp-dirs` is also not used: it would add `/tmp`, `/var/tmp`, `/var/run`, `/run`, `/var/cache`, `/var/log` as writable emptyDirs that tsgit does not need. The single writable scratch path is an `emptyDir` mounted at `/var/lib/tsgit/tmp`, which is what the image's `TMPDIR` points at, so git's temporary files land there without overriding the image's environment.

### Storage: two `zfs-generic-nvmeof-csi` PVCs

`state` (1Gi) and `repos` (20Gi) as separate PVCs, both `ReadWriteOnce`, `storageClassName: zfs-generic-nvmeof-csi` — the repo's default for application data and the class that survives node reschedules by reattaching the zvol.

Separating them is an image contract, not a preference: the state volume holds the node key and must not be swept into repository backups, while the repository volume is the durable artifact. `fsGroup: 10001` makes both writable for the image's user.

The NAS (`nas-media` / NFS-backed) alternative was rejected: git object access is random I/O with renames and lock files, which the block-backed zvol handles predictably, and the NAS export is shaped for large media, not small-file workloads.

Sizes are deliberately modest: repositories are text and packfiles. Expansion is a PVC resize.

### Image reference: `ghcr.io/kevindurb/tsgit:main` pinned by digest

The project has no release tags yet (`latest` is only published on a `vX.Y.Z` tag), so `main` is the only usable tag. Pinning the digest keeps deployments reproducible between Renovate runs while still letting Renovate bump it, exactly as `apps/minecraft` pins `java25@sha256:...`. A release tag should replace `main` once the project publishes one.

### Public GHCR package, no image pull secret

Anonymous pulls currently fail (401), so the image is private. Per the owner's decision, the package will be made public instead of storing a registry credential in the cluster. This removes a secret, an `imagePullSecrets` reference, and a renewal problem; the accepted trade-off is that the image bytes are publicly readable while the forge itself stays tailnet-only.

Alternatives kept on record: a committed `SealedSecret` of type `kubernetes.io/dockerconfigjson`, or the out-of-band `ghcr-creds` secret that `apps/consignment-app` relies on. Both add a credential that must be rotated.

### Auth key as a `SealedSecret` named to survive the `namePrefix`

The `SealedSecret` is committed as `apps/tsgit/auth-sealed-secret.yml` with `metadata.name: auth` and `namespace: tsgit`. Kustomize's `namePrefix: tsgit-` turns it into `tsgit-auth`, which is the name the controller generates and the name the deployment references in `env[].valueFrom.secretKeyRef`. Sealing must therefore be done against the final name `tsgit-auth` in namespace `tsgit` (the pitfall documented in `docs/secrets.md`).

`TS_AUTHKEY` is passed as an environment variable rather than a mounted file: it is a single short value, and the key is only used on first registration. `TS_AUTHKEY_FILE` would add a volume for no security gain.

### No readiness/liveness probes and no Gatus endpoint

There is no cluster-reachable socket to probe and no `exec` command that reflects tailnet health (`tsgit version` only proves the binary exists). Failure detection is therefore: pod phase and restart count in the cluster, and the forge itself as seen from a tailnet peer. A probe that cannot observe the real failure mode is noise, so none is declared.

For the same reason no `gatus.yml` is created. Gatus runs in-cluster with cluster DNS; it cannot resolve MagicDNS names, and no cluster route leads to the tsnet node's address. This is a deliberate documented deviation from the "every app has a Gatus check" convention. Restoring parity would need either a Tailscale sidecar in the Gatus pod or an external monitor on a tailnet device — both are separate changes.

### No `NetworkPolicy`

tsgit needs egress to `controlplane.tailscale.com`, DERP relays, and direct peer endpoints (UDP), plus DNS. The repo has no default-deny policy and this app gets none, so unrestricted egress is the default. A future default-deny would need an explicit allow for these flows.

## Risks / Trade-offs

- **Losing the state volume silently re-registers the node.** ACL grants that name `tag:tsgit` keep working; grants that name the specific node would stop matching, and the node reuses the hostname `tsgit`. → Treat the state PVC as disposable but avoid deleting it; document that after state loss the pod needs a fresh auth key and the node appears as a new device.
- **Private package blocks the first sync.** If GHCR visibility is not changed first, the pod sits in `ImagePullBackOff`. → Make package visibility the first prerequisite in `tasks.md` and verify anonymously before syncing.
- **`main` moves underneath the deployment.** → Digest pin plus Renovate; move to a release tag when one exists.
- **Single replica means downtime on every restart**, including a `Recreate` rollout during a push. → Accepted: a homelab forge with one user, and git clients tolerate retry.
- **`readOnlyRootFilesystem` with `HOME=/var/lib/tsgit` unwritable** could break a future tsgit/git version that writes to `$HOME`. → If that happens, mount an `emptyDir` at `/var/lib/tsgit` in addition to the two PVC mounts; it nests cleanly with the existing mount points.
- **PVC ownership assumptions.** If the CSI driver's mount root is not group-writable for `fsGroup: 10001`, startup fails on the state or repository path. → Check the first pod's logs; `fsGroupChangePolicy: OnRootMismatch` or an init container are the fallbacks, in that order.
- **No in-cluster alerting for tsgit.** A wedged process is visible only as a pod status or a user-visible failure. → Accepted for now; a tailnet-side monitor is a follow-up, not part of this change.
- **Tailnet policy drift.** The deployment advertises `tag:tsgit`; if `tagOwners` or the `cap/repo` grant changes, the pod still runs but the forge returns `404` for everyone. → The prerequisite task verifies the policy before the sync, and the risk is called out in the spec's authorization scenarios.

## Migration Plan

1. External prerequisites, in order: make the GHCR package public; add `tag:tsgit` to `tagOwners` and the `cap/repo` grant in `kevindurb/infra`; create a tag-scoped, reusable auth key.
2. Commit the manifests and the `SealedSecret`; Argo CD creates the namespace, secret, PVCs and deployment.
3. Verify from a tailnet device: index loads, a push creates a repository, a clone returns it.
4. Rollback: remove `./tsgit/app.yml` from `apps/kustomization.yml` and delete the Argo CD `Application` — with `prune: false` the workload and data are left in place. Destroying the volumes (and the repositories on them) is a separate, explicit manual action.
