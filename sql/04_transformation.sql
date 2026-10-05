/* 

   staging -> clean: derived analytical columns. All business logic lives
   here, never in Python or DAX.

   Transformation log (input -> rule -> output):
     churn_flag                   -> =0 means active                  -> is_active_flag
     churn_events membership      -> account has >= 1 churn event     -> is_churned_flag
     signup_date, last churn_date -> days between (as-of date if
                                     never churned)                   -> tenure_days
     tenure_days                  -> 0-90 / 91-180 / 181-365 /
                                     366-730 / 730+                   -> tenure_band
     mrr_amount                   -> <500 Low, <2000 Medium, else High -> mrr_band
     ticket_count                 -> above the 75th percentile of
                                     tickets per account              -> support_load_flag
     upgrade/downgrade_flag       -> PROXY (see below)                -> expansion/contraction_mrr_proxy

   As-of date: the latest date found in the data, NOT GETDATE(), so
   tenure values are reproducible and not inflated by today's date.

   PROXY WARNING: subscriptions rows per account are concurrent line items,
   so LAG() cannot produce a true MRR delta. Expansion / Contraction / NRR
   are PROXIES. Trial rows are excluded from the proxy columns.
   
   */

USE kpiscope;
GO

DROP TABLE IF EXISTS clean.accounts;
DROP TABLE IF EXISTS clean.subscription_activity;
DROP TABLE IF EXISTS clean.support_tickets;
DROP TABLE IF EXISTS clean.churn_events;
DROP TABLE IF EXISTS clean.feature_usage;
GO

-- clean.accounts -----------------------------------------------------
DECLARE @as_of DATE = (
    SELECT MAX(d) FROM (
        SELECT MAX(signup_date)                  AS d FROM staging.accounts
        UNION ALL SELECT MAX(start_date)                  FROM staging.subscriptions
        UNION ALL SELECT MAX(churn_date)                  FROM staging.churn_events
        UNION ALL SELECT MAX(CAST(submitted_at AS DATE))  FROM staging.support_tickets
    ) x
);

WITH churn AS (
    SELECT account_id,
           COUNT(*)        AS churn_event_count,
           MAX(churn_date) AS last_churn_date
    FROM staging.churn_events
    GROUP BY account_id
),
tix AS (
    SELECT account_id, COUNT(*) AS ticket_count
    FROM staging.support_tickets
    GROUP BY account_id
),
sub AS (
    SELECT account_id, MAX(CAST(churn_flag AS INT)) AS any_sub_churn_flag
    FROM staging.subscriptions
    GROUP BY account_id
),
base AS (
    SELECT
        a.account_id, a.account_name, a.industry, a.country, a.signup_date,
        a.referral_source, a.plan_tier, a.seats, a.is_trial, a.churn_flag,
        CASE WHEN a.churn_flag = 0 THEN 1 ELSE 0 END                 AS is_active_flag,
        CASE WHEN c.account_id IS NOT NULL THEN 1 ELSE 0 END         AS is_churned_flag,
        COALESCE(c.churn_event_count, 0)                             AS churn_event_count,
        c.last_churn_date,
        s.any_sub_churn_flag,
        COALESCE(t.ticket_count, 0)                                  AS ticket_count,
        DATEDIFF(DAY, a.signup_date, COALESCE(c.last_churn_date, @as_of)) AS tenure_days_raw
    FROM staging.accounts a
    LEFT JOIN churn c ON c.account_id = a.account_id
    LEFT JOIN tix   t ON t.account_id = a.account_id
    LEFT JOIN sub   s ON s.account_id = a.account_id
),
scored AS (
    SELECT b.*,
           PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY b.ticket_count) OVER () AS ticket_p75
    FROM base b
)
SELECT
    account_id, account_name, industry, country, signup_date,
    referral_source, plan_tier, seats, is_trial, churn_flag,
    is_active_flag,
    is_churned_flag,
    churn_event_count,
    last_churn_date,
    any_sub_churn_flag,
    CASE WHEN tenure_days_raw < 0 THEN NULL ELSE tenure_days_raw END AS tenure_days,
    CASE
        WHEN tenure_days_raw IS NULL OR tenure_days_raw < 0 THEN NULL
        WHEN tenure_days_raw <= 90   THEN '0-90'
        WHEN tenure_days_raw <= 180  THEN '91-180'
        WHEN tenure_days_raw <= 365  THEN '181-365'
        WHEN tenure_days_raw <= 730  THEN '366-730'
        ELSE '730+'
    END AS tenure_band,
    ticket_count,
    CASE WHEN ticket_count > ticket_p75 THEN 1 ELSE 0 END AS support_load_flag
INTO clean.accounts
FROM scored;
GO

-- Churn reconciliation: log every disagreement, never silently pick a source
INSERT INTO staging.dq_log (stage, table_name, check_name, issue_count, note)
SELECT 'clean', 'accounts', 'churn_flag=0 but churn_event exists', COUNT(*),
       N'accounts.churn_flag vs churn_events'
