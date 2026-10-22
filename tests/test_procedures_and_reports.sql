/* =============================================================================
   test_procedures_and_reports.sql

   Part A: workflow procedures (sql/08_stored_procedures.sql)
     Walks one patient through admit -> charge -> treat -> transfer -> discharge,
     and checks that every rule violation raises the documented error number and
     leaves nothing half-done. Runs inside one transaction that is rolled back,
     which also proves the procedures' savepoint handling: a failed call undoes
     only its own work and the outer transaction stays usable.

   Part B: report reconciliation (sql/07_reporting_views.sql)
     Each report's totals must equal an independent count from the base tables.
     This catches wrong join types (e.g. an INNER JOIN dropping treatments that
     have no physician) and double counting.

   Fails the run (RAISERROR severity 16) if any test fails.
   ============================================================================= */

USE HospitalOps;
GO
SET NOCOUNT ON;
SET XACT_ABORT OFF;

DROP TABLE IF EXISTS #results;
DROP TABLE IF EXISTS #ids;
CREATE TABLE #results (TestNo INT IDENTITY, Part CHAR(1), Test NVARCHAR(120), Result CHAR(4), Detail NVARCHAR(400));
CREATE TABLE #ids (k NVARCHAR(10) PRIMARY KEY, id INT NULL);
GO

CREATE OR ALTER PROCEDURE #check @part CHAR(1), @test NVARCHAR(120), @ok BIT, @detail NVARCHAR(400) = NULL
AS
    INSERT #results (Part, Test, Result, Detail) VALUES (@part, @test, CASE WHEN @ok = 1 THEN 'PASS' ELSE 'FAIL' END, @detail);
GO
-- Expect @sql to fail with error number @errno.
CREATE OR ALTER PROCEDURE #expect_error @test NVARCHAR(120), @sql NVARCHAR(MAX), @errno INT
AS
BEGIN
    BEGIN TRY
        EXEC sp_executesql @sql;
        INSERT #results (Part, Test, Result, Detail) VALUES ('A', @test, 'FAIL', CONCAT(N'Succeeded; expected error ', @errno));
    END TRY
    BEGIN CATCH
        INSERT #results (Part, Test, Result, Detail)
        VALUES ('A', @test,
                CASE WHEN ERROR_NUMBER() = @errno THEN 'PASS' ELSE 'FAIL' END,
                CONCAT(ERROR_NUMBER(), N': ', LEFT(ERROR_MESSAGE(), 300)));
    END CATCH
END;
GO

/* =============================================================================
   Part A: workflow procedures
   ============================================================================= */
BEGIN TRANSACTION;

-- Fixture: two new patients, three free beds in three different wards, one occupied bed,
-- and an empty ward (no beds) for the "no bed available" case.
INSERT dbo.Patient (FirstName, LastName, Gender, DOB, Street, Zip, Phone)
VALUES (N'Proc', N'TestA', 'F', '1980-01-01', N'1 Test St', '33620', N'(813) 555-0001');
INSERT #ids VALUES (N'PA', SCOPE_IDENTITY());
INSERT dbo.Patient (FirstName, LastName, Gender, DOB, Street, Zip, Phone)
VALUES (N'Proc', N'TestB', 'M', '1975-05-05', N'2 Test St', '33620', N'(813) 555-0002');
INSERT #ids VALUES (N'PB', SCOPE_IDENTITY());

WITH free AS (
    SELECT BedID, WardID, ROW_NUMBER() OVER (PARTITION BY WardID ORDER BY BedID) AS rn,
           DENSE_RANK() OVER (ORDER BY WardID) AS wr
    FROM dbo.Bed WHERE Availability = 'A'
)
INSERT #ids SELECT CASE wr WHEN 1 THEN N'B1' WHEN 2 THEN N'B2' ELSE N'B3' END, BedID
FROM free WHERE rn = 2 AND wr <= 3;                          -- 2nd free bed, so auto-assign (1st) won't take it
INSERT #ids SELECT N'W2', WardID FROM dbo.Bed WHERE BedID = (SELECT id FROM #ids WHERE k = N'B2');
INSERT #ids SELECT TOP (1) N'BO', BedID FROM dbo.Bed WHERE Availability = 'O' ORDER BY BedID;
INSERT #ids SELECT TOP (1) N'I1', ItemID FROM dbo.Item ORDER BY ItemID;
INSERT #ids SELECT TOP (1) N'T1', TreatmentID FROM dbo.Treatment ORDER BY TreatmentID;

