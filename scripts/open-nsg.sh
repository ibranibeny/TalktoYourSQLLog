#!/usr/bin/env bash
#
# open-nsg.sh — Open all inbound ports on the VM's Network Security Group.
#
# WARNING: This is for TESTING/DEMO purposes only. It creates an NSG rule
# that allows ALL inbound TCP traffic from Any source. Do NOT use this
# in production environments.
#
# Usage:
#   bash scripts/open-nsg.sh
# ────────────────────────────────────────────────────────────────────
set -euo pipefail

: "${RESOURCE_GROUP:=rg-contoso-sqlobs}"
: "${VM_NAME:=vm-sql-sea-01}"

echo "============================================================"
echo " Contoso SQL Observability — Open All Inbound NSG Rules"
echo "============================================================"
echo ""
echo " WARNING: This opens ALL inbound ports. Use for testing only."
echo ""

# Find the NSG associated with the VM's NIC
echo " Discovering NSG for VM '$VM_NAME'..."

NIC_ID=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "networkProfile.networkInterfaces[0].id" -o tsv)

NIC_NAME=$(basename "$NIC_ID")

NSG_ID=$(az network nic show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NIC_NAME" \
  --query "networkSecurityGroup.id" -o tsv 2>/dev/null || echo "")

if [[ -z "$NSG_ID" ]]; then
  # Check subnet-level NSG
  SUBNET_ID=$(az network nic show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NIC_NAME" \
    --query "ipConfigurations[0].subnet.id" -o tsv)
  VNET_NAME=$(echo "$SUBNET_ID" | awk -F'/' '{for(i=1;i<=NF;i++) if($i=="virtualNetworks") print $(i+1)}')
  SUBNET_NAME=$(basename "$SUBNET_ID")
  NSG_ID=$(az network vnet subnet show \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --query "networkSecurityGroup.id" -o tsv 2>/dev/null || echo "")
fi

if [[ -z "$NSG_ID" || "$NSG_ID" == "None" ]]; then
  echo " ERROR: No NSG found for VM '$VM_NAME'."
  exit 1
fi

NSG_NAME=$(basename "$NSG_ID")
echo " ✓ Found NSG: $NSG_NAME"

# Create allow-all inbound rule
echo ""
echo " Creating rule 'AllowAllInbound' (priority 100)..."

az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name "AllowAllInbound" \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol "*" \
  --source-address-prefixes "*" \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --destination-port-ranges "*" \
  --output none

echo " ✓ Rule created: AllowAllInbound"
echo ""

# List current rules
echo " Current NSG rules for '$NSG_NAME':"
az network nsg rule list \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --output table

echo ""
echo "============================================================"
echo " All inbound traffic is now allowed."
echo " To revert, delete the rule:"
echo "   az network nsg rule delete -g $RESOURCE_GROUP --nsg-name $NSG_NAME -n AllowAllInbound"
echo "============================================================"
