FROM ghcr.io/ublue-os/ucore-minimal:stable

# Container labels
LABEL org.opencontainers.image.title="kube-gateway-01"
LABEL org.opencontainers.image.description="Fedora CoreOS bootc image with Pangolin reverse proxy for Kubernetes cluster tunnel gateway"
LABEL org.opencontainers.image.source="https://github.com/kevindurb/k8s"

# Create required directories
RUN mkdir -p /etc/pangolin/traefik \
    && mkdir -p /etc/containers/systemd

# Copy Podman Quadlet files
COPY ./gateway-files/quadlets/*.network /etc/containers/systemd/
COPY ./gateway-files/quadlets/*.container /etc/containers/systemd/
COPY ./gateway-files/quadlets/*.volume /etc/containers/systemd/

# Copy configuration files
COPY ./gateway-files/config/traefik_config.yml /etc/pangolin/traefik/
COPY ./gateway-files/config/dynamic_config.yml /etc/pangolin/traefik/
COPY ./gateway-files/config/config.yaml /etc/pangolin/

# Copy health check script and make executable
COPY ./gateway-files/scripts/pangolin-health-check.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/pangolin-health-check.sh

# Copy logrotate configuration
COPY ./gateway-files/config/pangolin-logrotate /etc/logrotate.d/

# Configure firewall rules
RUN firewall-offline-cmd --add-port=80/tcp \
    && firewall-offline-cmd --add-port=443/tcp \
    && firewall-offline-cmd --add-port=51820/udp

# Note: Container images will be pulled automatically by systemd when services start

# Set proper ownership and permissions
RUN chown -R root:root /etc/pangolin \
    && chown -R root:root /etc/containers/systemd \
    && chmod 755 /etc/pangolin \
    && chmod 755 /etc/pangolin/traefik \
    && chmod 600 /etc/pangolin/config.yaml \
    && chmod 644 /etc/pangolin/traefik/*.yml \
    && chmod 644 /etc/logrotate.d/pangolin-logrotate

# Enable systemd services
RUN systemctl enable tailscaled.service \
    && systemctl enable podman-auto-update.timer

# Note: Quadlet services (.network and .container files) will be automatically
# processed by systemd-system-generators at boot time and enabled via their
# [Install] sections in the quadlet files