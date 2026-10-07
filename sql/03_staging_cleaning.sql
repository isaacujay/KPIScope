/* 

   raw -> staging: typed columns, trimmed text, standardized casing.
   Rules:
     - Failed casts become NULL (never 0).
     - Empty strings become NULL.
     - Duplicates and orphans are FLAGGED in staging.dq_log, never dropped.
   Standardization decisions:
     - plan_tier        -> Basic / Pro / Enterprise  ('ENT' -> 'Enterprise')
     - referral_source  -> lower case (organic/ads/event/partner/other)
     - country          -> upper case ISO-2
     - priority, reason_code, billing_frequency -> lower case
     - boolean text (True/False/1/0/yes/no) -> BIT
   
   */

USE kpiscope;
GO

-- Helper functions ---------------------------------------------------
-- Converts various text representations of booleans into SQL BIT (1, 0, or NULL)
CREATE OR ALTER FUNCTION staging.fn_to_bit (@v NVARCHAR(50))
RETURNS BIT
AS
BEGIN
    DECLARE @x NVARCHAR(50) = LOWER(TRIM(@v)); -- Normalize casing and remove surrounding whitespace
    RETURN CASE
        WHEN @x IN (N'true',  N'1', N'yes', N'y', N't') THEN CAST(1 AS BIT) -- Map affirmative variations to 1
        WHEN @x IN (N'false', N'0', N'no',  N'n', N'f') THEN CAST(0 AS BIT) -- Map negative variations to 0
        ELSE NULL -- Return NULL for unparseable or empty values
    END;
END;
GO

-- Normalizes subscription and account tier naming conventions
CREATE OR ALTER FUNCTION staging.fn_plan_tier (@v NVARCHAR(50))
RETURNS NVARCHAR(50)
AS
BEGIN
    RETURN CASE UPPER(TRIM(@v)) -- Evaluate trimmed uppercase string
        WHEN N'BASIC'      THEN N'Basic'
        WHEN N'PRO'        THEN N'Pro'
        WHEN N'ENTERPRISE' THEN N'Enterprise'
        WHEN N'ENT'        THEN N'Enterprise' -- Map shorthand 'ENT' to 'Enterprise'
        ELSE NULLIF(TRIM(@v), N'') -- Preserve other non-empty inputs as-is; blanks become NULL
    END;
END;
GO

-- Data-quality log ---------------------------------------------------
-- Stores non-blocking data quality audit issues across pipeline runs
DROP TABLE IF EXISTS staging.dq_log;
CREATE TABLE staging.dq_log (
    log_id       INT IDENTITY(1,1) PRIMARY KEY, -- Auto-incrementing issue ID
    logged_at    DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(), -- Timestamp of audit run
    stage        VARCHAR(20)   NOT NULL, -- Pipeline step (e.g., 'staging')
    table_name   VARCHAR(60)   NOT NULL, -- Target table evaluated
    check_name   VARCHAR(150)  NOT NULL, -- Type of rule violation evaluated
    issue_count  INT           NOT NULL, -- Total rows failing the check
    note         NVARCHAR(400) NULL      -- Optional context
);
GO

-- Typed staging tables -----------------------------------------------
-- Destination table for sanitized account records
DROP TABLE IF EXISTS staging.accounts;
CREATE TABLE staging.accounts (
    account_id       NVARCHAR(50),  -- Alphanumeric tenant identifier
    account_name     NVARCHAR(200), -- Customer company name
    industry         NVARCHAR(100), -- Business vertical
    country          NVARCHAR(10),  -- 2-character country code
    signup_date      DATE,          -- Converted date of registration
    referral_source  NVARCHAR(50),  -- Marketing acquisition channel
    plan_tier        NVARCHAR(50),  -- Subscription level
    seats            INT,           -- Number of purchased user seats
    is_trial         BIT,           -- Active trial flag (1/0)
    churn_flag       BIT            -- Historical churn indicator (1/0)
);

