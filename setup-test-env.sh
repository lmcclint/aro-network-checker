#!/bin/bash
#
# FOR DEVELOPMENT/TESTING ONLY — not part of the tool itself.
#
# Creates a throwaway Azure environment (resource group, VNet, subnets) to test
# aro-network-checker against. Not needed if you already have a VNet with ARO subnets.
#
# Usage:
#   ./setup-test-env.sh [--region <region>] [--prefix <name-prefix>]
#   ./setup-test-env.sh --cleanup [--prefix <name-prefix>]

set -euo pipefail

REGION="eastus"
PREFIX="aro-checker-test"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region|-l)    REGION="$2"; shift 2 ;;
        --prefix)       PREFIX="$2"; shift 2 ;;
        --cleanup)      CLEANUP=true; shift ;;
        --help|-h)
            echo "Usage: setup-test-env.sh [--region <region>] [--prefix <name-prefix>] [--cleanup]"
            exit 0
            ;;
        *)  echo "Unknown option: $1"; exit 1 ;;
    esac
done

RG="${PREFIX}-rg"
VNET="${PREFIX}-vnet"
MASTER_SUBNET="master-subnet"
WORKER_SUBNET="worker-subnet"

if [[ "${CLEANUP:-false}" == "true" ]]; then
    echo "Deleting resource group '$RG'..."
    az group delete --name "$RG" --yes --no-wait
    echo "Resource group deletion initiated (runs in background)."
    exit 0
fi

echo "Creating test environment..."
echo "  Resource Group: $RG"
echo "  Region:         $REGION"
echo "  VNet:           $VNET (10.0.0.0/16)"
echo "  Master Subnet:  $MASTER_SUBNET (10.0.1.0/24)"
echo "  Worker Subnet:  $WORKER_SUBNET (10.0.2.0/24)"
echo "  ACI Subnet:     Use --aci-subnet-prefix 10.0.255.240/28 with deploy.sh"
echo ""

az group create --name "$RG" --location "$REGION" --output none
echo "  Resource group created."

az network vnet create \
    --resource-group "$RG" \
    --name "$VNET" \
    --address-prefix 10.0.0.0/16 \
    --location "$REGION" \
    --output none
echo "  VNet created."

az network vnet subnet create \
    --resource-group "$RG" \
    --vnet-name "$VNET" \
    --name "$MASTER_SUBNET" \
    --address-prefixes 10.0.1.0/24 \
    --output none
echo "  Master subnet created."

az network vnet subnet create \
    --resource-group "$RG" \
    --vnet-name "$VNET" \
    --name "$WORKER_SUBNET" \
    --address-prefixes 10.0.2.0/24 \
    --output none
echo "  Worker subnet created."

echo ""
echo "Test environment ready. Run the checker with:"
echo ""
echo "  ./deploy.sh \\"
echo "    --resource-group $RG \\"
echo "    --vnet-name $VNET \\"
echo "    --master-subnet $MASTER_SUBNET \\"
echo "    --worker-subnet $WORKER_SUBNET \\"
echo "    --region $REGION \\"
echo "    --image quay.io/lmcclint/aro-network-checker:latest \\"
echo "    --aci-subnet-prefix 10.0.255.240/28"
echo ""
echo "To tear down: ./setup-test-env.sh --cleanup"
