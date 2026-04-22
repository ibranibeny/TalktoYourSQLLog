#!/usr/bin/env bash
#
# start-vm-sql.sh — Check VM state, start if deallocated, and ensure SQL service is running.
#
# Steps:
#   1. Check VM power state
#   2. Start VM if deallocated/stopped
#   3. Wait for VM agent to be ready
#   4. Check SQL Server Express service, start if stopped
#   5. Verify SQL Server is listening on TCP 1433
#
# Usage:
#   bash scripts/start-vm-sql.sh
# ────────────────────────────────────────────────────────────────────
set -euo pipefail

: "${RESOURCE_GROUP:=rg-contoso-sqlobs}"
: "${VM_NAME:=vm-sql-sea-01}"

echo "============================================================"
echo " Contoso SQL Observability — VM & SQL Server Startup"
echo "============================================================"

# ── 1. Check VM Power State ────────────────────────────────────────
echo ""
echo "[1/5] Checking VM power state..."

VM_STATE=$(az vm get-instance-view \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" \
  -o tsv 2>/dev/null || echo "NOT_FOUND")

echo "  Current state: $VM_STATE"

# ── 2. Start VM if not running ─────────────────────────────────────
echo ""
echo "[2/5] Starting VM if needed..."

if [[ "$VM_STATE" == "VM running" ]]; then
  echo "  ✓ VM is already running — skipping start"
elif [[ "$VM_STATE" == "NOT_FOUND" ]]; then
  echo "  ✗ VM '$VM_NAME' not found in resource group '$RESOURCE_GROUP'"
  echo "    Run scripts/deploy.sh first to create the VM."
  exit 1
else
  echo "  → VM is $VM_STATE — starting now..."
  az vm start \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --output none
  echo "  ✓ VM start command completed"
fi

# ── 3. Wait for VM agent to be ready ──────────────────────────────
echo ""
echo "[3/5] Waiting for VM agent to be ready..."

MAX_RETRIES=12
RETRY_INTERVAL=10
AGENT_READY=false

for i in $(seq 1 $MAX_RETRIES); do
  AGENT_STATUS=$(az vm get-instance-view \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --query "instanceView.vmAgent.statuses[0].displayStatus" \
    -o tsv 2>/dev/null || echo "UNKNOWN")

  if [[ "$AGENT_STATUS" == "Ready" ]]; then
    echo "  ✓ VM agent is ready"
    AGENT_READY=true
    break
  fi

  echo "  Attempt $i/$MAX_RETRIES — agent status: $AGENT_STATUS (retrying in ${RETRY_INTERVAL}s...)"
  sleep "$RETRY_INTERVAL"
done

if [[ "$AGENT_READY" != "true" ]]; then
  echo "  ✗ VM agent did not become ready after $((MAX_RETRIES * RETRY_INTERVAL))s"
  echo "    Proceeding anyway — SQL commands may fail."
fi

# ── 4. Check & start SQL Server Express service ───────────────────
echo ""
echo "[4/5] Checking SQL Server Express service..."

SQL_RESULT=$(az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts '
    $svcName = "MSSQL`$SQLEXPRESS"
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
      Write-Output "RESULT:NOT_INSTALLED"
      return
    }
    if ($svc.Status -eq "Running") {
      Write-Output "RESULT:ALREADY_RUNNING"
      return
    }
    # Service exists but not running — start it
    Write-Output "STARTING SQL Server Express..."
    Start-Service -Name $svcName -ErrorAction Stop
    # Also start SQL Agent if it exists
    $agent = Get-Service -Name "SQLAgent`$SQLEXPRESS" -ErrorAction SilentlyContinue
    if ($agent -and $agent.Status -ne "Running") {
      Start-Service -Name "SQLAgent`$SQLEXPRESS" -ErrorAction SilentlyContinue
    }
    # Verify
    $svc = Get-Service -Name $svcName
    Write-Output "RESULT:$($svc.Status)"
  ' \
  --query "value[0].message" -o tsv 2>/dev/null || echo "RESULT:ERROR")

SQL_STATUS=$(echo "$SQL_RESULT" | grep -oP 'RESULT:\K\S+' | head -1)

case "$SQL_STATUS" in
  ALREADY_RUNNING)
    echo "  ✓ SQL Server Express is already running"
    ;;
  Running)
    echo "  ✓ SQL Server Express started successfully"
    ;;
  NOT_INSTALLED)
    echo "  ✗ SQL Server Express is not installed"
    echo "    Run scripts/deploy-sql-express.sh to install it."
    exit 1
    ;;
  *)
    echo "  ✗ SQL Server Express status: $SQL_STATUS"
    echo "    Full output: $SQL_RESULT"
    exit 1
    ;;
esac

# ── 5. Verify SQL Server is listening on TCP 1433 ─────────────────
echo ""
echo "[5/5] Verifying SQL Server TCP port 1433..."

PORT_RESULT=$(az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts '
    $listener = Get-NetTCPConnection -LocalPort 1433 -State Listen -ErrorAction SilentlyContinue
    if ($listener) {
      Write-Output "PORT:LISTENING"
    } else {
      Write-Output "PORT:NOT_LISTENING"
    }
  ' \
  --query "value[0].message" -o tsv 2>/dev/null || echo "PORT:ERROR")

PORT_STATUS=$(echo "$PORT_RESULT" | grep -oP 'PORT:\K\S+' | head -1)

if [[ "$PORT_STATUS" == "LISTENING" ]]; then
  echo "  ✓ SQL Server is listening on TCP port 1433"
else
  echo "  ⚠ TCP port 1433 not listening (SQL Express may use dynamic ports)"
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " ✓ VM '$VM_NAME' is running and SQL Server Express is up"
echo "============================================================"
