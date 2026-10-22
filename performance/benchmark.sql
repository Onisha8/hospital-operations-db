/* =============================================================================
   performance/benchmark.sql
   Runs a fixed workload of report, lookup and workflow queries and records,
   per query: average elapsed time, CPU time, logical reads, and the cached
   execution plan.

   Called by performance/run_benchmark.ps1 with $(Phase) = 'before' or 'after'.

   Method
   - Plan cache cleared at the start (DBCC FREEPROCCACHE) so every query compiles
     against the current indexes.
   - Warm cache: each query runs once untimed (loads pages into memory, compiles
     the plan), then @Runs timed runs. Averages are reported. The data (~300 MB)
     fits in memory, so this measures CPU and logical I/O, not disk.
   - Counters come from sys.dm_exec_requests for this session, read before and
     after each run. They cover all work the query does, including inside views,
     functions and procedures.
   - Results go to a temp table (SELECT ... INTO #sink), so the cost of sending
     rows to the client isn't measured.
   - Parameter values are picked deterministically from the data, so before and
     after runs use the same values.
   ============================================================================= */

USE HospitalOps;
GO
SET NOCOUNT ON;

IF SCHEMA_ID(N'perf') IS NULL EXEC (N'CREATE SCHEMA perf AUTHORIZATION dbo;');
GO

IF OBJECT_ID(N'perf.BenchmarkRun') IS NULL
    CREATE TABLE perf.BenchmarkRun (
        RunID       INT IDENTITY(1,1) CONSTRAINT PK_BenchmarkRun PRIMARY KEY,
        Phase       VARCHAR(10)  NOT NULL,
        RunAt       DATETIME2(0) NOT NULL CONSTRAINT DF_BenchmarkRun_RunAt DEFAULT (SYSDATETIME()),
        TimedRuns   INT          NOT NULL
    );
IF OBJECT_ID(N'perf.BenchmarkResult') IS NULL
    CREATE TABLE perf.BenchmarkResult (
        RunID           INT           NOT NULL CONSTRAINT FK_BenchmarkResult_Run REFERENCES perf.BenchmarkRun (RunID),
        Code            CHAR(3)       NOT NULL,
        AvgElapsedMs    DECIMAL(12,2) NOT NULL,
        AvgCpuMs        DECIMAL(12,2) NOT NULL,
        AvgLogicalReads BIGINT        NOT NULL,
        PlanXml         XML           NULL,
        CONSTRAINT PK_BenchmarkResult PRIMARY KEY (RunID, Code)
    );
GO

/* =============================================================================
   Workload. Each statement starts with a /*PERF:Wnn*/ marker so its plan can be
   found in the plan cache.
   ============================================================================= */
DROP TABLE IF EXISTS perf.Workload;
CREATE TABLE perf.Workload (
    Code        CHAR(3)        NOT NULL CONSTRAINT PK_Workload PRIMARY KEY,
    Area        NVARCHAR(20)   NOT NULL,
    Description NVARCHAR(120)  NOT NULL,
    SqlText     NVARCHAR(MAX)  NOT NULL
);

INSERT perf.Workload (Code, Area, Description, SqlText) VALUES
-- Calibration: the fixed cost of SELECT ... INTO #sink (temp-table metadata).
-- Net reads for W01-W13 = their reads minus this.
('W00', N'Calibration', N'Empty SELECT INTO #sink (measurement overhead)',
 N'/*PERF:W00*/ SELECT 1 AS x INTO #sink;'),
('W01', N'R6 report',  N'Charge summary for one stay',
 N'/*PERF:W01*/ SELECT * INTO #sink FROM rpt.vw_StayCharges WHERE AdmissionID = @StayID;'),
('W02', N'R3 report',  N'Discharge treatment report for one stay',
 N'/*PERF:W02*/ SELECT * INTO #sink FROM rpt.vw_DischargeTreatments WHERE AdmissionID = @StayID;'),
('W03', N'R2 report',  N'Admissions and discharges for the last 7 days',
 N'/*PERF:W03*/ SELECT * INTO #sink FROM rpt.fn_AdmissionsDischarges(@WeekStart, @Today);'),
('W04', N'R5 report',  N'Shift rotation of nurse care for one day',
 N'/*PERF:W04*/ SELECT * INTO #sink FROM rpt.fn_ShiftRotation(@Day);'),
