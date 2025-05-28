# Guidelines for Adding New Kubernetes Services via GitOps

This document outlines the standard procedure for adding new services to the Kubernetes cluster using the GitOps workflow managed by ArgoCD.

## 1. Namespace Setup

- **Check for existing Namespace:** Before adding a new service, verify if an appropriate namespace already exists under the `apps/` directory.
- **Create Namespace (if needed):**
    - Create a new directory for the namespace: `apps/<new-namespace-name>/`
    - Create `apps/<new-namespace-name>/namespace.yml` using the template below.
```yaml
    ---
    apiVersion: v1
    kind: Namespace
    metadata:
      name: <new-namespace-name>
```
    - Create `apps/<new-namespace-name>/kustomization.yml` with the following content:
```yaml
      apiVersion: kustomize.config.k8s.io/v1beta1
      kind: Kustomization
      resources:
        - namespace.yml
        - <app-name> # Points to apps/<new-namespace-name>/<app-name>/
```
    - Add the new namespace to the main kustomization file `apps/kustomization.yml` under the `resources` section:
```yaml
      resources:
        # ... other namespaces ...
        - <new-namespace-name> # Points to apps/<new-namespace-name>/
```

## 2. Application Definition (ArgoCD)

- Create a directory for the new application within its namespace: `apps/<namespace-name>/<app-name>/`
- Create an ArgoCD Application manifest `apps/<namespace-name>/<app-name>/app.yml`.
    - **`metadata.name`**: Should be `<app-name>`.
    - **`metadata.namespace`**: Should be `argocd`.
    - **`metadata.finalizers`**: Include `resources-finalizer.argocd.argoproj.io`.
```yaml
      finalizers:
        - resources-finalizer.argocd.argoproj.io
```
    - **`spec.project`**: Typically `default`.
    - **`spec.source.repoURL`**: Use the correct Git repository URL (e.g., `https://github.com/kevindurb/k8s.git`).
    - **`spec.source.targetRevision`**: Typically `HEAD`.
    - **`spec.source.path`**: Points to the application's directory: `apps/<namespace-name>/<app-name>/`.
    - **`spec.destination.server`**: `https://kubernetes.default.svc`.
    - **`spec.destination.namespace`**: `<namespace-name>` where the app will be deployed.
    - **`spec.syncPolicy.automated`**:
```yaml
      automated:
        prune: true
        selfHeal: true
```
    - **`spec.syncPolicy.syncOptions`**: Generally, this should **not** be present. Namespace creation is handled by its own manifest.
- Create `apps/<namespace-name>/<app-name>/kustomization.yml` to include the `app.yml` and the `resources` directory:
```yaml
  apiVersion: kustomize.config.k8s.io/v1beta1
  kind: Kustomization
  resources: # Points to all resources created in apps/<namespace-name>/<app-name>/resources/
```
- Add the application directory to its namespace's kustomization file (`apps/<namespace-name>/kustomization.yml`):
```yaml
  resources:
    - namespace.yml
    - <app-name> # Points to apps/<namespace-name>/<app-name>/
```

## 3. Kubernetes Resource Definitions

- Create a `resources` directory for the application: `apps/<namespace-name>/<app-name>/resources/`
- Define Kubernetes manifests (Deployment, Service, PersistentVolumeClaim, Ingress, etc.) within this directory using the templates below as a starting point.
- For below templates `component-name` relates to the subcomponent within the app if the app has multiple components (ex web, db, etc). Default to "web"

### Deployment (`deployment.yml`)
- Customize image, ports, environment variables, volumeMounts, and resource requests/limits.
- Ensure `fsGroup` and `runAsUser`/`runAsGroup` are set appropriately for security.
- Never use `latest`, only point to specific tags, if you cant find the latest tag then ask the user for the tag
- Prefer ghcr.io over docker hub images

```yaml
  ---
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: <component-name>-deployment
    annotations:
      reloader.stakater.com/auto: 'true'
    labels: &labels
      app.kubernetes.io/component: <component-name>
  spec:
    replicas: 1
    strategy:
      type: Recreate
    selector:
      matchLabels: *labels
    template:
      metadata:
        labels: *labels
      spec:
        securityContext:
          fsGroup: 1000
        # volumes:
        #   - name: volume
        #     persistentVolumeClaim:
        #       claimName: volume
        containers:
          - name: <app-name>
            image: <image-ref> # e.g., ghcr.io/jellyfin/jellyfin:v1.2.3
            resources:
              requests:
                memory: 100M
              limits:
                memory: 1G
            securityContext:
              privileged: false
              allowPrivilegeEscalation: false
              runAsNonRoot: true
              runAsUser: 1000
              runAsGroup: 1000
              readOnlyRootFilesystem: true
              capabilities:
                drop: [ALL]
            # volumeMounts:
            #   - name: volume
            #     mountPath: /var/www/app/data
            env:
              - name: TZ
                value: America/Denver # Adjust to your timezone
            ports:
              - name: http
                containerPort: <port> # e.g., 8096 for Jellyfin
```

