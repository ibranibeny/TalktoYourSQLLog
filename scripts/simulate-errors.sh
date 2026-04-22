#!/bin/bash
# ============================================================
# simulate-errors.sh
# Generate SQL Server error events for AI Log Analysis testing
# Events flow: SQL Server → Windows Event Log → AMA → LAW
# ============================================================

set -e

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-contoso-sqlobs}"
VM_NAME="${VM_NAME:-vm-sql-sea-01}"
SQLCMD='C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE'

echo "============================================================"
echo " SQL Error Event Simulator"
echo " Target: ${VM_NAME} in ${RESOURCE_GROUP}"
echo "============================================================"
echo ""

# ── 1. Non-existent database ─────────────────────────────────
echo "[1/5] Simulating non-existent database access..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
    \$sqlcmd = '${SQLCMD}'
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -Q \"USE [NonExistentDB]; SELECT 1;\" 2>&1
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -Q \"USE [ClaimsDB]; SELECT 1;\" 2>&1
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -Q \"USE [ReportingDB]; SELECT 1;\" 2>&1
  " \
  --query 'value[0].message' -o tsv
echo "  ✓ Done"
echo ""

# ── 2. Non-existent table queries ────────────────────────────
echo "[2/5] Simulating non-existent table queries..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
    \$sqlcmd = '${SQLCMD}'
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -Q \"USE InsuranceDB; SELECT * FROM dbo.NonExistentTable;\" 2>&1
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -Q \"USE InsuranceDB; SELECT * FROM dbo.AuditTrail;\" 2>&1
  " \
  --query 'value[0].message' -o tsv
echo "  ✓ Done"
echo ""

# ── 3. RAISERROR with WITH LOG (business-context errors) ─────
echo "[3/5] Simulating business-context errors (RAISERROR WITH LOG)..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
    \$sqlcmd = '${SQLCMD}'
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -Q \"
      RAISERROR('Database NonExistentDB does not exist. Cannot process claim batch job.', 16, 1) WITH LOG;
      RAISERROR('Transaction deadlock detected on table PolicyHolders. Victim process killed.', 16, 1) WITH LOG;
      RAISERROR('Timeout expired connecting to database ClaimsDB. Connection pool exhausted.', 16, 1) WITH LOG;
      RAISERROR('Cannot open database RequestedByLogin. Login failed for user sa.', 16, 1) WITH LOG;
      RAISERROR('Disk space critically low on drive E:. Database auto-growth failed for InsuranceDB.', 16, 1) WITH LOG;
      RAISERROR('Premium calculation service timeout. Stored procedure sp_CalculatePremium exceeded 30s threshold.', 16, 1) WITH LOG;
      RAISERROR('Duplicate NRIC detected in PolicyHolders table. Constraint violation on insert batch.', 16, 1) WITH LOG;
      RAISERROR('Transaction log full for database InsuranceDB. Cannot commit pending claim transactions.', 16, 1) WITH LOG;
    \"
  " \
  --query 'value[0].message' -o tsv
echo "  ✓ Done"
echo ""

# ── 4. Failed login attempts ─────────────────────────────────
echo "[4/5] Simulating failed login attempts..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
    \$sqlcmd = '${SQLCMD}'
    & \$sqlcmd -S localhost\SQLEXPRESS -U hacker -P wrongpassword -C -Q \"SELECT 1\" 2>&1
    & \$sqlcmd -S localhost\SQLEXPRESS -U dbadmin -P badpass123 -C -Q \"SELECT 1\" 2>&1
    & \$sqlcmd -S localhost\SQLEXPRESS -U claimsapp -P test -C -Q \"SELECT 1\" 2>&1
    & \$sqlcmd -S localhost\SQLEXPRESS -U root -P password -C -Q \"SELECT 1\" 2>&1
    & \$sqlcmd -S localhost\SQLEXPRESS -U admin -P admin -C -Q \"SELECT 1\" 2>&1
  " \
  --query 'value[0].message' -o tsv
echo "  ✓ Done"
echo ""

# ── 5. Backup failure simulation ─────────────────────────────
echo "[5/5] Simulating backup failure..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
    \$sqlcmd = '${SQLCMD}'
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -Q \"BACKUP DATABASE [InsuranceDB] TO DISK = 'Z:\backups\InsuranceDB.bak';\" 2>&1
  " \
  --query 'value[0].message' -o tsv
echo "  ✓ Done"
echo ""

echo "============================================================"
echo " Simulation Complete"
echo "============================================================"
echo ""
echo " Events generated:"
echo "   • 3x non-existent database access"
echo "   • 2x non-existent table queries"
echo "   • 8x RAISERROR WITH LOG (business errors)"
echo "   • 5x failed login attempts"
echo "   • 1x backup failure"
echo ""
echo " Wait 5-10 minutes for events to appear in Log Analytics."
echo ""
echo " Verify with:"
echo "   az monitor log-analytics query \\"
echo "     --workspace \"\$LAW_WORKSPACE_ID\" \\"
echo "     --analytics-query \"Event | where TimeGenerated > ago(30m) | where EventLevelName == 'Error' | summarize count() by Source, EventID\" \\"
echo "     --timespan PT1H -o table"
echo "============================================================"
