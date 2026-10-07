/* 

   02_injection.sql
   Loads the 5 CSV files into raw.* exactly as received. No transformation.

   BEFORE RUNNING:
   1. Put the 5 CSVs in one folder the SQL Server SERVICE can read.
     
   2. Edit @base below if you use a different folder (keep trailing \).

   FORMAT = 'CSV' + FIELDQUOTE handles commas inside quoted text
   such as churn_events.feedback_text.

*/

USE kpiscope;
GO

SET NOCOUNT ON;

DECLARE @base NVARCHAR(260) = N'C:\Users\ujay\Desktop\desktop\Data Projects\KPIScope\data\raw\';

DECLARE @files TABLE (tbl SYSNAME, file_name NVARCHAR(100));
INSERT INTO @files (tbl, file_name) VALUES
    (N'accounts',        N'accounts.csv'),
    (N'subscriptions',   N'subscriptions.csv'),
    (N'feature_usage',   N'feature_usage.csv'),
    (N'support_tickets', N'support_tickets.csv'),
    (N'churn_events',    N'churn_events.csv');

DECLARE @tbl SYSNAME, @file NVARCHAR(100), @sql NVARCHAR(MAX);

DECLARE load_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT tbl, file_name FROM @files;

OPEN load_cur;
FETCH NEXT FROM load_cur INTO @tbl, @file;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql =
          N'TRUNCATE TABLE raw.' + QUOTENAME(@tbl) + N'; '
        + N'BULK INSERT raw.' + QUOTENAME(@tbl)
        + N' FROM ''' + @base + @file + N''' '
        + N'WITH (FORMAT = ''CSV'', FIELDQUOTE = ''"'', FIRSTROW = 2, '
        + N'CODEPAGE = ''65001'', TABLOCK);';

    PRINT N'Loading ' + @tbl + N' from ' + @base + @file;
    EXEC sys.sp_executesql @sql;

    FETCH NEXT FROM load_cur INTO @tbl, @file;
END

CLOSE load_cur;
DEALLOCATE load_cur;
GO

-- Gate check: row counts must match the source exactly 
SELECT  x.table_name,
        x.expected_rows,
        x.actual_rows,
        CASE WHEN x.expected_rows = x.actual_rows THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
    SELECT 'accounts' AS table_name,        500   AS expected_rows, (SELECT COUNT(*) FROM raw.accounts)        AS actual_rows
    UNION ALL
    SELECT 'subscriptions',                 5000,                   (SELECT COUNT(*) FROM raw.subscriptions)
    UNION ALL
    SELECT 'feature_usage',                 25000,                  (SELECT COUNT(*) FROM raw.feature_usage)
    UNION ALL
    SELECT 'support_tickets',               2000,                   (SELECT COUNT(*) FROM raw.support_tickets)
    UNION ALL
    SELECT 'churn_events',                  600,                    (SELECT COUNT(*) FROM raw.churn_events)
) x;
GO

-- Quick eyeball of the first rows
SELECT TOP (3) * FROM raw.accounts;
SELECT TOP (3) * FROM raw.subscriptions;
SELECT TOP (3) * FROM raw.feature_usage;
SELECT TOP (3) * FROM raw.support_tickets;
SELECT TOP (3) * FROM raw.churn_events;
GO