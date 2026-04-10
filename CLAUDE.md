# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bash diagnostic tool that collects Azure Red Hat OpenShift (ARO) network configuration data for troubleshooting provisioning failures. Designed to run as a container via Azure Container Instances (ACI) deployed directly into the target VNet, eliminating the need to spin up a VM.

## Files

- `aro-network-checker.sh` — Diagnostic collection script (runs inside the container)
- `Containerfile` — Container image based on `mcr.microsoft.com/azure-cli`
- `deploy.sh` — Orchestrates ACI deployment, log retrieval, and cleanup

## Building and Deploying

Build and push the container image:
```bash
podman build --platform linux/amd64 -t <registry>/aro-network-checker:latest .
podman push <registry>/aro-network-checker:latest
```

Deploy into a VNet via ACI:
```bash
./deploy.sh \
  --resource-group myRG \
  --vnet-name myVnet \
  --master-subnet master-subnet \
  --worker-subnet worker-subnet \
  --region eastus \
  --image <registry>/aro-network-checker:latest \
  --aci-subnet-prefix 10.0.255.240/28
```

Output is saved locally to `aro-diagnostics-<timestamp>.txt`.

The script can also run standalone (without ACI) if `az` is already authenticated and env vars are set.

## Architecture

**deploy.sh** handles the full lifecycle:
1. Creates a delegated ACI subnet (or reuses an existing one)
2. Creates a User-Assigned Managed Identity with Reader role
3. Deploys the container into the VNet with config passed as env vars
4. Polls for completion, retrieves logs via `az container logs`
5. Cleans up all created resources (container, identity, role assignment, subnet)

**aro-network-checker.sh** collects 7 diagnostic sections:
1. VNet/Subnet config — address spaces, route tables, NSGs, service endpoints
2. DNS — VNet DNS servers + `nslookup` tests against critical ARO endpoints
3. Private DNS Zones — zone listings and VNet links for ACR and OpenShift
4. Route Tables (UDR) — routes from attached route tables (deduplicates if shared)
5. NSG rules — security rules from attached NSGs (deduplicates if shared)
6. VNet Peering — peering relationships
7. Azure Firewall — rules/config if provided; NVA guidance otherwise

## Key Conventions

- Both scripts use `set -euo pipefail`
- Config is passed via environment variables (not hardcoded)
- `extract_rg()` helper uses bash parameter expansion to parse Azure resource IDs (POSIX-compatible, no GNU grep dependency)
- `MANAGED_IDENTITY=true` env var triggers `az login --identity` for container auth
- deploy.sh tracks which resources it created vs. pre-existing, only cleans up what it created
- ACI subnet requires delegation to `Microsoft.ContainerInstance/containerGroups`
- deploy.sh traps SIGINT/SIGTERM to clean up on interruption
