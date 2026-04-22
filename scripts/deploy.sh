#!/usr/bin/env bash
#
# deploy.sh — Provision the full Contoso SQL Observability + AI environment.
#
# Deploys:
#   1. Resource Group (SEA)
#   2. Log Analytics Workspace (SEA)
#   3. Azure VM + system-assigned managed identity (SEA)
#   4. Azure Monitor Agent + DCE + DCR (SEA)
#   5. Azure OpenAI Service + GPT-4o deployment (East US)
#   6. Azure AI Foundry Hub + Project (East US)
#   7. Azure App Service (Streamlit) with Managed Identity RBAC (SEA)
#
# Authentication: App Service → Azure OpenAI and Log Analytics uses
# system-assigned Managed Identity. No API keys are stored.
#
# Usage:
#   export SUBSCRIPTION_ID="..."
#   export ADMIN_PASSWORD="..."
#   bash scripts/deploy.sh
# ────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults (override via environment) ─────────────────────────────
: "${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID}"
: "${RESOURCE_GROUP:=rg-contoso-sqlobs}"
: "${LOCATION_SEA:=southeastasia}"
: "${LOCATION_US:=eastus}"
: "${VM_NAME:=vm-sql-sea-01}"
: "${VM_SIZE:=Standard_D2s_v3}"
: "${VM_IMAGE:=MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest}"
: "${ADMIN_USERNAME:=contosoadmin}"
: "${ADMIN_PASSWORD:?Set ADMIN_PASSWORD (min 12 chars, mixed case, number, symbol)}"
: "${LAW_NAME:=law-contoso-sqlobs}"
: "${AI_HUB_NAME:=ai-hub-contoso}"
: "${AI_PROJECT_NAME:=ai-proj-sqllogs}"
: "${AOAI_NAME:=aoai-contoso-sqllogs}"
: "${AOAI_DEPLOYMENT:=gpt-4o}"
: "${AOAI_MODEL:=gpt-4o}"
: "${AOAI_MODEL_VERSION:=2024-11-20}"
: "${APP_PLAN_NAME:=asp-contoso-streamlit}"
: "${WEBAPP_NAME:=app-contoso-sqllogs}"

echo "============================================================"
echo " Contoso SQL Observability + AI — Full Deployment"
echo "============================================================"

# ── 1. Subscription & Resource Group ────────────────────────────────
echo ""
echo "[1/7] Setting subscription and creating resource group..."
az account set --subscription "$SUBSCRIPTION_ID"

az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION_SEA" \
  --output none

echo "  ✓ Resource group: $RESOURCE_GROUP ($LOCATION_SEA)"

# ── 2. Log Analytics Workspace ──────────────────────────────────────
echo ""
echo "[2/7] Creating Log Analytics workspace..."
az monitor log-analytics workspace create \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$LAW_NAME" \
  --location "$LOCATION_SEA" \
  --sku PerGB2018 \
  --retention-time 30 \
  --output none

LAW_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$LAW_NAME" \
  --query id -o tsv)

LAW_WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$LAW_NAME" \
  --query customerId -o tsv)

echo "  ✓ Workspace: $LAW_NAME"
echo "  ✓ Workspace ID: $LAW_WORKSPACE_ID"

# ── 3. Virtual Machine ─────────────────────────────────────────────
echo ""
echo "[3/7] Creating Windows VM..."
az vm create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --location "$LOCATION_SEA" \
  --image "$VM_IMAGE" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USERNAME" \
  --admin-password "$ADMIN_PASSWORD" \
  --nsg-rule RDP \
  --public-ip-sku Standard \
  --output none

echo "  Assigning system-managed identity..."
az vm identity assign \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --output none

echo "  ✓ VM: $VM_NAME with system-assigned managed identity"

# ── 4. Azure Monitor Agent + Data Collection ────────────────────────
echo ""
echo "[4/7] Installing Azure Monitor Agent and configuring data collection..."

# Install AMA extension
az vm extension set \
  --resource-group "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  --name AzureMonitorWindowsAgent \
  --publisher Microsoft.Azure.Monitor \
  --enable-auto-upgrade true \
  --output none

echo "  ✓ Azure Monitor Agent extension installed"

# Data Collection Endpoint
az monitor data-collection endpoint create \
  --resource-group "$RESOURCE_GROUP" \
  --name "dce-contoso-sea" \
  --location "$LOCATION_SEA" \
  --public-network-access Enabled \
  --output none

DCE_ID=$(az monitor data-collection endpoint show \
  --resource-group "$RESOURCE_GROUP" \
  --name "dce-contoso-sea" \
  --query id -o tsv)

echo "  ✓ Data Collection Endpoint: dce-contoso-sea"

