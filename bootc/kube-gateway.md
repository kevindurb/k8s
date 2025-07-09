# 🚀 kube-gateway-01 Pangolin Tunnel Gateway Requirements

## 📋 Project Overview
Create a **Fedora CoreOS bootc container image** for a VPS named `kube-gateway-01` that will serve as a tunneled reverse proxy gateway for a Kubernetes cluster using **Pangolin**.

## 🎯 Core Requirements

### 1. **Base Image**
- Use `ghcr.io/ublue-os/ucore:stable` as the base image
- Target: Fedora CoreOS with Universal Blue's uCore enhancements

### 2. **Primary Software Stack**
- **Pangolin** (`fosrl/pangolin:latest`) - Main tunneled reverse proxy server
- **Gerbil** (`fosrl/gerbil:latest`) - WireGuard interface manager
- **Traefik** (`traefik:v3.3.3`) - HTTP reverse proxy and load balancer
- All services must run via **Podman Quadlets** (not Docker Compose)

### 3. **Podman Quadlet Services Required**

#### Network Configuration
- **pangolin-network.network**: Bridge network for all services

#### Container Services
- **pangolin.container**: 
  - Main server with health checks
  - Volume: `/var/lib/pangolin/config:/app/config:Z`
  - Health check: `curl -f http://localhost:3001/api/v1/`

- **gerbil.container**:
  - WireGuard interface manager
  - Ports: `51820:51820/udp`, `443:443`, `80:80`
  - Capabilities: `NET_ADMIN`, `SYS_MODULE`
  - Volume: `/var/lib/pangolin/config:/var/config:Z`
  - Command args for Pangolin integration

- **traefik.container**:
  - Uses `network_mode: container:gerbil` (Network=container:gerbil in Quadlet)
  - Volumes: traefik config and letsencrypt certificates
  - Config file: `/etc/traefik/traefik_config.yml`

### 4. **Directory Structure**
```
/var/lib/pangolin/
├── config/
│   ├── traefik/
│   │   ├── traefik_config.yml
│   │   └── dynamic_config.yml
│   ├── config.yaml (Pangolin main config)
│   └── (other config files)
└── letsencrypt/
    └── acme.json (auto-created)
```

### 5. **System Configuration**
- **Firewall**: Open ports 80/tcp, 443/tcp, 51820/udp
- **Services**: Auto-enable all Pangolin services on boot
- **Updates**: Enable podman-auto-update.timer
- **Pre-pull**: Container images cached in the OS image

### 6. **Operational Requirements**
- **Health Check Script**: `/usr/local/bin/pangolin-health-check.sh`
  - Check systemd service status
  - Check container health
  - Check API endpoints
  - Check port listening status
  - Check disk usage
- **Log Management**: Logrotate configuration for container logs
- **Permissions**: All files owned by root:root with appropriate permissions

### 7. **Build Structure Required**
```
build-context/
├── Containerfile
├── quadlets/
│   ├── pangolin-network.network
│   ├── pangolin.container
│   ├── gerbil.container
│   └── traefik.container
├── config/
│   ├── traefik_config.yml
│   ├── dynamic_config.yml
│   ├── config.yaml
│   └── pangolin-logrotate
└── scripts/
    └── pangolin-health-check.sh
```

## 🔧 Technical Specifications

### Quadlet Conversion Rules
- Convert Docker Compose `depends_on` → Quadlet `Wants`/`After`
- Convert `restart: unless-stopped` → `Restart=unless-stopped` in `[Service]` section
- Convert `network_mode: service:gerbil` → `Network=container:gerbil`
- Convert `cap_add` → `AddCapability`
- Add `:Z` suffix to volume mounts for SELinux compatibility
- Use `AutoUpdate=registry` for automatic image updates

### Service Dependencies
1. pangolin-network.service (starts first)
2. pangolin.service (depends on network)
3. gerbil.service (depends on pangolin, exposes ports)
4. traefik.service (depends on both, uses gerbil's network)

### Container Image Labels
- `org.opencontainers.image.title="kube-gateway-01"`
- `org.opencontainers.image.description="Fedora CoreOS bootc image with Pangolin reverse proxy for Kubernetes cluster tunnel gateway"`

## 📁 Deliverables Expected

1. **Complete Containerfile** - Builds the bootc image
2. **All Quadlet Files** - Properly converted from Docker Compose
3. **Health Check Script** - Comprehensive service monitoring
4. **Logrotate Configuration** - Container log management
5. **Build Instructions** - How to build and deploy the image
6. **Directory Structure Documentation** - What goes where

## 🎯 Success Criteria
- [ ] Image builds successfully with `podman build` or `bootc build`
- [ ] All services start automatically on boot
- [ ] Health check script reports all services healthy
- [ ] Pangolin web interface accessible on port 443
- [ ] WireGuard tunnel ready for client connections on port 51820
- [ ] Traefik properly proxying traffic through Pangolin
- [ ] Logs properly rotated and managed
- [ ] Firewall properly configured for required ports

## 📚 Reference Materials
- **Original Docker Compose**: Available at `github.com/fosrl/pangolin/blob/main/docker-compose.example.yml`
- **Pangolin Documentation**: `https://fossorial.io/`
- **Universal Blue uCore**: `https://github.com/ublue-os/ucore`
- **Podman Quadlets**: systemd container management for Podman

---
*This requirements document provides everything needed to create a production-ready tunneled reverse proxy gateway for a Kubernetes cluster using modern container technologies and immutable OS principles.*