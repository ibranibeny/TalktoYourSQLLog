#!/usr/bin/env bash
#
# check-vm-sql.sh — Verify the VM is running and SQL Server Express is operational.
#
# Checks:
#   1. VM power state (running / deallocated / stopped)
#   2. VM agent status
#   3. SQL Server (MSSQL$SQLEXPRESS) Windows service status
#   4. SQL Server TCP port 1433 listening
#   5. Azure Monitor Agent extension health
#
# Usage:
#   bash scripts/check-vm-sql.sh
# ────────────────────────────────────────────────────────────────────
set -euo pipefail

: "${RESOURCE_GROUP:=rg-contoso-sqlobs}"
: "${VM_NAME:=vm-sql-sea-01}"

echo "============================================================"
echo " Contoso SQL Observability — VM & SQL Server Health Check"
echo "============================================================"

PASS=0
FAIL=0

pass() { echo "  ✓ PASS: $1"; ((PASS++)); }
fail() { echo "  ✗ FAIL: $1"; ((FAIL++)); }

# ── 1. VM Power State ──────────────────────────────────────────────
echo ""
echo "[1/5] Checking VM power state..."

VM_STATE=$(az vm get-instance-view \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" \
  -o tsv 2>/dev/null || echo "NOT_FOUND")

if [[ "$VM_STATE" == "VM running" ]]; then
  pass "VM is running"
else
  fail "VM state: $VM_STATE (expected: VM running)"
fi

# ── 2. VM Agent Status ─────────────────────────────────────────────
echo ""
echo "[2/5] Checking VM agent status..."

AGENT_STATUS=$(az vm get-instance-view \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "instanceView.vmAgent.statuses[0].displayStatus" \
  -o tsv 2>/dev/null || echo "UNKNOWN")

if [[ "$AGENT_STATUS" == "Ready" ]]; then
  pass "VM agent is ready"
else
  fail "VM agent status: $AGENT_STATUS (expected: Ready)"
fi

# ── 3. SQL Server Service Status ───────────────────────────────────
echo ""
echo "[3/5] Checking SQL Server Express service (via remote command)..."

SQL_CHECK=$(az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts '
    $svc = Get-Service -Name "MSSQL`$SQLEXPRESS" -ErrorAction SilentlyContinue
    if ($svc) {
      Write-Output "STATUS:$($svc.Status)"
    } else {
      Write-Output "STATUS:NOT_INSTALLED"
    }
  ' \
  --query "value[0].message" -o tsv 2>/dev/null || echo "STATUS:ERROR")

SQL_STATUS=$(echo "$SQL_CHECK" | grep -oP 'STATUS:\K\S+' | head -1)

if [[ "$SQL_STATUS" == "Running" ]]; then
  pass "SQL Server Express service is running"
elif [[ "$SQL_STATUS" == "NOT_INSTALLED" ]]; then
  fail "SQL Server Express is not installed (run scripts/deploy-sql-express.sh)"
elif [[ "$SQL_STATUS" == "Stopped" ]]; then
  fail "SQL Server Express service is stopped"
else
  fail "SQL Server Express check returned: $SQL_STATUS"
fi

# ── 4. SQL Server TCP Port ─────────────────────────────────────────
echo ""
echo "[4/5] Checking SQL Server TCP port 1433..."

PORT_CHECK=$(az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts '
    $listener = Get-NetTCPConnection -LocalPort 1433 -State Listen -ErrorAction SilentlyContinue
    if ($listener) {
      Write-Output "LISTENING:YES"
    } else {
      Write-Output "LISTENING:NO"
    }
  ' \
  --query "value[0].message" -o tsv 2>/dev/null || echo "LISTENING:ERROR")

PORT_STATUS=$(echo "$PORT_CHECK" | grep -oP 'LISTENING:\K\S+' | head -1)

if [[ "$PORT_STATUS" == "YES" ]]; then
  pass "SQL Server is listening on TCP port 1433"
else
  fail "TCP port 1433 is not listening (SQL Express may use dynamic ports by default)"
fi

# ── 5. Azure Monitor Agent Extension ───────────────────────────────
echo ""
echo "[5/5] Checking Azure Monitor Agent extension..."

AMA_STATUS=$(az vm extension list \
  --resource-group "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  --query "[?name=='AzureMonitorWindowsAgent'].provisioningState" \
  -o tsv 2>/dev/null || echo "NOT_FOUND")

if [[ "$AMA_STATUS" == "Succeeded" ]]; then
  pass "Azure Monitor Agent extension provisioned successfully"
elif [[ -z "$AMA_STATUS" || "$AMA_STATUS" == "NOT_FOUND" ]]; then
  fail "Azure Monitor Agent extension not found"
else
  fail "Azure Monitor Agent extension state: $AMA_STATUS"
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " Results:  $PASS passed,  $FAIL failed"
echo "============================================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
