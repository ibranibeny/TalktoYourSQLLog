# SQL Error Event Simulation Guide

> **Purpose:** Generate realistic SQL Server error events to test the AI Log Analysis chat application.  
> **Target:** vm-sql-sea-01 in rg-contoso-sqlobs  
> **Script:** `scripts/simulate-errors.sh`

---

## Quick Start

```bash
# Load environment variables
source .env

# Run all simulations
bash scripts/simulate-errors.sh

# Wait 5–10 minutes, then test the AI app
```

---

## Simulated Errors

### 1. Non-Existent Database Access

Attempts to USE databases that do not exist on the SQL Server instance.

| Database | EventID | EventLevel |
|---|---|---|
| `NonExistentDB` | 911 | Error |
| `ClaimsDB` | 911 | Error |
| `ReportingDB` | 911 | Error |

**AI test question:** *"Are there any database not found errors in the last hour?"*

---

### 2. Non-Existent Table Queries

Runs SELECT against tables that do not exist in InsuranceDB.

| Table | EventID | EventLevel |
|---|---|---|
| `dbo.NonExistentTable` | 208 | Error |
| `dbo.AuditTrail` | 208 | Error |

**AI test question:** *"Were there any invalid object name errors today?"*

---

### 3. Business-Context Errors (RAISERROR WITH LOG)

Writes realistic error messages to the Windows Application Event Log via `RAISERROR ... WITH LOG`. These simulate production-like SQL failures.

| Error Message | Scenario |
|---|---|
| Database NonExistentDB does not exist. Cannot process claim batch job. | Missing database |
| Transaction deadlock detected on table PolicyHolders. Victim process killed. | Deadlock |
| Timeout expired connecting to database ClaimsDB. Connection pool exhausted. | Connection timeout |
| Cannot open database RequestedByLogin. Login failed for user sa. | Login failure |
| Disk space critically low on drive E:. Database auto-growth failed for InsuranceDB. | Disk space |
| Premium calculation service timeout. sp_CalculatePremium exceeded 30s threshold. | Stored proc timeout |
| Duplicate NRIC detected in PolicyHolders table. Constraint violation on insert batch. | Constraint violation |
| Transaction log full for database InsuranceDB. Cannot commit pending claim transactions. | Transaction log full |

**EventID:** 17063 (all)  
**EventLevel:** Error

**AI test questions:**
- *"What errors happened in the last 30 minutes and what caused them?"*
- *"Were there any deadlock or timeout errors recently?"*
- *"Show me all disk space related warnings"*

---

### 4. Failed Login Attempts

Attempts SQL Server authentication with invalid credentials. Generates EventID 18456 (Login failed).

| Username | Password |
|---|---|
| `hacker` | `wrongpassword` |
| `dbadmin` | `badpass123` |
| `claimsapp` | `test` |
| `root` | `password` |
| `admin` | `admin` |

**EventID:** 18456  
**EventLevel:** Error

**AI test questions:**
- *"Show me all failed login attempts today"*
- *"Is anyone trying to brute force SQL Server?"*
- *"Which usernames had the most failed logins?"*

---

### 5. Backup Failure

