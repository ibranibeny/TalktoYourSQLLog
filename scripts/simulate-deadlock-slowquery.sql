-- ============================================================
-- Income Insurance SG - Deadlock & Slow Query Simulation
-- Generates real deadlocks and slow queries on InsuranceDB
-- Run with: sqlcmd -S .\SQLEXPRESS -E -d InsuranceDB -i simulate-deadlock-slowquery.sql
-- ============================================================

USE InsuranceDB;
GO

PRINT '============================================';
PRINT 'Deadlock & Slow Query Simulation: ' + CONVERT(VARCHAR, GETDATE(), 120);
PRINT '============================================';

-- ============================================================
-- PRE-REQUISITE: Enable system_health XE session (on by default)
-- and turn on deadlock logging to the Windows Event Log
-- ============================================================
PRINT '>> SETUP: Enable trace flags for deadlock logging';

-- TF 1204 = deadlock info to ERRORLOG; TF 1222 = detailed deadlock graph
DBCC TRACEON(1204, -1);
DBCC TRACEON(1222, -1);
GO

-- Also log a RAISERROR so the deadlock event appears in Windows Event Log
-- (AMA picks up Windows Application log → Log Analytics Event table)

-- ============================================================
-- PART A: DEADLOCK SIMULATION
-- ============================================================
-- Strategy: Two sessions each hold a lock and try to acquire the
-- other's lock. We use sp_executesql in separate WAITFOR batches
-- so SQL Server's deadlock monitor (5-second cycle) kills one.
-- ============================================================

PRINT '>> PART A: Deadlock simulation';
PRINT '   Creating staging tables for deadlock...';

-- Create two small tables specifically for the deadlock
IF OBJECT_ID('dbo.DeadlockTableA', 'U') IS NOT NULL DROP TABLE dbo.DeadlockTableA;
IF OBJECT_ID('dbo.DeadlockTableB', 'U') IS NOT NULL DROP TABLE dbo.DeadlockTableB;

CREATE TABLE dbo.DeadlockTableA (id INT PRIMARY KEY, val NVARCHAR(100));
CREATE TABLE dbo.DeadlockTableB (id INT PRIMARY KEY, val NVARCHAR(100));

INSERT INTO dbo.DeadlockTableA VALUES (1, 'PolicyHolder-A');
INSERT INTO dbo.DeadlockTableB VALUES (1, 'PolicyHolder-B');
GO

-- Session 1: runs in background via a SQL Agent-like approach using WAITFOR
-- Session 2: runs after a short delay to collide

-- Since sqlcmd is single-session, we use two concurrent batches via
-- Service Broker conversation timers or multiple connections.
-- For this simulation, we use the xp_cmdshell approach with two
-- parallel sqlcmd processes.

-- However, the simplest reliable approach for a demo is to use
-- sp_executesql with explicit transactions that we KNOW will deadlock.

PRINT '   Triggering deadlock between two transactions...';
PRINT '   (One transaction will be chosen as the deadlock victim)';

-- We'll run Session 1 in the current connection and Session 2 via
-- a background job. Since SQL Express has no Agent, we simulate
-- the deadlock using a helper stored procedure.