-- Destination table for sanitized subscription intervals and billing metrics
DROP TABLE IF EXISTS staging.subscriptions;
CREATE TABLE staging.subscriptions (
    subscription_id   NVARCHAR(50),  -- Unique subscription contract ID
    account_id        NVARCHAR(50),  -- Foreign key reference to staging.accounts
    start_date        DATE,          -- Period effective start
    end_date          DATE,          -- Period cancellation/expiration date
    plan_tier         NVARCHAR(50),  -- Billed tier
    seats             INT,           -- Seat volume
    mrr_amount        DECIMAL(12,2), -- Monthly recurring revenue
    arr_amount        DECIMAL(14,2), -- Annualized run rate
    is_trial          BIT,           -- Trial billing flag (1/0)
    upgrade_flag      BIT,           -- Mid-cycle upgrade indicator (1/0)
    downgrade_flag    BIT,           -- Mid-cycle downgrade indicator (1/0)
    churn_flag        BIT,           -- Cancellation indicator (1/0)   <-- FIX: added missing comma
    billing_frequency NVARCHAR(50),  -- Cadence (e.g., monthly, annual)
    auto_renew_flag   BIT            -- Automatic renewal enabled (1/0)
);

-- Destination table for granular platform usage logs
DROP TABLE IF EXISTS staging.feature_usage;
CREATE TABLE staging.feature_usage (
    usage_id            NVARCHAR(50),  -- Unique usage event log ID
    subscription_id     NVARCHAR(50),  -- Foreign key reference to staging.subscriptions
    usage_date          DATE,          -- Event occurrence date
    feature_name        NVARCHAR(200), -- Specific platform capability accessed
    usage_count         INT,           -- Total interactions/invocations
    usage_duration_secs INT,           -- Aggregate active session seconds
    error_count         INT,           -- Exceptions encountered during usage
    is_beta_feature     BIT            -- Experimental feature flag (1/0)
);

-- Destination table for customer support incident tracking
DROP TABLE IF EXISTS staging.support_tickets;
CREATE TABLE staging.support_tickets (
    ticket_id                    NVARCHAR(50),   -- Unique support case ID
    account_id                   NVARCHAR(50),   -- Foreign key reference to staging.accounts
    submitted_at                 DATETIME2(0),   -- Ticket creation timestamp
    closed_at                    DATETIME2(0),   -- Resolution timestamp
    resolution_time_hours        DECIMAL(10,2),  -- Duration open in decimal hours
    priority                     NVARCHAR(50),   -- Normalized urgency rank
    first_response_time_minutes  DECIMAL(10,2),  -- Initial SLA response time
    satisfaction_score           DECIMAL(3,1),   -- CSAT score (1.0 to 5.0)
    escalation_flag              BIT             -- Tier-2/3 routing flag (1/0)
);

-- Destination table for account cancellation records and churn feedback
DROP TABLE IF EXISTS staging.churn_events;
CREATE TABLE staging.churn_events (
    churn_event_id            NVARCHAR(50),   -- Unique cancellation event ID
    account_id                NVARCHAR(50),   -- Foreign key reference to staging.accounts
    churn_date                DATE,           -- Date of cancellation request
    reason_code               NVARCHAR(100),  -- Categorical reason for departure
    refund_amount_usd         DECIMAL(10,2),  -- Credit or processed refund
    preceding_upgrade_flag    BIT,            -- Upgrade within trailing 90 days (1/0)
    preceding_downgrade_flag  BIT,            -- Downgrade within trailing 90 days (1/0)
    is_reactivation           BIT,            -- Prior churner re-signup flag (1/0)
    feedback_text             NVARCHAR(MAX)   -- Freeform exit survey commentary
);
GO

-- Load: raw -> staging -----------------------------------------------
-- Transform and load raw account records into typed staging
INSERT INTO staging.accounts
SELECT
    NULLIF(TRIM(account_id), N''),                      -- Strip spaces; blank becomes NULL
    NULLIF(TRIM(account_name), N''),                    -- Clean account name
    NULLIF(TRIM(industry), N''),                        -- Clean industry string
    UPPER(NULLIF(TRIM(country), N'')),                  -- Standardize ISO country codes to uppercase
    TRY_CAST(NULLIF(TRIM(signup_date), N'') AS DATE),   -- Safely cast date string; malformed inputs become NULL
    LOWER(NULLIF(TRIM(referral_source), N'')),          -- Standardize channel source to lowercase
    staging.fn_plan_tier(plan_tier),                    -- Standardize plan tier naming
    TRY_CAST(TRY_CAST(NULLIF(TRIM(seats), N'') AS DECIMAL(18,2)) AS INT), -- Intermediate cast handles float-formatted integers (e.g. '10.0')
    staging.fn_to_bit(is_trial),                        -- Normalize boolean to BIT
    staging.fn_to_bit(churn_flag)                       -- Normalize boolean to BIT
FROM raw.accounts;