### Service (`service.yml`)
- Ensure selectors match deployment labels and ports are correctly defined.

```yaml
  ---
  apiVersion: v1
  kind: Service
  metadata:
    name: <component-name>-service
  spec:
    selector:
      app.kubernetes.io/component: <component-name>``
    ports:
      - name: <proto> # e.g., http
        port: 80 # External port for the service
        targetPort: <port-name> # Named port from the deployment (e.g., http, which maps to containerPort)
```

### PersistentVolumeClaim (`<pvc-name>-pvc.yml`)
- **`metadata.name`**: Should be unique for the claim (e.g., `<component-name>-config-pvc`).
- **`spec.storageClassName`**: Must be `openebs-mayastor-replicated` (unless using NFS or other specific storage).
- **`spec.accessModes`**: Typically `[ReadWriteOnce]`.
- Define appropriate `spec.resources.requests.storage`.

```yaml
  ---
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: <component-name>-data # Or <component-name>-config, etc.
  spec:
    accessModes: [ReadWriteOnce]
    storageClassName: openebs-mayastor-replicated
    resources:
      requests:
        storage: <size> # e.g., 10Gi, 100Gi
```

### Ingress (`ingress.yml`)
- For services exposed via Tailscale.
- **`metadata.name`**: Should be unique within the namespace, e.g., `<app-name>-tailscale-ingress`.
- **`spec.ingressClassName`**: `tailscale`.
- **`spec.tls.hosts`**: Define the desired hostname (e.g., `[<app-name>]` which becomes `<app-name>.<tailnet>.ts.net`).
- **`spec.rules.host`**: Same as `tls.hosts`.
- **`spec.rules.http.paths.backend.service.name`**: Name of your Kubernetes service.
- **`spec.rules.http.paths.backend.service.port.name`**: Port name defined in your service.

```yaml
  ---
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  metadata:
    name: <component-name>-tailscale-ingress # Or more specific if <component-name> is generic
  spec:
    ingressClassName: tailscale
    tls:
      - hosts:
          - <subdomain> # e.g., jellyfin, my-app
    rules: # Older Ingress versions might not need/use 'rules' with defaultBackend
      - host: <subdomain>
        http:
          paths:
            - path: /
              pathType: Prefix # Or ImplementationSpecific
              backend:
                service:
                  name: <component-name>-service
                  port:
                    name: <proto> # e.g., http
  # For older Kubernetes versions or simpler configs, defaultBackend might be used directly under spec:
  # defaultBackend:
  #   service:
  #     name: <component-name>-service
  #     port:
  #       name: <proto>
```

### Kustomization for Resources
- Create `apps/<namespace-name>/<app-name>/kustomization.yml`:

```yaml
  apiVersion: kustomize.config.k8s.io/v1beta1
  kind: Kustomization
  resources:
    - ./resources/deployment.yml
    - ./resources/service.yml
    - ./resources/<pvc-name>-pvc.yml # Or specific PVC files like config-pvc.yml, media-pvc.yml
    - ./resources/ingress.yml # If applicable
    # Add other resource files (e.g., media-nfs-pv.yml if using NFS PV)
```

## 4. General Kustomization Practices
- When referencing another kustomization file within the same repository, point to the directory containing the `kustomization.yml` file, not the file itself.
  - *Correct:* `  - my-app` (where `my-app` is a directory with `kustomization.yml`)
  - *Incorrect:* `  - my-app/kustomization.yml`

## Example Structure:

```
apps/
├── media/
│   ├── namespace.yml
│   ├── kustomization.yml  # Includes 'namespace.yml' and 'jellyfin' (directory)
│   └── jellyfin/
│       ├── app.yml          # source.path points to 'apps/media/jellyfin/resources/'
│       ├── kustomization.yml # Includes all individual resource files
│       └── resources/
│           ├── deployment.yml
│           ├── service.yml
│           ├── config-pvc.yml
│           ├── media-nfs-pv.yml
│           ├── media-pvc.yml
│           └── ingress.yml
└── kustomization.yml # Includes 'media' (directory), 'ai' (directory), etc.
```
