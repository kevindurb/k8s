# Secrets

## Bitwarden Secrets

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
  secretName: {NAME}
  map:
    - secretKeyName: {KEY}
      bwSecretId: {SECRET_ID}
  authToken:
    secretName: bw-auth-token
    secretKey: token
```

### Use In Env
```yaml
env:
  - name: {ENV_NAME}
    valueFrom:
      secretKeyRef:
        name: {NAME}
        key: {KEY}
```
