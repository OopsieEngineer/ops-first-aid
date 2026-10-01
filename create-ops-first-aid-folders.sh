#!/usr/bin/env bash

set -e

echo "Creating Ops First Aid folder structure..."

mkdir -p \
    diagnostics \
    docker \
    rabbitmq \
    minio \
    traefik \
    swarm \
    network \
    azure \
    powershell

# Create README files
touch \
    README.md \
    diagnostics/README.md \
    docker/README.md \
    rabbitmq/README.md \
    minio/README.md \
    traefik/README.md \
    swarm/README.md \
    network/README.md \
    azure/README.md \
    powershell/README.md

# Create shell script placeholders
touch \
    diagnostics/diag.sh \
    docker/docker-health.sh \
    docker/docker-report.sh \
    rabbitmq/rabbitmq-health.sh \
    rabbitmq/rabbitmq-report.sh \
    minio/minio-health.sh \
    traefik/traefik-health.sh \
    swarm/swarm-health.sh \
    network/dns-check.sh \
    network/port-check.sh \
    network/ssl-check.sh

# Create PowerShell script placeholders
touch \
    azure/azure-vm-report.ps1 \
    azure/azure-resource-inventory.ps1 \
    powershell/process-report.ps1 \
    powershell/service-check.ps1

# Make shell scripts executable
find . -type f -name "*.sh" -exec chmod +x {} \;

echo
echo "Done! Created:"
echo

find . -maxdepth 2 -type f | sort

echo
echo "Repository structure:"
tree -a -L 2 2>/dev/null || find . -maxdepth 2 -print | sort
