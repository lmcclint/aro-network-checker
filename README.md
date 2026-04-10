# ARO Network Checker

Collects Azure Red Hat OpenShift (ARO) network diagnostics by deploying a container into the target VNet via Azure Container Instances (ACI). No VM required.

Built with assistance from [Claude](https://claude.ai).

## What it collects

- VNet and subnet configuration (address spaces, service endpoints, delegations)
- DNS resolution tests against critical ARO endpoints
- Private DNS zones and VNet links
- Route tables (UDR)
- Network Security Group rules
- VNet peering
- Azure Firewall rules (if applicable)

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) authenticated (`az login`)
- [Podman](https://podman.io/) (for building the container image)

## Quick start

### 1. Build and push the image

```bash
podman build --platform linux/amd64 -t quay.io/<your-user>/aro-network-checker:latest .
podman push quay.io/<your-user>/aro-network-checker:latest
```

A pre-built image is available at `quay.io/lmcclint/aro-network-checker:latest`.

### 2. Deploy into your VNet

You'll need an unused /28 CIDR block within your VNet's address space for the temporary ACI subnet. Pick any free range that doesn't overlap with existing subnets (e.g., if your VNet is `10.0.0.0/16`, you could use `10.0.255.240/28`).

```bash
./deploy.sh \
  --resource-group myRG \
  --vnet-name myVnet \
  --master-subnet master-subnet \
  --worker-subnet worker-subnet \
  --region eastus \
  --image quay.io/lmcclint/aro-network-checker:latest \
  --aci-subnet-prefix 10.0.255.240/28
```

The script will:
1. Create a temporary ACI subnet with the provided /28 CIDR
2. Create a managed identity with Reader access
3. Deploy the container into the VNet
4. Retrieve diagnostic logs and save to `aro-diagnostics-<timestamp>.txt`
5. Clean up all created resources

### 3. Share the output

Send the generated `aro-diagnostics-*.txt` file to whoever is troubleshooting the issue.

## deploy.sh options

| Flag | Required | Description |
|---|---|---|
| `--resource-group`, `-g` | Yes | Resource group containing the VNet |
| `--vnet-name` | Yes | VNet name used by ARO |
| `--master-subnet` | Yes | ARO master subnet name |
| `--worker-subnet` | Yes | ARO worker subnet name |
| `--region`, `-l` | Yes | Azure region |
| `--image` | Yes | Container image URL |
| `--aci-subnet-prefix` | When subnet is new | Unused /28 CIDR within your VNet for the ACI subnet (e.g., `10.0.255.240/28`) |
| `--aci-subnet` | No | ACI subnet name (default: `aci-diagnostic`) |
| `--firewall-rg` | No | Firewall resource group |
| `--firewall-name` | No | Azure Firewall name |
| `--aro-subnet-prefix` | No | ARO subnet prefix for log filtering |
| `--no-cleanup` | No | Skip automatic resource cleanup |

## Standalone usage

The script can also run directly without ACI if you're already on a machine inside the VNet:

```bash
export RESOURCE_GROUP=myRG
export VNET_NAME=myVnet
export MASTER_SUBNET_NAME=master-subnet
export WORKER_SUBNET_NAME=worker-subnet
export REGION=eastus
./aro-network-checker.sh
```
