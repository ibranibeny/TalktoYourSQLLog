#!/usr/bin/env bash
#
# cleanup.sh — Delete the entire Contoso SQL Observability resource group.
#
# This removes ALL resources: VM, Log Analytics, Azure OpenAI, AI Foundry,
# App Service, NSGs, public IPs, disks, and managed identity role assignments.
#
# Usage:
#   bash scripts/cleanup.sh
# ────────────────────────────────────────────────────────────────────
set -euo pipefail

: "${RESOURCE_GROUP:=rg-contoso-sqlobs}"

echo "============================================================"
echo " Contoso SQL Observability — Cleanup"
echo "============================================================"
echo ""
echo " Resource group to delete: $RESOURCE_GROUP"
echo ""

# Confirm before deletion
read -rp " Are you sure you want to delete ALL resources in '$RESOURCE_GROUP'? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo " Cancelled. No resources were deleted."
  exit 0
fi

echo ""
echo " Deleting resource group '$RESOURCE_GROUP'..."
echo " (This runs asynchronously; resources will be removed in the background.)"

az group delete \
  --name "$RESOURCE_GROUP" \
  --yes \
  --no-wait

echo ""
echo " ✓ Deletion initiated for resource group: $RESOURCE_GROUP"
echo ""
echo " To monitor progress:"
echo "   az group show --name $RESOURCE_GROUP --query provisioningState -o tsv"
echo ""
echo " Once complete, the group will no longer appear in:"
echo "   az group list -o table"
echo "============================================================"
