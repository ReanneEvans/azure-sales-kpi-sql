/* ----------------------------------------------------------------------
   Automated Daily Sales KPI – SQL Setup (Portfolio-safe)
   Author: You
   Notes:
     - Replace placeholders before running:
         <DB_NAME>, <BLOB_URL>, <SAS_TOKEN>, <MASTER_KEY_PASSWORD>
     - This script creates:
         dbo.Sales (with indexes)
         Views: vw_SalesDaily, vw_SalesDailyByCategory
         Config: KPI_Config (for MarginRate)
         Proc: dbo.GetDailyKpiSummary (resilient)
---------------------------------------------------------------------- */

-----------------------------------------------------------------------
-- 0) Set database context
-----------------------------------------------------------------------
USE [<DB_NAME>];
GO

-----------------------------------------------------------------------
-- 1) Security: Database Master Key  (DEV ONLY – use Key Vault in prod)
-----------------------------------------------------------------------
IF NOT EXISTS (
  SELECT 1 FROM sys.symmetric_keys
  WHERE name = '##MS_DatabaseMasterKey##'
)
BEGIN
  CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<MASTER_KEY_PASSWORD>';
END
GO

-----------------------------------------------------------------------
-- 2) External Access: Credential + External Data Source to Blob
--    (Placeholders only; DO NOT commit real secrets)
-----------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = 'MyBlobCred')
  DROP DATABASE SCOPED CREDENTIAL MyBlobCred;
GO
CREATE DATABASE SCOPED CREDENTIAL MyBlobCred
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
     SECRET   = '<SAS_TOKEN>';  -- e.g. sv=...&sig=... (short-lived!)
GO

IF EXISTS (SELECT 1 FROM sys.external_data_sources WHERE name = 'MyBlob')
  DROP EXTERNAL DATA SOURCE MyBlob;
GO
CREATE EXTERNAL DATA SOURCE MyBlob
WITH (
  TYPE      = BLOB_STORAGE,
  LOCATION  = '<BLOB_URL>',     -- e.g. https://acct.blob.core.windows.net/salesdata
  CREDENTIAL = MyBlobCred
);
GO

-----------------------------------------------------------------------
-- 3) Core Table: dbo.Sales
-----------------------------------------------------------------------
IF OBJECT_ID('dbo.Sales') IS NOT NULL
  DROP TABLE dbo.Sales;
GO
CREATE TABLE dbo.Sales (
  TransactionID   BIGINT        NOT NULL PRIMARY KEY,
  TxnDate         DATE          NOT NULL,
  CustomerID      NVARCHAR(50)  NULL,
  Gender          NVARCHAR(20)  NULL,
  Age             INT           NULL,
  ProductCategory NVARCHAR(100) NOT NULL,
  Quantity        INT           NOT NULL CHECK (Quantity >= 0),
  PricePerUnit    DECIMAL(12,2) NOT NULL CHECK (PricePerUnit >= 0),
  TotalAmount     DECIMAL(14,2) NOT NULL CHECK (TotalAmount >= 0)
);
GO

-- Helpful indexes for later KPI queries
CREATE INDEX IX_Sales_TxnDate         ON dbo.Sales (TxnDate);
CREATE INDEX IX_Sales_ProductCategory ON dbo.Sales (ProductCategory);
GO

-----------------------------------------------------------------------
-- 4) Bulk Load Sample Data from Blob (CSV file in the container)
-----------------------------------------------------------------------
BULK INSERT dbo.Sales
FROM 'retail_sales_dataset.csv'   -- exact blob filename
WITH (
  DATA_SOURCE = 'MyBlob',
  FORMAT      = 'CSV',
  FIRSTROW    = 2                 -- skip header
);
GO

-- Quick validation (safe to leave in script)
SELECT COUNT(*) AS RowsLoaded FROM dbo.Sales;
SELECT TOP 10 * FROM dbo.Sales ORDER BY TxnDate DESC, TransactionID DESC;
GO

-----------------------------------------------------------------------
-- 5) KPI Views
-----------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_SalesDaily AS
SELECT
  TxnDate,
  SUM(TotalAmount)                AS Revenue,
  COUNT(DISTINCT TransactionID)   AS Orders
FROM dbo.Sales
GROUP BY TxnDate;
GO

CREATE OR ALTER VIEW dbo.vw_SalesDailyByCategory AS
SELECT
  TxnDate,
  ProductCategory,
  SUM(TotalAmount) AS Revenue
FROM dbo.Sales
GROUP BY TxnDate, ProductCategory;
GO

-- View checks
SELECT TOP 10 * FROM dbo.vw_SalesDaily ORDER BY TxnDate DESC;
SELECT TOP 10 * FROM dbo.vw_SalesDailyByCategory ORDER BY TxnDate DESC, Revenue DESC;
GO

