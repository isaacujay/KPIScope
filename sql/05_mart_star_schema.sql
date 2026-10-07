/* 
       05_mart_star_schema.sql
       clean -> mart: star schema + read-only login for Python and Power BI.

       FACT GRAIN
         fact_subscription_activity : one row per subscription line item
                                      (an account has many concurrent rows).
                                      period_date_key = first day of the month
                                      of the subscription's start_date.
                                      Account-level flags repeat on every row of
                                      that account, so churn/active counts MUST use
                                      DISTINCT account_key.
         fact_support_tickets       : one row per support ticket.

       Columns beyond the agreed contract are additive only (nothing renamed):
         fact_subscription_activity : subscription_id, arr_amount, seats,
                                      is_trial, churned_mrr
         fact_support_tickets       : ticket_id, first_response_time_minutes
         dim_account                : signup_date, is_trial
         dim_date                   : month_start_date, month_name
   
   */

USE kpiscope;
GO

-- Drop in dependency order 
DROP TABLE IF EXISTS mart.fact_support_tickets;
DROP TABLE IF EXISTS mart.fact_subscription_activity;
DROP TABLE IF EXISTS mart.dim_date;
DROP TABLE IF EXISTS mart.dim_channel;
DROP TABLE IF EXISTS mart.dim_plan;
DROP TABLE IF EXISTS mart.dim_account;
GO

-- Dimensions 
CREATE TABLE mart.dim_account (
    account_key   INT IDENTITY(1,1) PRIMARY KEY,
    account_id    NVARCHAR(50) NOT NULL UNIQUE,
    account_name  NVARCHAR(200),
    industry      NVARCHAR(100),
    country       NVARCHAR(10),
    signup_date   DATE,
    is_trial      BIT
);

CREATE TABLE mart.dim_plan (
    plan_key   INT IDENTITY(1,1) PRIMARY KEY,
    plan_tier  NVARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE mart.dim_channel (
    channel_key      INT IDENTITY(1,1) PRIMARY KEY,
    referral_source  NVARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE mart.dim_date (
    date_key          DATE PRIMARY KEY,
    [year]            INT,
    [month]           INT,
    [quarter]         INT,
    month_start_date  DATE,
    month_name        NVARCHAR(20)
);
GO

-- Facts --------------------------------------------------------------------
CREATE TABLE mart.fact_subscription_activity (
    fact_id               INT IDENTITY(1,1) PRIMARY KEY,
    subscription_id       NVARCHAR(50),
    account_key           INT REFERENCES mart.dim_account(account_key),
    plan_key              INT REFERENCES mart.dim_plan(plan_key),
    channel_key           INT REFERENCES mart.dim_channel(channel_key),
    period_date_key       DATE REFERENCES mart.dim_date(date_key),
    mrr_amount            DECIMAL(12,2),
    arr_amount            DECIMAL(14,2),
    seats                 INT,
    is_trial              BIT,
    is_active_flag        BIT,
    is_churned_flag       BIT,
    upgrade_flag          BIT,
    downgrade_flag        BIT,
    expansion_mrr_proxy   DECIMAL(12,2),    -- PROXY, not a true delta
    contraction_mrr_proxy DECIMAL(12,2),    -- PROXY, not a true delta
    churned_mrr           DECIMAL(12,2),
    tenure_days           INT
);

CREATE TABLE mart.fact_support_tickets (
    ticket_key                   INT IDENTITY(1,1) PRIMARY KEY,
    ticket_id                    NVARCHAR(50),
    account_key                  INT REFERENCES mart.dim_account(account_key),
    opened_date_key              DATE REFERENCES mart.dim_date(date_key),
    resolved_date_key            DATE REFERENCES mart.dim_date(date_key),
    priority                     NVARCHAR(50),
    resolution_time_hours        DECIMAL(10,2),
    first_response_time_minutes  DECIMAL(10,2),
    satisfaction_score           DECIMAL(3,1) NULL,
    escalation_flag              BIT
);
GO

-- Populate dimensions 
;WITH d AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY signup_date) AS rn
    FROM clean.accounts
    WHERE account_id IS NOT NULL
)
INSERT INTO mart.dim_account (account_id, account_name, industry, country, signup_date, is_trial)
SELECT account_id, account_name, industry, country, signup_date, is_trial
FROM d
WHERE rn = 1;

INSERT INTO mart.dim_plan (plan_tier)
SELECT x.plan_tier
FROM (
    SELECT plan_tier FROM clean.subscription_activity
    UNION
    SELECT plan_tier FROM clean.accounts
) x
WHERE x.plan_tier IS NOT NULL
ORDER BY CASE x.plan_tier
             WHEN N'Basic' THEN 1 WHEN N'Pro' THEN 2 WHEN N'Enterprise' THEN 3 ELSE 4
         END;

INSERT INTO mart.dim_channel (referral_source)
SELECT DISTINCT referral_source
FROM clean.accounts
WHERE referral_source IS NOT NULL
ORDER BY referral_source;
GO

