#!/bin/bash
# ============================================================
# simulate-deadlock-slowquery.sh
# Generate deadlock events and slow query warnings in SQL Server
# Events flow: SQL Server → Windows Event Log → AMA → LAW
# ============================================================

set -e

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-contoso-sqlobs}"
VM_NAME="${VM_NAME:-vm-sql-sea-01}"
SQLCMD='C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE'

echo "============================================================"
echo " Deadlock & Slow Query Simulator"
echo " Target: ${VM_NAME} in ${RESOURCE_GROUP}"
echo "============================================================"
echo ""

# ── 1. Setup: enable deadlock trace flags ─────────────────────
echo "[1/5] Enabling deadlock trace flags (1204, 1222)..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
    \$sqlcmd = '${SQLCMD}'
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -Q \"DBCC TRACEON(1204, -1); DBCC TRACEON(1222, -1);\" 2>&1
  " \
  --query 'value[0].message' -o tsv
echo "  ✓ Trace flags enabled"
echo ""

# ── 2. Create deadlock staging tables & stored procedures ─────
echo "[2/5] Creating deadlock staging tables and procedures..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
    \$sqlcmd = '${SQLCMD}'
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -d InsuranceDB -Q \"
      IF OBJECT_ID('dbo.DeadlockTableA', 'U') IS NOT NULL DROP TABLE dbo.DeadlockTableA;
      IF OBJECT_ID('dbo.DeadlockTableB', 'U') IS NOT NULL DROP TABLE dbo.DeadlockTableB;
      CREATE TABLE dbo.DeadlockTableA (id INT PRIMARY KEY, val NVARCHAR(100));
      CREATE TABLE dbo.DeadlockTableB (id INT PRIMARY KEY, val NVARCHAR(100));
      INSERT INTO dbo.DeadlockTableA VALUES (1, 'PolicyHolder-A');
      INSERT INTO dbo.DeadlockTableB VALUES (1, 'PolicyHolder-B');
      PRINT 'Deadlock tables created.';
    \" 2>&1
  " \
  --query 'value[0].message' -o tsv
echo "  ✓ Staging tables ready"
echo ""

# ── 3. Simulate deadlock events (RAISERROR WITH LOG) ─────────
echo "[3/5] Simulating deadlock events (3 events)..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
    \$sqlcmd = '${SQLCMD}'
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -d InsuranceDB -Q \"
      RAISERROR('DEADLOCK DETECTED: Process 52 was chosen as the deadlock victim on table Policies. Transaction rolled back after 12.3 seconds. Resources involved: KEY lock on Policies (hobt_id=72057594039828480), KEY lock on Claims (hobt_id=72057594039893504).', 16, 1) WITH LOG;
      RAISERROR('DEADLOCK DETECTED: Process 67 was chosen as the deadlock victim on table Customers. Two concurrent UPDATE operations conflicted on customer_id index. Retry recommended.', 16, 1) WITH LOG;
      RAISERROR('DEADLOCK DETECTED: Process 89 was chosen as the deadlock victim on table Transactions. INSERT and UPDATE operations conflicted on clustered index. Transaction rolled back after 8.7 seconds.', 16, 1) WITH LOG;
    \"
  " \
  --query 'value[0].message' -o tsv
echo "  ✓ 3 deadlock events logged"
echo ""

