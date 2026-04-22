-- ============================================================
-- Income Insurance SG - Query Simulation Script
-- Runs various realistic queries to generate SQL Server logs
-- Run with: sqlcmd -S .\SQLEXPRESS -U sa -P "Contoso!Sql2024" -d InsuranceDB -i simulate-queries.sql
-- ============================================================

USE InsuranceDB;
GO

PRINT '============================================';
PRINT 'Starting query simulation: ' + CONVERT(VARCHAR, GETDATE(), 120);
PRINT '============================================';

-- ============================================================
-- Simulation 1: Customer Service - lookup customer & policies
-- ============================================================
PRINT '>> SIM 1: Customer lookup with active policies';

SELECT TOP 20 
    c.customer_id, c.full_name, c.email, c.phone,
    p.policy_number, p.status, p.annual_premium,
    pkg.package_name, pkg.category
FROM Customers c
JOIN Policies p ON c.customer_id = p.customer_id
JOIN InsurancePackages pkg ON p.package_id = pkg.package_id
WHERE p.status = 'Active'
ORDER BY c.full_name;
GO

-- ============================================================
-- Simulation 2: Dashboard - KPI summary per category
-- ============================================================
PRINT '>> SIM 2: Monthly KPI dashboard per category';

SELECT 
    pkg.category,
    COUNT(DISTINCT p.policy_id) AS total_policies,
    COUNT(DISTINCT p.customer_id) AS unique_customers,
    SUM(p.annual_premium) AS total_annual_premium,
    AVG(p.sum_insured) AS avg_sum_insured,
    COUNT(CASE WHEN p.status = 'Active' THEN 1 END) AS active_count,
    COUNT(CASE WHEN p.status = 'Lapsed' THEN 1 END) AS lapsed_count
FROM Policies p
JOIN InsurancePackages pkg ON p.package_id = pkg.package_id
GROUP BY pkg.category
ORDER BY total_annual_premium DESC;
GO

-- ============================================================
-- Simulation 3: Claims processing queue
-- ============================================================
PRINT '>> SIM 3: Pending claims queue with policy details';

SELECT TOP 30
    cl.claim_number, cl.claim_date, cl.claim_amount,
    cl.category AS claim_category, cl.status AS claim_status,
    p.policy_number, c.full_name AS customer_name,
    pkg.package_name,
    DATEDIFF(DAY, cl.claim_date, GETDATE()) AS days_pending
FROM Claims cl
JOIN Policies p ON cl.policy_id = p.policy_id
JOIN Customers c ON p.customer_id = c.customer_id
JOIN InsurancePackages pkg ON p.package_id = pkg.package_id
WHERE cl.status IN ('Submitted','UnderReview')
ORDER BY cl.claim_date ASC;
GO

-- ============================================================
-- Simulation 4: Financial report - monthly revenue
-- ============================================================
PRINT '>> SIM 4: Monthly premium revenue report';

SELECT 
    FORMAT(t.transaction_date, 'yyyy-MM') AS month,
    t.transaction_type,
    COUNT(*) AS txn_count,
    SUM(t.amount) AS total_amount,
    AVG(t.amount) AS avg_amount,
    MIN(t.amount) AS min_amount,
    MAX(t.amount) AS max_amount
FROM Transactions t
WHERE t.status = 'Completed'
  AND t.transaction_date >= DATEADD(YEAR, -1, GETDATE())
GROUP BY FORMAT(t.transaction_date, 'yyyy-MM'), t.transaction_type
ORDER BY month DESC, transaction_type;
GO

-- ============================================================
-- Simulation 5: Agent performance report
-- ============================================================
PRINT '>> SIM 5: Agent performance - policies sold & premium';

SELECT TOP 20
    a.agent_code, a.full_name AS agent_name, a.branch,
    COUNT(p.policy_id) AS policies_sold,
    SUM(p.annual_premium) AS total_premium_generated,
    COUNT(CASE WHEN p.status = 'Active' THEN 1 END) AS active_policies,
    COUNT(CASE WHEN p.status = 'Cancelled' THEN 1 END) AS cancelled_policies,
    CAST(COUNT(CASE WHEN p.status = 'Active' THEN 1 END) * 100.0 / NULLIF(COUNT(p.policy_id),0) AS DECIMAL(5,1)) AS retention_pct
