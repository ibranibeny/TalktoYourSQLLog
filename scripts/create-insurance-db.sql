-- ============================================================
-- Income Insurance SG - Demo Database
-- Creates InsuranceDB with 500+ rows per table
-- ============================================================

USE master;
GO

IF DB_ID('InsuranceDB') IS NOT NULL
BEGIN
    ALTER DATABASE InsuranceDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE InsuranceDB;
END
GO

CREATE DATABASE InsuranceDB;
GO

USE InsuranceDB;
GO

-- ============================================================
-- 1. Agents (50 rows)
-- ============================================================
CREATE TABLE Agents (
    agent_id        INT IDENTITY(1,1) PRIMARY KEY,
    agent_code      VARCHAR(10)   NOT NULL,
    full_name       NVARCHAR(100) NOT NULL,
    email           VARCHAR(120)  NOT NULL,
    phone           VARCHAR(20),
    branch          NVARCHAR(50)  NOT NULL,
    hire_date       DATE          NOT NULL,
    is_active       BIT           DEFAULT 1
);
GO

;WITH Nums AS (
    SELECT TOP 50 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects
)
INSERT INTO Agents (agent_code, full_name, email, phone, branch, hire_date, is_active)
SELECT
    'AGT' + RIGHT('000' + CAST(n AS VARCHAR), 3),
    CHOOSE((n % 10) + 1,
        'Ahmad Tan','Siti Lim','Budi Ng','Dewi Wong','Rizal Koh',
        'Nurul Chen','Fajar Teo','Maya Goh','Andi Lee','Putri Ong') 
        + ' ' + CAST(n AS VARCHAR),
    'agent' + CAST(n AS VARCHAR) + '@incomeins.sg',
    '+65 9' + RIGHT('000' + CAST(ABS(CHECKSUM(NEWID())) % 10000 AS VARCHAR), 4) 
             + RIGHT('000' + CAST(ABS(CHECKSUM(NEWID())) % 10000 AS VARCHAR), 4),
    CHOOSE((n % 5) + 1, 'Orchard','Jurong','Tampines','Woodlands','Marina Bay'),
    DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 3650), '2026-01-01'),
    CASE WHEN n % 8 = 0 THEN 0 ELSE 1 END
FROM Nums;
GO

-- ============================================================
-- 2. Insurance Packages (20 rows)
-- ============================================================
CREATE TABLE InsurancePackages (
    package_id      INT IDENTITY(1,1) PRIMARY KEY,
    package_code    VARCHAR(10)    NOT NULL,
    package_name    NVARCHAR(100)  NOT NULL,
    category        VARCHAR(20)    NOT NULL,  -- Life, Health, Auto, Property, Travel
    premium_monthly DECIMAL(10,2)  NOT NULL,
    coverage_amount DECIMAL(15,2)  NOT NULL,
    min_age         INT DEFAULT 18,
    max_age         INT DEFAULT 65,
    description     NVARCHAR(500)
);
GO