-----------------------------------------------------------------------
-- 6) Config Table (for margin rate, etc.)
-----------------------------------------------------------------------
IF OBJECT_ID('dbo.KPI_Config') IS NULL
BEGIN
  CREATE TABLE dbo.KPI_Config (
    ConfigKey   SYSNAME        PRIMARY KEY,
    ConfigValue DECIMAL(10,4)  NOT NULL
  );

  INSERT INTO dbo.KPI_Config (ConfigKey, ConfigValue)
  VALUES ('MarginRate', 0.3000);  -- 30%
END
ELSE
BEGIN
  -- Ensure MarginRate exists
  MERGE dbo.KPI_Config AS t
  USING (SELECT 'MarginRate' AS ConfigKey, CAST(0.3000 AS DECIMAL(10,4)) AS ConfigValue) s
  ON t.ConfigKey = s.ConfigKey
  WHEN NOT MATCHED THEN INSERT (ConfigKey, ConfigValue) VALUES (s.ConfigKey, s.ConfigValue);
END
GO

SELECT * FROM dbo.KPI_Config;
GO

-----------------------------------------------------------------------
-- 7) Stored Procedure: dbo.GetDailyKpiSummary (resilient)
--    Accepts text date; trims ISO timestamps; returns safe row for bad input
-----------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.GetDailyKpiSummary
  @ReportDate NVARCHAR(50)   -- text from automation
AS
BEGIN
  SET NOCOUNT ON;

  -- 1) Normalize input
  DECLARE @txt NVARCHAR(50) =
    REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(@ReportDate,''))), CHAR(13), ''), CHAR(10), '');
  IF CHARINDEX('T', @txt) > 0 SET @txt = LEFT(@txt, 10); -- keep yyyy-MM-dd if ISO
  DECLARE @d DATE = TRY_CONVERT(DATE, @txt, 23);         -- 23 = yyyy-MM-dd

  -- 2) If invalid, return a single safe row (no RAISERROR for automation)
  IF @d IS NULL
  BEGIN
    SELECT
      CAST(NULL AS DATE)            AS ReportDate,
      CAST(0    AS DECIMAL(14,2))   AS TotalRevenue,
      CAST(0    AS INT)             AS TotalOrders,
      CAST(0.0  AS DECIMAL(14,6))   AS AvgOrderValue,
      CAST(0    AS DECIMAL(14,2))   AS EstimatedMargin,
      N'Invalid ReportDate'         AS TopCategory,
      CAST(0    AS DECIMAL(14,2))   AS TopCategoryRevenue;
    RETURN;
  END

  -- 3) Fetch config
  DECLARE @MarginRate DECIMAL(5,4) =
    (SELECT ConfigValue FROM dbo.KPI_Config WHERE ConfigKey='MarginRate');

  -- 4) KPI calc (views ensure aggregation is simple)
  ;WITH kpi AS (
    SELECT
      d.TxnDate,
      d.Revenue,
      d.Orders,
      CASE WHEN d.Orders = 0 THEN 0 ELSE d.Revenue * 1.0 / d.Orders END AS AvgOrderValue,
      CAST(d.Revenue * @MarginRate AS DECIMAL(14,2)) AS Margin
    FROM dbo.vw_SalesDaily d
    WHERE d.TxnDate = @d
  ),
  topcat AS (
    SELECT TOP (1)
      s.ProductCategory,
      s.Revenue AS TopCategoryRevenue
    FROM dbo.vw_SalesDailyByCategory s
    WHERE s.TxnDate = @d
    ORDER BY s.Revenue DESC, s.ProductCategory ASC
  )
  -- 5) Always return exactly one row (ISNULL for no-sales days)
  SELECT
    @d                                  AS ReportDate,
    ISNULL(k.Revenue, 0)                AS TotalRevenue,
    ISNULL(k.Orders, 0)                 AS TotalOrders,
    ISNULL(k.AvgOrderValue, 0.0)        AS AvgOrderValue,
    ISNULL(k.Margin, 0)                 AS EstimatedMargin,
    ISNULL(t.ProductCategory, N'No data')  AS TopCategory,
    ISNULL(t.TopCategoryRevenue, 0)     AS TopCategoryRevenue
  FROM (VALUES(1)) AS one(x)
  LEFT JOIN kpi   k ON 1=1
  LEFT JOIN topcat t ON 1=1;
END;
GO

-----------------------------------------------------------------------
-- 8) Sanity checks for the proc (pick a real date from your data)
-----------------------------------------------------------------------
SELECT TOP 5 TxnDate FROM dbo.Sales ORDER BY TxnDate DESC;
EXEC dbo.GetDailyKpiSummary @ReportDate = '2023-12-29';
EXEC dbo.GetDailyKpiSummary @ReportDate = '2023-12-29T07:00:00Z'; -- ISO timestamp
EXEC dbo.GetDailyKpiSummary @ReportDate = 'not-a-date';            -- invalid input
GO
