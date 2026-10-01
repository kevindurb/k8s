# Secrets

## Sealed Secrets (current)

Secrets are managed via [sealed secrets](https://github.com/bitnami-labs/sealed-secrets) (`platform/sealed-secrets`): commit `SealedSecret` CRs encrypted with the cluster's private key, and the `sealed-secrets-controller` (chart in `kube-system`, name `sealed-secrets-controller`) unseals them into native k8s `Secret`s that work unchanged with `env[].valueFrom.secretKeyRef` / `envFrom.secretRef`.

Workflow:

1. Create a plain Secret locally (never commit this):

```sh
kubectl create secret generic { NAME } \
  --from-literal={ KEY }='{ VALUE }' -o yaml > { NAME }.secret.yml
```

2. Seal it with the cluster key and write the `SealedSecret`:

```sh
kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller < { NAME }.secret.yml > { NAME }-sealed-secret.yml
rm { NAME }.secret.yml
```

3. Commit the `SealedSecret` (see `apps/linkding/tsidp-sealed-secret.yml` for an example) and reference the generated `Secret` by name as usual. The default scope is strict (exact name + namespace), so the `SealedSecret` metadata must match what the app references.

The controller's private key is the root of trust — back it up after installing or rekeying:

```sh
just -f platform/sealed-secrets/justfile export-secrets
```

**Never commit raw secret values — only `SealedSecret` encrypted data.**

## Bitwarden Secrets (deprecated)

> **DEPRECATED: Bitwarden Secrets Manager is being migrated to Sealed Secrets — convert `BitwardenSecret` CRs to `SealedSecret`s as you touch them (workflow above).**

Kept for reference while existing usages are converted (marked with `DEPRECATED` comments in the manifests):

### Secret

```yaml
---
apiVersion: k8s.bitwarden.com/v1
kind: BitwardenSecret
metadata:
  name: secret
  annotations:
    argocd.argoproj.io/sync-options: Replace=true
spec:
  organizationId: 575f69b2-49f4-456d-bd6f-b14101103188
  secretName: { NAME }
  map:
    - secretKeyName: { KEY }
      bwSecretId: { SECRET_ID }
  authToken:
    secretName: bw-auth-token
    secretKey: token
```

### Use In Env

```yaml
env:
  - name: { ENV_NAME }
    valueFrom:
      secretKeyRef:
        name: { NAME }
        key: { KEY }

envFrom:
  secretRef:
    name: { NAME }
```