FROM Agents a
LEFT JOIN Policies p ON a.agent_id = p.agent_id
WHERE a.is_active = 1
GROUP BY a.agent_code, a.full_name, a.branch
ORDER BY total_premium_generated DESC;
GO

-- ============================================================
-- Simulation 6: High-value claims analysis
-- ============================================================
PRINT '>> SIM 6: High-value claims (>$10K) with approval rate';

SELECT 
    pkg.category,
    cl.category AS claim_type,
    COUNT(*) AS total_claims,
    SUM(cl.claim_amount) AS total_claimed,
    SUM(ISNULL(cl.approved_amount, 0)) AS total_approved,
    CAST(COUNT(CASE WHEN cl.status = 'Approved' OR cl.status = 'Paid' THEN 1 END) * 100.0 
         / NULLIF(COUNT(*), 0) AS DECIMAL(5,1)) AS approval_rate
FROM Claims cl
JOIN Policies p ON cl.policy_id = p.policy_id
JOIN InsurancePackages pkg ON p.package_id = pkg.package_id
WHERE cl.claim_amount > 10000
GROUP BY pkg.category, cl.category
ORDER BY total_claimed DESC;
GO

-- ============================================================
-- Simulation 7: Customer risk profiling
-- ============================================================
PRINT '>> SIM 7: Customer risk profile - claims frequency';

SELECT TOP 25
    c.customer_id, c.full_name,
    COUNT(DISTINCT p.policy_id) AS num_policies,
    COUNT(cl.claim_id) AS num_claims,
    SUM(cl.claim_amount) AS total_claimed,
    SUM(p.annual_premium) AS total_premium_paid,
    CASE 
        WHEN SUM(cl.claim_amount) > SUM(p.annual_premium) * 2 THEN 'High Risk'
        WHEN SUM(cl.claim_amount) > SUM(p.annual_premium) THEN 'Medium Risk'
        ELSE 'Low Risk'
    END AS risk_tier
FROM Customers c
JOIN Policies p ON c.customer_id = p.customer_id
LEFT JOIN Claims cl ON p.policy_id = cl.policy_id
GROUP BY c.customer_id, c.full_name
HAVING COUNT(cl.claim_id) > 0
ORDER BY total_claimed DESC;
GO

-- ============================================================
-- Simulation 8: Policy expiry / renewal pipeline
-- ============================================================
PRINT '>> SIM 8: Policies expiring in next 90 days';

SELECT 
    p.policy_number, p.end_date,
    DATEDIFF(DAY, GETDATE(), p.end_date) AS days_to_expiry,
    c.full_name, c.phone, c.email,
    pkg.package_name, pkg.category,
    p.annual_premium, a.full_name AS agent_name
FROM Policies p
JOIN Customers c ON p.customer_id = c.customer_id
JOIN InsurancePackages pkg ON p.package_id = pkg.package_id
JOIN Agents a ON p.agent_id = a.agent_id
WHERE p.status = 'Active'
  AND p.end_date BETWEEN GETDATE() AND DATEADD(DAY, 90, GETDATE())
ORDER BY p.end_date ASC;
GO

-- ============================================================
-- Simulation 9: Payment failure follow-up
-- ============================================================
PRINT '>> SIM 9: Failed transactions needing follow-up';

SELECT 
    t.transaction_ref, t.transaction_date, t.amount,
    t.payment_method, t.remarks,
    p.policy_number, c.full_name, c.phone,
    a.full_name AS agent_name
FROM Transactions t
JOIN Policies p ON t.policy_id = p.policy_id
JOIN Customers c ON p.customer_id = c.customer_id
JOIN Agents a ON p.agent_id = a.agent_id
WHERE t.status = 'Failed'
ORDER BY t.transaction_date DESC;
GO

-- ============================================================
-- Simulation 10: Branch-level summary
-- ============================================================
PRINT '>> SIM 10: Branch performance summary';

SELECT 
    a.branch,
    COUNT(DISTINCT a.agent_id) AS num_agents,
    COUNT(DISTINCT p.policy_id) AS total_policies,
    COUNT(DISTINCT p.customer_id) AS total_customers,
    SUM(p.annual_premium) AS total_premium,
    COUNT(DISTINCT cl.claim_id) AS total_claims,
    SUM(cl.claim_amount) AS total_claim_amount
FROM Agents a
LEFT JOIN Policies p ON a.agent_id = p.agent_id
LEFT JOIN Claims cl ON p.policy_id = cl.policy_id
GROUP BY a.branch
ORDER BY total_premium DESC;
GO

