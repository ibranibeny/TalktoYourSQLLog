#!/bin/bash
# ============================================================
# fix-dcr-counters.sh
# Fix DCR performance counter names for SQL Express named instance
# and enable Extended Events for query duration tracking.
#
# Problem: DCR used "SQLServer:*" counters (default instance only).
#          SQL Express registers counters as "MSSQL$SQLEXPRESS:*".
# ============================================================

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-contoso-sqlobs}"
VM_NAME="${VM_NAME:-vm-sql-sea-01}"
LAW_NAME="${LAW_NAME:-law-contoso-sqlobs}"
DCR_NAME="${DCR_NAME:-dcr-sql-windows-logs}"
LOCATION_SEA="${LOCATION_SEA:-southeastasia}"
SQLCMD='C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE'

echo "============================================================"
echo " DCR & Extended Events Fix"
echo " Target: ${VM_NAME} in ${RESOURCE_GROUP}"
echo "============================================================"
echo ""

# ── 0. Pre-flight checks ─────────────────────────────────────
echo "[0/5] Pre-flight checks..."

VM_STATE=$(az vm get-instance-view \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" \
  -o tsv)

if [[ "$VM_STATE" != "VM running" ]]; then
  echo "  ✗ VM is not running (state: $VM_STATE). Start it first."
  exit 1
fi
echo "  ✓ VM is running"

AMA_STATUS=$(az vm extension list \
  --resource-group "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  --query "[?contains(name,'AzureMonitor')].provisioningState" \
  -o tsv)

if [[ "$AMA_STATUS" != "Succeeded" ]]; then
  echo "  ✗ AMA extension status: $AMA_STATUS"
  exit 1
fi
echo "  ✓ AMA extension is healthy"
echo ""

# ── 1. Verify actual counter names on the VM ─────────────────
echo "[1/5] Checking actual SQL perf counter names on VM..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
    Write-Output '=== SQL Server Counter Sets ==='
    Get-Counter -ListSet 'MSSQL*' -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty CounterSetName | Sort-Object -Unique
    Write-Output ''
    Write-Output '=== Default Instance Counter Sets ==='
    Get-Counter -ListSet 'SQLServer*' -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty CounterSetName | Sort-Object -Unique
    if (-not (Get-Counter -ListSet 'SQLServer*' -ErrorAction SilentlyContinue)) {
      Write-Output '(none found - this is expected for named instances)'
    }
  " \
  --query 'value[0].message' -o tsv
echo ""

# ── 2. Update DCR with correct counter names ─────────────────
echo "[2/5] Updating DCR with correct MSSQL\$SQLEXPRESS counter names..."

LAW_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$LAW_NAME" \
  --query id -o tsv)

DCE_ID=$(az monitor data-collection endpoint show \
  --resource-group "$RESOURCE_GROUP" \
  --name "dce-contoso-sea" \
  --query id -o tsv)

DCR_FILE=$(mktemp /tmp/dcr-fix-XXXXXX.json)
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
            "Application!*[System[(Level=1 or Level=2 or Level=3 or Level=4)]]",
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
  --name "$DCR_NAME" \
  --location "$LOCATION_SEA" \
  --rule-file "$DCR_FILE" \
  --output none

rm -f "$DCR_FILE"
echo "  ✓ DCR updated with MSSQL\$SQLEXPRESS counters"
echo ""

# ── 3. Enable Extended Events for slow query tracking ─────────
echo "[3/5] Enabling Extended Events session for slow query capture..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
    \$sqlcmd = '${SQLCMD}'

    # Enable Query Store on InsuranceDB (tracks query performance automatically)
    Write-Output 'Enabling Query Store...'
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -Q \"
      ALTER DATABASE InsuranceDB SET QUERY_STORE = ON (
        OPERATION_MODE = READ_WRITE,
        MAX_STORAGE_SIZE_MB = 100,
        INTERVAL_LENGTH_MINUTES = 5,
        QUERY_CAPTURE_MODE = AUTO
      );
    \" 2>&1

    # Create Extended Events session for slow queries (>2 seconds)
    Write-Output 'Creating Extended Events session for slow queries...'
    & \$sqlcmd -S localhost\SQLEXPRESS -E -C -Q \"
      IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'SlowQueryCapture')
        DROP EVENT SESSION SlowQueryCapture ON SERVER;

      CREATE EVENT SESSION SlowQueryCapture ON SERVER
      ADD EVENT sqlserver.sql_batch_completed (
        ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.username,
                sqlserver.client_app_name, sqlserver.query_hash, sqlserver.query_plan_hash)
        WHERE duration > 2000000  -- 2 seconds in microseconds
      ),
      ADD EVENT sqlserver.rpc_completed (
        ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.username,
                sqlserver.client_app_name, sqlserver.query_hash, sqlserver.query_plan_hash)
        WHERE duration > 2000000
      )
      ADD TARGET package0.event_file (
        SET filename = N'C:\SQLLogs\SlowQueries.xel',
            max_file_size = 50,
            max_rollover_files = 5
      )
      WITH (
        MAX_MEMORY = 4096 KB,
        EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
        MAX_DISPATCH_LATENCY = 30 SECONDS,
        STARTUP_STATE = ON
      );

      ALTER EVENT SESSION SlowQueryCapture ON SERVER STATE = START;
      PRINT 'Extended Events session SlowQueryCapture started.';
    \" 2>&1

    # Create the log directory
    if (-not (Test-Path 'C:\SQLLogs')) { New-Item -Path 'C:\SQLLogs' -ItemType Directory -Force }
    Write-Output 'Done.'
  " \
  --query 'value[0].message' -o tsv
