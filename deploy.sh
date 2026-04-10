#!/bin/bash
#
# Deploy ARO Network Checker as an ACI container inside a VNet.
# Built with assistance from Claude (claude.ai)
#
# Prerequisites:
#   - Azure CLI installed and authenticated (az login)
#   - Container image already built and pushed to a registry
#
# Usage:
#   ./deploy.sh \
#     --resource-group myRG \
#     --vnet-name myVnet \
#     --master-subnet master-subnet \
#     --worker-subnet worker-subnet \
#     --region eastus \
#     --image quay.io/myuser/aro-network-checker:latest \
#     --aci-subnet-prefix 10.0.255.240/28

set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Defaults and state
# ──────────────────────────────────────────────────────────────

RESOURCE_GROUP=""
VNET_NAME=""
MASTER_SUBNET=""
WORKER_SUBNET=""
REGION=""
IMAGE=""

ACI_SUBNET="aci-diagnostic"
ACI_SUBNET_PREFIX=""
FIREWALL_RG=""
FIREWALL_NAME=""
ARO_SUBNET_PREFIX=""
NO_CLEANUP=false

CONTAINER_TIMEOUT=600

# Track resources created by this script for cleanup
CREATED_SUBNET=false
CREATED_MI=false
MI_NAME=""
MI_PRINCIPAL=""
CONTAINER_NAME=""
RG_SCOPE=""
FW_RG_SCOPE=""

# ──────────────────────────────────────────────────────────────
# Functions
# ──────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: deploy.sh [OPTIONS]

Deploy ARO Network Checker as an ACI container inside a VNet.

Required:
  --resource-group, -g     Resource group containing the VNet
  --vnet-name              VNet name used by ARO
  --master-subnet          ARO master subnet name
  --worker-subnet          ARO worker subnet name
  --region, -l             Azure region
  --image                  Container image URL (e.g., quay.io/user/aro-checker:latest)

Optional:
  --aci-subnet             Name for the ACI subnet (default: aci-diagnostic)
  --aci-subnet-prefix      CIDR for ACI subnet if it needs to be created (e.g., 10.0.255.240/28)
  --firewall-rg            Firewall resource group
  --firewall-name          Azure Firewall name
  --aro-subnet-prefix      ARO subnet prefix for log filtering
  --no-cleanup             Skip automatic cleanup of ACI resources
  --help, -h               Show this help
EOF
}

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

cleanup() {
    if [[ "$NO_CLEANUP" == "true" ]]; then
        log "Skipping cleanup (--no-cleanup specified)"
        log "Resources to clean up manually:"
        [[ -n "$CONTAINER_NAME" ]] && echo "  Container group: $CONTAINER_NAME"
        [[ "$CREATED_MI" == "true" ]] && echo "  Managed identity: $MI_NAME"
        [[ "$CREATED_SUBNET" == "true" ]] && echo "  Subnet: $ACI_SUBNET"
        return
    fi

    log "Cleaning up resources..."

    # Delete container group
    if [[ -n "$CONTAINER_NAME" ]]; then
        log "  Deleting container group: $CONTAINER_NAME"
        az container delete \
            --resource-group "$RESOURCE_GROUP" \
            --name "$CONTAINER_NAME" \
            --yes --output none 2>/dev/null || true
    fi

    # Delete role assignments
    if [[ -n "$MI_PRINCIPAL" ]]; then
        log "  Deleting role assignments"
        az role assignment delete \
            --assignee "$MI_PRINCIPAL" \
            --role Reader \
            --scope "$RG_SCOPE" 2>/dev/null || true
        if [[ -n "$FW_RG_SCOPE" ]]; then
            az role assignment delete \
                --assignee "$MI_PRINCIPAL" \
                --role Reader \
                --scope "$FW_RG_SCOPE" 2>/dev/null || true
        fi
    fi

    # Delete managed identity
    if [[ "$CREATED_MI" == "true" && -n "$MI_NAME" ]]; then
        log "  Deleting managed identity: $MI_NAME"
        az identity delete \
            --resource-group "$RESOURCE_GROUP" \
            --name "$MI_NAME" 2>/dev/null || true
    fi

    # Delete ACI subnet if we created it
    if [[ "$CREATED_SUBNET" == "true" ]]; then
        log "  Deleting ACI subnet: $ACI_SUBNET"
        # Subnet deletion can fail if Azure hasn't fully released the container's NIC yet
        local retries=0
        while [[ $retries -lt 6 ]]; do
            if az network vnet subnet delete \
                --resource-group "$RESOURCE_GROUP" \
                --vnet-name "$VNET_NAME" \
                --name "$ACI_SUBNET" 2>/dev/null; then
                break
            fi
            retries=$((retries + 1))
            if [[ $retries -lt 6 ]]; then
                log "    Subnet still in use, retrying in 10s... ($retries/6)"
                sleep 10
            else
                log "    WARNING: Could not delete subnet $ACI_SUBNET. Delete manually."
            fi
        done
    fi

    log "Cleanup complete."
}

