/* =====================================================================

   LAYER    : KPI layer on top of the mart star schema
   PIPELINE : raw -> staging -> clean -> mart -> [ kpi views ]  <-- here

   PURPOSE
     Gives KPIScope a MEASURED MRR bridge (new / expansion / contraction /
     churn) plus NRR, GRR and logo churn. It replaces the proxy-based
     expansion/contraction/NRR with figures built from account-level MRR
     compared month to month.

     Why this works when LAG() per subscription did not:
     subscription rows are concurrent line items, so there is no prior
     version of one subscription to compare against. Summing all of an
     account's open lines into ONE MRR figure per account per month gives a
     real series to compare. A new add-on line is genuine expansion; a
     closed line is genuine contraction.

   VIEWS (schema: kpi)
     1. vw_account_monthly_mrr  - MRR + seats per account per month
     2. vw_account_mrr_movement - New / Expansion / Contraction / Churn per account-month
     3. vw_mrr_movement         - Monthly MRR bridge, NRR, GRR, logo churn
     4. vw_monthly_mrr          - Monthly MRR, ARR, active accounts, ARPA, MoM growth

   DEFINITIONS
     ARR  = MRR x 12 (matches the arr_equals_mrr_x12 check in 04)
     NRR  = (Opening + Expansion - Contraction - Churn) / Opening
     GRR  = (Opening - Contraction - Churn) / Opening
     Logo churn = churned accounts / opening accounts
     New MRR includes reactivations (an account returning after a gap).
     Trial rows (is_trial = 1) are excluded: they do not generate MRR.

   ASSUMPTION TO VERIFY (see section 6)
     start_date / end_date on subscriptions represent real billing periods.
     Section 6 compares these measured figures with the proxy columns so the
     team can see how far apart they are.

   RULES KEPT
     - Reads ONLY from mart. Python and Power BI still calculate their own
       KPIs from mart; these views are an additional SQL cross-check, not a
       replacement for the Sprint 7 reconciliation.
     - Re-runnable: CREATE OR ALTER everywhere, guarded ALTER TABLE.
   ===================================================================== */

USE kpiscope;
GO

/* ---------------------------------------------------------------------
   0. Prerequisite: the mart fact needs the subscription start and end dates.
      (Adds the columns if missing and back-fills them from clean.)
      Also add start_date / end_date to fact_subscription_activity in
      05_mart_star_schema.sql so a full rebuild keeps them.
   --------------------------------------------------------------------- */
IF COL_LENGTH('mart.fact_subscription_activity', 'start_date') IS NULL
    ALTER TABLE mart.fact_subscription_activity ADD start_date DATE NULL;

IF COL_LENGTH('mart.fact_subscription_activity', 'end_date') IS NULL
    ALTER TABLE mart.fact_subscription_activity ADD end_date DATE NULL;
GO

UPDATE f
SET    f.start_date = s.start_date,
       f.end_date   = s.end_date
FROM   mart.fact_subscription_activity AS f
JOIN   clean.subscription_activity     AS s
       ON s.subscription_id = f.subscription_id;
GO

/* ---------------------------------------------------------------------
   0b. Schema (CREATE SCHEMA must be alone in its batch, hence EXEC)
   --------------------------------------------------------------------- */
IF SCHEMA_ID(N'kpi') IS NULL
    EXEC (N'CREATE SCHEMA kpi');
GO

