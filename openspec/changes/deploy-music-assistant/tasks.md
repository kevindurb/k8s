# Tasks

## 1. Scaffold the application

- [x] 1.1 Run `just tmpl apps music-assistant` and verify `apps/music-assistant/{app.yml,deployment.yml,gatus.yml,kustomization.yml}` exist and `apps/kustomization.yml` contains `./music-assistant/app.yml`
- [x] 1.2 Replace the scaffolded `app.yml` with the media-app shape: project `apps`, destination namespace `music-assistant`, `CreateNamespace=true`, automated sync with `prune: false`, and the documented `# exemption: hostNetwork …` comment above `managedNamespaceMetadata`; verify with `yq '.spec' apps/music-assistant/app.yml` and `kubectl apply --dry-run=client -f apps/music-assistant/app.yml`
- [x] 1.3 Set `kustomization.yml` to `namespace: music-assistant`, `namePrefix: music-assistant-`, components `storage-home-drone-01`, `app-pod-hardening`, `app-tmp-dirs`, `nas-media`, the gatus generator and the `app.kubernetes.io/name` label; verify with `kustomize build apps/music-assistant` that the gatus ConfigMap and label are present

## 2. Deployment, storage and networking

- [x] 2.1 Write the Deployment with the pinned image `ghcr.io/music-assistant/server:2.10.12@sha256:7eb272e2e13da9a5d61dcbc4e1fcfc734776222b23f2825a9b5690d4427cfafb`, `replicas: 1`, `strategy: Recreate`, and env `TZ=America/Denver`, `LOG_LEVEL=info`, `HOME=/data`; verify `kustomize build apps/music-assistant` shows the digest and all three env vars
- [x] 2.2 Add `hostNetwork: true` with `dnsPolicy: ClusterFirstWithHostNet` and a comment naming the mDNS/uPnP and stream-port reason; verify both fields render on the Deployment pod spec
- [x] 2.3 Declare the `data` claim (10Gi, `zfs-local`) and the `nas-media` claim, mounting `data` at `/data` and `nas-media` at `/music` with `subPath: Music` and `readOnly: true`; verify the rendered manifest shows both claims as `music-assistant-data` / `music-assistant-nas-media`, the subPath, and the read-only mount
- [x] 2.4 Add the port `http` 8095, a `startupProbe` (30 × 10 s) plus readiness/liveness probes all on `/`, and memory requests 512Mi / limits 4Gi; verify the rendered probes target the `http` port and the limits are present
- [x] 2.5 Add the `app-service` Service (80 → `http`) and the tailscale `Ingress` with `ingress-proxy-group`, `tag:media` and host `music-assistant`; verify the rendered Service selector matches the pod labels and the Ingress has no Funnel tag

## 3. Monitoring

- [x] 3.1 Write `gatus.yml` with endpoint `music-assistant`, group `apps`, URL `http://music-assistant-app-service.music-assistant` and condition `[STATUS] == 200`; verify `kustomize build apps/music-assistant` renders it in the gatus ConfigMap with the `gatus.io/enabled: 'true'` label

## 4. Documentation

- [x] 4.1 Add `music-assistant | 10Gi / ~0 + music-assistant-nas-media` to the drone-01 table in `docs/storage-placement.md` and adjust the node total; verify the table row and total are consistent with the rendered claim sizes

## 5. Integration verification

- [x] 5.1 Run `just check-kustomize` and confirm every kustomization builds, matching CI
- [ ] 5.2 After Argo CD syncs, verify the pod is `1/1` on drone-01 with `INTERNAL-IP`/pod IP `192.168.42.21`, the data claim is bound on drone-01, and `kubectl -n music-assistant exec deploy/music-assistant-app-deployment -- ls /music | head` lists the library (write attempt fails read-only)
- [ ] 5.3 Verify the UI answers at `http://192.168.42.21:8095/` (200 or redirect to `/setup`) and that `https://music-assistant.beaver-cloud.ts.net/` responds through the tailnet ingress, then confirm the Gatus endpoint is green
- [ ] 5.4 Complete the first-run setup at `/setup`, add the Filesystem provider at `/music`, and confirm at least one LAN speaker is discovered and plays; record whether any provider needed a writable path outside `/data`

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied.
- Verify the archived spec landed at `openspec/specs/music-assistant/spec.md` with its purpose intact.