# Data Collection Rule (JSON file approach for reliability)
DCR_FILE=$(mktemp /tmp/dcr-XXXXXX.json)
cat > "$DCR_FILE" <<DCRJSON
{
  "location": "$LOCATION_SEA",
  "properties": {
    "dataCollectionEndpointId": "$DCE_ID",
    "dataSources": {
      "windowsEventLogs": [
        {
          "streams": ["Microsoft-Event"],
          "xPathQueries": [
            "Application!*[System[(Level=1 or Level=2 or Level=3)]]",
            "System!*[System[(Level=1 or Level=2 or Level=3)]]",
            "Application!*[System[Provider[@Name='MSSQLSERVER' or @Name='MSSQL\$SQLEXPRESS']]]"
          ],
          "name": "sqlAndSystemEvents"
        }
      ],
      "performanceCounters": [
        {
          "streams": ["Microsoft-Perf"],
          "samplingFrequencyInSeconds": 60,
          "counterSpecifiers": [
            "\\\\Processor(_Total)\\\\% Processor Time",
            "\\\\Memory\\\\Available MBytes",
            "\\\\LogicalDisk(_Total)\\\\% Free Space",
            "\\\\MSSQL\$SQLEXPRESS:General Statistics\\\\User Connections",
            "\\\\MSSQL\$SQLEXPRESS:SQL Statistics\\\\Batch Requests/sec",
            "\\\\MSSQL\$SQLEXPRESS:SQL Statistics\\\\SQL Compilations/sec",
            "\\\\MSSQL\$SQLEXPRESS:SQL Statistics\\\\SQL Re-Compilations/sec",
            "\\\\MSSQL\$SQLEXPRESS:Locks(_Total)\\\\Lock Waits/sec",
            "\\\\MSSQL\$SQLEXPRESS:Locks(_Total)\\\\Average Wait Time (ms)",
            "\\\\MSSQL\$SQLEXPRESS:Buffer Manager\\\\Page life expectancy"
          ],
          "name": "sqlPerfCounters"
        }
      ]
    },
    "destinations": {
      "logAnalytics": [
        {
          "workspaceResourceId": "$LAW_ID",
          "name": "logAnalyticsWorkspace"
        }
      ]
    },
    "dataFlows": [
      {
        "streams": ["Microsoft-Event"],
        "destinations": ["logAnalyticsWorkspace"]
      },
      {
        "streams": ["Microsoft-Perf"],
        "destinations": ["logAnalyticsWorkspace"]
      }
    ]
  }
}
DCRJSON

az monitor data-collection rule create \
  --resource-group "$RESOURCE_GROUP" \
  --name "dcr-sql-windows-logs" \
  --location "$LOCATION_SEA" \
  --rule-file "$DCR_FILE" \
  --output none

rm -f "$DCR_FILE"

echo "  ✓ Data Collection Rule: dcr-sql-windows-logs"

# Associate DCR with VM
DCR_ID=$(az monitor data-collection rule show \
  --resource-group "$RESOURCE_GROUP" \
  --name "dcr-sql-windows-logs" \
  --query id -o tsv)

VM_ID=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query id -o tsv)

az monitor data-collection rule association create \
  --name "assoc-vm-sql-dcr" \
  --resource "$VM_ID" \
  --rule-id "$DCR_ID" \
  --output none

echo "  ✓ DCR associated with VM"

# ── 5. Azure OpenAI Service (East US) ──────────────────────────────
echo ""
echo "[5/7] Deploying Azure OpenAI Service..."
az cognitiveservices account create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AOAI_NAME" \
  --location "$LOCATION_US" \
  --kind OpenAI \
  --sku S0 \
  --custom-domain "$AOAI_NAME" \
  --output none

az cognitiveservices account deployment create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AOAI_NAME" \
  --deployment-name "$AOAI_DEPLOYMENT" \
  --model-name "$AOAI_MODEL" \
  --model-version "$AOAI_MODEL_VERSION" \
  --model-format OpenAI \
  --sku-name "Standard" \
  --sku-capacity 30 \
  --output none

