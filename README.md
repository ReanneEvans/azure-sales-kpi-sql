# Azure Sales KPI (SQL Only)

## 📌 Overview
This repository contains the **SQL code** for the *Automated Daily Sales KPI Report* project.  
The database schema, views, config table, and stored procedure form the backend for an Azure-based automation that delivers a styled KPI email every morning.

👉 The automation/orchestration (Logic Apps) is described in my [portfolio case study](your-notion-link-here).  
This repo focuses only on the **SQL layer**.

---

## ⚙️ What’s Included
- `setup.sql` → Creates the schema (`dbo.Sales`), loads sample data, defines views, config table, and stored procedure.  
- Sample queries at the bottom of the script → row count, sample data, view outputs, stored procedure results.  

---

## 📊 Example Output
The stored procedure `dbo.GetDailyKpiSummary` generates a daily KPI summary including:  

- Total Revenue  
- Total Orders  
- Average Order Value  
- Estimated Margin (from config table)  
- Top Category + Revenue  

Example (for 2023-12-29):  

| ReportDate | TotalRevenue | TotalOrders | AvgOrderValue | EstimatedMargin | TopCategory | TopCategoryRevenue |
|------------|--------------|-------------|---------------|-----------------|-------------|---------------------|
| 2023-12-29 | 10,200.50    | 94          | 108.52        | 3,060.15        | Windows     | 5,400.00           |

---

## 🚀 How to Use
1. Deploy an **Azure SQL Database** (or use local SQL Server).  
2. Open `setup.sql` in **SSMS** or **Azure Data Studio**.  
3. Replace placeholders (`<DB_NAME>`, `<BLOB_URL>`, `<SAS_TOKEN>`) with your own values.  
4. Run the script to create the table, views, config table, and stored procedure.  
5. Test with the sample queries included at the bottom of the script.  

---

## 🛠️ Placeholders in setup.sql
The script uses placeholders so no secrets are published in this repo.  
Replace them with your own values before running:

- `<DB_NAME>` → Your Azure SQL Database name  
- `<MASTER_KEY_PASSWORD>` → A strong password for the database master key  
- `<BLOB_URL>` → The URL of your Azure Blob Storage container  
- `<SAS_TOKEN>` → A valid Shared Access Signature token (short-lived for security)  

⚠️ **Important:** Never commit your real passwords, tokens, or keys to GitHub.  
In production, store them in **Azure Key Vault** instead of inline SQL.  

## 🔐 Security Notes
- No secrets are stored in this repo.  
- Replace `<SAS_TOKEN>` and `<BLOB_URL>` placeholders with your own secure values.  
- In production, manage secrets with **Azure Key Vault** instead of inline SQL.  

---

## 💡 Key Learnings
- Designing KPI-ready schemas and views in SQL.  
- Using config tables for flexible, non-hardcoded business logic.  
- Writing robust stored procedures that handle invalid dates and no-data days.  
- Preparing SQL outputs for cloud automation (Azure Logic Apps).  
