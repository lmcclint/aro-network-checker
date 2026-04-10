#!/bin/bash
#
# ARO Diagnostic Data Collection Script
# Built with assistance from Claude (claude.ai)
#
# Usage:
#   As a standalone script (with az CLI already authenticated):
#     export RESOURCE_GROUP=myRG VNET_NAME=myVnet ...
#     ./aro-network-checker.sh
#
#   As a container (via deploy.sh):
#     ./deploy.sh --resource-group myRG --vnet-name myVnet ...
#
# This script collects network, DNS, routing, and firewall configuration
# relevant to troubleshooting ARO provisioning failures.
#
# For DNS resolution tests (nslookup), run this script from a machine
# or container inside the same VNet as the ARO cluster for accurate results.

set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Authenticate via managed identity when running in a container
# ──────────────────────────────────────────────────────────────

if [[ "${MANAGED_IDENTITY:-false}" == "true" ]]; then
    echo "Authenticating via managed identity..."
    az login --identity 2>&1
    echo ""
fi

# ──────────────────────────────────────────────────────────────
# CONFIGURATION — Set via environment variables
# ──────────────────────────────────────────────────────────────

RESOURCE_GROUP="${RESOURCE_GROUP:-}"
VNET_NAME="${VNET_NAME:-}"
MASTER_SUBNET_NAME="${MASTER_SUBNET_NAME:-}"
WORKER_SUBNET_NAME="${WORKER_SUBNET_NAME:-}"
REGION="${REGION:-}"

# Optional — fill in if you know the firewall details
FIREWALL_RG="${FIREWALL_RG:-}"
FIREWALL_NAME="${FIREWALL_NAME:-}"
ARO_SUBNET_PREFIX="${ARO_SUBNET_PREFIX:-}"

# ──────────────────────────────────────────────────────────────
# Helper functions
# ──────────────────────────────────────────────────────────────

header() {
    echo ""
    echo "================================================================"
    echo " $1"
    echo "================================================================"
    echo ""
}

run_cmd() {
    local description="$1"
    shift
    echo "--- $description ---"
    echo "\$ $*"
    echo ""
    if "$@" 2>&1; then
        echo ""
    else
        echo "(command returned non-zero or resource not found)"
        echo ""
    fi
}

# Extract resource group name from an Azure resource ID
extract_rg() {
    local id="$1"
    local tmp="${id#*resourceGroups/}"
    echo "${tmp%%/*}"
}

# ──────────────────────────────────────────────────────────────
# Main diagnostic collection
# ──────────────────────────────────────────────────────────────

echo "ARO Diagnostic Data Collection"
echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Subscription: $(az account show --query '{Name:name, Id:id}' -o json 2>/dev/null || echo 'unable to determine')"

# ── Validate configuration ──
if [[ -z "$RESOURCE_GROUP" || -z "$VNET_NAME" || -z "$MASTER_SUBNET_NAME" || -z "$WORKER_SUBNET_NAME" ]]; then
    echo ""
    echo "ERROR: Please set the required environment variables before running."
    echo "Required: RESOURCE_GROUP, VNET_NAME, MASTER_SUBNET_NAME, WORKER_SUBNET_NAME"
    exit 1
fi

# ══════════════════════════════════════════════════════════
header "1. VNet and Subnet Configuration"
# ══════════════════════════════════════════════════════════

run_cmd "VNet details" \
    az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" \
    --query '{Name:name, AddressSpace:addressSpace.addressPrefixes, DnsServers:dhcpOptions.dnsServers, Location:location}' -o json

run_cmd "Master subnet" \
    az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
    --name "$MASTER_SUBNET_NAME" \
    --query '{Name:name, AddressPrefix:addressPrefix, RouteTable:routeTable.id, NSG:networkSecurityGroup.id, ServiceEndpoints:serviceEndpoints[].service, Delegations:delegations[].serviceName}' -o json

run_cmd "Worker subnet" \
    az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
    --name "$WORKER_SUBNET_NAME" \
    --query '{Name:name, AddressPrefix:addressPrefix, RouteTable:routeTable.id, NSG:networkSecurityGroup.id, ServiceEndpoints:serviceEndpoints[].service, Delegations:delegations[].serviceName}' -o json

# ══════════════════════════════════════════════════════════
header "2. DNS Configuration"
# ══════════════════════════════════════════════════════════

run_cmd "VNet DNS servers" \
    az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" \
    --query "dhcpOptions" -o json

run_cmd "DNS resolution: arosvc.azurecr.io" \
    nslookup arosvc.azurecr.io

run_cmd "DNS resolution: arosvc.${REGION}.data.azurecr.io" \
    nslookup "arosvc.${REGION}.data.azurecr.io"

run_cmd "DNS resolution: management.azure.com" \
    nslookup management.azure.com

run_cmd "DNS resolution: login.microsoftonline.com" \
    nslookup login.microsoftonline.com

# ══════════════════════════════════════════════════════════
header "3. Private DNS Zones"
# ══════════════════════════════════════════════════════════

run_cmd "All Private DNS zones in subscription" \
    az network private-dns zone list --query "[].{Name:name, ResourceGroup:resourceGroup}" -o table

run_cmd "Private DNS zone links for privatelink.azurecr.io" \
    az network private-dns link vnet list --resource-group "$RESOURCE_GROUP" \
    --zone-name privatelink.azurecr.io -o table

run_cmd "Private DNS zone links for privatelink.openshift.io" \
    az network private-dns link vnet list --resource-group "$RESOURCE_GROUP" \
    --zone-name privatelink.openshift.io -o table