/* ---------------------------------------------------------------------
   1. kpi.vw_account_monthly_mrr
      Grain : one row per account per calendar month with paying MRR (> 0).
      Logic : a subscription counts toward a month if it started on or before
              the month's last day AND (has no end date OR ended on/after the
              month's first day). Concurrent lines of one account are summed.
      Months: from the first start_date month to the latest start/end month.
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW kpi.vw_account_monthly_mrr
AS
WITH bounds AS (
    SELECT  MIN(start_date)                    AS min_date,
            MAX(start_date)                    AS max_start,
            MAX(COALESCE(end_date, start_date)) AS max_end
    FROM    mart.fact_subscription_activity
    WHERE   COALESCE(is_trial, 0) = 0
      AND   start_date IS NOT NULL
),
months AS (
    SELECT DISTINCT
           d.month_start_date            AS month_start,
           EOMONTH(d.month_start_date)   AS month_end
    FROM   mart.dim_date AS d
    CROSS JOIN bounds AS b
    WHERE  d.month_start_date >= DATEFROMPARTS(YEAR(b.min_date), MONTH(b.min_date), 1)
      AND  d.month_start_date <= CASE WHEN b.max_end > b.max_start THEN b.max_end ELSE b.max_start END
)
SELECT  f.account_key,
        m.month_start,
        SUM(f.mrr_amount) AS mrr,
        SUM(f.seats)      AS seats
FROM    mart.fact_subscription_activity AS f
JOIN    months AS m
        ON  f.start_date <= m.month_end
        AND (f.end_date IS NULL OR f.end_date >= m.month_start)
WHERE   COALESCE(f.is_trial, 0) = 0
  AND   f.start_date IS NOT NULL
GROUP BY f.account_key, m.month_start
HAVING  SUM(COALESCE(f.mrr_amount, 0)) > 0;
GO

/* ---------------------------------------------------------------------
   2. kpi.vw_account_mrr_movement
      Grain : one row per account per month where MRR existed this month OR
              last month.
      Categories
        New         : last month 0, this month > 0 (includes reactivations)
        Churn       : last month > 0, this month 0
        Expansion   : both > 0 and MRR went up
        Contraction : both > 0 and MRR went down
        Unchanged   : both > 0 and MRR identical
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW kpi.vw_account_mrr_movement
AS
WITH paired AS (
    -- FULL OUTER JOIN against the previous month keeps accounts that existed
    -- last month but vanished this month (the churn rows).
    SELECT  COALESCE(c.account_key, p.account_key)                    AS account_key,
            COALESCE(c.month_start, DATEADD(MONTH, 1, p.month_start)) AS month_start,
            ISNULL(p.mrr, 0)                                          AS prev_mrr,
            ISNULL(c.mrr, 0)                                          AS cur_mrr
    FROM    kpi.vw_account_monthly_mrr AS c
    FULL OUTER JOIN kpi.vw_account_monthly_mrr AS p
            ON  p.account_key = c.account_key
            AND p.month_start = DATEADD(MONTH, -1, c.month_start)
)
SELECT  account_key,
        month_start,
        prev_mrr,
        cur_mrr,
        CASE WHEN prev_mrr = 0 AND cur_mrr > 0 THEN cur_mrr ELSE 0 END                   AS new_mrr,
        CASE WHEN prev_mrr > 0 AND cur_mrr > prev_mrr THEN cur_mrr - prev_mrr ELSE 0 END AS expansion_mrr,
        CASE WHEN prev_mrr > 0 AND cur_mrr > 0 AND cur_mrr < prev_mrr
             THEN prev_mrr - cur_mrr ELSE 0 END                                          AS contraction_mrr,
        CASE WHEN prev_mrr > 0 AND cur_mrr = 0 THEN prev_mrr ELSE 0 END                  AS churned_mrr,
        CASE
            WHEN prev_mrr = 0 AND cur_mrr > 0 THEN 'New'
            WHEN prev_mrr > 0 AND cur_mrr = 0 THEN 'Churn'
            WHEN cur_mrr > prev_mrr           THEN 'Expansion'
            WHEN cur_mrr < prev_mrr           THEN 'Contraction'
            ELSE 'Unchanged'
        END                                                                              AS movement_type
FROM    paired
-- Do not emit a trailing month beyond the last month that has any MRR.
WHERE   month_start <= (SELECT MAX(month_start) FROM kpi.vw_account_monthly_mrr);
GO

/* ---------------------------------------------------------------------
   3. kpi.vw_mrr_movement
      Grain : one row per month (company level).
      Gives : the MRR bridge (opening + new + expansion - contraction -
              churn = closing) and the retention KPIs.
      NOTE  : New MRR is excluded from NRR/GRR by design. Retention looks
              only at the customers you already had at the start of the month.
              bridge_check must be 0 in every month.
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW kpi.vw_mrr_movement
AS
SELECT  month_start,

        -- MRR bridge
        SUM(prev_mrr)        AS opening_mrr,
        SUM(new_mrr)         AS new_mrr,
        SUM(expansion_mrr)   AS expansion_mrr,
        SUM(contraction_mrr) AS contraction_mrr,
        SUM(churned_mrr)     AS churned_mrr,
        SUM(cur_mrr)         AS closing_mrr,
        SUM(prev_mrr) + SUM(new_mrr) + SUM(expansion_mrr)
          - SUM(contraction_mrr) - SUM(churned_mrr) - SUM(cur_mrr) AS bridge_check,

        -- Account counts
        SUM(CASE WHEN prev_mrr > 0 THEN 1 ELSE 0 END)            AS opening_accounts,
        SUM(CASE WHEN movement_type = 'New'   THEN 1 ELSE 0 END) AS new_accounts,
        SUM(CASE WHEN movement_type = 'Churn' THEN 1 ELSE 0 END) AS churned_accounts,
        SUM(CASE WHEN cur_mrr > 0 THEN 1 ELSE 0 END)             AS closing_accounts,

        -- Retention KPIs (percentages, 2 decimals)
        CAST(100.0 * (SUM(prev_mrr) + SUM(expansion_mrr) - SUM(contraction_mrr) - SUM(churned_mrr))
             / NULLIF(SUM(prev_mrr), 0) AS DECIMAL(9,2)) AS nrr_pct,
        CAST(100.0 * (SUM(prev_mrr) - SUM(contraction_mrr) - SUM(churned_mrr))
             / NULLIF(SUM(prev_mrr), 0) AS DECIMAL(9,2)) AS grr_pct,
        CAST(100.0 * SUM(CASE WHEN movement_type = 'Churn' THEN 1 ELSE 0 END)
             / NULLIF(SUM(CASE WHEN prev_mrr > 0 THEN 1 ELSE 0 END), 0) AS DECIMAL(9,2)) AS logo_churn_pct,
        CAST(100.0 * SUM(churned_mrr)
             / NULLIF(SUM(prev_mrr), 0) AS DECIMAL(9,2)) AS revenue_churn_pct
FROM    kpi.vw_account_mrr_movement
GROUP BY month_start;
GO

/* ---------------------------------------------------------------------
   4. kpi.vw_monthly_mrr
      Grain : one row per month.
      Gives : MRR, ARR (MRR x 12), active paying accounts, ARPA, revenue per
              seat, and month-over-month MRR growth.
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW kpi.vw_monthly_mrr
AS
WITH monthly AS (
    SELECT  month_start,
            SUM(mrr)                    AS mrr,
            COUNT(DISTINCT account_key) AS active_accounts,
            SUM(seats)                  AS total_seats
    FROM    kpi.vw_account_monthly_mrr
    GROUP BY month_start
)
SELECT  month_start,
        mrr,
        mrr * 12                                                AS arr,
        active_accounts,
        total_seats,
        CAST(mrr / NULLIF(active_accounts, 0) AS DECIMAL(12,2)) AS arpa,
        CAST(mrr / NULLIF(total_seats, 0)     AS DECIMAL(12,2)) AS revenue_per_seat,
        CAST(100.0 * (mrr - LAG(mrr) OVER (ORDER BY month_start))
             / NULLIF(LAG(mrr) OVER (ORDER BY month_start), 0) AS DECIMAL(9,2)) AS mrr_mom_growth_pct
FROM    monthly;
GO

/* 
   5. Access for the read-only login (if 05 created it)
  */
