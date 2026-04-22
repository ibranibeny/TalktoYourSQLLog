#!/bin/bash
# ============================================================
# run-all-simulations.sh
# Runs all error simulations + deadlock/slow query simulations
# and verifies events in Log Analytics
# ============================================================

set -e

# ── Configuration ─────────────────────────────────────────────
export RESOURCE_GROUP="${RESOURCE_GROUP:-rg-contoso-sqlobs}"
export VM_NAME="${VM_NAME:-vm-sql-sea-01}"
export LAW_NAME="${LAW_NAME:-law-contoso-sqlobs}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================================"
echo " Income Insurance SG — Full Simulation Runner"
echo " VM:        ${VM_NAME}"
echo " RG:        ${RESOURCE_GROUP}"
echo " Workspace: ${LAW_NAME}"
echo "============================================================"
echo ""

# ── Pre-flight checks ────────────────────────────────────────
echo "[PRE-FLIGHT] Checking Azure CLI login..."
if ! az account show &>/dev/null; then
    echo "  ✗ Not logged in. Run: az login"
    exit 1
fi
ACCOUNT=$(az account show --query '[name, id]' -o tsv)
echo "  ✓ Logged in: ${ACCOUNT}"
echo ""

echo "[PRE-FLIGHT] Checking VM is running..."
VM_STATE=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" -d --query powerState -o tsv 2>/dev/null || echo "NOT_FOUND")
if [[ "$VM_STATE" != "VM running" ]]; then
    echo "  ✗ VM state: ${VM_STATE}"
    echo "  Starting VM..."
    az vm start -g "$RESOURCE_GROUP" -n "$VM_NAME" --no-wait
    echo "  Waiting 60 seconds for VM to start..."
    sleep 60
else
    echo "  ✓ VM is running"
fi
echo ""

# ── Phase 1: Error simulations ───────────────────────────────
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  PHASE 1: SQL Error Event Simulation (19 events)       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
bash "${SCRIPT_DIR}/simulate-errors.sh"
echo ""

# ── Phase 2: Deadlock & slow query simulations ────────────────
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  PHASE 2: Deadlock & Slow Query Simulation (9 events)  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
bash "${SCRIPT_DIR}/simulate-deadlock-slowquery.sh"
echo ""

# ── Phase 3: Verify events in Log Analytics ───────────────────
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  PHASE 3: Verification                                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Waiting 30 seconds for events to propagate to Log Analytics..."
sleep 30

LAW_WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$LAW_NAME" \
  --query customerId -o tsv)

echo ""
echo "── Error event summary ──────────────────────────────────"
az monitor log-analytics query \
  --workspace "$LAW_WORKSPACE_ID" \
  --analytics-query "Event | where TimeGenerated > ago(30m) | where EventLevelName == 'Error' | summarize Count=count() by Source, EventID | order by Count desc" \
  --timespan PT1H -o table 2>/dev/null || echo "  (Events may not have arrived yet — retry in a few minutes)"

echo ""
echo "── Deadlock events ──────────────────────────────────────"
az monitor log-analytics query \
  --workspace "$LAW_WORKSPACE_ID" \
  --analytics-query "Event | where TimeGenerated > ago(30m) | where RenderedDescription contains 'DEADLOCK' | project TimeGenerated, Source, RenderedDescription | order by TimeGenerated desc" \
  --timespan PT1H -o table 2>/dev/null || echo "  (No deadlock events yet)"

echo ""
echo "── Top 5 slowest queries ────────────────────────────────"
az monitor log-analytics query \
  --workspace "$LAW_WORKSPACE_ID" \
  --analytics-query "Event | where TimeGenerated > ago(30m) | where RenderedDescription contains 'SLOW QUERY WARNING' | parse RenderedDescription with * 'took ' Duration:double ' seconds' * | project TimeGenerated, Duration, RenderedDescription | order by Duration desc | take 5" \
  --timespan PT1H -o table 2>/dev/null || echo "  (No slow query events yet)"

echo ""
echo "============================================================"
echo " All simulations complete!"
echo "============================================================"
echo ""
echo " Total events generated: ~28"
echo "   Phase 1: 19 error events"
echo "   Phase 2:  9 deadlock + slow query events"
echo ""
echo " If events haven't appeared yet, wait 5-10 min and run:"
echo "   az monitor log-analytics query \\"
echo "     --workspace \"${LAW_WORKSPACE_ID}\" \\"
echo "     --analytics-query \"Event | where TimeGenerated > ago(1h) | where EventLevelName == 'Error' | summarize count() by Source, EventID\" \\"
echo "     --timespan PT1H -o table"
echo ""
echo " Then test in the Streamlit app:"
echo "   • Are there any deadlocks in SQL Server?"
echo "   • List the top 5 slowest queries"
echo "   • What errors occurred in the last 30 minutes?"
echo "============================================================"