-- Transform and load raw subscription history
INSERT INTO staging.subscriptions
SELECT
    NULLIF(TRIM(subscription_id), N''),
    NULLIF(TRIM(account_id), N''),
    TRY_CAST(NULLIF(TRIM(start_date), N'') AS DATE),            -- Safe date parse
    TRY_CAST(NULLIF(TRIM(end_date), N'') AS DATE),              -- Safe date parse (NULL if currently active)
    staging.fn_plan_tier(plan_tier),
    TRY_CAST(TRY_CAST(NULLIF(TRIM(seats), N'') AS DECIMAL(18,2)) AS INT), -- Safe integer parse
    TRY_CAST(NULLIF(TRIM(mrr_amount), N'') AS DECIMAL(12,2)),   -- Safe decimal cast for currency
    TRY_CAST(NULLIF(TRIM(arr_amount), N'') AS DECIMAL(14,2)),   -- Safe decimal cast for annual rate
    staging.fn_to_bit(is_trial),
    staging.fn_to_bit(upgrade_flag),
    staging.fn_to_bit(downgrade_flag),
    staging.fn_to_bit(churn_flag),
    LOWER(NULLIF(TRIM(billing_frequency), N'')),                -- Standardize billing interval casing
    staging.fn_to_bit(auto_renew_flag)
FROM raw.subscriptions;

-- Transform and load raw daily feature telemetry
INSERT INTO staging.feature_usage
SELECT
    NULLIF(TRIM(usage_id), N''),
    NULLIF(TRIM(subscription_id), N''),
    TRY_CAST(NULLIF(TRIM(usage_date), N'') AS DATE),
    NULLIF(TRIM(feature_name), N''),
    TRY_CAST(TRY_CAST(NULLIF(TRIM(usage_count), N'') AS DECIMAL(18,2)) AS INT),         -- Safe integer parse
    TRY_CAST(TRY_CAST(NULLIF(TRIM(usage_duration_secs), N'') AS DECIMAL(18,2)) AS INT), -- Safe integer parse
    TRY_CAST(TRY_CAST(NULLIF(TRIM(error_count), N'') AS DECIMAL(18,2)) AS INT),         -- Safe integer parse
    staging.fn_to_bit(is_beta_feature)
FROM raw.feature_usage;

-- Transform and load raw support ticket metrics
INSERT INTO staging.support_tickets
SELECT
    NULLIF(TRIM(ticket_id), N''),
    NULLIF(TRIM(account_id), N''),
    TRY_CAST(NULLIF(TRIM(submitted_at), N'') AS DATETIME2(0)),           -- Safe conversion to timestamp (second precision)
    TRY_CAST(NULLIF(TRIM(closed_at), N'') AS DATETIME2(0)),              -- Safe conversion to timestamp (second precision)
    TRY_CAST(NULLIF(TRIM(resolution_time_hours), N'') AS DECIMAL(10,2)), -- Safe decimal cast
    LOWER(NULLIF(TRIM(priority), N'')),                                  -- Standardize ticket priority casing
    TRY_CAST(NULLIF(TRIM(first_response_time_minutes), N'') AS DECIMAL(10,2)),
    TRY_CAST(NULLIF(TRIM(satisfaction_score), N'') AS DECIMAL(3,1)),     -- NULL = no response, kept as NULL
    staging.fn_to_bit(escalation_flag)
FROM raw.support_tickets;

-- Transform and load raw customer churn logs
INSERT INTO staging.churn_events
SELECT
    NULLIF(TRIM(churn_event_id), N''),
    NULLIF(TRIM(account_id), N''),
    TRY_CAST(NULLIF(TRIM(churn_date), N'') AS DATE),
    LOWER(NULLIF(TRIM(reason_code), N'')),                               -- Standardize churn reason casing
    TRY_CAST(NULLIF(TRIM(refund_amount_usd), N'') AS DECIMAL(10,2)),     -- Safe decimal cast
    staging.fn_to_bit(preceding_upgrade_flag),
    staging.fn_to_bit(preceding_downgrade_flag),
    staging.fn_to_bit(is_reactivation),
    NULLIF(TRIM(feedback_text), N'')                                     -- NULL on ~25% rows is expected
FROM raw.churn_events;
GO

-- Data-quality checks (flag, never drop) -----------------------------

-- 1) Failed casts: value was present in raw but became NULL in staging
-- Identify values lost due to unparseable date/numeric formatting in raw
INSERT INTO staging.dq_log
    (stage, table_name, check_name, issue_count)
SELECT 'staging',
     'accounts', 
     'failed_cast: signup_date', 
     COUNT(*)
