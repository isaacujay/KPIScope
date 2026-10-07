/* 
   
   Profiling, integrity checks, and the five reconciliation queries used
   in Sprint 7. Run any section on its own.
    */

USE kpiscope;
GO

/* 
   1. Row counts across every layer
 */
SELECT 'accounts' AS tbl,
       (SELECT COUNT(*) FROM raw.accounts)   AS raw_rows,
       (SELECT COUNT(*) FROM staging.accounts)  AS staging_rows,
       (SELECT COUNT(*) FROM clean.accounts)   AS clean_rows,
       (SELECT COUNT(*) FROM mart.dim_account)   AS mart_rows
UNION ALL
SELECT 'subscriptions',
       (SELECT COUNT(*) FROM raw.subscriptions),
       (SELECT COUNT(*) FROM staging.subscriptions),
       (SELECT COUNT(*) FROM clean.subscription_activity),
       (SELECT COUNT(*) FROM mart.fact_subscription_activity)
UNION ALL
SELECT 'feature_usage',
       (SELECT COUNT(*) FROM raw.feature_usage),
       (SELECT COUNT(*) FROM staging.feature_usage),
       (SELECT COUNT(*) FROM clean.feature_usage),
       NULL
UNION ALL
SELECT 'support_tickets',
       (SELECT COUNT(*) FROM raw.support_tickets),
       (SELECT COUNT(*) FROM staging.support_tickets),
       (SELECT COUNT(*) FROM clean.support_tickets),
       (SELECT COUNT(*) FROM mart.fact_support_tickets)
UNION ALL
SELECT 'churn_events',
       (SELECT COUNT(*) FROM raw.churn_events),
       (SELECT COUNT(*) FROM staging.churn_events),
       (SELECT COUNT(*) FROM clean.churn_events),
       NULL;
GO

/* 
   2. Null / blank counts on raw tables (for Data_Quality_Report.md)
 */

 --accounts
SELECT 'accounts' AS tbl, 
       COUNT(*) AS total_rows,
       SUM(CASE WHEN NULLIF(TRIM(account_id), '')   IS NULL THEN 1 ELSE 0 END) AS null_account_id,
       SUM(CASE WHEN NULLIF(TRIM(signup_date), '')  IS NULL THEN 1 ELSE 0 END) AS null_signup_date,
       SUM(CASE WHEN NULLIF(TRIM(referral_source), '') IS NULL THEN 1 ELSE 0 END) AS null_referral_source,
       SUM(CASE WHEN NULLIF(TRIM(plan_tier), '')   IS NULL THEN 1 ELSE 0 END) AS null_plan_tier
FROM raw.accounts;

--subscriptions - >(4514 null end_date seen )
SELECT 'subscriptions' AS tbl, COUNT(*) AS total_rows,
       SUM(CASE WHEN NULLIF(TRIM(subscription_id), '') IS NULL THEN 1 ELSE 0 END) AS null_subscription_id,
       SUM(CASE WHEN NULLIF(TRIM(start_date), '')  IS NULL THEN 1 ELSE 0 END) AS null_start_date,
       SUM(CASE WHEN NULLIF(TRIM(end_date), '')  IS NULL THEN 1 ELSE 0 END) AS null_end_date,
       SUM(CASE WHEN NULLIF(TRIM(mrr_amount), '')  IS NULL THEN 1 ELSE 0 END) AS null_mrr_amount
FROM raw.subscriptions;

SELECT 'support_tickets' AS tbl,
       COUNT(*) AS total_rows,
       SUM(CASE WHEN NULLIF(TRIM(closed_at), '') IS NULL THEN 1 ELSE 0 END) AS null_closed_at,
       SUM(CASE WHEN NULLIF(TRIM(satisfaction_score), '')  IS NULL THEN 1 ELSE 0 END) AS null_satisfaction_score,
       CAST(100.0 * SUM(CASE WHEN NULLIF(TRIM(satisfaction_score), '') IS NULL THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,1)) AS pct_null_satisfaction
FROM raw.support_tickets;