Attempts a database backup to a non-existent drive path (`Z:\backups\`).

| Database | Target Path | EventID |
|---|---|---|
| `InsuranceDB` | `Z:\backups\InsuranceDB.bak` | 3041 |

**EventLevel:** Error

**AI test question:** *"Did any backup jobs fail recently?"*

---

## Event Summary

| # | Simulation | Count | EventID | EventLevel |
|---|---|---|---|---|
| 1 | Non-existent database | 3 | 911 | Error |
| 2 | Non-existent table | 2 | 208 | Error |
| 3 | RAISERROR WITH LOG | 8 | 17063 | Error |
| 4 | Failed logins | 5 | 18456 | Error |
| 5 | Backup failure | 1 | 3041 | Error |
| | **Total** | **19** | | |

---

## Verify Events in Log Analytics

Wait 5–10 minutes after running the script, then:

```bash
LAW_WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$LAW_NAME" \
  --query customerId -o tsv)

# Count errors by source and EventID
az monitor log-analytics query \
  --workspace "$LAW_WORKSPACE_ID" \
  --analytics-query "Event | where TimeGenerated > ago(30m) | where EventLevelName == 'Error' | summarize count() by Source, EventID" \
  --timespan PT1H -o table

# View error details
az monitor log-analytics query \
  --workspace "$LAW_WORKSPACE_ID" \
  --analytics-query "Event | where TimeGenerated > ago(30m) | where EventLevelName == 'Error' | project TimeGenerated, Source, EventID, RenderedDescription | order by TimeGenerated desc" \
  --timespan PT1H -o table
```

---

---

## Deadlock & Slow Query Simulation

> **Script:** `scripts/simulate-deadlock-slowquery.sh`  
> **SQL file:** `scripts/simulate-deadlock-slowquery.sql`

### Quick Start

```bash
# Via bash (runs on Azure VM remotely)
bash scripts/simulate-deadlock-slowquery.sh

# Or run SQL directly on the VM
sqlcmd -S .\SQLEXPRESS -E -d InsuranceDB -i scripts/simulate-deadlock-slowquery.sql
```

### 6. Deadlock Events

Simulates SQL Server deadlocks using two approaches:
1. **RAISERROR WITH LOG** — 3 realistic deadlock messages written to the Windows Event Log
2. **Actual deadlock** — Two concurrent stored procedures (`sp_DeadlockSession1`, `sp_DeadlockSession2`) that create a real deadlock via conflicting UPDATE locks

| Event Message | Tables Involved | Duration |
|---|---|---|
| Process 52 deadlock victim on Policies | Policies, Claims | 12.3s |
| Process 67 deadlock victim on Customers | Customers (index) | — |
| Process 89 deadlock victim on Transactions | Transactions (clustered) | 8.7s |

**EventID:** 17063  
**EventLevel:** Error

**AI test questions:**
- *"Are there any deadlocks in SQL Server?"*
- *"Which tables are involved in deadlock events?"*
- *"How many deadlocks happened today and what caused them?"*

---

### 7. Slow Queries

Runs 5 intentionally expensive queries that generate real CPU load, then logs warning events to the Windows Event Log.

| # | Query Pattern | Why It's Slow | Logged Duration |
|---|---|---|---|
| 1 | Cartesian join (`CROSS JOIN` Customers × Customers × Packages) | No filter, 360K rows scanned | 28.4s |
| 2 | Scalar subquery in SELECT (N+1 on Claims/Transactions) | Row-by-row execution | 15.7s |
| 3 | Deeply nested subqueries (Customers → Policies → Claims) | Optimizer can't flatten | 12.1s |
| 4 | Leading wildcard `LIKE '%Tan%'` on Customers | Full table scan, no index seek | 9.3s |
| 5 | Heavy aggregation with `STRING_AGG` across 5 tables | TempDB spill, 3 sort ops | 22.8s |

**EventID:** 17063  
**EventLevel:** Error

**AI test questions:**
- *"List the top 5 slowest queries"*
- *"Are there any slow query warnings in the logs?"*
- *"Which queries caused full table scans?"*
- *"What query optimization recommendations can you give based on the logs?"*

---

### Deadlock & Slow Query Event Summary

| # | Simulation | Count | EventID | EventLevel |
|---|---|---|---|---|
| 6 | Deadlock (RAISERROR) | 3 | 17063 | Error |
| 6b | Deadlock (actual) | 1 | 17063 | Error |
| 7 | Slow query warnings | 5 | 17063 | Error |
| | **Subtotal** | **9** | | |

### Verify in Log Analytics

```bash
# Check deadlock events
az monitor log-analytics query \
  --workspace "$LAW_WORKSPACE_ID" \
  --analytics-query "Event | where TimeGenerated > ago(30m) | where RenderedDescription contains 'DEADLOCK' | project TimeGenerated, Source, RenderedDescription | order by TimeGenerated desc" \
  --timespan PT1H -o table

# Check slow query events
az monitor log-analytics query \
  --workspace "$LAW_WORKSPACE_ID" \
  --analytics-query "Event | where TimeGenerated > ago(30m) | where RenderedDescription contains 'SLOW QUERY' | project TimeGenerated, Source, RenderedDescription | order by TimeGenerated desc" \
  --timespan PT1H -o table

# Top 5 slowest queries by logged duration
az monitor log-analytics query \
  --workspace "$LAW_WORKSPACE_ID" \
  --analytics-query "Event | where TimeGenerated > ago(1h) | where RenderedDescription contains 'SLOW QUERY WARNING' | parse RenderedDescription with * 'took ' Duration:double ' seconds' * | project TimeGenerated, Duration, RenderedDescription | order by Duration desc | take 5" \
  --timespan PT1H -o table
```

---

## Recommended AI App Test Scenarios

After events appear in Log Analytics, test these questions in the Streamlit chat:

| # | Question | Expected Insight |
|---|---|---|
| 1 | What errors occurred in the last 30 minutes? | Summary of all 28 error events |
| 2 | Are there any database not found errors? | NonExistentDB, ClaimsDB, ReportingDB |
| 3 | Show me all failed login attempts | 5 attempts with usernames |
| 4 | Were there any deadlock or timeout errors? | Deadlock on PolicyHolders, ClaimsDB timeout |
| 5 | Did any backup jobs fail? | InsuranceDB backup to Z:\ failed |
| 6 | Is there any sign of unauthorized access? | Failed logins from hacker, root, admin |
| 7 | What is the most critical issue right now? | AI prioritises across all error types |
| 8 | Are there any disk space issues? | Auto-growth failure on drive E: |
| 9 | Summarise all SQL Server problems from today | Full timeline of all simulated events |
| 10 | **Are there any deadlocks in SQL Server?** | 3 deadlock events with table names and durations |
| 11 | **List the top 5 slowest queries** | 5 slow queries ranked by duration with optimisation tips |
| 12 | Which tables are involved in deadlocks? | Policies, Claims, Customers, Transactions |
| 13 | What query optimisation do you recommend? | Full-text index, JOIN rewrite, materialised views |