FROM raw.accounts
WHERE NULLIF(TRIM(signup_date), N'') IS NOT NULL
  AND TRY_CAST(NULLIF(TRIM(signup_date), N'') AS DATE) IS NULL
UNION ALL
SELECT 'staging', 'subscriptions', 'failed_cast: start_date', COUNT(*)
FROM raw.subscriptions
WHERE NULLIF(TRIM(start_date), N'') IS NOT NULL
  AND TRY_CAST(NULLIF(TRIM(start_date), N'') AS DATE) IS NULL
UNION ALL
SELECT 'staging', 'subscriptions', 'failed_cast: end_date', COUNT(*)
FROM raw.subscriptions
WHERE NULLIF(TRIM(end_date), N'') IS NOT NULL
  AND TRY_CAST(NULLIF(TRIM(end_date), N'') AS DATE) IS NULL
UNION ALL
SELECT 'staging', 'subscriptions', 'failed_cast: mrr_amount', COUNT(*)
FROM raw.subscriptions
WHERE NULLIF(TRIM(mrr_amount), N'') IS NOT NULL
  AND TRY_CAST(NULLIF(TRIM(mrr_amount), N'') AS DECIMAL(12,2)) IS NULL
UNION ALL
SELECT 'staging', 'subscriptions', 'failed_cast: arr_amount', COUNT(*)
FROM raw.subscriptions
WHERE NULLIF(TRIM(arr_amount), N'') IS NOT NULL
  AND TRY_CAST(NULLIF(TRIM(arr_amount), N'') AS DECIMAL(14,2)) IS NULL
UNION ALL
SELECT 'staging', 'feature_usage', 'failed_cast: usage_date', COUNT(*)
FROM raw.feature_usage
WHERE NULLIF(TRIM(usage_date), N'') IS NOT NULL
  AND TRY_CAST(NULLIF(TRIM(usage_date), N'') AS DATE) IS NULL
UNION ALL
SELECT 'staging', 'support_tickets', 'failed_cast: submitted_at', COUNT(*)
FROM raw.support_tickets
WHERE NULLIF(TRIM(submitted_at), N'') IS NOT NULL
  AND TRY_CAST(NULLIF(TRIM(submitted_at), N'') AS DATETIME2(0)) IS NULL
UNION ALL
SELECT 'staging', 'support_tickets', 'failed_cast: closed_at', COUNT(*)
FROM raw.support_tickets
WHERE NULLIF(TRIM(closed_at), N'') IS NOT NULL
  AND TRY_CAST(NULLIF(TRIM(closed_at), N'') AS DATETIME2(0)) IS NULL
UNION ALL
SELECT 'staging', 'support_tickets', 'failed_cast: satisfaction_score', COUNT(*)
FROM raw.support_tickets
WHERE NULLIF(TRIM(satisfaction_score), N'') IS NOT NULL
  AND TRY_CAST(NULLIF(TRIM(satisfaction_score), N'') AS DECIMAL(3,1)) IS NULL
UNION ALL
SELECT 'staging', 'churn_events', 'failed_cast: churn_date', COUNT(*)
FROM raw.churn_events
WHERE NULLIF(TRIM(churn_date), N'') IS NOT NULL
  AND TRY_CAST(NULLIF(TRIM(churn_date), N'') AS DATE) IS NULL;