# ══════════════════════════════════════════════════════════
header "4. Route Tables (UDR)"
# ══════════════════════════════════════════════════════════

MASTER_RT_ID=$(az network vnet subnet show --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" --name "$MASTER_SUBNET_NAME" \
    --query "routeTable.id" -o tsv 2>/dev/null || echo "")

if [[ -n "$MASTER_RT_ID" && "$MASTER_RT_ID" != "None" ]]; then
    MASTER_RT_NAME=$(basename "$MASTER_RT_ID")
    MASTER_RT_RG=$(extract_rg "$MASTER_RT_ID")
    run_cmd "Master subnet route table" \
        az network route-table route list --resource-group "$MASTER_RT_RG" \
        --route-table-name "$MASTER_RT_NAME" -o table
else
    echo "--- Master subnet route table ---"
    echo "No route table attached to master subnet"
    echo ""
fi

WORKER_RT_ID=$(az network vnet subnet show --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" --name "$WORKER_SUBNET_NAME" \
    --query "routeTable.id" -o tsv 2>/dev/null || echo "")

if [[ -n "$WORKER_RT_ID" && "$WORKER_RT_ID" != "None" ]]; then
    WORKER_RT_NAME=$(basename "$WORKER_RT_ID")
    WORKER_RT_RG=$(extract_rg "$WORKER_RT_ID")
    if [[ "$WORKER_RT_ID" != "$MASTER_RT_ID" ]]; then
        run_cmd "Worker subnet route table" \
            az network route-table route list --resource-group "$WORKER_RT_RG" \
            --route-table-name "$WORKER_RT_NAME" -o table
    else
        echo "--- Worker subnet route table ---"
        echo "Same route table as master subnet"
        echo ""
    fi
else
    echo "--- Worker subnet route table ---"
    echo "No route table attached to worker subnet"
    echo ""
fi

# ══════════════════════════════════════════════════════════
header "5. Network Security Groups (NSG)"
# ══════════════════════════════════════════════════════════

MASTER_NSG_ID=$(az network vnet subnet show --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" --name "$MASTER_SUBNET_NAME" \
    --query "networkSecurityGroup.id" -o tsv 2>/dev/null || echo "")

if [[ -n "$MASTER_NSG_ID" && "$MASTER_NSG_ID" != "None" ]]; then
    MASTER_NSG_NAME=$(basename "$MASTER_NSG_ID")
    MASTER_NSG_RG=$(extract_rg "$MASTER_NSG_ID")
    run_cmd "Master subnet NSG rules" \
        az network nsg rule list --resource-group "$MASTER_NSG_RG" \
        --nsg-name "$MASTER_NSG_NAME" -o table
else
    echo "--- Master subnet NSG ---"
    echo "No NSG attached to master subnet"
    echo ""
fi

WORKER_NSG_ID=$(az network vnet subnet show --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" --name "$WORKER_SUBNET_NAME" \
    --query "networkSecurityGroup.id" -o tsv 2>/dev/null || echo "")

if [[ -n "$WORKER_NSG_ID" && "$WORKER_NSG_ID" != "None" ]]; then
    WORKER_NSG_NAME=$(basename "$WORKER_NSG_ID")
    WORKER_NSG_RG=$(extract_rg "$WORKER_NSG_ID")
    if [[ "$WORKER_NSG_ID" != "$MASTER_NSG_ID" ]]; then
        run_cmd "Worker subnet NSG rules" \
            az network nsg rule list --resource-group "$WORKER_NSG_RG" \
            --nsg-name "$WORKER_NSG_NAME" -o table
    else
        echo "--- Worker subnet NSG ---"
        echo "Same NSG as master subnet"
        echo ""
    fi
else
    echo "--- Worker subnet NSG ---"
    echo "No NSG attached to worker subnet"
    echo ""
fi

# ══════════════════════════════════════════════════════════
header "6. VNet Peering"
# ══════════════════════════════════════════════════════════

run_cmd "VNet peerings" \
    az network vnet peering list --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" -o table

# ══════════════════════════════════════════════════════════
header "7. Azure Firewall Configuration (if applicable)"
# ══════════════════════════════════════════════════════════

if [[ -n "$FIREWALL_NAME" && -n "$FIREWALL_RG" ]]; then
    run_cmd "Azure Firewall overview" \
        az network firewall show --resource-group "$FIREWALL_RG" --name "$FIREWALL_NAME" \
        --query '{Name:name, ThreatIntelMode:threatIntelMode, SkuTier:sku.tier, DNSProxy:additionalProperties.Network.DNS.EnableProxy}' -o json

    run_cmd "Firewall network rule collections" \
        az network firewall network-rule collection list --resource-group "$FIREWALL_RG" \
        --firewall-name "$FIREWALL_NAME" -o json

    run_cmd "Firewall application rule collections" \
        az network firewall application-rule collection list --resource-group "$FIREWALL_RG" \
        --firewall-name "$FIREWALL_NAME" -o json
else
    echo "Azure Firewall name/RG not provided — skipping."
    echo "If using a third-party NVA (Palo Alto, Fortinet, etc.), please manually export:"
    echo "  - All firewall rules applicable to the ARO subnets"
    echo "  - TLS inspection / SSL decryption policy status"
    echo "  - Traffic logs (allowed + denied) from the ARO subnets during a deployment window"
    echo ""
fi

header "Collection Complete"
echo "Diagnostic data collection finished."