# ── 4. Trigger actual deadlock between two sessions ───────────
echo "[4/5] Triggering actual deadlock (two concurrent sessions)..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
    \$sqlcmd = '${SQLCMD}'

    # Create stored procedures for deadlock
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -d InsuranceDB -Q \"
      IF OBJECT_ID('dbo.sp_DeadlockSession1', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_DeadlockSession1;
      IF OBJECT_ID('dbo.sp_DeadlockSession2', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_DeadlockSession2;
    \" 2>&1

    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -d InsuranceDB -Q \"
      EXEC sp_executesql N'
        CREATE PROCEDURE dbo.sp_DeadlockSession1
        AS
        BEGIN
          SET NOCOUNT ON;
          SET DEADLOCK_PRIORITY LOW;
          BEGIN TRY
            BEGIN TRANSACTION;
              UPDATE dbo.DeadlockTableA SET val = ''Session1-Locked-A'' WHERE id = 1;
              WAITFOR DELAY ''00:00:05'';
              UPDATE dbo.DeadlockTableB SET val = ''Session1-Wants-B'' WHERE id = 1;
            COMMIT;
          END TRY
          BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            DECLARE @msg NVARCHAR(500) = ''DEADLOCK DETECTED (ACTUAL): '' + ERROR_MESSAGE();
            RAISERROR(@msg, 16, 1) WITH LOG;
          END CATCH
        END';
    \" 2>&1

    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -d InsuranceDB -Q \"
      EXEC sp_executesql N'
        CREATE PROCEDURE dbo.sp_DeadlockSession2
        AS
        BEGIN
          SET NOCOUNT ON;
          SET DEADLOCK_PRIORITY HIGH;
          BEGIN TRY
            BEGIN TRANSACTION;
              UPDATE dbo.DeadlockTableB SET val = ''Session2-Locked-B'' WHERE id = 1;
              WAITFOR DELAY ''00:00:05'';
              UPDATE dbo.DeadlockTableA SET val = ''Session2-Wants-A'' WHERE id = 1;
            COMMIT;
          END TRY
          BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            DECLARE @msg NVARCHAR(500) = ''DEADLOCK DETECTED (ACTUAL): '' + ERROR_MESSAGE();
            RAISERROR(@msg, 16, 1) WITH LOG;
          END CATCH
        END';
    \" 2>&1

    # Launch both sessions in parallel to cause a real deadlock
    Write-Output 'Launching two concurrent sessions to trigger deadlock...'
    \$job1 = Start-Job -ScriptBlock {
      & '${SQLCMD}' -S localhost\SQLEXPRESS -E -C -d InsuranceDB -Q 'EXEC dbo.sp_DeadlockSession1;' 2>&1
    }
    Start-Sleep -Seconds 1
    \$job2 = Start-Job -ScriptBlock {
      & '${SQLCMD}' -S localhost\SQLEXPRESS -E -C -d InsuranceDB -Q 'EXEC dbo.sp_DeadlockSession2;' 2>&1
    }

    # Wait for both to finish (deadlock monitor runs every 5 seconds)
    Wait-Job \$job1, \$job2 -Timeout 30 | Out-Null
    Write-Output 'Session 1 output:'
    Receive-Job \$job1
    Write-Output 'Session 2 output:'
    Receive-Job \$job2
    Remove-Job \$job1, \$job2 -Force
    Write-Output 'Deadlock trigger complete.'
  " \
  --query 'value[0].message' -o tsv
echo "  ✓ Actual deadlock triggered"
echo ""

# ── 5a. Run actual slow queries (generate CPU/duration load) ──
echo "[5/6] Running slow queries (real CPU load)..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
    \$sqlcmd = '${SQLCMD}'
    \$ErrorActionPreference = 'Continue'

    Write-Output 'Running slow query 1/5: Cartesian join...'
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -d InsuranceDB -Q \"
      SELECT COUNT(*) FROM Customers c1 CROSS JOIN Customers c2
      CROSS JOIN (SELECT TOP 10 * FROM InsurancePackages) pkg
      WHERE c1.full_name LIKE '%%a%%' AND c2.full_name LIKE '%%e%%';
    \" 2>&1

    Write-Output 'Running slow query 2/5: N+1 scalar subquery...'
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -d InsuranceDB -Q \"
      SELECT TOP 200 p.policy_number, p.annual_premium,
        (SELECT COUNT(*) FROM Claims cl WHERE cl.policy_id = p.policy_id) AS claim_count,
        (SELECT MAX(cl.claim_amount) FROM Claims cl WHERE cl.policy_id = p.policy_id) AS max_claim,
        (SELECT SUM(t.amount) FROM Transactions t WHERE t.policy_id = p.policy_id) AS total_txn
      FROM Policies p ORDER BY p.annual_premium DESC;
    \" 2>&1

    Write-Output 'Running slow query 3/5: Nested subqueries...'
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -d InsuranceDB -Q \"
      SELECT * FROM Customers c WHERE c.customer_id IN (
        SELECT p.customer_id FROM Policies p WHERE p.policy_id IN (
          SELECT cl.policy_id FROM Claims cl WHERE cl.claim_amount > (
            SELECT AVG(cl2.claim_amount) * 2 FROM Claims cl2)));
    \" 2>&1

    Write-Output 'Running slow query 4/5: Leading wildcard LIKE...'
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -d InsuranceDB -Q \"
      SELECT c.customer_id, c.full_name, c.email, p.policy_number, p.annual_premium
      FROM Customers c JOIN Policies p ON c.customer_id = p.customer_id
      WHERE c.full_name LIKE '%%Tan%%' OR c.email LIKE '%%gmail%%'
      ORDER BY c.full_name;
    \" 2>&1

    Write-Output 'Running slow query 5/5: Heavy aggregation with STRING_AGG...'
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -d InsuranceDB -Q \"
      SELECT a.branch, a.full_name, COUNT(DISTINCT p.policy_id) AS policies,
        COUNT(DISTINCT cl.claim_id) AS claims, SUM(p.annual_premium) AS premium,
        SUM(cl.claim_amount) AS claim_total,
        STRING_AGG(DISTINCT pkg.package_name, ', ') AS packages
      FROM Agents a
      JOIN Policies p ON a.agent_id = p.agent_id
      JOIN InsurancePackages pkg ON p.package_id = pkg.package_id
      LEFT JOIN Claims cl ON p.policy_id = cl.policy_id
      LEFT JOIN Transactions t ON p.policy_id = t.policy_id
      GROUP BY a.branch, a.full_name, a.agent_id
      ORDER BY claim_total DESC;
    \" 2>&1

    Write-Output 'All slow queries executed.'
  " \
  --query 'value[0].message' -o tsv
echo "  ✓ 5 slow queries executed"
echo ""

# ── 5b. Log slow query warning events (separate invoke to guarantee delivery)
echo "[6/6] Logging slow query warning events to Windows Event Log..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
    \$sqlcmd = '${SQLCMD}'
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -d InsuranceDB -Q \"
      RAISERROR('SLOW QUERY WARNING: Query on Customers x Policies cartesian join took 28.4 seconds. 360000 rows scanned with no index seek. Query hash: 0x7A3F2B1C. Plan guide recommended.', 16, 1) WITH LOG;
      RAISERROR('SLOW QUERY WARNING: N+1 scalar subquery pattern detected on Claims/Transactions lookup. Elapsed 15.7 seconds for 200 rows. Consider rewriting with JOIN or APPLY.', 16, 1) WITH LOG;
      RAISERROR('SLOW QUERY WARNING: Deeply nested subquery on Customers/Policies/Claims exceeded 12.1 seconds. Query optimizer unable to flatten. Estimated vs actual rows: 50 vs 12400.', 16, 1) WITH LOG;
      RAISERROR('SLOW QUERY WARNING: Leading wildcard LIKE on Customers.full_name caused full table scan. 600 rows scanned, 0 index seeks. Duration: 9.3 seconds. Consider full-text index.', 16, 1) WITH LOG;
      RAISERROR('SLOW QUERY WARNING: Heavy aggregation across Agents/Policies/Claims/Transactions with STRING_AGG took 22.8 seconds. TempDB spill detected (3 sort operations). Consider pre-aggregated materialized view.', 16, 1) WITH LOG;
    \"

    # Verify events landed in Windows Event Log
    Write-Output ''
    Write-Output 'Verifying events in Windows Application log...'
    \$events = Get-WinEvent -LogName 'Application' -MaxEvents 20 -ErrorAction SilentlyContinue |
      Where-Object { \$_.Message -like '*SLOW QUERY*' -and \$_.TimeCreated -gt (Get-Date).AddMinutes(-5) }
    Write-Output \"Found \$(\$events.Count) SLOW QUERY events in Application log.\"
  " \
  --query 'value[0].message' -o tsv
echo "  ✓ 5 slow query events logged to Windows Event Log"
echo ""

echo "============================================================"
echo " Simulation Complete"
echo "============================================================"
echo ""
echo " Events generated:"
echo "   • 3x deadlock events (RAISERROR WITH LOG)"
echo "   • 1x actual deadlock between two sessions"
echo "   • 5x slow queries executed (real CPU load)"
echo "   • 5x slow query warning events (RAISERROR WITH LOG, separate invoke)"
echo ""
echo " Note: RAISERROR events are now logged in a separate step to"
echo "       guarantee delivery even if slow queries fail/timeout."
echo ""
echo " Wait 5-10 minutes for events to appear in Log Analytics."
echo ""
echo " Verify deadlocks:"
echo "   az monitor log-analytics query \\"
echo "     --workspace \"\$LAW_WORKSPACE_ID\" \\"
echo "     --analytics-query \"Event | where TimeGenerated > ago(30m) | where RenderedDescription contains 'DEADLOCK' | project TimeGenerated, Source, RenderedDescription\" \\"
echo "     --timespan PT1H -o table"
echo ""
echo " Verify slow queries:"
echo "   az monitor log-analytics query \\"
echo "     --workspace \"\$LAW_WORKSPACE_ID\" \\"
echo "     --analytics-query \"Event | where TimeGenerated > ago(30m) | where RenderedDescription contains 'SLOW QUERY' | project TimeGenerated, Source, RenderedDescription | order by TimeGenerated desc\" \\"
echo "     --timespan PT1H -o table"
echo ""
echo " Verify SQL perf counters (use MSSQL\$SQLEXPRESS, not SQLServer):"
echo "   az monitor log-analytics query \\"
echo "     --workspace \"\$LAW_WORKSPACE_ID\" \\"
echo "     --analytics-query \"Perf | where ObjectName contains 'MSSQL' | summarize avg(CounterValue) by ObjectName, CounterName | order by ObjectName\" \\"
echo "     --timespan PT1H -o table"
echo "============================================================"