INSERT INTO InsurancePackages (package_code, package_name, category, premium_monthly, coverage_amount, min_age, max_age, description) VALUES
('LIF-BAS','Life Basic Shield','Life',45.00,100000.00,18,70,'Basic life coverage with death and TPD benefit'),
('LIF-PRE','Life Premium Guard','Life',120.00,500000.00,18,65,'Premium life plan with CI and death benefit'),
('LIF-FAM','Life Family Protect','Life',180.00,750000.00,21,60,'Family life plan covering spouse and children'),
('HLT-ESS','Health Essential','Health',85.00,50000.00,18,75,'Essential hospitalisation and surgery coverage'),
('HLT-PLU','Health Plus','Health',150.00,150000.00,18,70,'Enhanced health plan with outpatient and dental'),
('HLT-MAX','Health MaxCare','Health',280.00,500000.00,18,65,'Comprehensive health with intl hospital network'),
('HLT-SEN','Health Senior Care','Health',200.00,80000.00,55,85,'Tailored health plan for seniors'),
('AUT-TPO','Auto Third Party','Auto',35.00,75000.00,18,80,'Third-party liability coverage'),
('AUT-CMP','Auto Comprehensive','Auto',95.00,200000.00,18,80,'Full comprehensive vehicle coverage'),
('AUT-PRE','Auto Premium Drive','Auto',160.00,350000.00,21,70,'Premium auto with roadside and rental car'),
('PRP-HOM','Property HomeShield','Property',60.00,300000.00,21,80,'Home building and contents insurance'),
('PRP-RNT','Property RentGuard','Property',30.00,50000.00,18,80,'Renters contents and liability coverage'),
('PRP-COM','Property CommercialPro','Property',350.00,1000000.00,21,80,'Commercial property and business interruption'),
('TRV-SGL','Travel SingleTrip','Travel',15.00,30000.00,18,80,'Single trip coverage up to 30 days'),
('TRV-ANN','Travel Annual Multi','Travel',120.00,100000.00,18,70,'Annual multi-trip worldwide coverage'),
('TRV-FAM','Travel Family Pack','Travel',180.00,150000.00,21,70,'Family travel for up to 2 adults + 4 kids'),
('ACC-PER','Accident Personal','Life',25.00,50000.00,18,70,'Personal accident with daily hospital cash'),
('ACC-GRP','Accident Group Plan','Life',18.00,40000.00,18,65,'Group accident plan for SMEs'),
('CRI-SHL','Critical Illness Shield','Health',95.00,200000.00,18,65,'37 critical illness conditions covered'),
('INV-GRW','Investment-Linked Growth','Life',250.00,300000.00,21,60,'ILP with equity and bond fund options');
GO

-- ============================================================
-- 3. Customers (600 rows)
-- ============================================================
CREATE TABLE Customers (
    customer_id     INT IDENTITY(1,1) PRIMARY KEY,
    nric_last4      CHAR(4)        NOT NULL,
    full_name       NVARCHAR(120)  NOT NULL,
    email           VARCHAR(150)   NOT NULL,
    phone           VARCHAR(20),
    date_of_birth   DATE           NOT NULL,
    gender          CHAR(1)        NOT NULL,
    address         NVARCHAR(200),
    postal_code     CHAR(6),
    city            NVARCHAR(50)   DEFAULT 'Singapore',
    registration_date DATE         NOT NULL,
    preferred_agent_id INT         NULL REFERENCES Agents(agent_id)
);
GO

;WITH Nums AS (
    SELECT TOP 600 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO Customers (nric_last4, full_name, email, phone, date_of_birth, gender, address, postal_code, city, registration_date, preferred_agent_id)
SELECT
    RIGHT('0000' + CAST(ABS(CHECKSUM(NEWID())) % 10000 AS VARCHAR), 4),
    CHOOSE((n % 15) + 1,
        'Tan Wei Ming','Lim Mei Hua','Ng Jia Wei','Wong Siew Leng','Koh Boon Huat',
        'Chen Xiu Ying','Teo Chee Keong','Goh Lay Kuan','Lee Kang Sheng','Ong Bee Lian',
        'Chua Shu Ting','Yeo Hock Seng','Ang Mei Fong','Seah Kok Leong','Ho Pei Shan') 
        + ' ' + CAST(n AS VARCHAR),
    'cust' + CAST(n AS VARCHAR) + CHOOSE((n % 4) + 1, '@gmail.com','@yahoo.com.sg','@hotmail.com','@outlook.sg'),
    '+65 8' + RIGHT('000' + CAST(ABS(CHECKSUM(NEWID())) % 10000 AS VARCHAR), 4) 
             + RIGHT('000' + CAST(ABS(CHECKSUM(NEWID())) % 10000 AS VARCHAR), 4),
    DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 20000 + 6570), '2026-04-16'),  -- age 18-73
    CASE WHEN n % 2 = 0 THEN 'F' ELSE 'M' END,
    'Blk ' + CAST((ABS(CHECKSUM(NEWID())) % 800) + 1 AS VARCHAR) 
        + CHOOSE((n % 5) + 1, ' Ang Mo Kio Ave',' Bedok North St',' Clementi Ave',' Toa Payoh Lor',' Yishun Ring Rd') 
        + ' #' + RIGHT('00' + CAST((ABS(CHECKSUM(NEWID())) % 20) + 1 AS VARCHAR), 2) 
        + '-' + RIGHT('000' + CAST((ABS(CHECKSUM(NEWID())) % 300) + 1 AS VARCHAR), 3),
    RIGHT('000000' + CAST(ABS(CHECKSUM(NEWID())) % 900000 + 100000 AS VARCHAR), 6),
    'Singapore',
    DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 1825), '2026-04-16'),
    (ABS(CHECKSUM(NEWID())) % 50) + 1