AOAI_ENDPOINT=$(az cognitiveservices account show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AOAI_NAME" \
  --query "properties.endpoint" -o tsv)

AOAI_RESOURCE_ID=$(az cognitiveservices account show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AOAI_NAME" \
  --query id -o tsv)

echo "  ✓ Azure OpenAI: $AOAI_NAME"
echo "  ✓ Deployment: $AOAI_DEPLOYMENT ($AOAI_MODEL)"
echo "  ✓ Endpoint: $AOAI_ENDPOINT"

# ── 6. Azure AI Foundry Hub + Project (East US) ────────────────────
echo ""
echo "[6/7] Creating AI Foundry Hub and Project..."

# Ensure ml extension is installed
az extension add --name ml --upgrade --yes 2>/dev/null || true

az ml workspace create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AI_HUB_NAME" \
  --location "$LOCATION_US" \
  --kind hub \
  --output none

AI_HUB_ID=$(az ml workspace show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AI_HUB_NAME" \
  --query id -o tsv)

az ml workspace create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AI_PROJECT_NAME" \
  --location "$LOCATION_US" \
  --kind project \
  --hub-id "$AI_HUB_ID" \
  --output none

# Create Azure OpenAI connection (credential-less / Managed Identity)
CONNECTION_FILE=$(mktemp /tmp/conn-XXXXXX.yml)
cat > "$CONNECTION_FILE" <<CONNYML
name: aoai-connection
type: azure_open_ai
azure_endpoint: $AOAI_ENDPOINT
CONNYML

az ml connection create \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$AI_HUB_NAME" \
  --file "$CONNECTION_FILE" \
  --output none

rm -f "$CONNECTION_FILE"

echo "  ✓ AI Hub: $AI_HUB_NAME"
echo "  ✓ AI Project: $AI_PROJECT_NAME"
echo "  ✓ Connection: aoai-connection (credential-less / Managed Identity)"

# ── 7. App Service + Managed Identity RBAC ─────────────────────────
echo ""
echo "[7/7] Deploying Azure App Service with Managed Identity..."

# Create App Service Plan (Linux)
az appservice plan create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APP_PLAN_NAME" \
  --location "$LOCATION_SEA" \
  --sku B1 \
  --is-linux \
  --output none

# Create Web App
az webapp create \
  --resource-group "$RESOURCE_GROUP" \
  --plan "$APP_PLAN_NAME" \
  --name "$WEBAPP_NAME" \
  --runtime "PYTHON:3.11" \
  --output none

# Startup command for Streamlit
az webapp config set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --startup-file "python -m streamlit run app.py --server.port 8000 --server.address 0.0.0.0" \
  --output none

# App settings — NO API KEYS, only endpoints
az webapp config appsettings set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --settings \
    AZURE_OPENAI_ENDPOINT="$AOAI_ENDPOINT" \
    AZURE_OPENAI_DEPLOYMENT="$AOAI_DEPLOYMENT" \
    LOG_ANALYTICS_WORKSPACE_ID="$LAW_WORKSPACE_ID" \
  --output none

# Enable system-assigned managed identity
az webapp identity assign \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --output none

WEBAPP_PRINCIPAL_ID=$(az webapp identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --query principalId -o tsv)

echo "  ✓ Web App: $WEBAPP_NAME"
echo "  ✓ Managed Identity Principal: $WEBAPP_PRINCIPAL_ID"

# Grant Cognitive Services OpenAI User on Azure OpenAI resource
echo "  Assigning 'Cognitive Services OpenAI User' role..."
az role assignment create \
  --assignee-object-id "$WEBAPP_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI User" \
  --scope "$AOAI_RESOURCE_ID" \
  --output none

echo "  ✓ Role: Cognitive Services OpenAI User → Azure OpenAI"

# Grant Log Analytics Reader on the workspace
echo "  Assigning 'Log Analytics Reader' role..."
az role assignment create \
  --assignee-object-id "$WEBAPP_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Log Analytics Reader" \
  --scope "$LAW_ID" \
  --output none

echo "  ✓ Role: Log Analytics Reader → Log Analytics Workspace"

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " Deployment Complete"
echo "============================================================"
echo ""
echo " Resource Group:       $RESOURCE_GROUP"
echo " VM:                   $VM_NAME ($LOCATION_SEA)"
echo " Log Analytics:        $LAW_NAME (ID: $LAW_WORKSPACE_ID)"
echo " Azure OpenAI:         $AOAI_ENDPOINT"
echo " AI Hub:               $AI_HUB_NAME ($LOCATION_US)"
echo " AI Project:           $AI_PROJECT_NAME"
echo " Web App:              https://${WEBAPP_NAME}.azurewebsites.net"
echo ""
echo " Authentication:       Managed Identity (no API keys)"
echo "   App Service → OpenAI:   Cognitive Services OpenAI User"
echo "   App Service → Logs:     Log Analytics Reader"
echo ""
echo " Next steps:"
echo "   1. bash scripts/deploy-sql-express.sh   # Install SQL Express on VM"
echo "   2. Deploy Streamlit app code via zip deploy"
echo "   3. Wait 10-15 min for log ingestion"
echo "   4. bash scripts/check-vm-sql.sh         # Verify health"
echo "============================================================"
