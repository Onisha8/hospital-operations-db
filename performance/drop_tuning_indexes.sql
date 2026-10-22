/* =============================================================================
   performance/drop_tuning_indexes.sql
   Removes every performance index (named IX_*) from dbo tables, returning the
   database to its constraint-only baseline for a "before" benchmark.

   Indexes that enforce rules (PK_*, UQ_*, UX_*) are never touched.
   Re-apply the tuning indexes with sql/09_performance_indexes.sql.
   ============================================================================= */

USE HospitalOps;
GO
SET NOCOUNT ON;

DECLARE @sql NVARCHAR(MAX) = N'';
SELECT @sql += CONCAT(N'DROP INDEX ', QUOTENAME(i.name), N' ON ', QUOTENAME(s.name), N'.', QUOTENAME(t.name), N';', CHAR(10))
FROM sys.indexes i
JOIN sys.tables  t ON t.object_id = i.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = N'dbo' AND i.name LIKE N'IX[_]%' AND i.is_primary_key = 0 AND i.is_unique_constraint = 0;

EXEC sys.sp_executesql @sql;
PRINT CONCAT(N'Dropped ', (LEN(@sql) - LEN(REPLACE(@sql, CHAR(10), N''))), N' tuning index(es).');
GO