FROM Nums;
GO

-- ============================================================
-- 4. Policies (700 rows)
-- ============================================================
CREATE TABLE Policies (
    policy_id       INT IDENTITY(1,1) PRIMARY KEY,
    policy_number   VARCHAR(20)    NOT NULL,
    customer_id     INT            NOT NULL REFERENCES Customers(customer_id),
    package_id      INT            NOT NULL REFERENCES InsurancePackages(package_id),
    agent_id        INT            NOT NULL REFERENCES Agents(agent_id),
    start_date      DATE           NOT NULL,
    end_date        DATE           NOT NULL,
    status          VARCHAR(15)    NOT NULL,  -- Active, Expired, Cancelled, Pending, Lapsed
    sum_insured     DECIMAL(15,2)  NOT NULL,
    annual_premium  DECIMAL(10,2)  NOT NULL,
    payment_freq    VARCHAR(10)    DEFAULT 'Monthly',  -- Monthly, Quarterly, Annually
    created_at      DATETIME       DEFAULT GETDATE()
);
GO

;WITH Nums AS (
    SELECT TOP 700 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO Policies (policy_number, customer_id, package_id, agent_id, start_date, end_date, status, sum_insured, annual_premium, payment_freq)
SELECT
    'POL-' + FORMAT(DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 1825), '2026-04-16'), 'yyyyMM') 
           + '-' + RIGHT('0000' + CAST(n AS VARCHAR), 4),
    (ABS(CHECKSUM(NEWID())) % 600) + 1,
    (ABS(CHECKSUM(NEWID())) % 20) + 1,
    (ABS(CHECKSUM(NEWID())) % 50) + 1,
    sd.start_dt,
    DATEADD(YEAR, CHOOSE((n % 3) + 1, 1, 2, 5), sd.start_dt),
    CHOOSE((n % 10) + 1, 'Active','Active','Active','Active','Active','Active','Expired','Cancelled','Pending','Lapsed'),
    pkg.coverage_amount * (0.5 + (ABS(CHECKSUM(NEWID())) % 100) / 100.0),
    pkg.premium_monthly * 12,
    CHOOSE((n % 3) + 1, 'Monthly','Quarterly','Annually')
FROM Nums
CROSS APPLY (SELECT DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 1825), '2026-04-16') AS start_dt) sd
CROSS APPLY (SELECT TOP 1 coverage_amount, premium_monthly FROM InsurancePackages WHERE package_id = (ABS(CHECKSUM(NEWID())) % 20) + 1) pkg;
GO

-- ============================================================
-- 5. Claims (550 rows)
-- ============================================================
CREATE TABLE Claims (
    claim_id        INT IDENTITY(1,1) PRIMARY KEY,
    claim_number    VARCHAR(20)    NOT NULL,
    policy_id       INT            NOT NULL REFERENCES Policies(policy_id),
    claim_date      DATE           NOT NULL,
    incident_date   DATE           NOT NULL,
    claim_amount    DECIMAL(12,2)  NOT NULL,
    approved_amount DECIMAL(12,2)  NULL,
    status          VARCHAR(15)    NOT NULL,  -- Submitted, UnderReview, Approved, Rejected, Paid, Appealed
    category        VARCHAR(30)    NOT NULL,
    description     NVARCHAR(500),
    assessor_notes  NVARCHAR(500)  NULL,
    processed_date  DATE           NULL
);
GO