('W05', N'R1 report',  N'Bed occupancy by ward on a past date',
 N'/*PERF:W05*/ SELECT * INTO #sink FROM rpt.fn_BedOccupancyOn(@Day);'),
('W06', N'R8 report',  N'Ward and bed history for one patient',
 N'/*PERF:W06*/ SELECT * INTO #sink FROM rpt.vw_PatientWardAssignment WHERE PatientID = @PatientID;'),
('W07', N'R9 report',  N'Treatments without a physician, last 30 days',
 N'/*PERF:W07*/ SELECT * INTO #sink FROM rpt.vw_PatientTreatments
                WHERE PhysicianID IS NULL AND DateOfService >= DATEADD(DAY, -30, @Today);'),
('W08', N'Lookup',     N'Front-desk patient search by last name + first initial',
 N'/*PERF:W08*/ SELECT PatientID, FirstName, LastName, DOB, Phone INTO #sink FROM dbo.Patient
                WHERE LastName = @LastName AND FirstName LIKE @FirstPrefix + N''%'';'),
('W09', N'Lookup',     N'Nursing chart (care events) for one stay',
 N'/*PERF:W09*/ SELECT e.EventAt, et.EventTypeName, n.LastName AS Nurse INTO #sink
                FROM dbo.NurseCareEvent e
                JOIN dbo.CareEventType et ON et.EventTypeCode = e.EventTypeCode
                JOIN dbo.Nurse n ON n.NurseID = e.NurseID
                WHERE e.AdmissionID = @StayID;'),
('W10', N'Analytics',  N'Monthly revenue, last 12 months (treatments + items)',
 N'/*PERF:W10*/ SELECT DATEFROMPARTS(YEAR(d), MONTH(d), 1) AS MonthStart, SUM(Amount) AS Revenue INTO #sink
                FROM (SELECT CAST(AdministeredAt AS DATE) AS d, ChargedAmount AS Amount FROM dbo.TreatmentAdministration
                      WHERE AdministeredAt >= @From12m
                      UNION ALL
                      SELECT ChargeDate, LineTotal FROM dbo.ItemCharge WHERE ChargeDate >= @From12m) x
                GROUP BY DATEFROMPARTS(YEAR(d), MONTH(d), 1);'),
('W11', N'R4 report',  N'Physician monthly admits, full history (control)',
 N'/*PERF:W11*/ SELECT * INTO #sink FROM rpt.vw_PhysicianMonthlyAdmits;'),
('W12', N'R7 report',  N'Ward schedule for one day',
 N'/*PERF:W12*/ SELECT * INTO #sink FROM rpt.vw_WardSchedule WHERE ShiftDate = @Day;'),
('W13', N'Census',     N'Current census: open stays with ward and bed',
 N'/*PERF:W13*/ SELECT * INTO #sink FROM rpt.vw_AdmissionDetail WHERE DischargeDate IS NULL;'),
('W14', N'Workflow',   N'Full stay: admit, charge item, discharge (rolled back)',
 N'/*PERF:W14*/ DECLARE @a INT, @b INT;
                BEGIN TRANSACTION;
                EXEC dbo.usp_AdmitPatient @PatientID = @FreePatientID, @AdmitPhysicianID = 1,
                                          @AdmissionID = @a OUTPUT, @AssignedBedID = @b OUTPUT;
                EXEC dbo.usp_RecordItemCharge @AdmissionID = @a, @ItemID = 1, @Quantity = 1;
                EXEC dbo.usp_DischargePatient @AdmissionID = @a, @DischargePhysicianID = 1;
                ROLLBACK TRANSACTION;'),
-- Write cost: every index on NurseCareEvent must be maintained on insert.
('W15', N'Write cost', N'Bulk insert 10,000 care events (rolled back)',
 N'/*PERF:W15*/ BEGIN TRANSACTION;
                INSERT dbo.NurseCareEvent (AdmissionID, NurseID, EventTypeCode, EventAt)
                SELECT TOP (10000) AdmissionID, NurseID, EventTypeCode, DATEADD(SECOND, 1, EventAt)
                FROM dbo.NurseCareEvent ORDER BY CareEventID;
                ROLLBACK TRANSACTION;');
GO

/* =============================================================================
   Run
   ============================================================================= */
DECLARE @Phase VARCHAR(10) = '$(Phase)', @Runs INT = 5;

-- Deterministic parameter values
DECLARE @Today DATE = CAST(GETDATE() AS DATE);
DECLARE @Day DATE = DATEADD(DAY, -1, @Today), @WeekStart DATE = DATEADD(DAY, -6, @Today);
DECLARE @From12m DATE = DATEADD(MONTH, -12, DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1));
DECLARE @StayID INT = (SELECT MIN(AdmissionID) FROM dbo.Admission
                       WHERE DischargeDate IS NOT NULL
                         AND AdmissionID >= (SELECT MAX(AdmissionID) / 2 FROM dbo.Admission));
DECLARE @PatientID INT = (SELECT PatientID FROM dbo.Admission WHERE AdmissionID = @StayID);
DECLARE @FreePatientID INT = (SELECT MIN(p.PatientID) FROM dbo.Patient p
                              WHERE NOT EXISTS (SELECT 1 FROM dbo.Admission a WHERE a.PatientID = p.PatientID AND a.DischargeDate IS NULL));
DECLARE @LastName NVARCHAR(40) = N'Nguyen', @FirstPrefix NVARCHAR(10) = N'A';
DECLARE @Params NVARCHAR(400) = N'@StayID INT, @PatientID INT, @FreePatientID INT, @Today DATE, @Day DATE,
                                  @WeekStart DATE, @From12m DATE, @LastName NVARCHAR(40), @FirstPrefix NVARCHAR(10)';

DBCC FREEPROCCACHE WITH NO_INFOMSGS;

INSERT perf.BenchmarkRun (Phase, TimedRuns) VALUES (@Phase, @Runs);
DECLARE @RunID INT = SCOPE_IDENTITY();

DECLARE @code CHAR(3), @sql NVARCHAR(MAX), @i INT,
        @r0 BIGINT, @c0 BIGINT, @t0 DATETIME2(7),
        @reads BIGINT, @cpu BIGINT, @elapsedUs BIGINT;

DECLARE w CURSOR LOCAL FAST_FORWARD FOR SELECT Code, SqlText FROM perf.Workload ORDER BY Code;
OPEN w;
FETCH NEXT FROM w INTO @code, @sql;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- warm-up: compile and load pages
    EXEC sp_executesql @sql, @Params, @StayID, @PatientID, @FreePatientID, @Today, @Day, @WeekStart, @From12m, @LastName, @FirstPrefix;

    SELECT @i = 0, @reads = 0, @cpu = 0, @elapsedUs = 0;
    WHILE @i < @Runs
    BEGIN
        SELECT @r0 = logical_reads, @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
        SET @t0 = SYSDATETIME();

        EXEC sp_executesql @sql, @Params, @StayID, @PatientID, @FreePatientID, @Today, @Day, @WeekStart, @From12m, @LastName, @FirstPrefix;

        SET @elapsedUs += DATEDIFF_BIG(MICROSECOND, @t0, SYSDATETIME());
        SELECT @reads += logical_reads - @r0, @cpu += cpu_time - @c0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;
        SET @i += 1;
    END;

    INSERT perf.BenchmarkResult (RunID, Code, AvgElapsedMs, AvgCpuMs, AvgLogicalReads, PlanXml)
    SELECT @RunID, @code,
           @elapsedUs / 1000.0 / @Runs,
           @cpu * 1.0 / @Runs,
           @reads / @Runs,
           (SELECT TOP (1) qp.query_plan
            FROM sys.dm_exec_cached_plans cp
            CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) st
            CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) qp
            WHERE st.text LIKE N'(@StayID%' AND st.text LIKE N'%/*PERF:' + @code + N'*/%');

    FETCH NEXT FROM w INTO @code, @sql;
END;
CLOSE w; DEALLOCATE w;

SELECT r.Code, wl.Description, r.AvgElapsedMs, r.AvgCpuMs, r.AvgLogicalReads,
       CASE WHEN r.PlanXml IS NULL THEN 'no' ELSE 'yes' END AS PlanCaptured
FROM perf.BenchmarkResult r JOIN perf.Workload wl ON wl.Code = r.Code
WHERE r.RunID = @RunID ORDER BY r.Code;

PRINT CONCAT(N'Benchmark run ', @RunID, N' (', @Phase, N') completed.');
GO