FROM clean.accounts WHERE churn_flag = 0 AND is_churned_flag = 1
UNION ALL
SELECT 'clean', 'accounts', 'churn_flag=1 but no churn_event', COUNT(*),
       N'accounts.churn_flag vs churn_events'
FROM clean.accounts WHERE churn_flag = 1 AND is_churned_flag = 0
UNION ALL
SELECT 'clean', 'accounts', 'churn_flag=1 but no churned subscription', COUNT(*),
       N'accounts.churn_flag vs subscriptions.churn_flag'
FROM clean.accounts WHERE churn_flag = 1 AND COALESCE(any_sub_churn_flag, 0) = 0
UNION ALL
SELECT 'clean', 'accounts', 'churn_flag=0 but a churned subscription exists', COUNT(*),
       N'accounts.churn_flag vs subscriptions.churn_flag'
FROM clean.accounts WHERE churn_flag = 0 AND any_sub_churn_flag = 1
UNION ALL
SELECT 'clean', 'accounts', 'negative tenure (churn before signup)', COUNT(*),
       N'tenure_days set to NULL'
FROM clean.accounts WHERE tenure_days IS NULL AND signup_date IS NOT NULL;
GO

-- clean.subscription_activity (carries the labeled PROXY columns) -------
SELECT
    s.subscription_id,
    s.account_id,
    DATEFROMPARTS(YEAR(s.start_date), MONTH(s.start_date), 1) AS period_date,   -- month of start_date
    s.start_date,
    s.end_date,
    s.plan_tier,
    s.seats,
    s.mrr_amount,
    s.arr_amount,
    s.billing_frequency,
    s.auto_renew_flag,
    s.is_trial,
    s.upgrade_flag,
    s.downgrade_flag,
    s.churn_flag,
    CASE
        WHEN s.mrr_amount IS NULL  THEN NULL
        WHEN s.mrr_amount < 500    THEN 'Low'
        WHEN s.mrr_amount < 2000   THEN 'Medium'
        ELSE 'High'
    END AS mrr_band,
    -- ARR definition check: does the source arr_amount equal MRR x 12?
    CASE
        WHEN s.arr_amount IS NULL OR s.mrr_amount IS NULL THEN NULL
        WHEN ABS(s.arr_amount - s.mrr_amount * 12) < 0.01 THEN 1
        ELSE 0
    END AS arr_equals_mrr_x12,
    -- PROXIES: whole mrr_amount of a flagged row, trials excluded
    CASE WHEN s.upgrade_flag   = 1 AND s.is_trial = 0 THEN s.mrr_amount ELSE 0 END AS expansion_mrr_proxy,
    CASE WHEN s.downgrade_flag = 1 AND s.is_trial = 0 THEN s.mrr_amount ELSE 0 END AS contraction_mrr_proxy,
    -- Revenue lost to churn (feeds NRR proxy)
    CASE WHEN s.churn_flag = 1 THEN s.mrr_amount ELSE 0 END                        AS churned_mrr
INTO clean.subscription_activity
FROM staging.subscriptions s;
GO

-- clean.support_tickets ------------------------------------------------
SELECT
    t.ticket_id,
    t.account_id,
    t.submitted_at,
    t.closed_at,
    CAST(t.submitted_at AS DATE) AS opened_date,
    CAST(t.closed_at AS DATE)    AS resolved_date,
    t.resolution_time_hours,
    t.priority,
    t.first_response_time_minutes,
    t.satisfaction_score,                                           -- NULL kept; KPIs must exclude, not zero-fill
    CASE WHEN t.satisfaction_score IS NOT NULL THEN 1 ELSE 0 END AS has_csat,
    t.escalation_flag
INTO clean.support_tickets
FROM staging.support_tickets t;
GO

-- clean.churn_events ---------------------------------------------------
SELECT
    c.*,
    DATEFROMPARTS(YEAR(c.churn_date), MONTH(c.churn_date), 1) AS churn_month
INTO clean.churn_events
FROM staging.churn_events c;
GO

-- clean.feature_usage (pass-through, orphans flagged) -------------------
SELECT
    f.*,
    CASE WHEN EXISTS (SELECT 1 FROM staging.subscriptions s
                      WHERE s.subscription_id = f.subscription_id)
         THEN 0 ELSE 1 END AS is_orphan_flag
INTO clean.feature_usage
FROM staging.feature_usage f;
GO

-- Spot-check: compare 5 clean rows against their source rows --------------
SELECT TOP (5)
    a.account_id, a.signup_date, a.churn_flag, a.is_active_flag, a.is_churned_flag,
    a.tenure_days, a.tenure_band, a.ticket_count, a.support_load_flag
FROM clean.accounts a
ORDER BY a.account_id;

SELECT TOP (5)
    subscription_id, account_id, period_date, mrr_amount, mrr_band, is_trial,
    upgrade_flag, expansion_mrr_proxy, downgrade_flag, contraction_mrr_proxy
FROM clean.subscription_activity
WHERE upgrade_flag = 1 OR downgrade_flag = 1
ORDER BY subscription_id;
GO