# ──────────────────────────────────────────────────────────────
# Parse arguments
# ──────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group|-g)    RESOURCE_GROUP="$2"; shift 2 ;;
        --vnet-name)            VNET_NAME="$2"; shift 2 ;;
        --master-subnet)        MASTER_SUBNET="$2"; shift 2 ;;
        --worker-subnet)        WORKER_SUBNET="$2"; shift 2 ;;
        --region|-l)            REGION="$2"; shift 2 ;;
        --image)                IMAGE="$2"; shift 2 ;;
        --aci-subnet)           ACI_SUBNET="$2"; shift 2 ;;
        --aci-subnet-prefix)    ACI_SUBNET_PREFIX="$2"; shift 2 ;;
        --firewall-rg)          FIREWALL_RG="$2"; shift 2 ;;
        --firewall-name)        FIREWALL_NAME="$2"; shift 2 ;;
        --aro-subnet-prefix)    ARO_SUBNET_PREFIX="$2"; shift 2 ;;
        --no-cleanup)           NO_CLEANUP=true; shift ;;
        --help|-h)              usage; exit 0 ;;
        *)
            echo "ERROR: Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# ──────────────────────────────────────────────────────────────
# Step 1: Validate prerequisites
# ──────────────────────────────────────────────────────────────

log "Validating prerequisites..."

# Check required parameters
missing=()
[[ -z "$RESOURCE_GROUP" ]] && missing+=("--resource-group")
[[ -z "$VNET_NAME" ]] && missing+=("--vnet-name")
[[ -z "$MASTER_SUBNET" ]] && missing+=("--master-subnet")
[[ -z "$WORKER_SUBNET" ]] && missing+=("--worker-subnet")
[[ -z "$REGION" ]] && missing+=("--region")
[[ -z "$IMAGE" ]] && missing+=("--image")

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required parameters: ${missing[*]}"
    echo ""
    usage
    exit 1
fi

# Check az CLI is authenticated
if ! az account show &>/dev/null; then
    echo "ERROR: Azure CLI is not authenticated. Run 'az login' first."
    exit 1
fi

# Check VNet exists
if ! az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" &>/dev/null; then
    echo "ERROR: VNet '$VNET_NAME' not found in resource group '$RESOURCE_GROUP'."
    exit 1
fi

log "Prerequisites validated."

# ──────────────────────────────────────────────────────────────
# Step 2: Prepare ACI subnet
# ──────────────────────────────────────────────────────────────

log "Checking ACI subnet '$ACI_SUBNET'..."

SUBNET_EXISTS=false
if az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
    --name "$ACI_SUBNET" &>/dev/null; then
    SUBNET_EXISTS=true
fi

if [[ "$SUBNET_EXISTS" == "true" ]]; then
    # Check delegation
    DELEGATION=$(az network vnet subnet show --resource-group "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" --name "$ACI_SUBNET" \
        --query "delegations[0].serviceName" -o tsv 2>/dev/null || echo "")

    if [[ "$DELEGATION" == "Microsoft.ContainerInstance/containerGroups" ]]; then
        log "  Reusing existing ACI subnet '$ACI_SUBNET' with correct delegation."
    else
        echo "ERROR: Subnet '$ACI_SUBNET' exists but is not delegated to Microsoft.ContainerInstance/containerGroups."
        echo "Use a different subnet name with --aci-subnet, or delegate this subnet manually."
        exit 1
    fi
else
    # Need to create the subnet
    if [[ -z "$ACI_SUBNET_PREFIX" ]]; then
        echo "ERROR: ACI subnet '$ACI_SUBNET' does not exist in VNet '$VNET_NAME'."
        echo "Please provide --aci-subnet-prefix (a free /28 CIDR in the VNet)."
        echo ""
        echo "Existing subnets:"
        az network vnet subnet list --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
            --query "[].{Name:name, AddressPrefix:addressPrefix}" -o table
        echo ""
        echo "VNet address space:"
        az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" \
            --query "addressSpace.addressPrefixes" -o tsv
        echo ""
        echo "Example: --aci-subnet-prefix 10.0.255.240/28"
        exit 1
    fi

    log "  Creating ACI subnet '$ACI_SUBNET' with prefix $ACI_SUBNET_PREFIX..."
    az network vnet subnet create \
        --resource-group "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --name "$ACI_SUBNET" \
        --address-prefixes "$ACI_SUBNET_PREFIX" \
        --delegations Microsoft.ContainerInstance/containerGroups \
        --output none
    CREATED_SUBNET=true
    log "  ACI subnet created."
fi

# Register cleanup trap — runs on any exit (error, interrupt, or normal)
CLEANUP_ENABLED=true
trap 'if [[ "$CLEANUP_ENABLED" == "true" ]]; then CLEANUP_ENABLED=false; echo ""; cleanup; fi' EXIT
trap 'exit 130' INT TERM

