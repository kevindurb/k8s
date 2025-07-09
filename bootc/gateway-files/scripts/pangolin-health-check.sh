#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Exit codes
EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2

# Counters
WARNINGS=0
ERRORS=0

log() {
    echo -e "${1}${2}${NC}"
}

check_systemd_service() {
    local service=$1
    local description=$2
    
    if systemctl is-active --quiet "$service"; then
        log "$GREEN" "✓ $description is running"
        return 0
    else
        log "$RED" "✗ $description is not running"
        ((ERRORS++))
        return 1
    fi
}

check_container_health() {
    local container=$1
    local description=$2
    
    local health_status=$(podman healthcheck run "$container" 2>/dev/null || echo "unhealthy")
    
    if [[ "$health_status" == "healthy" ]]; then
        log "$GREEN" "✓ $description container is healthy"
        return 0
    else
        log "$RED" "✗ $description container is unhealthy"
        ((ERRORS++))
        return 1
    fi
}

check_api_endpoint() {
    local url=$1
    local description=$2
    
    if curl -f -s --max-time 10 "$url" > /dev/null; then
        log "$GREEN" "✓ $description API is responding"
        return 0
    else
        log "$RED" "✗ $description API is not responding"
        ((ERRORS++))
        return 1
    fi
}

check_port_listening() {
    local port=$1
    local description=$2
    
    if ss -tuln | grep -q ":$port "; then
        log "$GREEN" "✓ Port $port ($description) is listening"
        return 0
    else
        log "$RED" "✗ Port $port ($description) is not listening"
        ((ERRORS++))
        return 1
    fi
}

check_disk_usage() {
    local path=$1
    local threshold=${2:-90}
    
    local usage=$(df "$path" | tail -1 | awk '{print $5}' | sed 's/%//')
    
    if [[ $usage -lt $threshold ]]; then
        log "$GREEN" "✓ Disk usage for $path: ${usage}%"
        return 0
    elif [[ $usage -lt 95 ]]; then
        log "$YELLOW" "⚠ Disk usage for $path: ${usage}% (warning)"
        ((WARNINGS++))
        return 1
    else
        log "$RED" "✗ Disk usage for $path: ${usage}% (critical)"
        ((ERRORS++))
        return 1
    fi
}

main() {
    log "$YELLOW" "=== Pangolin Gateway Health Check ==="
    
    # Check systemd services
    check_systemd_service "tailscaled.service" "Tailscale daemon"
    check_systemd_service "pangolin-network.service" "Pangolin network"
    check_systemd_service "pangolin.service" "Pangolin service"
    check_systemd_service "gerbil.service" "Gerbil service"
    check_systemd_service "traefik.service" "Traefik service"
    
    # Check container health
    check_container_health "pangolin" "Pangolin"
    
    # Check API endpoints
    check_api_endpoint "http://localhost:3001/api/v1/" "Pangolin"
    
    # Check port listening
    check_port_listening "80" "HTTP"
    check_port_listening "443" "HTTPS"
    check_port_listening "51820" "WireGuard"
    
    # Check disk usage
    check_disk_usage "/var/lib/pangolin" 85
    check_disk_usage "/" 90
    
    # Summary
    log "$YELLOW" "=== Health Check Summary ==="
    
    if [[ $ERRORS -gt 0 ]]; then
        log "$RED" "✗ $ERRORS critical error(s) found"
        exit $EXIT_CRITICAL
    elif [[ $WARNINGS -gt 0 ]]; then
        log "$YELLOW" "⚠ $WARNINGS warning(s) found"
        exit $EXIT_WARNING
    else
        log "$GREEN" "✓ All checks passed"
        exit $EXIT_OK
    fi
}

main "$@"