echo "  ✓ Extended Events session created (captures queries > 2s)"
echo "  ✓ Query Store enabled on InsuranceDB"
echo ""

# ── 4. Restart AMA to pick up new DCR ────────────────────────
echo "[4/5] Restarting Azure Monitor Agent to apply new DCR..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
    Restart-Service -Name 'AzureMonitorAgent' -Force
    Start-Sleep -Seconds 5
    Get-Service -Name 'AzureMonitorAgent' | Select-Object Name, Status | Format-Table
  " \
  --query 'value[0].message' -o tsv
echo "  ✓ AMA restarted"
echo ""

# ── 5. Verify events are in Windows Event Log ────────────────
echo "[5/5] Verifying events in Windows Application Event Log..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
    Write-Output '=== Recent SQL Express Application Events (last 24h) ==='
    \$events = Get-WinEvent -LogName 'Application' -MaxEvents 200 -ErrorAction SilentlyContinue |
      Where-Object { \$_.ProviderName -like 'MSSQL*' -and \$_.TimeCreated -gt (Get-Date).AddHours(-24) }
    if (\$events) {
      Write-Output \"Found \$(\$events.Count) SQL events in Application log:\"
      \$events | Group-Object -Property LevelDisplayName | ForEach-Object {
        Write-Output \"  \$(\$_.Name): \$(\$_.Count)\"
      }
      Write-Output ''
      Write-Output '=== Last 5 events ==='
      \$events | Select-Object -First 5 | ForEach-Object {
        Write-Output \"[\$(\$_.TimeCreated)] [\$(\$_.LevelDisplayName)] \$(\$_.Message.Substring(0, [Math]::Min(150, \$_.Message.Length)))...\"
      }
    } else {
      Write-Output 'No SQL events found in last 24h. Run simulate scripts first!'
    }
  " \
  --query 'value[0].message' -o tsv
echo ""

echo "============================================================"
echo " Fix Applied"
echo "============================================================"
echo ""
echo " Changes made:"
echo "   1. DCR counter names fixed: SQLServer:* → MSSQL\$SQLEXPRESS:*"
echo "   2. Added counters: Compilations, Lock Waits, Page Life Expectancy"
echo "   3. XPath now includes Level=4 (Informational) for broader capture"
echo "   4. Extended Events session captures queries > 2 seconds"
echo "   5. Query Store enabled on InsuranceDB"
echo "   6. AMA restarted to pick up changes"
echo ""
echo " Wait 5-10 minutes, then verify with:"
echo ""
echo " Perf counters (SQL):"
echo "   az monitor log-analytics query \\"
echo "     --workspace \"\$LAW_WORKSPACE_ID\" \\"
echo "     --analytics-query \"Perf | where ObjectName contains 'MSSQL' | summarize count() by ObjectName, CounterName | order by count_ desc\" \\"
echo "     --timespan PT1H -o table"
echo ""
echo " Events (deadlocks + slow queries):"
echo "   az monitor log-analytics query \\"
echo "     --workspace \"\$LAW_WORKSPACE_ID\" \\"
echo "     --analytics-query \"Event | where Source == 'MSSQL\\\$SQLEXPRESS' | where TimeGenerated > ago(1h) | summarize count() by EventLevelName\" \\"
echo "     --timespan PT1H -o table"
echo ""
echo " After running simulate-deadlock-slowquery.sh again:"
echo "   az monitor log-analytics query \\"
echo "     --workspace \"\$LAW_WORKSPACE_ID\" \\"
echo "     --analytics-query \"Event | where RenderedDescription contains 'SLOW QUERY' or RenderedDescription contains 'DEADLOCK' | project TimeGenerated, RenderedDescription | order by TimeGenerated desc\" \\"
echo "     --timespan PT1H -o table"
echo "============================================================"