;WITH Nums AS (
    SELECT TOP 550 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO Claims (claim_number, policy_id, claim_date, incident_date, claim_amount, approved_amount, status, category, description, assessor_notes, processed_date)
SELECT
    'CLM-2' + RIGHT('00' + CAST(21 + (n % 6) AS VARCHAR), 2) 
            + '-' + RIGHT('00000' + CAST(n AS VARCHAR), 5),
    (ABS(CHECKSUM(NEWID())) % 700) + 1,
    claim_dt.dt,
    DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 14), claim_dt.dt),
    CAST((ABS(CHECKSUM(NEWID())) % 45000 + 500) AS DECIMAL(12,2)),
    CASE WHEN n % 5 IN (0,1,2) 
         THEN CAST((ABS(CHECKSUM(NEWID())) % 40000 + 400) AS DECIMAL(12,2)) 
         ELSE NULL END,
    CHOOSE((n % 6) + 1, 'Submitted','UnderReview','Approved','Rejected','Paid','Appealed'),
    CHOOSE((n % 8) + 1, 
        'Hospitalisation','Surgery','Outpatient','Vehicle Damage','Vehicle Theft',
        'Property Damage','Travel Delay','Death Benefit'),
    CHOOSE((n % 6) + 1,
        'Admitted to SGH for appendectomy',
        'Vehicle rear-ended at PIE exit',
        'Water damage from burst pipe in unit above',
        'Flight delayed >6hrs at Changi T3',
        'Outpatient visit for dengue treatment',
        'Theft of vehicle at HDB carpark'),
    CASE WHEN n % 5 IN (0,1,2) 
         THEN CHOOSE((n % 3) + 1, 'Verified with hospital records','Police report confirmed','Documents complete, approved') 
         ELSE NULL END,
    CASE WHEN n % 5 IN (0,1,2) 
         THEN DATEADD(DAY, ABS(CHECKSUM(NEWID())) % 30 + 3, claim_dt.dt)
         ELSE NULL END
FROM Nums
CROSS APPLY (SELECT DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 1095), '2026-04-16') AS dt) claim_dt;
GO

-- ============================================================
-- 6. Transactions (800 rows)
-- ============================================================
CREATE TABLE Transactions (
    transaction_id   INT IDENTITY(1,1) PRIMARY KEY,
    transaction_ref  VARCHAR(25)    NOT NULL,
    policy_id        INT            NOT NULL REFERENCES Policies(policy_id),
    transaction_date DATETIME       NOT NULL,
    amount           DECIMAL(12,2)  NOT NULL,
    transaction_type VARCHAR(20)    NOT NULL,  -- PremiumPayment, ClaimPayout, Refund, Adjustment, Penalty
    payment_method   VARCHAR(20)    NULL,      -- GIRO, CreditCard, PayNow, Cash, BankTransfer
    status           VARCHAR(15)    NOT NULL,  -- Completed, Pending, Failed, Reversed
    reference_id     INT            NULL,      -- FK to claim_id if ClaimPayout
    remarks          NVARCHAR(200)  NULL
);
GO