# ──────────────────────────────────────────────────────────────
# Step 3: Create managed identity
# ──────────────────────────────────────────────────────────────

MI_NAME="aro-checker-mi-$(date +%s)"
log "Creating managed identity '$MI_NAME'..."

az identity create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$MI_NAME" \
    --location "$REGION" \
    --output none

CREATED_MI=true

MI_ID=$(az identity show -g "$RESOURCE_GROUP" -n "$MI_NAME" --query id -o tsv)
MI_PRINCIPAL=$(az identity show -g "$RESOURCE_GROUP" -n "$MI_NAME" --query principalId -o tsv)

log "Managed identity created."

# ──────────────────────────────────────────────────────────────
# Step 4: Assign Reader role
# ──────────────────────────────────────────────────────────────

log "Assigning Reader role..."

RG_SCOPE=$(az group show --name "$RESOURCE_GROUP" --query id -o tsv)
az role assignment create \
    --assignee-object-id "$MI_PRINCIPAL" \
    --assignee-principal-type ServicePrincipal \
    --role Reader \
    --scope "$RG_SCOPE" \
    --output none

# If firewall is in a different resource group, grant Reader there too
if [[ -n "$FIREWALL_RG" && "$FIREWALL_RG" != "$RESOURCE_GROUP" ]]; then
    FW_RG_SCOPE=$(az group show --name "$FIREWALL_RG" --query id -o tsv)
    az role assignment create \
        --assignee-object-id "$MI_PRINCIPAL" \
        --assignee-principal-type ServicePrincipal \
        --role Reader \
        --scope "$FW_RG_SCOPE" \
        --output none
    log "  Reader role assigned on resource groups: $RESOURCE_GROUP, $FIREWALL_RG"
else
    log "  Reader role assigned on resource group: $RESOURCE_GROUP"
fi

# ──────────────────────────────────────────────────────────────
# Step 5: Wait for role propagation
# ──────────────────────────────────────────────────────────────

log "Waiting 30 seconds for role assignment propagation..."
sleep 30

# ──────────────────────────────────────────────────────────────
# Step 6: Deploy ACI container
# ──────────────────────────────────────────────────────────────

CONTAINER_NAME="aro-checker-$(date +%s)"
log "Deploying container '$CONTAINER_NAME' into VNet..."

az container create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINER_NAME" \
    --image "$IMAGE" \
    --assign-identity "$MI_ID" \
    --vnet "$VNET_NAME" \
    --subnet "$ACI_SUBNET" \
    --restart-policy Never \
    --cpu 1 --memory 1 \
    --os-type Linux \
    --environment-variables \
        RESOURCE_GROUP="$RESOURCE_GROUP" \
        VNET_NAME="$VNET_NAME" \
        MASTER_SUBNET_NAME="$MASTER_SUBNET" \
        WORKER_SUBNET_NAME="$WORKER_SUBNET" \
        REGION="$REGION" \
        FIREWALL_RG="$FIREWALL_RG" \
        FIREWALL_NAME="$FIREWALL_NAME" \
        ARO_SUBNET_PREFIX="$ARO_SUBNET_PREFIX" \
        MANAGED_IDENTITY="true" \
    --output none

log "Container deployed. Waiting for completion..."

# ──────────────────────────────────────────────────────────────
# Step 7: Poll for completion
# ──────────────────────────────────────────────────────────────

ELAPSED=0
while true; do
    STATE=$(az container show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CONTAINER_NAME" \
        --query "containers[0].instanceView.currentState.state" \
        -o tsv 2>/dev/null || echo "Unknown")

    if [[ "$STATE" == "Terminated" ]]; then
        break
    fi

    if [[ $ELAPSED -ge $CONTAINER_TIMEOUT ]]; then
        log "WARNING: Container did not complete within ${CONTAINER_TIMEOUT}s. Retrieving partial logs."
        break
    fi

    log "  Container state: $STATE ($((CONTAINER_TIMEOUT - ELAPSED))s remaining)"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

# Check exit code
EXIT_CODE=$(az container show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINER_NAME" \
    --query "containers[0].instanceView.currentState.exitCode" \
    -o tsv 2>/dev/null || echo "unknown")

if [[ "$EXIT_CODE" != "0" ]]; then
    log "WARNING: Container exited with code $EXIT_CODE"
fi

# ──────────────────────────────────────────────────────────────
# Step 8: Retrieve logs
# ──────────────────────────────────────────────────────────────

OUTPUT_FILE="aro-diagnostics-$(date +%Y%m%d-%H%M%S).txt"
log "Retrieving diagnostic logs..."

az container logs \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINER_NAME" \
    > "$OUTPUT_FILE"

log "Diagnostic output saved to: $OUTPUT_FILE"

log "Done. Share $OUTPUT_FILE with whoever is troubleshooting the issue."