INSERT dbo.Nurse (FirstName, LastName, Street, City, Zip, Phone, Email)
VALUES (N'Proc', N'Charge', N'3 Test St', N'Tampa', '33620', N'(813) 555-0003', N'proc.charge@example.test');
INSERT dbo.Ward (WardNumber, WardName, Location, Phone, ChargeNurseID)
VALUES (N'T-99', N'Empty Test Ward', N'Nowhere', N'(813) 555-0099', SCOPE_IDENTITY());
INSERT #ids VALUES (N'WE', SCOPE_IDENTITY());

DECLARE @PA INT = (SELECT id FROM #ids WHERE k = N'PA'), @PB INT = (SELECT id FROM #ids WHERE k = N'PB'),
        @B1 INT = (SELECT id FROM #ids WHERE k = N'B1'), @B2 INT = (SELECT id FROM #ids WHERE k = N'B2'),
        @B3 INT = (SELECT id FROM #ids WHERE k = N'B3'), @W2 INT = (SELECT id FROM #ids WHERE k = N'W2'),
        @I1 INT = (SELECT id FROM #ids WHERE k = N'I1'), @T1 INT = (SELECT id FROM #ids WHERE k = N'T1');
DECLARE @A1 INT, @A2 INT, @bed INT, @ok BIT, @d NVARCHAR(400), @n INT;

/* ---------- Admit ------------------------------------------------------------ */
EXEC dbo.usp_AdmitPatient @PatientID = @PA, @AdmitPhysicianID = 1, @BedID = @B1,
                          @AdmissionID = @A1 OUTPUT, @AssignedBedID = @bed OUTPUT;
INSERT #ids VALUES (N'A1', @A1);
SELECT @ok = CASE WHEN a.DischargeDate IS NULL AND ba.BedID = @B1 AND ba.EndDate IS NULL AND b.Availability = 'O' THEN 1 ELSE 0 END,
       @d  = CONCAT(N'AdmissionID ', @A1, N', bed ', b.BedNumber, N' now ', b.Availability)
FROM dbo.Admission a JOIN dbo.BedAssignment ba ON ba.AdmissionID = a.AdmissionID JOIN dbo.Bed b ON b.BedID = ba.BedID
WHERE a.AdmissionID = @A1;
EXEC #check 'A', N'Admit: stay opened, bed assigned and marked occupied', @ok, @d;

-- Error cases run as dynamic SQL so #expect_error can catch them (EXEC arguments
-- can't be expressions, so IDs are concatenated into the statement).
DECLARE @sql NVARCHAR(MAX);
SET @sql = CONCAT(N'EXEC dbo.usp_AdmitPatient @PatientID = ', @PA, N', @AdmitPhysicianID = 1, @BedID = ', @B2);
EXEC #expect_error N'Admit: patient already admitted -> 50003', @sql, 50003;
SET @sql = CONCAT(N'EXEC dbo.usp_AdmitPatient @PatientID = ', @PB, N', @AdmitPhysicianID = 1, @BedID = ', @B1);
EXEC #expect_error N'Admit: bed occupied -> 50004', @sql, 50004;
SET @sql = CONCAT(N'EXEC dbo.usp_AdmitPatient @PatientID = ', @PB, N', @AdmitPhysicianID = 1, @BedID = -1');
EXEC #expect_error N'Admit: bed does not exist -> 50006', @sql, 50006;
SET @sql = N'EXEC dbo.usp_AdmitPatient @PatientID = -1, @AdmitPhysicianID = 1';
EXEC #expect_error N'Admit: patient does not exist -> 50001', @sql, 50001;
SET @sql = CONCAT(N'EXEC dbo.usp_AdmitPatient @PatientID = ', @PB, N', @AdmitPhysicianID = -1');
EXEC #expect_error N'Admit: physician does not exist -> 50002', @sql, 50002;
SET @sql = CONCAT(N'EXEC dbo.usp_AdmitPatient @PatientID = ', @PB, N', @AdmitPhysicianID = 1, @AdmitDate = ''2099-01-01''');
EXEC #expect_error N'Admit: future date -> 50007', @sql, 50007;
SET @sql = CONCAT(N'EXEC dbo.usp_AdmitPatient @PatientID = ', @PB, N', @AdmitPhysicianID = 1, @WardID = ', (SELECT id FROM #ids WHERE k = N'WE'));
EXEC #expect_error N'Admit: no free bed in ward -> 50005', @sql, 50005;

SELECT @n = COUNT(*) FROM dbo.Admission WHERE PatientID = @PB;
SET @ok = CASE WHEN @n = 0 AND @@TRANCOUNT = 1 THEN 1 ELSE 0 END;
SET @d  = CONCAT(N'patient B stays: ', @n, N'; @@TRANCOUNT: ', @@TRANCOUNT);
EXEC #check 'A', N'Failed calls left no partial rows and the outer transaction alive (savepoints)', @ok, @d;

EXEC dbo.usp_AdmitPatient @PatientID = @PB, @AdmitPhysicianID = 2, @WardID = @W2,
                          @AdmissionID = @A2 OUTPUT, @AssignedBedID = @bed OUTPUT;
SELECT @ok = CASE WHEN b.WardID = @W2 AND b.Availability = 'O' AND @bed <> @B2 THEN 1 ELSE 0 END,
       @d  = CONCAT(N'auto-assigned bed ', b.BedNumber)
FROM dbo.Bed b WHERE b.BedID = @bed;
EXEC #check 'A', N'Admit with ward only: first free bed in that ward chosen', @ok, @d;

/* ---------- Charges and treatments ------------------------------------------ */
SET @sql = CONCAT(N'EXEC dbo.usp_DischargePatient @AdmissionID = ', @A1, N', @DischargePhysicianID = 1');
EXEC #expect_error N'Discharge: no item charges yet -> 50013 (BR-34)', @sql, 50013;

DECLARE @ic INT, @ta INT;
EXEC dbo.usp_RecordItemCharge @AdmissionID = @A1, @ItemID = @I1, @Quantity = 2, @ItemChargeID = @ic OUTPUT;
SELECT @ok = CASE WHEN ic.UnitCharge = i.UnitCharge AND ic.LineTotal = 2 * i.UnitCharge THEN 1 ELSE 0 END,
       @d  = CONCAT(N'unit ', ic.UnitCharge, N', line total ', ic.LineTotal)
FROM dbo.ItemCharge ic JOIN dbo.Item i ON i.ItemID = ic.ItemID WHERE ic.ItemChargeID = @ic;
EXEC #check 'A', N'Item charge: list price snapshotted, line total computed', @ok, @d;

SET @sql = CONCAT(N'EXEC dbo.usp_RecordItemCharge @AdmissionID = ', @A1, N', @ItemID = ', @I1, N', @Quantity = 0');
EXEC #expect_error N'Item charge: quantity 0 -> 50016', @sql, 50016;
SET @sql = CONCAT(N'EXEC dbo.usp_RecordItemCharge @AdmissionID = ', @A1, N', @ItemID = -1');
EXEC #expect_error N'Item charge: unknown item -> 50015', @sql, 50015;
SET @sql = CONCAT(N'EXEC dbo.usp_RecordItemCharge @AdmissionID = ', @A1, N', @ItemID = ', @I1, N', @ChargeDate = ''2000-01-01''');
EXEC #expect_error N'Item charge: date before the stay -> 50017', @sql, 50017;

EXEC dbo.usp_RecordTreatment @AdmissionID = @A1, @TreatmentID = @T1, @PhysicianID = NULL,
                             @Results = N'Normal', @TreatmentAdminID = @ta OUTPUT;
SELECT @ok = CASE WHEN ta.PhysicianID IS NULL AND ta.ChargedAmount = t.StandardCharge THEN 1 ELSE 0 END,
       @d  = CONCAT(N'charged ', ta.ChargedAmount, N', physician ', ISNULL(CAST(ta.PhysicianID AS NVARCHAR(10)), N'NULL'))
FROM dbo.TreatmentAdministration ta JOIN dbo.Treatment t ON t.TreatmentID = ta.TreatmentID WHERE ta.TreatmentAdminID = @ta;
EXEC #check 'A', N'Treatment without physician recorded at list price', @ok, @d;

SET @sql = CONCAT(N'EXEC dbo.usp_RecordTreatment @AdmissionID = ', @A1, N', @TreatmentID = ', @T1, N', @AdministeredAt = ''2099-01-01''');
EXEC #expect_error N'Treatment: time in the future -> 50017', @sql, 50017;

/* ---------- Transfer ----------------------------------------------------------- */
EXEC dbo.usp_TransferPatient @AdmissionID = @A1, @NewBedID = @B3;
SELECT @ok = CASE WHEN COUNT(*) = 2
                   AND SUM(CASE WHEN ba.BedID = @B1 AND ba.EndDate IS NOT NULL THEN 1 ELSE 0 END) = 1
                   AND SUM(CASE WHEN ba.BedID = @B3 AND ba.EndDate IS NULL     THEN 1 ELSE 0 END) = 1
                   AND (SELECT Availability FROM dbo.Bed WHERE BedID = @B1) = 'A'
                   AND (SELECT Availability FROM dbo.Bed WHERE BedID = @B3) = 'O' THEN 1 ELSE 0 END,
       @d  = CONCAT(COUNT(*), N' bed assignments for the stay')
FROM dbo.BedAssignment ba WHERE ba.AdmissionID = @A1;
EXEC #check 'A', N'Transfer: old bed closed and freed, new bed open and occupied', @ok, @d;

SET @sql = CONCAT(N'EXEC dbo.usp_TransferPatient @AdmissionID = ', @A1, N', @NewBedID = ', @B3);
EXEC #expect_error N'Transfer: same bed -> 50014', @sql, 50014;
SET @sql = CONCAT(N'EXEC dbo.usp_TransferPatient @AdmissionID = ', @A1, N', @NewBedID = ', (SELECT id FROM #ids WHERE k = N'BO'));
EXEC #expect_error N'Transfer: target bed occupied -> 50004', @sql, 50004;

/* ---------- Discharge ---------------------------------------------------------- */
SET @sql = CONCAT(N'EXEC dbo.usp_DischargePatient @AdmissionID = ', @A1, N', @DischargePhysicianID = 1, @DischargeDate = ''2000-01-01''');
EXEC #expect_error N'Discharge: date before admission -> 50012', @sql, 50012;
SET @sql = N'EXEC dbo.usp_DischargePatient @AdmissionID = -1, @DischargePhysicianID = 1';
EXEC #expect_error N'Discharge: unknown stay -> 50010', @sql, 50010;

EXEC dbo.usp_DischargePatient @AdmissionID = @A1, @DischargePhysicianID = 2;
SELECT @ok = CASE WHEN a.DischargeDate = CAST(GETDATE() AS DATE) AND a.DischargePhysicianID = 2
                   AND NOT EXISTS (SELECT 1 FROM dbo.BedAssignment WHERE AdmissionID = @A1 AND EndDate IS NULL)
                   AND (SELECT Availability FROM dbo.Bed WHERE BedID = @B3) = 'A' THEN 1 ELSE 0 END,
       @d  = CONCAT(N'discharged ', a.DischargeDate, N' by physician ', a.DischargePhysicianID)
FROM dbo.Admission a WHERE a.AdmissionID = @A1;
EXEC #check 'A', N'Discharge: stay closed, bed assignment closed, bed released', @ok, @d;

SET @sql = CONCAT(N'EXEC dbo.usp_DischargePatient @AdmissionID = ', @A1, N', @DischargePhysicianID = 1');
EXEC #expect_error N'Discharge: already discharged -> 50011', @sql, 50011;

SELECT @ok = CASE WHEN sc.ItemTotal = 2 * i.UnitCharge AND sc.TreatmentTotal = t.StandardCharge
                   AND sc.GrandTotal = sc.ItemTotal + sc.TreatmentTotal THEN 1 ELSE 0 END,
       @d  = CONCAT(N'items ', sc.ItemTotal, N' + treatments ', sc.TreatmentTotal, N' = ', sc.GrandTotal)
FROM rpt.vw_StayCharges sc
CROSS JOIN dbo.Item i CROSS JOIN dbo.Treatment t
WHERE sc.AdmissionID = @A1 AND i.ItemID = @I1 AND t.TreatmentID = @T1;
EXEC #check 'A', N'R6 bill for the test stay adds up', @ok, @d;

DECLARE @r TABLE (TestNo INT, Part CHAR(1), Test NVARCHAR(120), Result CHAR(4), Detail NVARCHAR(400));
INSERT @r SELECT * FROM #results;
ROLLBACK TRANSACTION;                                   -- leave the database unchanged
SET IDENTITY_INSERT #results ON;
INSERT #results (TestNo, Part, Test, Result, Detail) SELECT * FROM @r;
SET IDENTITY_INSERT #results OFF;
GO

/* =============================================================================
   Part B: report reconciliation against the base tables
   ============================================================================= */
DECLARE @a BIGINT, @b BIGINT, @d NVARCHAR(400), @ok BIT;
DECLARE @Today DATE = CAST(GETDATE() AS DATE), @Yesterday DATE = DATEADD(DAY, -1, CAST(GETDATE() AS DATE));

-- R1 current
SELECT @a = SUM(Occupied) FROM rpt.vw_BedOccupancyByWard;
SELECT @b = COUNT(*) FROM dbo.BedAssignment WHERE EndDate IS NULL;
SET @ok = IIF(@a = @b, 1, 0); SET @d = CONCAT(@a, N' vs ', @b);
EXEC #check 'B', N'R1  occupied beds = open bed assignments', @ok, @d;

-- R1 historical
SELECT @a = SUM(Occupied) FROM rpt.fn_BedOccupancyOn(@Yesterday);
SELECT @b = COUNT(*) FROM dbo.BedAssignment WHERE StartDate <= @Yesterday AND (EndDate IS NULL OR EndDate > @Yesterday);
SET @ok = IIF(@a = @b, 1, 0); SET @d = CONCAT(@a, N' vs ', @b);
EXEC #check 'B', N'R1  occupancy rebuilt for yesterday = assignments spanning it', @ok, @d;

-- R2
SELECT @a = COUNT(*) FROM rpt.fn_AdmissionsDischarges(DATEADD(DAY, -6, @Today), @Today);
SELECT @b = COUNT(*) FROM dbo.Admission
WHERE AdmitDate BETWEEN DATEADD(DAY, -6, @Today) AND @Today OR DischargeDate BETWEEN DATEADD(DAY, -6, @Today) AND @Today;
SET @ok = IIF(@a = @b AND @a > 0, 1, 0); SET @d = CONCAT(@a, N' vs ', @b);
EXEC #check 'B', N'R2  weekly admits/discharges = stays touching the week', @ok, @d;

-- R3
SELECT @a = COUNT(*) FROM rpt.vw_DischargeTreatments;
SELECT @b = COUNT(*) FROM dbo.TreatmentAdministration ta JOIN dbo.Admission a ON a.AdmissionID = ta.AdmissionID WHERE a.DischargeDate IS NOT NULL;
SET @ok = IIF(@a = @b, 1, 0); SET @d = CONCAT(@a, N' vs ', @b);
EXEC #check 'B', N'R3  discharge report keeps treatments without a physician', @ok, @d;

-- R4
SELECT @a = SUM(Admits) FROM rpt.vw_PhysicianMonthlyAdmits;
SELECT @b = COUNT(*) FROM dbo.Admission;
SET @ok = IIF(@a = @b, 1, 0); SET @d = CONCAT(@a, N' vs ', @b);
EXEC #check 'B', N'R4  monthly admits sum to all admissions', @ok, @d;

-- R5
SELECT @a = COUNT(*) FROM rpt.fn_ShiftRotation(@Yesterday);
SELECT @b = COUNT(*) FROM dbo.NurseAssignment WHERE ShiftDate = @Yesterday;
SET @ok = IIF(@a = @b AND @a > 0, 1, 0); SET @d = CONCAT(@a, N' vs ', @b, N' shifts');
EXEC #check 'B', N'R5  shift rotation has one row per shift', @ok, @d;
SELECT @a = SUM(TotalEvents) FROM rpt.fn_ShiftRotation(@Yesterday);
SELECT @b = COUNT(*) FROM dbo.NurseCareEvent WHERE CAST(EventAt AS DATE) = @Yesterday;
SET @ok = IIF(@a = @b, 1, 0); SET @d = CONCAT(@a, N' vs ', @b, N' events');
EXEC #check 'B', N'R5  shift rotation events = care events that day', @ok, @d;

-- R6
SELECT @a = SUM(GrandTotal * 100) FROM rpt.vw_StayCharges;
SELECT @b = ((SELECT SUM(ChargedAmount) FROM dbo.TreatmentAdministration) + (SELECT SUM(LineTotal) FROM dbo.ItemCharge)) * 100;
SET @ok = IIF(@a = @b, 1, 0); SET @d = CONCAT(@a / 100.0, N' vs ', @b / 100.0);
EXEC #check 'B', N'R6  sum of stay totals = all treatments + all items', @ok, @d;

-- R7
SELECT @a = SUM(NursesOnShift) FROM rpt.vw_WardSchedule;
SELECT @b = COUNT(*) FROM dbo.NurseAssignment;
SET @ok = IIF(@a = @b, 1, 0); SET @d = CONCAT(@a, N' vs ', @b);
EXEC #check 'B', N'R7  ward schedule covers every shift', @ok, @d;

-- R8
SELECT @a = COUNT(*) FROM rpt.vw_PatientWardAssignment;
SELECT @b = COUNT(*) FROM dbo.BedAssignment;
SET @ok = IIF(@a = @b, 1, 0); SET @d = CONCAT(@a, N' vs ', @b);
EXEC #check 'B', N'R8  ward assignment report = bed assignment history', @ok, @d;

-- R9
SELECT @a = COUNT(*) FROM rpt.vw_PatientTreatments WHERE HasTreatingPhysician = 'N';
SELECT @b = COUNT(*) FROM dbo.TreatmentAdministration WHERE PhysicianID IS NULL;
SET @ok = IIF(@a = @b AND @a > 0, 1, 0); SET @d = CONCAT(@a, N' vs ', @b);
EXEC #check 'B', N'R9  "without physician" rows = NULL-physician treatments', @ok, @d;
SELECT @a = COUNT(*) FROM rpt.vw_PatientTreatments;
SELECT @b = COUNT(*) FROM dbo.TreatmentAdministration;
SET @ok = IIF(@a = @b, 1, 0); SET @d = CONCAT(@a, N' vs ', @b);
EXEC #check 'B', N'R9  with + without = all treatments', @ok, @d;

-- R10
SELECT @a = SUM(TimesAdministered) FROM rpt.vw_PhysicianTreatments;
SELECT @b = COUNT(*) FROM dbo.TreatmentAdministration WHERE PhysicianID IS NOT NULL;
SET @ok = IIF(@a = @b, 1, 0); SET @d = CONCAT(@a, N' vs ', @b);
EXEC #check 'B', N'R10 physician treatment counts = treatments with a physician', @ok, @d;

-- R11
SELECT @a = COUNT(*), @b = SUM(SpecialtyCount) FROM rpt.vw_PhysicianSpecialties;
SET @ok = IIF(@a = (SELECT COUNT(*) FROM dbo.Physician) AND @b = (SELECT COUNT(*) FROM dbo.PhysicianSpecialty), 1, 0);
SET @d = CONCAT(@a, N' physicians, ', @b, N' specialties');
EXEC #check 'B', N'R11 every physician and specialty listed once', @ok, @d;

-- R12
SELECT @a = COUNT(*) FROM rpt.vw_NurseRoster;
SELECT @b = COUNT(*) FROM rpt.vw_NurseHierarchy;
SET @ok = IIF(@a = (SELECT COUNT(*) FROM dbo.Nurse) AND @b = @a, 1, 0); SET @d = CONCAT(@a, N' in roster, ', @b, N' in hierarchy');
EXEC #check 'B', N'R12 every nurse in roster and reachable in hierarchy', @ok, @d;
SELECT @a = COUNT(*) FROM rpt.vw_NurseRoster WHERE ChargeNurseOf IS NOT NULL;
SET @ok = IIF(@a = (SELECT COUNT(*) FROM dbo.Ward), 1, 0); SET @d = CONCAT(@a, N' charge nurses');
EXEC #check 'B', N'R12 one charge nurse flagged per ward', @ok, @d;
GO

/* ---------- Report ------------------------------------------------------------ */
SELECT TestNo AS [#], Part, Test, Result, Detail FROM #results ORDER BY TestNo;
GO
DECLARE @pass INT = (SELECT COUNT(*) FROM #results WHERE Result = 'PASS'),
        @fail INT = (SELECT COUNT(*) FROM #results WHERE Result = 'FAIL');
PRINT CONCAT(N'Procedure and report tests: ', @pass, N' passed, ', @fail, N' failed.');
DROP TABLE #results; DROP TABLE #ids;
DROP PROCEDURE #check; DROP PROCEDURE #expect_error;
IF @fail > 0 RAISERROR (N'%d procedure/report test(s) failed.', 16, 1, @fail);
GO
