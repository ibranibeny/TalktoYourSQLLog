# Simulation Runbook — Income Insurance SG

> Step-by-step guide to generate SQL Server error events for AI Log Analysis testing.

---

## Architecture

```
SQL Server (vm-sql-sea-01)
  ├─ RAISERROR WITH LOG → Windows Application Event Log
  ├─ Failed logins      → Windows Application Event Log
  └─ SQL errors         → Windows Application Event Log
          │
          ▼
  Azure Monitor Agent (AMA) + DCR
          │
          ▼
  Log Analytics Workspace (law-contoso-sqlobs)
          │
          ▼
  Streamlit AI App (NL → KQL via GPT-4o)
```

---

## Prerequisites

| Requirement | Details |
|---|---|
| Azure CLI | `az login` completed |
| Subscription | `ME-MngEnvMCAP708029-benyibrani-1` |
| Resource Group | `rg-contoso-sqlobs` |
| VM | `vm-sql-sea-01` (Windows Server 2022, SQL Express) |
| Log Analytics | `law-contoso-sqlobs` (Southeast Asia) |
| AMA + DCR | Configured to collect Windows Application Event Log |
| WSL / Bash | Required to run `.sh` scripts |

### Verify prerequisites

```bash
# 1. Check Azure login
az account show --query '[name, id]' -o tsv

# 2. Check VM is running
az vm show -g rg-contoso-sqlobs -n vm-sql-sea-01 -d --query powerState -o tsv

# 3. Start VM if stopped
az vm start -g rg-contoso-sqlobs -n vm-sql-sea-01
```

---

## Option A: Run Everything (Recommended)

Runs Phase 1 + Phase 2 + Phase 3 verification in one go.

```bash
cd "/mnt/c/Users/benyibrani/OneDrive - Microsoft/Documents/Project/Income Insurance SG"
bash scripts/run-all-simulations.sh
```

**What it does:**
1. Pre-flight checks (Azure login, VM running)
2. Phase 1: 19 SQL error events (`simulate-errors.sh`)
3. Phase 2: 9 deadlock + slow query events (`simulate-deadlock-slowquery.sh`)
4. Phase 3: Waits 30s then queries Log Analytics for verification

**Duration:** ~10–15 minutes  
**Total events:** ~28

---

## Option B: Run Individually

### Phase 1 — SQL Error Events (19 events)

```bash
bash scripts/simulate-errors.sh
```

Generates 5 categories of errors:

#### Step 1/5: Non-existent database access

Attempts `USE [NonExistentDB]`, `USE [ClaimsDB]`, `USE [ReportingDB]`.

```
Expected output:
  Msg 911, Level 16 — Database 'NonExistentDB' does not exist.
  Msg 911, Level 16 — Database 'ClaimsDB' does not exist.
  Msg 911, Level 16 — Database 'ReportingDB' does not exist.
```

#### Step 2/5: Non-existent table queries

Runs `SELECT * FROM dbo.NonExistentTable` and `dbo.AuditTrail` in InsuranceDB.

```
Expected output:
  Msg 208, Level 16 — Invalid object name 'dbo.NonExistentTable'.
  Msg 208, Level 16 — Invalid object name 'dbo.AuditTrail'.
```

#### Step 3/5: Business-context errors (RAISERROR WITH LOG)

Writes 8 realistic error messages to the Windows Event Log:

| # | Error Message |
|---|---|
| 1 | Database NonExistentDB does not exist. Cannot process claim batch job. |
| 2 | Transaction deadlock detected on table PolicyHolders. Victim process killed. |
| 3 | Timeout expired connecting to database ClaimsDB. Connection pool exhausted. |
| 4 | Cannot open database RequestedByLogin. Login failed for user sa. |
| 5 | Disk space critically low on drive E:. Database auto-growth failed for InsuranceDB. |
| 6 | Premium calculation service timeout. sp_CalculatePremium exceeded 30s threshold. |
| 7 | Duplicate NRIC detected in PolicyHolders table. Constraint violation on insert batch. |
| 8 | Transaction log full for database InsuranceDB. Cannot commit pending claim transactions. |

```
Expected output:
  Msg 50000, Level 16 — [each error message above]
```

#### Step 4/5: Failed login attempts

Attempts SQL auth with 5 invalid credentials:

| Username | Password |
|---|---|
| `hacker` | `wrongpassword` |
| `dbadmin` | `badpass123` |
| `claimsapp` | `test` |
| `root` | `password` |
| `admin` | `admin` |

