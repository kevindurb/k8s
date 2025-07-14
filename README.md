# Kubernetes Infrastructure

This repository contains Kubernetes infrastructure configurations managed using GitOps principles with ArgoCD and Kustomize.

## Overview

The infrastructure includes:
- Application deployments organized by namespace
- Kubernetes cluster configuration via Talos OS and BootC
- Infrastructure components (storage, monitoring, networking)
- Secret management via Bitwarden Secrets Manager

## Quick Start

See [CLAUDE.md](./CLAUDE.md) for comprehensive development guidelines and common commands.

## Secrets Management

### Bitwarden Secrets Manager

The cluster uses the Bitwarden Secrets Manager Kubernetes Operator to synchronize secrets from Bitwarden Secrets Manager into Kubernetes secrets.

#### Prerequisites

1. **Bitwarden Secrets Manager Account**: You need access to a Bitwarden Secrets Manager organization
2. **Machine Account**: Create a machine account in your Bitwarden Secrets Manager organization
3. **Machine Account Token**: Generate an access token for the machine account

#### Setup

1. **Create the authentication secret**:
   ```bash
   # Create a temporary secret with your machine account token
   kubectl create secret generic bitwarden-auth-token \
     --from-literal=token="<MACHINE_ACCOUNT_TOKEN>" \
     --dry-run=client -o yaml | kubeseal -o yaml > auth-secret.yml
   ```

2. **Update the SealedSecret**:
   - Replace the `<ENCRYPTED_MACHINE_ACCOUNT_TOKEN>` in `apps/bitwarden-secrets/sm-operator/resources/auth-secret.yml` with the encrypted token from step 1

#### Usage

Create a `BitwardenSecret` resource to sync secrets from Bitwarden Secrets Manager:

```yaml
apiVersion: k8s.bitwarden.com/v1
kind: BitwardenSecret
metadata:
  name: my-app-secrets
  namespace: my-namespace
spec:
  organizationId: "<ORG_ID_GUID>"
  secretName: my-app-secret
  map:
    - bwSecretId: "<SECRET_UUID_1>"
      secretKeyName: database_password
    - bwSecretId: "<SECRET_UUID_2>"
      secretKeyName: api_key
  authToken:
    secretName: bitwarden-auth-token
    secretKey: token
  refreshInterval: "10m"
```

Replace:
- `<ORG_ID_GUID>`: Your Bitwarden organization ID
- `<SECRET_UUID_1>`, `<SECRET_UUID_2>`: UUIDs of secrets in your Bitwarden Secrets Manager
- `secretKeyName`: The key names in the resulting Kubernetes secret

The operator will create a Kubernetes secret named `my-app-secret` with the specified keys containing values from your Bitwarden Secrets Manager.

#### Finding IDs

- **Organization ID**: Found in your Bitwarden Secrets Manager organization settings
- **Secret UUIDs**: Found in the URL or details of each secret in Bitwarden Secrets Manager

## Contributing

1. Follow the GitOps workflow - all changes go through Git and ArgoCD
2. Never apply resources directly with `kubectl apply`
3. Follow the patterns established in existing applications
4. See [CLAUDE.md](./CLAUDE.md) for detailed development guidelines