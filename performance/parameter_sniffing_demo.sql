/* =============================================================================
   performance/parameter_sniffing_demo.sql
   Parameter sniffing, OPTION (RECOMPILE), index hints and Query Store,
   measured on NurseCareEvent (~467k rows).

   Setup: a deliberately NON-covering index on EventAt (demo only). For a narrow
   time range the best plan is Index Seek + Key Lookup (a few rows). For a wide
   range it's a Clustered Index Scan: hundreds of thousands of key lookups cost
   far more than reading the table once.

   A procedure compiles its plan for the parameter values of its FIRST call
   ("sniffing") and reuses that plan for every later call.

     Scenario A  narrow call first -> seek plan cached -> wide call reuses it   (bad)
     Scenario B  wide call first   -> scan plan cached -> narrow call reuses it (wasteful)
     Scenario C  OPTION (RECOMPILE): a fresh plan per call                      (fix)
     Scenario D  WITH (INDEX(...)) forces the seek on the wide range            (why hints are risky)
     Query Store shows the same query with two plans and their costs.

   Read-only on business data. Demo objects are dropped at the end.
   Run:  .\run_sql.ps1 -Files performance\parameter_sniffing_demo.sql
   ============================================================================= */

USE HospitalOps;
GO
SET NOCOUNT ON;

IF SCHEMA_ID(N'perf') IS NULL EXEC (N'CREATE SCHEMA perf AUTHORIZATION dbo;');
GO

DROP INDEX IF EXISTS IX_Demo_NurseCareEvent_EventAt ON dbo.NurseCareEvent;
CREATE INDEX IX_Demo_NurseCareEvent_EventAt ON dbo.NurseCareEvent (EventAt);   -- not covering: Notes, NurseID... need lookups
GO

-- The procedure under test: an ordinary range query
CREATE OR ALTER PROCEDURE perf.usp_EventsInRange @From DATETIME2(0), @To DATETIME2(0)
AS
    SELECT CareEventID, AdmissionID, NurseID, EventTypeCode, EventAt, Notes
    INTO #sink
    FROM dbo.NurseCareEvent
    WHERE EventAt >= @From AND EventAt < @To;
GO
-- Same query with OPTION (RECOMPILE): compiled for the actual values on every call
CREATE OR ALTER PROCEDURE perf.usp_EventsInRange_Recompile @From DATETIME2(0), @To DATETIME2(0)
AS
    SELECT CareEventID, AdmissionID, NurseID, EventTypeCode, EventAt, Notes
    INTO #sink
    FROM dbo.NurseCareEvent
    WHERE EventAt >= @From AND EventAt < @To
    OPTION (RECOMPILE);
GO
-- Same query with a forced index hint
CREATE OR ALTER PROCEDURE perf.usp_EventsInRange_ForcedSeek @From DATETIME2(0), @To DATETIME2(0)
AS
    SELECT CareEventID, AdmissionID, NurseID, EventTypeCode, EventAt, Notes
    INTO #sink
    FROM dbo.NurseCareEvent WITH (INDEX (IX_Demo_NurseCareEvent_EventAt))
    WHERE EventAt >= @From AND EventAt < @To;
GO

-- Measures one call: logical reads, CPU, elapsed, and the plan shape from the cached plan.
CREATE OR ALTER PROCEDURE #measure
    @scenario NVARCHAR(60), @call NVARCHAR(40), @proc SYSNAME, @From DATETIME2(0), @To DATETIME2(0)
AS
BEGIN
    DECLARE @r0 BIGINT, @c0 BIGINT, @t0 DATETIME2(7), @sql NVARCHAR(200) = N'EXEC ' + @proc + N' @From, @To;';
    -- counted BEFORE the measurement window so its reads aren't included
    DECLARE @rows INT = (SELECT COUNT(*) FROM dbo.NurseCareEvent WHERE EventAt >= @From AND EventAt < @To);
    SELECT @r0 = logical_reads, @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    SET @t0 = SYSDATETIME();
    EXEC sp_executesql @sql, N'@From DATETIME2(0), @To DATETIME2(0)', @From, @To;
    INSERT #demo (Scenario, CallDesc, RowsInRange, LogicalReads, CpuMs, ElapsedMs, PlanShape)
    SELECT @scenario, @call, @rows,
           r.logical_reads - @r0, r.cpu_time - @c0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()),
           ISNULL((SELECT TOP (1) CASE WHEN CAST(qp.query_plan AS NVARCHAR(MAX)) LIKE N'%Lookup="1"%' THEN N'Index Seek + Key Lookup'
                                       ELSE N'Clustered Index Scan' END
                   FROM sys.dm_exec_procedure_stats ps CROSS APPLY sys.dm_exec_query_plan(ps.plan_handle) qp
                   WHERE ps.object_id = OBJECT_ID(@proc) AND ps.database_id = DB_ID()), N'(not cached: recompiled)')
    FROM sys.dm_exec_requests r WHERE r.session_id = @@SPID;