-- dim_date: one row per calendar day covering every date in the model 
DECLARE @min DATE = (
    SELECT MIN(d) FROM (
        SELECT MIN(signup_date)   AS d FROM clean.accounts
        UNION ALL SELECT MIN(start_date)    FROM clean.subscription_activity
        UNION ALL SELECT MIN(opened_date)   FROM clean.support_tickets
        UNION ALL SELECT MIN(churn_date)    FROM clean.churn_events
    ) x
);
DECLARE @max DATE = (
    SELECT MAX(d) FROM (
        SELECT MAX(signup_date)   AS d FROM clean.accounts
        UNION ALL SELECT MAX(start_date)    FROM clean.subscription_activity
        UNION ALL SELECT MAX(end_date)      FROM clean.subscription_activity
        UNION ALL SELECT MAX(opened_date)   FROM clean.support_tickets
        UNION ALL SELECT MAX(resolved_date) FROM clean.support_tickets
        UNION ALL SELECT MAX(churn_date)    FROM clean.churn_events
    ) x
);
SET @min = DATEFROMPARTS(YEAR(@min), MONTH(@min), 1);   -- start on a month boundary

;WITH cal AS (
    SELECT @min AS dt
    UNION ALL
    SELECT DATEADD(DAY, 1, dt) FROM cal WHERE dt < @max
)
INSERT INTO mart.dim_date (date_key, [year], [month], [quarter], month_start_date, month_name)
SELECT dt,
       YEAR(dt),
       MONTH(dt),
       DATEPART(QUARTER, dt),
       DATEFROMPARTS(YEAR(dt), MONTH(dt), 1),
       DATENAME(MONTH, dt)
FROM cal
OPTION (MAXRECURSION 0);
GO

-- Populate facts -------------------------------------------------------------
INSERT INTO mart.fact_subscription_activity
    (subscription_id, account_key, plan_key, channel_key, period_date_key,
     mrr_amount, arr_amount, seats, is_trial,
     is_active_flag, is_churned_flag, upgrade_flag, downgrade_flag,
     expansion_mrr_proxy, contraction_mrr_proxy, churned_mrr, tenure_days)
SELECT
    s.subscription_id,
    da.account_key,
    p.plan_key,
    ch.channel_key,
    s.period_date,
    s.mrr_amount,
    s.arr_amount,
    s.seats,
    s.is_trial,
    a.is_active_flag,
    a.is_churned_flag,
    s.upgrade_flag,
    s.downgrade_flag,
    s.expansion_mrr_proxy,
    s.contraction_mrr_proxy,
    s.churned_mrr,
    a.tenure_days
FROM clean.subscription_activity s
JOIN mart.dim_account da   ON da.account_id = s.account_id
JOIN clean.accounts a      ON a.account_id  = s.account_id
LEFT JOIN mart.dim_plan p      ON p.plan_tier        = s.plan_tier
LEFT JOIN mart.dim_channel ch  ON ch.referral_source = a.referral_source;

INSERT INTO mart.fact_support_tickets
    (ticket_id, account_key, opened_date_key, resolved_date_key, priority,
     resolution_time_hours, first_response_time_minutes, satisfaction_score, escalation_flag)
SELECT
    t.ticket_id,
    da.account_key,
    t.opened_date,
    t.resolved_date,
    t.priority,
    t.resolution_time_hours,
    t.first_response_time_minutes,
    t.satisfaction_score,
    t.escalation_flag
FROM clean.support_tickets t
JOIN mart.dim_account da ON da.account_id = t.account_id;
GO

-- Indexes for the downstream read patterns 
CREATE INDEX ix_fact_sub_account ON mart.fact_subscription_activity (account_key);
CREATE INDEX ix_fact_sub_plan    ON mart.fact_subscription_activity (plan_key);
CREATE INDEX ix_fact_sub_channel ON mart.fact_subscription_activity (channel_key);
CREATE INDEX ix_fact_sub_period  ON mart.fact_subscription_activity (period_date_key);
CREATE INDEX ix_fact_tix_account ON mart.fact_support_tickets (account_key);
GO

-- Read-only access for Python and Power BI 
-- Requires SQL Server authentication enabled (mixed mode). If you stay on
-- Windows authentication, skip the login and grant SELECT on mart to your
-- Windows user instead. Replace the password and NEVER commit the real one.
USE master;
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'kpiscope_reader')
    CREATE LOGIN kpiscope_reader
        WITH PASSWORD = N'Replace_With_Str0ng_Passw0rd!', CHECK_POLICY = ON;
GO

USE kpiscope;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'kpiscope_reader')
    CREATE USER kpiscope_reader FOR LOGIN kpiscope_reader;
GO

GRANT SELECT ON SCHEMA::mart TO kpiscope_reader;
DENY  INSERT, UPDATE, DELETE, ALTER ON SCHEMA::mart    TO kpiscope_reader;
DENY  SELECT, INSERT, UPDATE, DELETE ON SCHEMA::raw     TO kpiscope_reader;
DENY  SELECT, INSERT, UPDATE, DELETE ON SCHEMA::staging TO kpiscope_reader;
DENY  SELECT, INSERT, UPDATE, DELETE ON SCHEMA::clean   TO kpiscope_reader;
GO

-- Row counts for the build
SELECT 'dim_account' AS tbl, COUNT(*) AS row_count FROM mart.dim_account
UNION ALL SELECT 'dim_plan',                    COUNT(*) FROM mart.dim_plan
UNION ALL SELECT 'dim_channel',                 COUNT(*) FROM mart.dim_channel
UNION ALL SELECT 'dim_date',                    COUNT(*) FROM mart.dim_date
UNION ALL SELECT 'fact_subscription_activity',  COUNT(*) FROM mart.fact_subscription_activity
UNION ALL SELECT 'fact_support_tickets',        COUNT(*) FROM mart.fact_support_tickets;
GO

select * from mart.dim_account;
select * from mart.dim_channel
select * from mart.dim_date
select * from mart.dim_plan
select * from mart.fact_support_tickets