SELECT 'churn_events' AS tbl, COUNT(*) AS total_rows,
       SUM(CASE WHEN NULLIF(TRIM(feedback_text), '') IS NULL THEN 1 ELSE 0 END) AS null_feedback_text,
       CAST(100.0 * SUM(CASE WHEN NULLIF(TRIM(feedback_text), '') IS NULL THEN 1 ELSE 0 END)
            / COUNT(*) AS DECIMAL(5,1))  AS pct_null_feedback
FROM raw.churn_events;
GO

/* 
   3. Grain checks: subscriptions are concurrent line items
*/
-- Distribution of subscription rows per account
SELECT subs_per_account, 
    COUNT(*) AS accounts
FROM (
    SELECT account_id,
        COUNT(*) AS subs_per_account
    FROM staging.subscriptions
    GROUP BY account_id
) x
GROUP BY subs_per_account
ORDER BY subs_per_account;
-- Maximum rows for a single account
SELECT MAX(c) AS max_subscriptions_per_account
FROM (SELECT COUNT(*) AS c FROM staging.subscriptions GROUP BY account_id) x;

-- Handoff test: does one row's end_date line up with another row's start_date?
-- (Expected: a handful of coincidences, i.e. no chained version history)
SELECT COUNT(*) AS handoff_matches
FROM staging.subscriptions a
JOIN staging.subscriptions b
  ON  a.account_id      = b.account_id
  AND a.subscription_id <> b.subscription_id
  AND b.start_date      = a.end_date;
GO

/* ---------------------------------------------------------------------
   4. Proxy sanity: do zero-MRR rows cluster under trials?
   --------------------------------------------------------------------- */
SELECT
    is_trial,
    upgrade_flag,
    downgrade_flag,
    COUNT(*)                                                    AS row_count,
    SUM(CASE WHEN mrr_amount = 0   THEN 1 ELSE 0 END)           AS zero_mrr_rows,
    SUM(CASE WHEN mrr_amount IS NULL THEN 1 ELSE 0 END)         AS null_mrr_rows
FROM staging.subscriptions
GROUP BY is_trial, upgrade_flag, downgrade_flag
ORDER BY is_trial, upgrade_flag, downgrade_flag;

-- ARR definition: how often does source arr_amount equal MRR x 12?
SELECT arr_equals_mrr_x12, COUNT(*) AS row_count
FROM clean.subscription_activity
GROUP BY arr_equals_mrr_x12;

-- MRR distribution (use to sanity-check the Low/Medium/High band cut-offs)
SELECT mrr_band, COUNT(*) AS row_count,
       MIN(mrr_amount) AS min_mrr, MAX(mrr_amount) AS max_mrr
FROM clean.subscription_activity
GROUP BY mrr_band
ORDER BY MIN(mrr_amount);
GO

/* 
   5. Data-quality log (everything flagged in staging and clean)
 */
SELECT stage, table_name, check_name, issue_count, note
FROM staging.dq_log
WHERE issue_count > 0
ORDER BY log_id;
GO

/* 
   6. Mart integrity checks (every issue_count should be 0)
 */
SELECT 'subscriptions lost between clean and fact' AS check_name,
       (SELECT COUNT(*) FROM clean.subscription_activity)
     - (SELECT COUNT(*) FROM mart.fact_subscription_activity) AS issue_count
UNION ALL
SELECT 'tickets lost between clean and fact',
       (SELECT COUNT(*) FROM clean.support_tickets)
     - (SELECT COUNT(*) FROM mart.fact_support_tickets)
