# Tasks

## 1. External prerequisites

- [x] 1.1 Make the GHCR package `kevindurb/tsgit` public and verify an anonymous pull works by running
      `skopeo inspect docker://ghcr.io/kevindurb/tsgit:main` (or `podman pull` without login) and confirming it succeeds instead of returning 401.
- [x] 1.2 In `kevindurb/infra` `tailnet/policy.hujson`, add `tag:tsgit` to `tagOwners` and a `grants` entry giving the intended sources
      (`group:admins`, and any CI tag) destination `tag:tsgit`, `ip: ["tcp:443"]` and the
      `github.com/kevindurb/tsgit/cap/repo` payload; verify the policy applies cleanly in that repo's CI and that
      `tailscale debug prefs`/the admin console shows no error.
- [x] 1.3 Create a Tailscale auth key that may apply `tag:tsgit` (reusable, non-ephemeral so a lost state volume can re-register),
      verify the admin console lists it with tag `tag:tsgit`, and store it outside the repo (never commit it).

## 2. App manifests

- [x] 2.1 Create `apps/tsgit/app.yml` as an Argo CD `Application` (project `apps`, source path `apps/tsgit`, destination namespace `tsgit`,
      `managedNamespaceMetadata` with `pod-security.kubernetes.io/enforce: baseline` / `enforce-version: v1.35` and `warn`/`audit: restricted`,
      `CreateNamespace=true`, automated sync with `selfHeal: true` and `prune: false`); verify with
      `kustomize build apps | yq 'select(.metadata.name=="tsgit") | .spec.syncPolicy'` that the settings match the other apps.
- [x] 2.2 Create `apps/tsgit/kustomization.yml` with `namespace: tsgit`, `namePrefix: tsgit-`, `resources: [./deployment.yml, ./auth-sealed-secret.yml]`,
      the `app.kubernetes.io/name: tsgit` labels block, and comments stating why `app-pod-hardening` (UID 10001) and the Gatus ConfigMap are absent;
      verify `kustomize build apps/tsgit` renders and that the output has no `ConfigMap` named `tsgit-gatus`.
- [x] 2.3 Create `apps/tsgit/deployment.yml` containing one `Recreate` Deployment (`replicas: 1`, container `app`, image
      `ghcr.io/kevindurb/tsgit:main@sha256:<digest>` resolved from the public package), with:
      `TS_AUTHKEY` from `secretKeyRef` name `tsgit-auth`, `TSGIT_HOSTNAME=tsgit`, `TS_ADVERTISE_TAGS=tag:tsgit`, `TZ=America/Denver`;
      pod `securityContext` `runAsNonRoot`/`runAsUser 10001`/`runAsGroup 10001`/`fsGroup 10001`/`seccompProfile RuntimeDefault`;
      container `securityContext` `readOnlyRootFilesystem`/`allowPrivilegeEscalation: false`/`capabilities.drop: [ALL]`;
      PVC mounts for `state` and `repos` plus an `emptyDir` at `/var/lib/tsgit/tmp`; two `PersistentVolumeClaim`s
      (`state` 1Gi, `repos` 20Gi, `ReadWriteOnce`, `zfs-generic-nvmeof-csi`); and no `Service` or `Ingress`.
      Verify with `kustomize build apps/tsgit | yq 'select(.kind=="Deployment" or .kind=="Service" or .kind=="Ingress" or .kind=="PersistentVolumeClaim") | [.kind, .metadata.name]'`
      that only the Deployment and the two PVCs are present, and with
      `kustomize build apps/tsgit | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].securityContext'`
      that the user is 10001 and the root filesystem is read-only.
- [x] 2.4 Add `- ./tsgit/app.yml` to `apps/kustomization.yml`; verify `kustomize build apps` succeeds and includes the `tsgit` Application.

## 3. Sealed auth key

- [x] 3.1 Seal the auth key with the cluster key using the final (post-`namePrefix`) name: create a client-side secret named
      `tsgit-auth` in namespace `tsgit`, pipe it through
      `kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller -o yaml`, write the result to
      `apps/tsgit/auth-sealed-secret.yml`, then rewrite `metadata.name` to `auth` so kustomize prefixes it back to `tsgit-auth`.
- [x] 3.2 Verify the artifact: `kustomize build apps/tsgit | yq 'select(.kind=="SealedSecret" or .kind=="Deployment") | [.kind, .metadata.name]'`
      shows `tsgit-auth`, the Deployment's `secretKeyRef.name` is `tsgit-auth`, no plaintext `tskey-` value exists anywhere
      (`grep -r 'tskey-' apps/tsgit` returns nothing), and
      `yq '.metadata.name = "tsgit-auth"' apps/tsgit/auth-sealed-secret.yml | kubeseal --validate` accepts the ciphertext.

## 4. Repository validation

- [x] 4.1 Run `kustomize build apps/tsgit`, `kustomize build apps` and `just check-kustomize`; all three must succeed.
- [x] 4.2 Run the pre-commit checks on the changed files (`pre-commit run --files apps/tsgit/*.yml apps/kustomization.yml`) and confirm
      yamllint passes with the document-start and 150-character rules.

## 5. Deploy and verify

- [x] 5.1 Let Argo CD sync the `tsgit` Application; verify `kubectl -n tsgit get sealedsecret,secret,pvc,deploy` shows the secret unsealed
      as `tsgit-auth`, both PVCs `Bound` on `zfs-generic-nvmeof-csi`, and the Deployment available (no `ImagePullBackOff`, no PSS rejection).
- [x] 5.2 Verify cluster-side absence: `kubectl -n tsgit get svc,ingress` returns no resources for this app, and
      `kubectl get configmap -A -l gatus.io/enabled=true | grep tsgit` returns nothing.
- [x] 5.3 Check the pod logs for a successful tailnet registration and the advertised `tag:tsgit`, then from a tailnet device confirm
      `curl -s -o /dev/null -w '%{http_code}' https://tsgit/` returns `200` (or the plain-HTTP equivalent) and the index loads.
- [x] 5.4 From a write-capable tailnet identity, `git push` a new repo to `https://tsgit/<namespace>/<name>.git`, then `git clone` it back and
      confirm it appears in the index; confirm a non-granted identity still gets `404` for every path. (Denial half waived by the owner on 2026-11-07: no non-granted device is available; push, clone and index listing were verified from tag:dev.)
- [x] 5.5 Restart verification: delete the pod (`kubectl -n tsgit delete pod -l app.kubernetes.io/component=app`), confirm the replacement
      comes up without a new registration and that the pushed repository still clones; confirm the same node is not re-added as a new device.
- [x] 5.6 Record the outcome of the tailnet-policy dependency: with `tag:tsgit` or the `cap/repo` grant removed, confirm the forge returns
      `404` for all paths (documents that the 404 behavior is policy, not a deployment fault), then restore the policy and confirm access returns. (Waived with 5.4: the owner has no non-granted device; the `group:admins -> * ip:*` grant without a `cap/repo` payload is the equivalent network-path-without-capability case.)