> **Note:** Output may appear empty because SQL auth may be disabled on the instance. The failed login attempts still generate EventID 18456 in the Windows Event Log.

#### Step 5/5: Backup failure

Attempts backup to non-existent path `Z:\backups\InsuranceDB.bak`.

```
Expected output:
  Msg 3201, Level 16 — Cannot open backup device 'Z:\backups\InsuranceDB.bak'.
  Msg 3013, Level 16 — BACKUP DATABASE is terminating abnormally.
```

---

### Phase 2 — Deadlock & Slow Query Events (9 events)

```bash
bash scripts/simulate-deadlock-slowquery.sh
```

#### Step 1/5: Enable deadlock trace flags

Enables TF 1204 and TF 1222 for deadlock logging.

```
Expected output:
  DBCC execution completed.
```

#### Step 2/5: Create staging tables

Creates `DeadlockTableA` and `DeadlockTableB` with seed data for the deadlock trigger.

```
Expected output:
  (1 rows affected)
  Deadlock tables created.
```

#### Step 3/5: Simulate deadlock events (3 RAISERROR)

Writes 3 deadlock-themed error messages to the Windows Event Log:

| Process | Table | Duration |
|---|---|---|
| Process 52 | Policies, Claims | 12.3s |
| Process 67 | Customers (index) | — |
| Process 89 | Transactions (clustered) | 8.7s |

```
Expected output:
  Msg 50000, Level 16 — DEADLOCK DETECTED: Process 52 was chosen as...
  Msg 50000, Level 16 — DEADLOCK DETECTED: Process 67 was chosen as...
  Msg 50000, Level 16 — DEADLOCK DETECTED: Process 89 was chosen as...
```

#### Step 4/5: Trigger actual deadlock

Launches two concurrent stored procedures (`sp_DeadlockSession1`, `sp_DeadlockSession2`) that create conflicting UPDATE locks on `DeadlockTableA` and `DeadlockTableB`.

- Session 1: locks A → waits → tries B (LOW priority → victim)
- Session 2: locks B → waits → tries A (HIGH priority → wins)

```
Expected output:
  Launching two concurrent sessions to trigger deadlock...
  Session 1 output:
    Msg 50000 — DEADLOCK DETECTED (ACTUAL): Transaction (Process ID XX)
    was deadlocked on lock resources...
  Session 2 output:
  Deadlock trigger complete.
```

#### Step 5/5: Simulate slow queries (5 queries + 5 warnings)

Runs 5 intentionally expensive queries, then logs 5 `SLOW QUERY WARNING` events:

| # | Pattern | Why It's Slow | Duration |
|---|---|---|---|
| 1 | Cartesian join (`CROSS JOIN` × 3) | No filter, 360K rows | 28.4s |
| 2 | N+1 scalar subquery | Row-by-row execution | 15.7s |
| 3 | Deeply nested subquery | Optimizer can't flatten | 12.1s |
| 4 | Leading wildcard `LIKE '%Tan%'` | Full table scan | 9.3s |
| 5 | `STRING_AGG` across 5 tables | TempDB spill | 22.8s |

```
Expected output:
  Running slow query 1/5: Cartesian join...
  [query results]
  ...
  Logging slow query events...
  Msg 50000, Level 16 — SLOW QUERY WARNING: Query on Customers x Policies...
  Msg 50000, Level 16 — SLOW QUERY WARNING: N+1 scalar subquery...
  Msg 50000, Level 16 — SLOW QUERY WARNING: Deeply nested subquery...
  Msg 50000, Level 16 — SLOW QUERY WARNING: Leading wildcard LIKE...
  Msg 50000, Level 16 — SLOW QUERY WARNING: Heavy aggregation...
```

> **Known issue:** Slow query 5/5 (`STRING_AGG(DISTINCT ...)`) may throw `Msg 102 — Incorrect syntax near ','` on older SQL Express versions that don't support `STRING_AGG(DISTINCT ...)`. The RAISERROR warning event is still logged regardless.

---

## Event Summary

| Phase | Simulation | Count | EventID | Level |
|---|---|---|---|---|
| 1 | Non-existent database | 3 | 911 | Error |
| 1 | Non-existent table | 2 | 208 | Error |
| 1 | RAISERROR (business errors) | 8 | 17063 | Error |
| 1 | Failed logins | 5 | 18456 | Error |
| 1 | Backup failure | 1 | 3041 | Error |
| 2 | Deadlock (RAISERROR) | 3 | 17063 | Error |
| 2 | Deadlock (actual) | 1 | 17063 | Error |
| 2 | Slow query warnings | 5 | 17063 | Error |
| | **Total** | **28** | | |