END;
GO

DROP TABLE IF EXISTS #demo;
CREATE TABLE #demo (Step INT IDENTITY, Scenario NVARCHAR(60), CallDesc NVARCHAR(40), RowsInRange INT,
                    LogicalReads BIGINT, CpuMs INT, ElapsedMs INT, PlanShape NVARCHAR(40));

DECLARE @Now DATETIME2(0) = DATEADD(DAY, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME2(0)));
DECLARE @NarrowFrom DATETIME2(0) = DATEADD(HOUR, 9, @Now), @NarrowTo DATETIME2(0) = DATEADD(HOUR, 10, @Now);  -- 1 hour
DECLARE @WideFrom   DATETIME2(0) = DATEADD(YEAR, -6, @Now), @WideTo DATETIME2(0) = DATEADD(DAY, 1, @Now);    -- everything

-- warm the buffer pool so every call is measured on a warm cache
DECLARE @warm INT = (SELECT COUNT(*) FROM dbo.NurseCareEvent WHERE Notes IS NULL);

/* ---------- A: narrow first ---------- */
EXEC sp_recompile N'perf.usp_EventsInRange';
EXEC #measure N'A. Sniffed for narrow range', N'1st call: 1 hour',  N'perf.usp_EventsInRange', @NarrowFrom, @NarrowTo;
EXEC #measure N'A. Sniffed for narrow range', N'2nd call: 5 years', N'perf.usp_EventsInRange', @WideFrom,   @WideTo;

/* ---------- B: wide first ---------- */
EXEC sp_recompile N'perf.usp_EventsInRange';
EXEC #measure N'B. Sniffed for wide range',   N'1st call: 5 years', N'perf.usp_EventsInRange', @WideFrom,   @WideTo;
EXEC #measure N'B. Sniffed for wide range',   N'2nd call: 1 hour',  N'perf.usp_EventsInRange', @NarrowFrom, @NarrowTo;

/* ---------- C: RECOMPILE ---------- */
EXEC #measure N'C. OPTION (RECOMPILE)',       N'1 hour',            N'perf.usp_EventsInRange_Recompile', @NarrowFrom, @NarrowTo;
EXEC #measure N'C. OPTION (RECOMPILE)',       N'5 years',           N'perf.usp_EventsInRange_Recompile', @WideFrom,   @WideTo;

/* ---------- D: forced index hint ---------- */
EXEC sp_recompile N'perf.usp_EventsInRange_ForcedSeek';
EXEC #measure N'D. Forced WITH (INDEX(...))', N'5 years',           N'perf.usp_EventsInRange_ForcedSeek', @WideFrom, @WideTo;

SELECT Step, Scenario, CallDesc AS [Call], RowsInRange, LogicalReads, CpuMs, ElapsedMs, PlanShape
FROM #demo ORDER BY Step;
GO

/* ---------- Query Store: one query, two plans ---------- */
-- Runtime stats in memory are included, so no flush is needed.
SELECT q.query_id AS QueryID,
       p.plan_id  AS PlanID,
       CASE WHEN CAST(p.query_plan AS NVARCHAR(MAX)) LIKE N'%Lookup="1"%' THEN N'Index Seek + Key Lookup' ELSE N'Clustered Index Scan' END AS PlanShape,
       SUM(rs.count_executions)                                              AS Executions,
       CAST(SUM(rs.avg_logical_io_reads * rs.count_executions) / SUM(rs.count_executions) AS BIGINT) AS AvgLogicalReads,
       CAST(MIN(rs.min_logical_io_reads) AS BIGINT)                          AS MinReads,
       CAST(MAX(rs.max_logical_io_reads) AS BIGINT)                          AS MaxReads
FROM sys.query_store_query q
JOIN sys.query_store_plan p          ON p.query_id = q.query_id
JOIN sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
WHERE q.object_id = OBJECT_ID(N'perf.usp_EventsInRange')
GROUP BY q.query_id, p.plan_id, p.query_plan
ORDER BY p.plan_id;
GO

/* ---------- Clean up demo objects ---------- */
DROP PROCEDURE IF EXISTS perf.usp_EventsInRange, perf.usp_EventsInRange_Recompile, perf.usp_EventsInRange_ForcedSeek, #measure;
DROP INDEX IF EXISTS IX_Demo_NurseCareEvent_EventAt ON dbo.NurseCareEvent;
DROP TABLE IF EXISTS #demo;
PRINT N'parameter_sniffing_demo.sql completed; demo objects removed.';
GO