;WITH Nums AS (
    SELECT TOP 800 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO Transactions (transaction_ref, policy_id, transaction_date, amount, transaction_type, payment_method, status, reference_id, remarks)
SELECT
    'TXN' + FORMAT(txn_dt.dt, 'yyyyMMdd') + RIGHT('00000' + CAST(n AS VARCHAR), 5),
    (ABS(CHECKSUM(NEWID())) % 700) + 1,
    txn_dt.dt,
    CASE 
        WHEN n % 5 < 3 THEN CAST((ABS(CHECKSUM(NEWID())) % 3000 + 15) AS DECIMAL(12,2))  -- premium
        WHEN n % 5 = 3 THEN CAST((ABS(CHECKSUM(NEWID())) % 40000 + 500) AS DECIMAL(12,2))  -- payout
        ELSE CAST((ABS(CHECKSUM(NEWID())) % 500 + 10) AS DECIMAL(12,2))  -- refund
    END,
    CHOOSE((n % 5) + 1, 'PremiumPayment','PremiumPayment','PremiumPayment','ClaimPayout','Refund'),
    CHOOSE((n % 5) + 1, 'GIRO','CreditCard','PayNow','BankTransfer','BankTransfer'),
    CHOOSE((n % 8) + 1, 'Completed','Completed','Completed','Completed','Completed','Completed','Pending','Failed'),
    CASE WHEN n % 5 = 3 THEN (ABS(CHECKSUM(NEWID())) % 550) + 1 ELSE NULL END,
    CHOOSE((n % 4) + 1, 'Monthly premium auto-deduction','Quarterly premium payment','Claim settlement transfer','Premium refund - policy cancelled')
FROM Nums
CROSS APPLY (SELECT DATEADD(MINUTE, -(ABS(CHECKSUM(NEWID())) % 525600), '2026-04-16T10:00:00') AS dt) txn_dt;
GO

-- ============================================================
-- 7. Beneficiaries (500 rows)
-- ============================================================
CREATE TABLE Beneficiaries (
    beneficiary_id  INT IDENTITY(1,1) PRIMARY KEY,
    policy_id       INT            NOT NULL REFERENCES Policies(policy_id),
    full_name       NVARCHAR(120)  NOT NULL,
    relationship    VARCHAR(20)    NOT NULL,
    percentage      DECIMAL(5,2)   NOT NULL,
    nric_last4      CHAR(4),
    phone           VARCHAR(20)
);
GO

;WITH Nums AS (
    SELECT TOP 500 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO Beneficiaries (policy_id, full_name, relationship, percentage, nric_last4, phone)
SELECT
    (ABS(CHECKSUM(NEWID())) % 700) + 1,
    CHOOSE((n % 10) + 1,
        'Tan Ah Kow','Lim Bee Hoon','Ng Siew Mei','Wong Kwok Wai','Koh Shu Fen',
        'Chen Wei Lin','Teo Geok Tin','Goh Beng Huat','Lee Siew Hong','Ong Kok Peng')
        + ' ' + CAST(n AS VARCHAR),
    CHOOSE((n % 5) + 1, 'Spouse','Child','Parent','Sibling','Other'),
    CASE WHEN n % 3 = 0 THEN 50.00 WHEN n % 3 = 1 THEN 100.00 ELSE 30.00 END,
    RIGHT('0000' + CAST(ABS(CHECKSUM(NEWID())) % 10000 AS VARCHAR), 4),
    '+65 9' + RIGHT('000' + CAST(ABS(CHECKSUM(NEWID())) % 10000 AS VARCHAR), 4) 
             + RIGHT('000' + CAST(ABS(CHECKSUM(NEWID())) % 10000 AS VARCHAR), 4)
FROM Nums;
GO

-- ============================================================
-- Create useful indexes
-- ============================================================
CREATE INDEX IX_Policies_CustomerID ON Policies(customer_id);
CREATE INDEX IX_Policies_PackageID ON Policies(package_id);
CREATE INDEX IX_Policies_Status ON Policies(status);
CREATE INDEX IX_Claims_PolicyID ON Claims(policy_id);
CREATE INDEX IX_Claims_Status ON Claims(status);
CREATE INDEX IX_Transactions_PolicyID ON Transactions(policy_id);
CREATE INDEX IX_Transactions_Type ON Transactions(transaction_type);
CREATE INDEX IX_Beneficiaries_PolicyID ON Beneficiaries(policy_id);
GO

-- ============================================================
-- Print summary
-- ============================================================
PRINT '========================================';
PRINT 'InsuranceDB created successfully!';
PRINT '========================================';
SELECT t.name AS TableName, p.[rows] AS [RowCount]
FROM sys.tables t
JOIN sys.partitions p ON t.object_id = p.object_id AND p.index_id < 2
ORDER BY t.name;
GO
