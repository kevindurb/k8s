# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Kubernetes infrastructure repository managed using GitOps principles. It contains:

1. Kubernetes cluster configuration via Talos OS and BootC
2. Application deployments managed via ArgoCD and Kustomize
3. Various applications organized by namespace (media, ai, apps, etc.)
4. Infrastructure components like storage (OpenEBS), monitoring (Prometheus), networking (Tailscale), and secrets management (Bitwarden Secrets Manager)

## Common Commands

### Kubernetes Operations

```bash
# Build and validate all manifests
task k8s:build-all
task k8s:validate

# Get dashboard authentication token
task k8s:get-dashboard-token

# Force update an external secret
task k8s:force-update-external-secret name=SECRET_NAME

# Lint all YAML files
task lint
```

### ArgoCD Operations

```bash
# Refresh a specific ArgoCD application
task argo:refresh-app appname=APPLICATION_NAME

# Refresh all ArgoCD applications
task argo:refresh-all
```

### Talos Management

```bash
# Generate Talos cluster configuration
task tal:genconfig

# Get kubeconfig for cluster
task tal:kubeconfig
```

### BootC Management

```bash
# Build BootC container image
task bootc:build

# Push BootC container image to registry
task bootc:push
```

### Bitwarden Secrets Manager

```bash
# Create a SealedSecret for Bitwarden machine account token
kubectl create secret generic bitwarden-auth-token \
  --from-literal=token="<MACHINE_ACCOUNT_TOKEN>" \
  --dry-run=client -o yaml | kubeseal -o yaml

# Force refresh a BitwardenSecret
kubectl annotate bitwardensecret <SECRET_NAME> \
  --namespace=<NAMESPACE> \
  bitwarden.com/force-sync=$(date +%s)
```

## Architecture and Code Structure

### Node Deployment Options

1. Talos OS
   - Traditional Talos-based node deployment using `talos/` configuration

2. BootC Container Image
   - Container-based OS image for Kubernetes nodes using `bootc/` configuration
   - Uses ghcr.io/ublue-os/ucore-minimal as base image
   - Contains Kubernetes 1.32 and CRI-O 1.32
   - Configured with proper kernel modules and sysctl settings for Kubernetes
   - Node configuration templated using Butane

### Directory Structure

```
apps/
├── <namespace>/                # e.g., media, ai, apps
│   ├── namespace.yml          # Namespace definition
│   ├── kustomization.yml      # Includes namespace.yml and app directories
│   └── <application>/
│       ├── app.yml            # ArgoCD Application definition
│       ├── kustomization.yml  # Includes resource files
│       └── resources/
│           ├── deployment.yml # Kubernetes resources
│           ├── service.yml
│           └── etc...
├── kustomization.yml          # Main kustomization including all namespaces
talos/                         # Talos OS configuration
└── clusterconfig/             # Generated cluster configs
    └── ...
bootc/                         # BootC container image configuration
├── Containerfile              # Container image definition for K8s nodes
├── files/                     # Configuration files for the container
│   ├── modules.conf           # Kernel modules for K8s
│   └── sysctl.conf            # System settings for K8s
├── hosts.yml                  # Host network configuration
└── node.bu.j2                 # Butane template for node configuration
```

### Deployment Patterns

1. Each application follows consistent directory structure:
   - `app.yml` - ArgoCD Application definition
   - `kustomization.yml` - Kustomize configuration
   - `resources/` - Kubernetes manifests

2. ArgoCD Application specs:
   - Defined in `apps/<namespace>/<app-name>/app.yml`
   - Source path points to the app directory containing kustomization.yml
   - Automated sync with prune and self-heal enabled

3. Application resources:
   - Deployments with security contexts (non-root, read-only filesystem)
   - Services exposing application ports
   - PVCs using OpenEBS storage
   - Ingress via Tailscale

### Networking Architecture

1. Tailscale provides secure external access to services
   - Tailscale operator deploys ingress proxies for each ingress resource
   - Each ingress gets a tailscale.com subdomain (e.g., app-name.beaver-cloud.ts.net)
   - The main Tailscale ingress pod can be exposed to LAN via LoadBalancer service

2. MetalLB provides LoadBalancer IP allocation on the LAN
   - Uses Layer 2 mode to advertise IPs from the 192.168.50.0/24 range
   - Configure in the metallb-system namespace
   - Use LoadBalancer service type to expose services on LAN IPs

3. Ingress resources should use Tailscale ingress class

### Storage Architecture

1. OpenEBS Mayastor provides block storage with replication
2. Default storage class is `openebs-mayastor-replicated`

### Secrets Management

1. **Bitwarden Secrets Manager**: Synchronizes secrets from Bitwarden Secrets Manager into Kubernetes secrets
   - Deployed via official Helm chart in `bitwarden-secrets` namespace
   - Uses machine account authentication with SealedSecret for secure token storage
   - Supports automatic refresh of secrets at configurable intervals
   - Creates standard Kubernetes secrets that can be referenced by applications

2. **BitwardenSecret Resource**: Custom resource for defining secret synchronization
   - Specifies organization ID, secret UUIDs, and key mappings
   - References authentication token from SealedSecret
   - Configurable refresh intervals (default: 15 minutes)

3. **SealedSecrets**: Used for encrypting the Bitwarden machine account token
   - Allows safe storage of authentication credentials in Git
   - Namespace-wide sealed secrets for shared authentication

#### Example BitwardenSecret Configuration

```yaml
apiVersion: k8s.bitwarden.com/v1
kind: BitwardenSecret
metadata:
  name: app-secrets
  namespace: my-namespace
spec:
  organizationId: "your-org-id"
  secretName: app-secret
  map:
    - bwSecretId: "secret-uuid-1"
      secretKeyName: database_password
    - bwSecretId: "secret-uuid-2"
      secretKeyName: api_key
  authToken:
    secretName: bitwarden-auth-token
    secretKey: token
  refreshInterval: "10m"
```

#### Setup Process

1. Create machine account in Bitwarden Secrets Manager
2. Generate access token for machine account
3. Create SealedSecret with the token
4. Create BitwardenSecret resources as needed
5. Reference the resulting Kubernetes secrets in applications

## Development Guidelines

1. Follow standard procedure for adding new services as defined in GUIDELINES.md
2. Use proper namespace organization
3. Follow ArgoCD Application definition standards
4. Use standardized templates for Kubernetes resources
5. Use specific image tags (not 'latest')
6. Prefer ghcr.io over Docker Hub images
7. Security best practices:
   - Non-root users (UID/GID 1000)
   - Read-only root filesystem
   - Dropped capabilities
   - No privilege escalation

## Important Workflows

### GitOps Practices

1. NEVER apply resources directly to the cluster with `kubectl apply`
   - All changes must go through Git and ArgoCD
   - Use `git add`, `git commit`, and `git push` for all changes

2. Namespace organization:
   - Namespace directories should match the namespace name (e.g., `apps/metallb-system` for the `metallb-system` namespace)
   - Namespace kustomization.yml should include:
     - `namespace.yml` - The namespace definition
     - `<app-name>/app.yml` - Direct reference to application ArgoCD definition
   - Main kustomization.yml in `apps/` should include all namespace directories

## Memories

- Don't use extraneous quotes in YAML