-- ============================================================
-- Simulation 11: Cross-sell opportunities (customers with 1 policy)
-- ============================================================
PRINT '>> SIM 11: Cross-sell targets (single-policy customers)';

SELECT TOP 30
    c.customer_id, c.full_name, c.email,
    pkg.category AS current_category,
    pkg.package_name AS current_package,
    p.annual_premium
FROM Customers c
JOIN Policies p ON c.customer_id = p.customer_id
JOIN InsurancePackages pkg ON p.package_id = pkg.package_id
WHERE p.status = 'Active'
  AND c.customer_id IN (
      SELECT customer_id FROM Policies WHERE status = 'Active'
      GROUP BY customer_id HAVING COUNT(*) = 1
  )
ORDER BY p.annual_premium DESC;
GO

-- ============================================================
-- Simulation 12: Claim processing time analysis
-- ============================================================
PRINT '>> SIM 12: Average claim processing time by category';

SELECT 
    cl.category,
    cl.status,
    COUNT(*) AS claim_count,
    AVG(DATEDIFF(DAY, cl.claim_date, cl.processed_date)) AS avg_processing_days,
    MIN(DATEDIFF(DAY, cl.claim_date, cl.processed_date)) AS min_days,
    MAX(DATEDIFF(DAY, cl.claim_date, cl.processed_date)) AS max_days
FROM Claims cl
WHERE cl.processed_date IS NOT NULL
GROUP BY cl.category, cl.status
ORDER BY cl.category, avg_processing_days DESC;
GO

-- ============================================================
-- Simulation 13: DML - insert new policy application
-- ============================================================
PRINT '>> SIM 13: INSERT - new policy application';

INSERT INTO Policies (policy_number, customer_id, package_id, agent_id, start_date, end_date, status, sum_insured, annual_premium, payment_freq)
VALUES ('POL-202604-SIM1', 1, 5, 3, '2026-04-16', '2027-04-16', 'Pending', 150000.00, 1800.00, 'Monthly');

PRINT '   Inserted new pending policy POL-202604-SIM1';
GO

-- ============================================================
-- Simulation 14: DML - approve a claim
-- ============================================================
PRINT '>> SIM 14: UPDATE - approve pending claims batch';

UPDATE TOP (5) Claims 
SET status = 'Approved', 
    approved_amount = claim_amount * 0.85,
    processed_date = GETDATE(),
    assessor_notes = 'Batch approved via simulation'
WHERE status = 'Submitted';

PRINT '   Approved batch of claims';
GO

-- ============================================================
-- Simulation 15: DML - record premium payments
-- ============================================================
PRINT '>> SIM 15: INSERT - batch premium payments';

INSERT INTO Transactions (transaction_ref, policy_id, transaction_date, amount, transaction_type, payment_method, status, remarks)
SELECT TOP 10
    'TXN' + FORMAT(GETDATE(), 'yyyyMMdd') + 'SIM' + RIGHT('000' + CAST(ROW_NUMBER() OVER (ORDER BY policy_id) AS VARCHAR), 3),
    policy_id,
    GETDATE(),
    annual_premium / 12,
    'PremiumPayment',
    'GIRO',
    'Completed',
    'Simulated monthly GIRO deduction'
FROM Policies
WHERE status = 'Active'
ORDER BY NEWID();

PRINT '   Recorded 10 premium payment transactions';
GO

-- ============================================================
-- Simulation 16: Complex subquery - policy utilisation ratio
-- ============================================================
PRINT '>> SIM 16: Policy utilisation ratio analysis';

SELECT TOP 20
    p.policy_number,
    c.full_name,
    pkg.package_name,
    p.sum_insured,
    ISNULL(claim_summary.total_claimed, 0) AS total_claimed,
    CAST(ISNULL(claim_summary.total_claimed, 0) * 100.0 / p.sum_insured AS DECIMAL(5,1)) AS utilisation_pct,
    p.status
FROM Policies p
JOIN Customers c ON p.customer_id = c.customer_id
JOIN InsurancePackages pkg ON p.package_id = pkg.package_id
OUTER APPLY (
    SELECT SUM(cl.claim_amount) AS total_claimed
    FROM Claims cl WHERE cl.policy_id = p.policy_id
) claim_summary
WHERE p.sum_insured > 0
ORDER BY utilisation_pct DESC;
GO