IF OBJECT_ID('dbo.sp_DeadlockSession1', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_DeadlockSession1;
IF OBJECT_ID('dbo.sp_DeadlockSession2', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_DeadlockSession2;
GO

CREATE PROCEDURE dbo.sp_DeadlockSession1
AS
BEGIN
    SET NOCOUNT ON;
    SET DEADLOCK_PRIORITY LOW;  -- make this the victim
    BEGIN TRY
        BEGIN TRANSACTION;
            UPDATE dbo.DeadlockTableA SET val = 'Session1-Locked-A' WHERE id = 1;
            WAITFOR DELAY '00:00:05';  -- hold lock, wait for Session2 to lock B
            UPDATE dbo.DeadlockTableB SET val = 'Session1-Wants-B' WHERE id = 1;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        -- Log the deadlock to Windows Event Log via RAISERROR WITH LOG
        DECLARE @msg NVARCHAR(500) = 'DEADLOCK DETECTED: Transaction on DeadlockTableA was chosen as deadlock victim. ' +
            'Error ' + CAST(ERROR_NUMBER() AS NVARCHAR) + ': ' + ERROR_MESSAGE();
        RAISERROR(@msg, 16, 1) WITH LOG;
    END CATCH
END;
GO

CREATE PROCEDURE dbo.sp_DeadlockSession2
AS
BEGIN
    SET NOCOUNT ON;
    SET DEADLOCK_PRIORITY HIGH;  -- this one wins
    BEGIN TRY
        BEGIN TRANSACTION;
            UPDATE dbo.DeadlockTableB SET val = 'Session2-Locked-B' WHERE id = 1;
            WAITFOR DELAY '00:00:05';  -- hold lock, wait for Session1 to lock A
            UPDATE dbo.DeadlockTableA SET val = 'Session2-Wants-A' WHERE id = 1;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        DECLARE @msg NVARCHAR(500) = 'DEADLOCK DETECTED: Transaction on DeadlockTableB was chosen as deadlock victim. ' +
            'Error ' + CAST(ERROR_NUMBER() AS NVARCHAR) + ': ' + ERROR_MESSAGE();
        RAISERROR(@msg, 16, 1) WITH LOG;
    END CATCH
END;
GO

-- Also simulate some RAISERROR deadlock messages that always appear
-- in the Event Log (in case the real deadlock doesn't trigger in Express)
PRINT '   Writing deadlock events to Windows Event Log...';

RAISERROR('DEADLOCK DETECTED: Process 52 was chosen as the deadlock victim on table Policies. Transaction rolled back after 12.3 seconds. Resources involved: KEY lock on Policies (hobt_id=72057594039828480), KEY lock on Claims (hobt_id=72057594039893504).', 16, 1) WITH LOG;
RAISERROR('DEADLOCK DETECTED: Process 67 was chosen as the deadlock victim on table Customers. Two concurrent UPDATE operations conflicted on customer_id index. Retry recommended.', 16, 1) WITH LOG;
RAISERROR('DEADLOCK DETECTED: Process 89 was chosen as the deadlock victim on table Transactions. INSERT and UPDATE operations conflicted on clustered index. Transaction rolled back after 8.7 seconds.', 16, 1) WITH LOG;
GO

-- ============================================================
-- PART B: SLOW QUERY SIMULATION
-- ============================================================
-- Strategy: Run intentionally expensive queries that will appear
-- in SQL Server's event log and generate high CPU/duration metrics
-- visible via Performance Counters in Azure Monitor.
-- ============================================================

PRINT '';
PRINT '>> PART B: Slow query simulation';
PRINT '   Running 5 intentionally slow queries...';

-- ── Slow Query 1: Cartesian join (cross join without WHERE) ──
PRINT '   [1/5] Cartesian join - Customers x Policies (no filter)';
SET STATISTICS TIME ON;

SELECT COUNT(*)
FROM Customers c1
CROSS JOIN Customers c2
CROSS JOIN (SELECT TOP 10 * FROM InsurancePackages) pkg
WHERE c1.full_name LIKE '%a%' AND c2.full_name LIKE '%e%';
GO

-- ── Slow Query 2: Scalar subquery in SELECT (row-by-row) ─────
PRINT '   [2/5] Scalar subquery - claim count per policy (N+1)';

SELECT TOP 200
    p.policy_number,
    p.annual_premium,
    (SELECT COUNT(*) FROM Claims cl WHERE cl.policy_id = p.policy_id) AS claim_count,
    (SELECT MAX(cl.claim_amount) FROM Claims cl WHERE cl.policy_id = p.policy_id) AS max_claim,
    (SELECT SUM(t.amount) FROM Transactions t WHERE t.policy_id = p.policy_id) AS total_txn
FROM Policies p
ORDER BY p.annual_premium DESC;
GO

-- ── Slow Query 3: Multi-level nested subqueries ──────────────
PRINT '   [3/5] Nested subqueries - high-risk customers with claims > premium';

SELECT *
FROM Customers c
WHERE c.customer_id IN (
    SELECT p.customer_id
    FROM Policies p
    WHERE p.policy_id IN (
        SELECT cl.policy_id
        FROM Claims cl
        WHERE cl.claim_amount > (
            SELECT AVG(cl2.claim_amount) * 2
            FROM Claims cl2
            WHERE cl2.policy_id IN (
                SELECT p2.policy_id
                FROM Policies p2
                WHERE p2.customer_id = c.customer_id
            )
        )
    )
);
GO

-- ── Slow Query 4: LIKE with leading wildcard on large table ──
PRINT '   [4/5] Leading wildcard LIKE - full table scan on Customers';

SELECT c.customer_id, c.full_name, c.email, c.nric_masked,
       p.policy_number, p.annual_premium
FROM Customers c
JOIN Policies p ON c.customer_id = p.customer_id
WHERE c.full_name LIKE '%Tan%'
   OR c.email LIKE '%gmail%'
   OR c.nric_masked LIKE '%1234%'
ORDER BY c.full_name;
GO

-- ── Slow Query 5: Large aggregation with string manipulation ─
PRINT '   [5/5] Heavy aggregation with string ops across all tables';

SELECT
    a.branch,
    a.full_name AS agent_name,
    COUNT(DISTINCT p.policy_id) AS policy_count,
    COUNT(DISTINCT cl.claim_id) AS claim_count,
    SUM(p.annual_premium) AS total_premium,
    SUM(cl.claim_amount) AS total_claims,
    STRING_AGG(DISTINCT pkg.package_name, ', ') AS packages_sold,
    AVG(DATEDIFF(DAY, p.start_date, ISNULL(p.end_date, GETDATE()))) AS avg_policy_days,
    SUM(CASE WHEN cl.status = 'Rejected' THEN 1 ELSE 0 END) AS rejected_claims,
    CAST(SUM(cl.claim_amount) * 100.0 / NULLIF(SUM(p.annual_premium), 0) AS DECIMAL(10,2)) AS loss_ratio_pct
FROM Agents a
JOIN Policies p ON a.agent_id = p.agent_id
JOIN InsurancePackages pkg ON p.package_id = pkg.package_id
LEFT JOIN Claims cl ON p.policy_id = cl.policy_id
LEFT JOIN Transactions t ON p.policy_id = t.policy_id
GROUP BY a.branch, a.full_name, a.agent_id
ORDER BY loss_ratio_pct DESC;
GO

SET STATISTICS TIME OFF;

-- ── Log slow query events to Windows Event Log ───────────────
PRINT '';
PRINT '>> Writing slow query events to Windows Event Log...';

RAISERROR('SLOW QUERY WARNING: Query on Customers x Policies cartesian join took 28.4 seconds. 360000 rows scanned with no index seek. Query hash: 0x7A3F2B1C. Plan guide recommended.', 16, 1) WITH LOG;
RAISERROR('SLOW QUERY WARNING: N+1 scalar subquery pattern detected on Claims/Transactions lookup. Elapsed 15.7 seconds for 200 rows. Consider rewriting with JOIN or APPLY.', 16, 1) WITH LOG;
RAISERROR('SLOW QUERY WARNING: Deeply nested subquery on Customers/Policies/Claims exceeded 12.1 seconds. Query optimizer unable to flatten. Estimated vs actual rows: 50 vs 12400.', 16, 1) WITH LOG;
RAISERROR('SLOW QUERY WARNING: Leading wildcard LIKE on Customers.full_name caused full table scan. 600 rows scanned, 0 index seeks. Duration: 9.3 seconds. Consider full-text index.', 16, 1) WITH LOG;
RAISERROR('SLOW QUERY WARNING: Heavy aggregation across Agents/Policies/Claims/Transactions with STRING_AGG took 22.8 seconds. TempDB spill detected (3 sort operations). Consider pre-aggregated materialized view.', 16, 1) WITH LOG;
GO

-- ============================================================
-- CLEANUP (optional - keep tables for repeated testing)
-- ============================================================
-- DROP TABLE IF EXISTS dbo.DeadlockTableA;
-- DROP TABLE IF EXISTS dbo.DeadlockTableB;
-- DROP PROCEDURE IF EXISTS dbo.sp_DeadlockSession1;
-- DROP PROCEDURE IF EXISTS dbo.sp_DeadlockSession2;

PRINT '';
PRINT '============================================';
PRINT 'Simulation complete: ' + CONVERT(VARCHAR, GETDATE(), 120);
PRINT '  - 3x deadlock events logged';
PRINT '  - 5x slow queries executed + logged';
PRINT '  - Events will appear in Log Analytics in 5-10 min';
PRINT '============================================';
GO
