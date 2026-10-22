/* =============================================================================
   01_create_database.sql
   Creates the HospitalOps database and its schemas.

   Schemas
     dbo  - operational tables
     stg  - ETL staging (05_etl_patient_import.sql)
     rpt  - reporting views (07_reporting_views.sql)

   Re-runnable: creates objects only if they don't already exist.
   ============================================================================= */

USE master;
GO

IF DB_ID(N'HospitalOps') IS NULL
BEGIN
    CREATE DATABASE HospitalOps;
END
GO

-- Snapshot isolation lets readers (reports) avoid blocking writers (admissions).
ALTER DATABASE HospitalOps SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
ALTER DATABASE HospitalOps SET QUERY_STORE = ON;          -- used by the performance/ benchmark and sniffing demo
ALTER DATABASE HospitalOps SET RECOVERY SIMPLE;           -- dev database: keep the log small during bulk loads
GO

USE HospitalOps;
GO

IF SCHEMA_ID(N'stg') IS NULL EXEC (N'CREATE SCHEMA stg AUTHORIZATION dbo;');
IF SCHEMA_ID(N'rpt') IS NULL EXEC (N'CREATE SCHEMA rpt AUTHORIZATION dbo;');
GO

PRINT N'01_create_database.sql completed.';
GO