IF DATABASE_PRINCIPAL_ID(N'kpiscope_reader') IS NOT NULL
    GRANT SELECT ON SCHEMA::kpi TO kpiscope_reader;
GO

/* =====================================================================
   6. VALIDATION (run after the script)
   ===================================================================== */

-- 6a. Date sanity on the mart fact (all should be low / explainable)
SELECT 'subscriptions with NULL start_date'  AS check_name, COUNT(*) AS issue_count
FROM   mart.fact_subscription_activity WHERE start_date IS NULL
UNION ALL
SELECT 'subscriptions ending before start',  COUNT(*)
FROM   mart.fact_subscription_activity WHERE end_date < start_date
UNION ALL
SELECT 'open subscriptions (no end_date)',   COUNT(*)
FROM   mart.fact_subscription_activity WHERE end_date IS NULL
UNION ALL
SELECT 'trial rows excluded from kpi views', COUNT(*)
FROM   mart.fact_subscription_activity WHERE is_trial = 1;

-- 6b. Bridge integrity: bad_months must be 0
SELECT COUNT(*) AS months_checked,
       SUM(CASE WHEN bridge_check <> 0 THEN 1 ELSE 0 END) AS bad_months
FROM   kpi.vw_mrr_movement;

-- 6c. Latest month: view MRR vs an independent direct calculation (must match)
WITH last_month AS (
    SELECT MAX(month_start) AS month_start FROM kpi.vw_monthly_mrr
)
SELECT  l.month_start,
        v.mrr AS view_mrr,
        (SELECT SUM(f.mrr_amount)
         FROM   mart.fact_subscription_activity f
         WHERE  COALESCE(f.is_trial, 0) = 0
           AND  f.start_date <= EOMONTH(l.month_start)
           AND  (f.end_date IS NULL OR f.end_date >= l.month_start)) AS direct_mrr
FROM    last_month l
JOIN    kpi.vw_monthly_mrr v ON v.month_start = l.month_start;

-- 6d. MEASURED vs PROXY: how far apart are they?
--     Measured = sum of monthly account-level movements (flows over time).
--     Proxy    = full mrr_amount of flagged / churned line items.
--     A large gap means the proxy figures on the scorecard are misleading.
SELECT 'Expansion MRR' AS component,
       (SELECT SUM(expansion_mrr)   FROM kpi.vw_mrr_movement)                  AS measured_total,
       (SELECT SUM(expansion_mrr_proxy)   FROM mart.fact_subscription_activity) AS proxy_total
UNION ALL
SELECT 'Contraction MRR',
       (SELECT SUM(contraction_mrr) FROM kpi.vw_mrr_movement),
       (SELECT SUM(contraction_mrr_proxy) FROM mart.fact_subscription_activity)
UNION ALL
SELECT 'Churned MRR',
       (SELECT SUM(churned_mrr)     FROM kpi.vw_mrr_movement),
       (SELECT SUM(churned_mrr)           FROM mart.fact_subscription_activity);

-- 6e. Smoke tests
SELECT TOP (5) * FROM kpi.vw_monthly_mrr  ORDER BY month_start DESC;
SELECT TOP (5) * FROM kpi.vw_mrr_movement ORDER BY month_start DESC;
SELECT movement_type, COUNT(*) AS account_months, SUM(cur_mrr) AS cur_mrr
FROM   kpi.vw_account_mrr_movement
GROUP BY movement_type
ORDER BY movement_type;
GO