-- 2) True duplicate keys, checked at each table's real grain.
--    NOTE: subscriptions.account_id repeating is EXPECTED (concurrent line items).
-- Count extra duplicate instances across primary identifiers
INSERT INTO staging.dq_log (stage, table_name, check_name, issue_count)
SELECT 'staging', 'accounts', 'duplicate_key: account_id', COALESCE(SUM(c - 1), 0)
FROM (SELECT COUNT(*) AS c FROM staging.accounts GROUP BY account_id HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'staging', 'subscriptions', 'duplicate_key: subscription_id', COALESCE(SUM(c - 1), 0)
FROM (SELECT COUNT(*) AS c FROM staging.subscriptions GROUP BY subscription_id HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'staging', 'feature_usage', 'duplicate_key: usage_id', COALESCE(SUM(c - 1), 0)
FROM (SELECT COUNT(*) AS c FROM staging.feature_usage GROUP BY usage_id HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'staging', 'support_tickets', 'duplicate_key: ticket_id', COALESCE(SUM(c - 1), 0)
FROM (SELECT COUNT(*) AS c FROM staging.support_tickets GROUP BY ticket_id HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'staging', 'churn_events', 'duplicate_key: churn_event_id', COALESCE(SUM(c - 1), 0)
FROM (SELECT COUNT(*) AS c FROM staging.churn_events GROUP BY churn_event_id HAVING COUNT(*) > 1) x;

-- 3) Orphaned foreign keys
-- Detect records pointing to non-existent parent records
INSERT INTO staging.dq_log (stage, table_name, check_name, issue_count)
SELECT 'staging', 'subscriptions', 'orphan: account_id not in accounts', COUNT(*)
FROM staging.subscriptions s
WHERE NOT EXISTS (SELECT 1 FROM staging.accounts a WHERE a.account_id = s.account_id) -- Check child subscription has valid account parent
UNION ALL
SELECT 'staging', 'feature_usage', 'orphan: subscription_id not in subscriptions', COUNT(*)
FROM staging.feature_usage f
WHERE NOT EXISTS (SELECT 1 FROM staging.subscriptions s WHERE s.subscription_id = f.subscription_id) -- Check child usage has valid subscription parent
UNION ALL
SELECT 'staging', 'support_tickets', 'orphan: account_id not in accounts', COUNT(*)
FROM staging.support_tickets t
WHERE NOT EXISTS (SELECT 1 FROM staging.accounts a WHERE a.account_id = t.account_id) -- Check ticket has valid account parent
UNION ALL
SELECT 'staging', 'churn_events', 'orphan: account_id not in accounts', COUNT(*)
FROM staging.churn_events c
WHERE NOT EXISTS (SELECT 1 FROM staging.accounts a WHERE a.account_id = c.account_id); -- Check churn event has valid account parent

-- 4) Temporal logic and unexpected categories
-- Identify inverted dates, out-of-range metrics, or unstandardized categorical values
INSERT INTO staging.dq_log (stage, table_name, check_name, issue_count)
SELECT 'staging', 'subscriptions', 'end_date before start_date', COUNT(*)
FROM staging.subscriptions WHERE end_date < start_date -- Check chronology of subscription window
UNION ALL
SELECT 'staging', 'support_tickets', 'closed_at before submitted_at', COUNT(*)
FROM staging.support_tickets WHERE closed_at < submitted_at -- Check ticket resolution happens after ticket creation
UNION ALL
SELECT 'staging', 'churn_events', 'churn_date before signup_date', COUNT(*)
FROM staging.churn_events c
JOIN staging.accounts a ON a.account_id = c.account_id
WHERE c.churn_date < a.signup_date -- Verify churn date is after initial account signup
UNION ALL
SELECT 'staging', 'accounts', 'unexpected plan_tier', COUNT(*)
FROM staging.accounts
WHERE plan_tier IS NOT NULL AND plan_tier NOT IN (N'Basic', N'Pro', N'Enterprise') -- Detect unmapped tiers
UNION ALL
SELECT 'staging', 'subscriptions', 'unexpected plan_tier', COUNT(*)
FROM staging.subscriptions
WHERE plan_tier IS NOT NULL AND plan_tier NOT IN (N'Basic', N'Pro', N'Enterprise') -- Detect unmapped tiers
UNION ALL
SELECT 'staging', 'accounts', 'unexpected referral_source', COUNT(*)
FROM staging.accounts
WHERE referral_source IS NOT NULL
  AND referral_source NOT IN (N'organic', N'ads', N'event', N'partner', N'other') -- Verify against allowed marketing channels
UNION ALL
SELECT 'staging', 'support_tickets', 'satisfaction_score outside 1-5', COUNT(*)
FROM staging.support_tickets
WHERE satisfaction_score IS NOT NULL AND satisfaction_score NOT BETWEEN 1 AND 5; -- Confirm CSAT score is on a 1.0 to 5.0 scale
GO

-- Review ---------------------------------------------------------------
-- Query all logged data quality discrepancies
SELECT stage, table_name, check_name, issue_count
FROM staging.dq_log
ORDER BY log_id;

-- Verify total successfully loaded rows per staging table
SELECT 'accounts' AS tbl,        COUNT(*) AS staging_rows FROM staging.accounts
UNION ALL SELECT 'subscriptions',   COUNT(*) FROM staging.subscriptions
UNION ALL SELECT 'feature_usage',   COUNT(*) FROM staging.feature_usage
UNION ALL SELECT 'support_tickets', COUNT(*) FROM staging.support_tickets
UNION ALL SELECT 'churn_events',    COUNT(*) FROM staging.churn_events;
GO