UNION ALL
SELECT 'fact rows with NULL plan_key',    COUNT(*) FROM mart.fact_subscription_activity WHERE plan_key IS NULL
UNION ALL
SELECT 'fact rows with NULL channel_key', COUNT(*) FROM mart.fact_subscription_activity WHERE channel_key IS NULL
UNION ALL
SELECT 'fact rows with NULL period_date_key', COUNT(*) FROM mart.fact_subscription_activity WHERE period_date_key IS NULL
UNION ALL
SELECT 'orphaned account_key (subscriptions)', COUNT(*)
FROM mart.fact_subscription_activity f
WHERE NOT EXISTS (SELECT 1 FROM mart.dim_account d WHERE d.account_key = f.account_key)
UNION ALL
SELECT 'orphaned account_key (tickets)', COUNT(*)
FROM mart.fact_support_tickets f
WHERE NOT EXISTS (SELECT 1 FROM mart.dim_account d WHERE d.account_key = f.account_key)
UNION ALL
SELECT 'duplicate subscription_id in fact', COALESCE(SUM(c - 1), 0)
FROM (SELECT COUNT(*) AS c FROM mart.fact_subscription_activity GROUP BY subscription_id HAVING COUNT(*) > 1) x;
GO

/* 
   7. SPRINT 7 RECONCILIATION: the five KPIs
      Churn rate = distinct churned accounts / distinct accounts in the fact.
  */

-- KPI 1: Total MRR
SELECT SUM(mrr_amount) AS total_mrr
FROM mart.fact_subscription_activity;

-- KPI 2: Churn Rate
SELECT
    COUNT(DISTINCT CASE WHEN is_churned_flag = 1 THEN account_key END) AS churned_accounts,
    COUNT(DISTINCT account_key) AS total_accounts,
    CAST(COUNT(DISTINCT CASE WHEN is_churned_flag = 1 THEN account_key END) AS DECIMAL(18,6))
        / NULLIF(COUNT(DISTINCT account_key), 0) AS churn_rate
FROM mart.fact_subscription_activity;

-- KPI 3: Churn Rate by Referral Source
SELECT
    ch.referral_source,
    COUNT(DISTINCT f.account_key)                                            AS accounts,
    COUNT(DISTINCT CASE WHEN f.is_churned_flag = 1 THEN f.account_key END)   AS churned_accounts,
    CAST(COUNT(DISTINCT CASE WHEN f.is_churned_flag = 1 THEN f.account_key END) AS DECIMAL(18,6))
        / NULLIF(COUNT(DISTINCT f.account_key), 0)                           AS churn_rate
FROM mart.fact_subscription_activity f
JOIN mart.dim_channel ch ON ch.channel_key = f.channel_key
GROUP BY ch.referral_source
ORDER BY ch.referral_source;

-- KPI 4: Avg. Resolution Time (hours, nulls excluded automatically by AVG)
SELECT AVG(resolution_time_hours) AS avg_resolution_hours
FROM mart.fact_support_tickets;

-- KPI 5: Expansion MRR (PROXY, trial rows excluded)
SELECT SUM(expansion_mrr_proxy) AS expansion_mrr_proxy
FROM mart.fact_subscription_activity;
GO

/* 
   8. Extra baselines for the scorecard
    */

-- NRR (PROXY) = (Total MRR - Churned MRR + Expansion MRR proxy) / Total MRR
SELECT
    SUM(mrr_amount) AS starting_mrr,
    SUM(churned_mrr) AS churned_mrr,
    SUM(expansion_mrr_proxy) AS expansion_mrr_proxy,
    SUM(contraction_mrr_proxy) AS contraction_mrr_proxy,
    (SUM(mrr_amount) - SUM(churned_mrr) + SUM(expansion_mrr_proxy))
        / NULLIF(SUM(mrr_amount), 0) AS nrr_proxy
FROM mart.fact_subscription_activity;

-- Support load vs churn (correlation only, not causation)
SELECT
    a.support_load_flag,
    COUNT(*) AS accounts,
    SUM(a.is_churned_flag)  AS churned_accounts,
    CAST(100.0 * SUM(a.is_churned_flag) / COUNT(*) AS DECIMAL(5,1)) AS pct_churned
FROM clean.accounts a
GROUP BY a.support_load_flag;

-- Average satisfaction, excluding non-responses
SELECT AVG(satisfaction_score) AS avg_csat_responders_only
FROM mart.fact_support_tickets
WHERE satisfaction_score IS NOT NULL;
GO