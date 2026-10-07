/*
   Creates the database, the four schemas, and the 5 raw tables.
   Raw tables are all NVARCHAR so no file can fail on formatting.
*/

IF DB_ID(N'kpiscope') IS NULL
    CREATE DATABASE kpiscope;
GO

USE kpiscope;
GO

-- Schemas (EXEC keeps each CREATE SCHEMA in its own batch)
IF SCHEMA_ID(N'raw')     IS NULL EXEC (N'CREATE SCHEMA raw');
IF SCHEMA_ID(N'staging') IS NULL EXEC (N'CREATE SCHEMA staging');
IF SCHEMA_ID(N'clean')   IS NULL EXEC (N'CREATE SCHEMA clean');
IF SCHEMA_ID(N'mart')    IS NULL EXEC (N'CREATE SCHEMA mart');
GO

-- Raw tables 
DROP TABLE IF EXISTS raw.accounts;
CREATE TABLE raw.accounts (
    account_id       NVARCHAR(50),
    account_name     NVARCHAR(200),
    industry         NVARCHAR(100),
    country          NVARCHAR(10),
    signup_date      NVARCHAR(50),
    referral_source  NVARCHAR(50),
    plan_tier        NVARCHAR(50),
    seats            NVARCHAR(50),
    is_trial         NVARCHAR(10),
    churn_flag       NVARCHAR(10)
);

DROP TABLE IF EXISTS raw.subscriptions;
CREATE TABLE raw.subscriptions (
    subscription_id    NVARCHAR(50),
    account_id         NVARCHAR(50),
    start_date         NVARCHAR(50),
    end_date           NVARCHAR(50),
    plan_tier          NVARCHAR(50),
    seats              NVARCHAR(50),
    mrr_amount         NVARCHAR(50),
    arr_amount         NVARCHAR(50),
    is_trial           NVARCHAR(10),
    upgrade_flag       NVARCHAR(10),
    downgrade_flag     NVARCHAR(10),
    churn_flag         NVARCHAR(10),
    billing_frequency  NVARCHAR(50),
    auto_renew_flag    NVARCHAR(10)
);

DROP TABLE IF EXISTS raw.feature_usage;
CREATE TABLE raw.feature_usage (
    usage_id             NVARCHAR(50),
    subscription_id      NVARCHAR(50),
    usage_date           NVARCHAR(50),
    feature_name         NVARCHAR(200),
    usage_count          NVARCHAR(50),
    usage_duration_secs  NVARCHAR(50),
    error_count          NVARCHAR(50),
    is_beta_feature      NVARCHAR(10)
);

DROP TABLE IF EXISTS raw.support_tickets;
CREATE TABLE raw.support_tickets (
    ticket_id                    NVARCHAR(50),
    account_id                   NVARCHAR(50),
    submitted_at                 NVARCHAR(50),
    closed_at                    NVARCHAR(50),
    resolution_time_hours        NVARCHAR(50),
    priority                     NVARCHAR(50),
    first_response_time_minutes  NVARCHAR(50),
    satisfaction_score           NVARCHAR(50),
    escalation_flag              NVARCHAR(10)
);

DROP TABLE IF EXISTS raw.churn_events;
CREATE TABLE raw.churn_events (
    churn_event_id          NVARCHAR(50),
    account_id              NVARCHAR(50),
    churn_date              NVARCHAR(50),
    reason_code             NVARCHAR(100),
    refund_amount_usd       NVARCHAR(50),
    preceding_upgrade_flag  NVARCHAR(10),
    preceding_downgrade_flag NVARCHAR(10),
    is_reactivation         NVARCHAR(10),
    feedback_text           NVARCHAR(MAX)
);
GO

-- Verify
SELECT s.name AS schema_name
FROM sys.schemas s
WHERE s.name IN (N'raw', N'staging', N'clean', N'mart')
ORDER BY s.name;

SELECT t.name AS raw_table
FROM sys.tables t
WHERE t.schema_id = SCHEMA_ID(N'raw')
ORDER BY t.name;
GO