-- ============================================================
-- Simulation 17: Beneficiary audit
-- ============================================================
PRINT '>> SIM 17: Policies with multiple beneficiaries check';

SELECT 
    p.policy_number,
    c.full_name AS policyholder,
    COUNT(b.beneficiary_id) AS num_beneficiaries,
    SUM(b.percentage) AS total_pct,
    CASE WHEN SUM(b.percentage) <> 100 THEN 'NEEDS REVIEW' ELSE 'OK' END AS allocation_status
FROM Policies p
JOIN Customers c ON p.customer_id = c.customer_id
LEFT JOIN Beneficiaries b ON p.policy_id = b.policy_id
WHERE p.status = 'Active'
GROUP BY p.policy_number, c.full_name
HAVING COUNT(b.beneficiary_id) > 1
ORDER BY total_pct DESC;
GO

-- ============================================================
-- Simulation 18: Window function - running totals
-- ============================================================
PRINT '>> SIM 18: Daily transaction running total (last 30 days)';

SELECT 
    CAST(t.transaction_date AS DATE) AS txn_date,
    t.transaction_type,
    COUNT(*) AS daily_count,
    SUM(t.amount) AS daily_amount,
    SUM(SUM(t.amount)) OVER (PARTITION BY t.transaction_type ORDER BY CAST(t.transaction_date AS DATE)) AS running_total
FROM Transactions t
WHERE t.transaction_date >= DATEADD(DAY, -30, GETDATE())
  AND t.status = 'Completed'
GROUP BY CAST(t.transaction_date AS DATE), t.transaction_type
ORDER BY txn_date DESC, transaction_type;
GO

-- ============================================================
-- Simulation 19: Temp table + multi-step report
-- ============================================================
PRINT '>> SIM 19: Multi-step report with temp table';

CREATE TABLE #MonthlySnapshot (
    report_month VARCHAR(7),
    new_policies INT,
    cancelled_policies INT,
    new_claims INT,
    premium_collected DECIMAL(15,2),
    claims_paid DECIMAL(15,2)
);

INSERT INTO #MonthlySnapshot
SELECT 
    FORMAT(p.start_date, 'yyyy-MM'),
    COUNT(*),
    0, 0, 0, 0
FROM Policies p
WHERE p.start_date >= DATEADD(YEAR, -1, GETDATE())
GROUP BY FORMAT(p.start_date, 'yyyy-MM');

UPDATE ms SET ms.premium_collected = t.total_amt
FROM #MonthlySnapshot ms
JOIN (
    SELECT FORMAT(transaction_date, 'yyyy-MM') AS m, SUM(amount) AS total_amt
    FROM Transactions WHERE transaction_type = 'PremiumPayment' AND status = 'Completed'
    GROUP BY FORMAT(transaction_date, 'yyyy-MM')
) t ON ms.report_month = t.m;

UPDATE ms SET ms.claims_paid = c.total_amt
FROM #MonthlySnapshot ms
JOIN (
    SELECT FORMAT(transaction_date, 'yyyy-MM') AS m, SUM(amount) AS total_amt
    FROM Transactions WHERE transaction_type = 'ClaimPayout' AND status = 'Completed'
    GROUP BY FORMAT(transaction_date, 'yyyy-MM')
) c ON ms.report_month = c.m;

SELECT * FROM #MonthlySnapshot ORDER BY report_month DESC;
DROP TABLE #MonthlySnapshot;
GO

-- ============================================================
-- Simulation 20: Full-text style search (LIKE patterns)
-- ============================================================
PRINT '>> SIM 20: Search claims by description keywords';

SELECT TOP 15
    cl.claim_number, cl.description, cl.claim_amount, cl.status,
    c.full_name, pkg.package_name
FROM Claims cl
JOIN Policies p ON cl.policy_id = p.policy_id
JOIN Customers c ON p.customer_id = c.customer_id
JOIN InsurancePackages pkg ON p.package_id = pkg.package_id
WHERE cl.description LIKE '%hospital%'
   OR cl.description LIKE '%vehicle%'
   OR cl.description LIKE '%damage%'
ORDER BY cl.claim_amount DESC;
GO

-- ============================================================
PRINT '============================================';
PRINT 'Query simulation completed: ' + CONVERT(VARCHAR, GETDATE(), 120);
PRINT '20 simulations executed successfully.';
PRINT '============================================';
GO