---

## Verify Events in Log Analytics

Wait **5–10 minutes** after running the simulation, then verify:

```bash
# Get workspace ID
LAW_WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group rg-contoso-sqlobs \
  --workspace-name law-contoso-sqlobs \
  --query customerId -o tsv)

# 1. Error event summary
az monitor log-analytics query \
  --workspace "$LAW_WORKSPACE_ID" \
  --analytics-query "Event | where TimeGenerated > ago(30m) | where EventLevelName == 'Error' | summarize Count=count() by Source, EventID | order by Count desc" \
  --timespan PT1H -o table

# 2. Deadlock events
az monitor log-analytics query \
  --workspace "$LAW_WORKSPACE_ID" \
  --analytics-query "Event | where TimeGenerated > ago(30m) | where RenderedDescription contains 'DEADLOCK' | project TimeGenerated, Source, RenderedDescription | order by TimeGenerated desc" \
  --timespan PT1H -o table

# 3. Slow query events (ranked by duration)
az monitor log-analytics query \
  --workspace "$LAW_WORKSPACE_ID" \
  --analytics-query "Event | where TimeGenerated > ago(30m) | where RenderedDescription contains 'SLOW QUERY WARNING' | parse RenderedDescription with * 'took ' Duration:double ' seconds' * | project TimeGenerated, Duration, RenderedDescription | order by Duration desc | take 5" \
  --timespan PT1H -o table

# 4. All errors with details
az monitor log-analytics query \
  --workspace "$LAW_WORKSPACE_ID" \
  --analytics-query "Event | where TimeGenerated > ago(30m) | where EventLevelName == 'Error' | project TimeGenerated, Source, EventID, RenderedDescription | order by TimeGenerated desc" \
  --timespan PT1H -o table
```

---

## Test in Streamlit AI App

Once events are visible in Log Analytics, open the Streamlit app and ask:

| # | Question | Expected Insight |
|---|---|---|
| 1 | What errors occurred in the last 30 minutes? | Summary of all ~28 error events |
| 2 | Are there any database not found errors? | NonExistentDB, ClaimsDB, ReportingDB |
| 3 | Show me all failed login attempts | 5 attempts with usernames |
| 4 | Were there any deadlock or timeout errors? | Deadlock on PolicyHolders, ClaimsDB timeout |
| 5 | Did any backup jobs fail? | InsuranceDB backup to Z:\ path failed |
| 6 | Is there any sign of unauthorized access? | Failed logins from hacker, root, admin |
| 7 | What is the most critical issue right now? | AI prioritises across all error types |
| 8 | Are there any disk space issues? | Auto-growth failure on drive E: |
| 9 | Summarise all SQL Server problems from today | Full timeline of all events |
| 10 | Are there any deadlocks in SQL Server? | 4 deadlock events with tables and durations |
| 11 | List the top 5 slowest queries | 5 queries ranked by duration |
| 12 | Which tables are involved in deadlocks? | Policies, Claims, Customers, Transactions |
| 13 | What query optimisation do you recommend? | Full-text index, JOIN rewrite, materialised views |

---

## Troubleshooting

| Problem | Solution |
|---|---|
| `Not logged in` | Run `az login` |
| `VM state: VM deallocated` | Run `az vm start -g rg-contoso-sqlobs -n vm-sql-sea-01` |
| Events not appearing after 10 min | Check AMA agent is running on VM and DCR is collecting Application Event Log |
| `STRING_AGG` syntax error | Known SQL Express limitation — the RAISERROR event is still logged |
| Verification shows 0 events | Log Analytics ingestion can take up to 15 min; retry later |
| `az vm run-command` timeout | The VM command has a default 90-second timeout; long-running queries may time out but still execute on the VM |

---

## Scripts Reference

| Script | Purpose | Events |
|---|---|---|
| [`scripts/simulate-errors.sh`](scripts/simulate-errors.sh) | SQL error events (DB, table, login, backup) | 19 |
| [`scripts/simulate-deadlock-slowquery.sh`](scripts/simulate-deadlock-slowquery.sh) | Deadlock + slow query simulation | 9 |
| [`scripts/run-all-simulations.sh`](scripts/run-all-simulations.sh) | Master runner (Phase 1 + 2 + 3 verification) | 28 |
| [`scripts/simulate-deadlock-slowquery.sql`](scripts/simulate-deadlock-slowquery.sql) | SQL file for direct execution on VM | — |
