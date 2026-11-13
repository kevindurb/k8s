# Tasks

## 1. Scaffold the app

- [x] 1.1 Run `just tmpl apps livesync`, then remove the template's sample `deployment.yml` bodies that do not apply, and verify `apps/livesync/app.yml` and `apps/livesync/kustomization.yml` exist and `./livesync/app.yml` appears once in `apps/kustomization.yml`
- [x] 1.2 Point `app.yml` at `apps/livesync` with destination namespace `livesync` and add the standard `managedNamespaceMetadata` pod-security labels (baseline enforce, restricted warn/audit); verify `kustomize build apps/livesync` renders the `Application` with those labels
- [x] 1.3 Set `kustomization.yml` to `namespace: livesync`, `namePrefix: livesync-`, and the `app.kubernetes.io/name: livesync` label; verify `kustomize build apps/livesync` shows prefixed resource names and the label on every object

## 2. Server configuration

- [x] 2.1 Add a ConfigMap source with a CouchDB ini fragment setting `[chttpd] bind_address = 0.0.0.0`, `require_valid_user = true`, `enable_cors = true`, `[cors] origins` for `app://obsidian.md`, `capacitor://localhost` and `http://localhost`, and `[compactions] _default` thresholds; verify `kustomize build apps/livesync` renders it and the rendered value contains all three origins
- [x] 2.2 Add a `config-init` init container that copies the image's `/opt/couchdb/etc` into a shared `emptyDir` and installs the ini fragment under its `local.d/`, and mount that `emptyDir` at `/opt/couchdb/etc` in the main container; verify `kustomize build` shows both mounts and that the main container has `readOnlyRootFilesystem: true`
- [x] 2.3 Add the `postStart` hook that waits for `/_up`, creates the vault database, upserts the vault user document in `_users`, and sets `_security`; keep it idempotent (`412`/`409` handled) and verify the script is syntactically valid with `sh -n` on the extracted command
- [x] 2.4 Define the main container (`couchdb` image tag+digest, name `app`, port `http` 5984), `COUCHDB_USER`/`COUCHDB_PASSWORD` from the `livesync-credentials` Secret, a writable `/tmp` `emptyDir`, and readiness/liveness probes on `/_up`; verify `kustomize build apps/livesync` contains every field and no plaintext credential
- [x] 2.5 Add the 10Gi `zfs-generic-nvmeof-csi` PVC mounted at `/opt/couchdb/data`, plus `replicas: 1` and `strategy: Recreate`; verify `kustomize build` shows one replica, the Recreate strategy, and the claim name on both the mount and the PVC
- [x] 2.6 Give the pod an explicit securityContext (non-root uid/gid of the image's `couchdb` user, seccomp RuntimeDefault, no privilege escalation, all capabilities dropped) instead of `components/app-pod-hardening`, and verify the rendered pod spec has no `runAsUser: 0` and no added capabilities
- [x] 2.7 Add the `Service` (port 80 named `http` to container 5984) and the `Ingress` with `ingressClassName: tailscale`, `tailscale.com/proxy-group: ingress-proxy-group`, `tailscale.com/tags: tag:apps`, and `tls.hosts: [livesync]`; verify `kustomize build` contains no Funnel annotation, no `hostPort`, and no NodePort

## 3. Credentials

- [x] 3.1 Create a plain temporary Secret with `admin-user`, `admin-password`, `vault-user`, `vault-password`, seal it with the cluster key into `apps/livesync/credentials-sealed-secret.yml` named `credentials` so the unsealed name is `livesync-credentials`, delete the plaintext file, and verify `yq '.metadata.name = "livesync-credentials"' apps/livesync/credentials-sealed-secret.yml | kubeseal --validate` passes
- [x] 3.2 Confirm `git grep -nEi 'password|secretkey' apps/livesync` reports only the `SealedSecret` structure and env references, never a value

## 4. Health check

- [x] 4.1 Add `gatus.yml` with endpoint `http://livesync-app-service.livesync` and `[STATUS] == 401`, wire it through the `gatus` ConfigMap generator with `gatus.io/enabled: 'true'`, and verify `kustomize build apps/livesync` renders a ConfigMap carrying that label and the 401 condition

## 5. Repository validation

- [x] 5.1 Run `just check-kustomize` and confirm it passes for `apps/livesync` and the parent `apps` tree
- [x] 5.2 Run the repo pre-commit hooks on the changed files and confirm yamllint, EOF, and kustomize-changed checks pass

## 6. Cluster verification

- [ ] 6.1 Sync the Application and confirm the namespace carries the pod-security labels, the pod reaches Ready, the init container completed, and the PVC is Bound (`kubectl -n livesync get ns,pods,pvc` plus `kubectl -n livesync logs deploy/livesync-app-deployment -c config-init`)
- [ ] 6.2 Confirm the deployment appears in the reboot playbook's plan by running `just playbook reboot-drone-04.yml -e dry_run=true` and checking the printed scale targets include `livesync/livesync-app-deployment`
- [ ] 6.3 From a tailnet device, verify unauthenticated `GET https://livesync.<tailnet>.ts.net/` returns `401`, authenticated admin `GET` returns the CouchDB welcome document, and the TLS chain is trusted without warnings
- [ ] 6.4 Verify CORS for all three origins with `curl -H 'Origin: <origin>'` and confirm each allowed origin is echoed while an unrelated origin is not
- [ ] 6.5 Verify the `postStart` result: the vault database exists in `_all_dbs`, `_security` lists only the vault user as member, the vault user can write to that database, and admin-only endpoints refuse the vault user
- [ ] 6.6 Restart the pod twice and confirm the database, documents written by the vault user, and the vault user's password all still work, proving initialisation is idempotent and the seeded config survives
- [ ] 6.7 Confirm Gatus reports the endpoint healthy, then scale the deployment to 0 and confirm it turns unhealthy, then restore it and confirm it returns to healthy

## 7. Client bring-up and rehearsal

- [ ] 7.1 Write `docs/obsidian-livesync.md` with the operational procedure (server URL, credentials, rehearsal-then-real vault order, E2EE on before first sync, Customisation Sync instead of Hidden File Sync, passphrase and Setup URI storage, rollback by deleting the Application) and verify each command and setting name in it against the running deployment
- [ ] 7.2 On the desktop, create a disposable rehearsal vault, connect the LiveSync plugin, and verify a note created locally appears remotely and survives a pod restart
- [ ] 7.3 On iOS with Tailscale connected, open the same rehearsal vault and verify a note created on the phone appears on the desktop and an offline edit made with the VPN off queues and syncs once reconnected
- [ ] 7.4 Enable Customisation Sync with plugins/snippets/themes, verify a new plugin appears on the second device, and confirm `workspace.json` is not synced
- [ ] 7.5 Create the real vault with E2EE enabled from the first sync, store the passphrase and Setup URI outside the cluster, connect the remaining devices, and remove the Obsidian vault from Syncthing on each device once both directions are verified

## Workflow follow-up

- Archive the change after the deployment and the two-device rehearsal are verified.
- Verify the archived result and that `openspec/specs/obsidian-sync/spec.md` exists with the requirements above.
