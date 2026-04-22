# Deploy Guidance: Contoso SQL Server Log Monitoring with AI-Powered Analysis

> **Last updated:** April 2026  
> **Audience:** Platform engineers, DevOps, and cloud architects  
> **Deployment method:** Azure CLI (bash scripts)

---

## Table of Contents

1. [Use Scenario](#use-scenario)
2. [Deployment Overview](#deployment-overview)
3. [Pre-Deployment Checklist](#pre-deployment-checklist)
4. [Step-by-Step Deployment Walkthrough](#step-by-step-deployment-walkthrough)
5. [Post-Deployment Configuration](#post-deployment-configuration)
6. [Deploying the Streamlit Application Code](#deploying-the-streamlit-application-code)
7. [Verification & Smoke Testing](#verification--smoke-testing)
8. [Troubleshooting Common Issues](#troubleshooting-common-issues)
9. [Security Considerations](#security-considerations)
10. [Production Hardening](#production-hardening)
11. [Day-2 Operations](#day-2-operations)
12. [Cleanup](#cleanup)

---

## Use Scenario

### Business Context

**Contoso Ltd.**, a financial services company operating out of Singapore, runs a legacy on-premises SQL Server workload that has been migrated to an Azure Virtual Machine. The operations team needs to:

- **Centralise SQL Server log collection** — Instead of RDP-ing into each VM to read Event Viewer, all SQL Server error logs, application events, and performance counters are streamed to a single Log Analytics workspace.
- **Enable AI-powered log analysis** — Instead of writing KQL queries manually, engineers can ask questions in natural language (*"Why did errors spike on 12 April?"*) and get answers with official Microsoft documentation references.
- **Eliminate credential management** — All service-to-service communication uses Azure Managed Identity. No API keys or secrets are stored in application settings.

### Target Architecture

```
┌──────────────────────────── SOUTHEAST ASIA ────────────────────────────────┐
│                                                                             │
│   Azure VM (Win 2022)              Log Analytics Workspace                  │
│   SQL Server Express   ──AMA/DCR──▶  Event table + Perf table              │
│                                           │                                 │
│                                           │ KQL queries                     │
│                                           ▼                                 │
│   Azure App Service (Linux B1)    ◀───── azure-monitor-query SDK            │
│   Streamlit "Talk to Your SQL Logs"                                         │
│     │                                                                       │
│     │  Managed Identity                                                     │
│     │  (Cognitive Services OpenAI User)                                     │
│     │  (Log Analytics Reader)                                               │
└─────┼───────────────────────────────────────────────────────────────────────┘
      │
      │                     ┌───────── EAST US ─────────┐
      │                     │                            │
      ├───GPT-4o calls────▶ │  Azure OpenAI (S0)        │
      │                     │  GPT-4o deployment         │
      │                     │                            │
      │                     │  Azure AI Foundry          │
      │                     │  Hub + Project             │
      │                     └────────────────────────────┘
      │
      │                     ┌───────── PUBLIC ──────────┐
      └───MCP protocol───▶ │  learn.microsoft.com/     │
                            │  api/mcp (no auth)        │
                            └───────────────────────────┘
```

### Who Should Deploy This

| Role | Responsibility |
|---|---|
| **Platform / Cloud Engineer** | Run `deploy.sh` to provision infrastructure. Configure environment variables. |
| **DevOps Engineer** | Set up CI/CD for the Streamlit app. Configure deployment slots for staging/production. |
| **Data / AI Engineer** | Tune KQL prompts in `kql_prompt.py`. Add new table schemas if DCR is extended. |
| **Security Engineer** | Review RBAC assignments. Plan Private Link migration for production. |

---

## Deployment Overview

The deployment creates **10 Azure resources** across **2 regions** using a single script (`scripts/deploy.sh`):

| Step | Resources Created | Region | Script Section |
|---|---|---|---|
| 1 | Resource Group | Southeast Asia | `[1/7]` |
| 2 | Log Analytics Workspace (PerGB2018, 30-day retention) | Southeast Asia | `[2/7]` |
| 3 | Windows VM (D2s_v3) + system-assigned Managed Identity | Southeast Asia | `[3/7]` |
| 4 | AMA extension + Data Collection Endpoint + Data Collection Rule + DCR association | Southeast Asia | `[4/7]` |
| 5 | Azure OpenAI Service (S0) + GPT-4o model deployment (30K TPM) | East US | `[5/7]` |
| 6 | AI Foundry Hub + Project + credential-less OpenAI connection | East US | `[6/7]` |
| 7 | App Service Plan (B1 Linux) + Web App + MI + RBAC role assignments | Southeast Asia | `[7/7]` |

**Estimated time:** 15–25 minutes (VM creation is the longest step).

---

## Pre-Deployment Checklist

Complete every item before running `deploy.sh`:

### 1. Azure Subscription Access

```bash
# Verify you have an active subscription with Contributor role
az login
az account show --query "{Name:name, SubscriptionId:id, State:state}" -o table
```

You need **Contributor** on the subscription, plus **User Access Administrator** (or **Owner**) to create RBAC role assignments in Step 7.

### 2. Azure CLI Version

```bash
az version --query '"azure-cli"' -o tsv
# Required: 2.61.0 or later

# Update if needed
az upgrade
```

### 3. Azure CLI ML Extension

```bash
# Install or update the ML extension (required for AI Foundry Hub/Project)
az extension add --name ml --upgrade --yes

# Verify
az extension show --name ml --query version -o tsv
# Required: 2.26.0 or later
```

### 4. Resource Provider Registration

The following providers must be registered on your subscription:

```bash
# Check registration status
az provider show --namespace Microsoft.Compute --query registrationState -o tsv
az provider show --namespace Microsoft.OperationalInsights --query registrationState -o tsv
az provider show --namespace Microsoft.Insights --query registrationState -o tsv
az provider show --namespace Microsoft.CognitiveServices --query registrationState -o tsv
az provider show --namespace Microsoft.MachineLearningServices --query registrationState -o tsv
az provider show --namespace Microsoft.Web --query registrationState -o tsv

# Register any that show "NotRegistered"
az provider register --namespace Microsoft.Insights --wait
az provider register --namespace Microsoft.CognitiveServices --wait
az provider register --namespace Microsoft.MachineLearningServices --wait
```

### 5. Regional Quotas

| Region | Resource | Minimum Required |
|---|---|---|
| Southeast Asia | Standard_D2s_v3 vCPUs | 2 vCPUs |
| Southeast Asia | App Service Plan (B1) | 1 instance |
| East US | Azure OpenAI GPT-4o Standard | 30K tokens per minute |

```bash
# Check VM quota in Southeast Asia
az vm list-usage --location southeastasia \
  --query "[?contains(localName, 'Standard DSv3 Family')].{Name:localName, Current:currentValue, Limit:limit}" \
  -o table
```

### 6. Unique Resource Names

The following names must be **globally unique** across all Azure tenants:

| Resource | Variable | Naming Convention |
|---|---|---|
| Azure OpenAI account | `AOAI_NAME` | `aoai-{company}-{purpose}` |
| Web App | `WEBAPP_NAME` | `app-{company}-{purpose}` |
| AI Hub | `AI_HUB_NAME` | `ai-hub-{company}` |

```bash
# Quick check: is your web app name available?
az webapp list --query "[?name=='app-contoso-sqllogs']" -o table
# Empty result = name is available
```

### 7. Prepare Environment Variables

Create a `.env` file in the project root:

```bash
cat > .env << 'EOF'
export SUBSCRIPTION_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export RESOURCE_GROUP="rg-contoso-sqlobs"
export LOCATION_SEA="southeastasia"
export LOCATION_US="eastus"
export VM_NAME="vm-sql-sea-01"
export VM_SIZE="Standard_D2s_v3"
export VM_IMAGE="MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest"
export ADMIN_USERNAME="contosoadmin"
export ADMIN_PASSWORD="YourStr0ng!Pass#2026"
export LAW_NAME="law-contoso-sqlobs"
export AI_HUB_NAME="ai-hub-contoso"
export AI_PROJECT_NAME="ai-proj-sqllogs"
export AOAI_NAME="aoai-contoso-sqllogs"
export AOAI_DEPLOYMENT="gpt-4o"
export AOAI_MODEL="gpt-4o"
export AOAI_MODEL_VERSION="2024-08-06"
export APP_PLAN_NAME="asp-contoso-streamlit"
export WEBAPP_NAME="app-contoso-sqllogs"
EOF
```

> **Security:** Never commit `.env` to source control. Add it to `.gitignore`.

---

## Step-by-Step Deployment Walkthrough

### Deploy All Infrastructure

```bash
# 1. Load environment variables
source .env

# 2. Run the deployment script
bash scripts/deploy.sh
```

The script produces structured output for each of the 7 steps. A successful run ends with:

```
============================================================
 Deployment Complete
============================================================

 Resource Group:       rg-contoso-sqlobs
 VM:                   vm-sql-sea-01 (southeastasia)
 Log Analytics:        law-contoso-sqlobs (ID: xxxxxxxx-...)
 Azure OpenAI:         https://aoai-contoso-sqllogs.openai.azure.com/
 AI Hub:               ai-hub-contoso (eastus)
 AI Project:           ai-proj-sqllogs
 Web App:              https://app-contoso-sqllogs.azurewebsites.net

 Authentication:       Managed Identity (no API keys)
   App Service → OpenAI:   Cognitive Services OpenAI User
   App Service → Logs:     Log Analytics Reader
```

### Install SQL Server Express on the VM

After the infrastructure is deployed, install SQL Server Express:

```bash
bash scripts/deploy-sql-express.sh
```

This script runs remotely on the VM via `az vm run-command` and:
1. Downloads SQL Server 2022 Express silently
2. Configures TCP/IP protocol on port 1433
3. Opens Windows Firewall for SQL Server
4. Enables SQL Server Browser service
5. Verifies the installation

### (Optional) Open NSG for Testing

If you need to access the VM for debugging:

```bash
bash scripts/open-nsg.sh
```

> **Warning:** This opens all inbound ports. Revert after testing:
> ```bash
> az network nsg rule delete -g $RESOURCE_GROUP --nsg-name <NSG_NAME> -n AllowAllInbound
> ```

---

## Post-Deployment Configuration

### Wait for Log Ingestion

After deploying AMA and the DCR, allow **10–15 minutes** for the first logs to appear in the workspace. Verify:

```bash
# Get the workspace ID
LAW_WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$LAW_NAME" \
  --query customerId -o tsv)

# Check if Event table has data
az monitor log-analytics query \
  --workspace "$LAW_WORKSPACE_ID" \
  --analytics-query "Event | summarize count() by EventLevelName" \
  --timespan PT1H \
  -o table
```

### Verify RBAC Assignments

```bash
WEBAPP_PRINCIPAL_ID=$(az webapp identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --query principalId -o tsv)

# List role assignments for the web app identity
az role assignment list \
  --assignee "$WEBAPP_PRINCIPAL_ID" \
  --query "[].{Role:roleDefinitionName, Scope:scope}" \
  -o table
```

Expected output:

| Role | Scope |
|---|---|
| Cognitive Services OpenAI User | .../Microsoft.CognitiveServices/accounts/aoai-contoso-sqllogs |
| Log Analytics Reader | .../Microsoft.OperationalInsights/workspaces/law-contoso-sqlobs |

---

## Deploying the Streamlit Application Code

The infrastructure deployment creates the Web App but does **not** deploy the application code. You have three options:

### Option A: ZIP Deploy (Simplest)

```bash
# From the project root
cd streamlit-app

# Create a deployment package
zip -r ../deploy.zip . -x "*.pyc" "__pycache__/*" ".env"

# Deploy
az webapp deploy \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --src-path ../deploy.zip \
  --type zip

cd ..
rm deploy.zip
```

### Option B: Local Git Deploy

```bash
# Enable local git deployment
az webapp deployment source config-local-git \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --query url -o tsv

# The URL returned is your deployment remote. Add it:
# git remote add azure <url>
# git push azure main
```

### Option C: GitHub Actions CI/CD

1. Get the publish profile:
   ```bash
   az webapp deployment list-publishing-profiles \
     --resource-group "$RESOURCE_GROUP" \
     --name "$WEBAPP_NAME" \
     --xml
   ```
2. Store the output as a GitHub secret named `AZURE_WEBAPP_PUBLISH_PROFILE`.
3. Use the [Azure/webapps-deploy](https://github.com/Azure/webapps-deploy) GitHub Action.

### Verify App Deployment

```bash
# Check if the app is responding
curl -s -o /dev/null -w "%{http_code}" "https://${WEBAPP_NAME}.azurewebsites.net"
# Expected: 200

# Check application logs
az webapp log tail \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --timeout 30
```

---

## Verification & Smoke Testing

Run the full health check after deployment:

```bash
bash scripts/check-vm-sql.sh
```

This validates:

| # | Check | What it verifies |
|---|---|---|
| 1 | VM power state | VM is running |
| 2 | VM agent status | Guest agent is ready |
| 3 | SQL Server service | `MSSQL$SQLEXPRESS` is running |
| 4 | TCP port 1433 | SQL Server is listening |
| 5 | AMA extension | Azure Monitor Agent is provisioned |

### Manual Smoke Tests

```bash
# Test Azure OpenAI via Managed Identity (from your local machine with az login)
az rest --method post \
  --url "$AOAI_ENDPOINT/openai/deployments/$AOAI_DEPLOYMENT/chat/completions?api-version=2024-06-01" \
  --body '{"messages":[{"role":"user","content":"hello"}],"max_tokens":10}' \
  --headers Content-Type=application/json

# Test KQL query against Log Analytics
az monitor log-analytics query \
  --workspace "$LAW_WORKSPACE_ID" \
  --analytics-query "Event | take 5 | project TimeGenerated, Source, EventLevelName" \
  --timespan P1D \
  -o table

# Test the Streamlit app
curl -s "https://${WEBAPP_NAME}.azurewebsites.net" | head -20
```

---

## Troubleshooting Common Issues

### Deploy Script Fails

| Error | Cause | Fix |
|---|---|---|
| `SUBSCRIPTION_ID is not set` | Missing env var | Run `source .env` before deploying |
| `The subscription is not registered to use namespace 'Microsoft.CognitiveServices'` | Provider not registered | `az provider register --namespace Microsoft.CognitiveServices --wait` |
| `The requested VM size Standard_D2s_v3 is not available in the current region` | Quota exhausted | Check quota: `az vm list-usage --location southeastasia -o table` |
| `The resource name 'aoai-contoso-sqllogs' is already in use` | Name conflict | Change `AOAI_NAME` to a unique value |
| `InvalidTemplateDeployment` during DCR creation | JSON formatting issue | Check the temporary DCR JSON file was created correctly |

### No Logs in Workspace

| Symptom | Check | Fix |
|---|---|---|
| `Event` table empty after 30 min | AMA extension status | `az vm extension list -g $RESOURCE_GROUP --vm-name $VM_NAME -o table` — must show `ProvisioningState: Succeeded` |
| Events not flowing | DCR association | `az monitor data-collection rule association list --resource $VM_ID -o table` |
| Only system events, no SQL events | SQL Server not running | `bash scripts/check-vm-sql.sh` then `bash scripts/deploy-sql-express.sh` |
| Perf counters missing | Counter names wrong | RDP into VM → `typeperf -q "SQLServer:General Statistics"` to verify counter names |

### App Service Errors

| Symptom | Check | Fix |
|---|---|---|
| HTTP 500 | App logs | `az webapp log tail -g $RESOURCE_GROUP -n $WEBAPP_NAME` |
| `DefaultAzureCredential` fails | MI not enabled | `az webapp identity show -g $RESOURCE_GROUP -n $WEBAPP_NAME` — verify `principalId` exists |
| `AuthorizationFailed` to OpenAI | RBAC not assigned | Re-run RBAC assignment from Step 7 of deploy.sh |
| `AuthorizationFailed` to Log Analytics | RBAC propagation delay | Wait 5 minutes for RBAC to propagate, then restart app: `az webapp restart -g $RESOURCE_GROUP -n $WEBAPP_NAME` |
| `ModuleNotFoundError` | Code not deployed | Deploy the Streamlit app code (see [Deploying the Streamlit Application Code](#deploying-the-streamlit-application-code)) |

### Microsoft Learn Search Returns Empty

| Symptom | Cause | Fix |
|---|---|---|
| No doc snippets in answers | Network restriction | App Service must have outbound internet access to `learn.microsoft.com` |
| Timeout errors in logs | Slow response from API | Increase `_REQUEST_TIMEOUT` in `learn_search.py` (default: 8s) |

---

## Security Considerations

### What This Deployment Does Right

| Practice | Implementation |
|---|---|
| **No secrets in app settings** | Managed Identity replaces API keys for both Azure OpenAI and Log Analytics |
| **Least privilege RBAC** | `Cognitive Services OpenAI User` (not Contributor); `Log Analytics Reader` (not Contributor) |
| **System-assigned identity** | Lifecycle tied to the App Service — automatically cleaned up on deletion |
| **No credentials in code** | `DefaultAzureCredential` handles all token acquisition |
| **HTTPS by default** | App Service enforces TLS for all traffic |

### What to Harden for Production

| Risk | Current State | Recommended Fix |
|---|---|---|
| Public VM IP with RDP | NSG allows RDP (3389) | Remove public IP. Use Azure Bastion or Just-In-Time VM access. |
| Public App Service endpoint | Internet-accessible | Add IP restrictions or integrate with Azure Front Door + WAF. |
| Azure OpenAI public endpoint | Accessible from any Azure service | Enable Azure Private Link for the Cognitive Services account. |
| Log Analytics public endpoint | Standard ingestion | Configure Private Link Scope (AMPLS) for the workspace. |
| SQL Server SA password | Stored as env variable | Use Azure Key Vault for secrets. Rotate regularly. |
| VM admin password | Passed as `--admin-password` in CLI | Use SSH keys or Azure Key Vault integration. |

---

## Production Hardening

### Networking

```bash
# 1. Remove public IP from VM
az network nic ip-config update \
  --resource-group "$RESOURCE_GROUP" \
  --nic-name "${VM_NAME}VMNic" \
  --name ipconfig1 \
  --remove publicIpAddress

# 2. Deploy Azure Bastion for secure VM access
az network bastion create \
  --resource-group "$RESOURCE_GROUP" \
  --name "bastion-contoso" \
  --vnet-name "${VM_NAME}VNET" \
  --location "$LOCATION_SEA"

# 3. App Service VNet Integration (for private access to Log Analytics)
az webapp vnet-integration add \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --vnet "${VM_NAME}VNET" \
  --subnet "webapp-subnet"

# 4. Azure OpenAI Private Endpoint
az network private-endpoint create \
  --resource-group "$RESOURCE_GROUP" \
  --name "pe-aoai-contoso" \
  --vnet-name "${VM_NAME}VNET" \
  --subnet "private-endpoints" \
  --private-connection-resource-id "$AOAI_RESOURCE_ID" \
  --group-id "account" \
  --connection-name "aoai-pe-connection"
```

### Scaling

| Component | Current | Production Recommendation |
|---|---|---|
| VM size | D2s_v3 (2 vCPU, 8 GB) | D4s_v3 or higher for production SQL workloads |
| SQL Server | Express (10 GB limit) | Standard or Enterprise edition |
| App Service Plan | B1 (1 core, 1.75 GB) | S1 or P1v3 with auto-scale |
| Azure OpenAI TPM | 30K | Increase to 100K+ for production traffic |
| Log Analytics retention | 30 days | 90+ days for compliance; archive to Storage Account |

### High Availability

```bash
# Add deployment slots for zero-downtime deployments
az webapp deployment slot create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --slot staging

# Configure health check
az webapp config set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --generic-configurations '{"healthCheckPath": "/"}'
```

---

## Day-2 Operations

### Monitor the App Service

```bash
# Enable Application Insights (recommended)
az monitor app-insights component create \
  --resource-group "$RESOURCE_GROUP" \
  --app "ai-contoso-streamlit" \
  --location "$LOCATION_SEA" \
  --kind web

# Link to the web app
APPINSIGHTS_KEY=$(az monitor app-insights component show \
  --resource-group "$RESOURCE_GROUP" \
  --app "ai-contoso-streamlit" \
  --query instrumentationKey -o tsv)

az webapp config appsettings set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --settings APPINSIGHTS_INSTRUMENTATIONKEY="$APPINSIGHTS_KEY"
```

### Update the GPT-4o Model Version

```bash
# List available model versions
az cognitiveservices account deployment list \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AOAI_NAME" \
  -o table

# Update deployment to a newer version
az cognitiveservices account deployment create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AOAI_NAME" \
  --deployment-name "$AOAI_DEPLOYMENT" \
  --model-name "gpt-4o" \
  --model-version "2024-11-20" \
  --model-format OpenAI \
  --sku-name "Standard" \
  --sku-capacity 30
```

### Extend Data Collection

To collect additional log sources, update the Data Collection Rule:

```bash
# Export current DCR
az monitor data-collection rule show \
  --resource-group "$RESOURCE_GROUP" \
  --name "dcr-sql-windows-logs" \
  -o json > dcr-updated.json

# Edit dcr-updated.json to add new XPath queries or perf counters
# Then update:
az monitor data-collection rule update \
  --resource-group "$RESOURCE_GROUP" \
  --name "dcr-sql-windows-logs" \
  --rule-file dcr-updated.json
```

After adding new tables, update `TABLE_SCHEMAS` in `kql_prompt.py` so GPT-4o knows about the new columns.

### Rotate VM Admin Password

```bash
az vm user update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --username "$ADMIN_USERNAME" \
  --password "NewStr0ng!Pass#2026"
```

---

## Cleanup

To tear down all resources and stop incurring costs:

```bash
bash scripts/cleanup.sh
```

This deletes the entire resource group and all resources within it. The script prompts for confirmation before proceeding.

For selective cleanup:

```bash
# Delete only the web app (keep infrastructure)
az webapp delete --resource-group "$RESOURCE_GROUP" --name "$WEBAPP_NAME"

# Delete only the AI resources (keep VM and monitoring)
az cognitiveservices account delete --resource-group "$RESOURCE_GROUP" --name "$AOAI_NAME"
az ml workspace delete --resource-group "$RESOURCE_GROUP" --name "$AI_PROJECT_NAME" --yes
az ml workspace delete --resource-group "$RESOURCE_GROUP" --name "$AI_HUB_NAME" --yes

# Stop the VM to save compute costs (keep disk)
az vm deallocate --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"
```
