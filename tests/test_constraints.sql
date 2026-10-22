/* =============================================================================
   test_constraints.sql
   Automated tests for the business rules in docs/02_business_rules.md.

   - Positive tests: valid data is accepted and defaults/computed columns work.
   - Negative tests: invalid data is rejected BY THE EXPECTED NAMED CONSTRAINT
     (not just "some error"), which proves the right rule fired.

   Everything runs inside one transaction that is rolled back, so the database
   is left unchanged. Results are copied to a table variable first because
   table variables are not affected by ROLLBACK.

   Fails the run (RAISERROR severity 16) if any test fails.
   ============================================================================= */

USE HospitalOps;
GO
SET NOCOUNT ON;
SET XACT_ABORT OFF;   -- constraint errors must not doom the transaction
GO

DROP TABLE IF EXISTS #results;
DROP TABLE IF EXISTS #ids;
CREATE TABLE #results (TestNo INT IDENTITY, Rule_ NVARCHAR(10), Test NVARCHAR(120), Result CHAR(4), Detail NVARCHAR(400));
CREATE TABLE #ids (k NVARCHAR(10) PRIMARY KEY, id INT NOT NULL);
GO

/* ---------- helpers --------------------------------------------------------- */
-- Expect @sql to FAIL, and the error message to name @constraint.
CREATE OR ALTER PROCEDURE #expect_fail @rule NVARCHAR(10), @test NVARCHAR(120), @sql NVARCHAR(MAX), @constraint SYSNAME
AS
BEGIN
    BEGIN TRY
        EXEC sp_executesql @sql;
        INSERT #results (Rule_, Test, Result, Detail) VALUES (@rule, @test, 'FAIL', N'Statement succeeded but should have been rejected by ' + @constraint);
    END TRY
    BEGIN CATCH
        IF ERROR_MESSAGE() LIKE N'%' + @constraint + N'%'
            INSERT #results (Rule_, Test, Result, Detail) VALUES (@rule, @test, 'PASS', N'Rejected by ' + @constraint);
        ELSE
            INSERT #results (Rule_, Test, Result, Detail) VALUES (@rule, @test, 'FAIL', N'Wrong error: ' + LEFT(ERROR_MESSAGE(), 300));
    END CATCH
END;
GO
-- Expect @sql to SUCCEED.
CREATE OR ALTER PROCEDURE #expect_ok @rule NVARCHAR(10), @test NVARCHAR(120), @sql NVARCHAR(MAX)
AS
BEGIN
    BEGIN TRY
        EXEC sp_executesql @sql;
        INSERT #results (Rule_, Test, Result, Detail) VALUES (@rule, @test, 'PASS', N'Accepted');
    END TRY
    BEGIN CATCH
        INSERT #results (Rule_, Test, Result, Detail) VALUES (@rule, @test, 'FAIL', N'Unexpected error: ' + LEFT(ERROR_MESSAGE(), 300));
    END CATCH
END;
GO
-- Record a value comparison.
CREATE OR ALTER PROCEDURE #expect_equal @rule NVARCHAR(10), @test NVARCHAR(120), @actual SQL_VARIANT, @expected SQL_VARIANT
AS
    INSERT #results (Rule_, Test, Result, Detail)
    VALUES (@rule, @test,
            CASE WHEN @actual = @expected THEN 'PASS' ELSE 'FAIL' END,
            CONCAT(N'expected ', CAST(@expected AS NVARCHAR(100)), N', got ', ISNULL(CAST(@actual AS NVARCHAR(100)), N'NULL')));
GO

BEGIN TRANSACTION;

/* =============================================================================
   Fixture: a minimal valid hospital
   ============================================================================= */
INSERT dbo.Nurse (FirstName, LastName, Street, City, Zip, Phone, Email)
VALUES (N'Test', N'Supervisor', N'1 Main St', N'Tampa', '33620', N'813-555-0001', N'test.sup@example.test');
INSERT #ids VALUES (N'N1', SCOPE_IDENTITY());

INSERT dbo.Nurse (FirstName, LastName, Street, City, Zip, Phone, Email, SupervisorID)
VALUES (N'Test', N'Nurse', N'2 Main St', N'Tampa', '33620', N'813-555-0002', N'test.nurse@example.test', (SELECT id FROM #ids WHERE k = N'N1'));
INSERT #ids VALUES (N'N2', SCOPE_IDENTITY());

INSERT dbo.Ward (WardNumber, WardName, Location, Phone, ChargeNurseID)
VALUES (N'T-01', N'Test Ward', N'Bldg T', N'813-555-0100', (SELECT id FROM #ids WHERE k = N'N1'));
INSERT #ids VALUES (N'W1', SCOPE_IDENTITY());

INSERT dbo.Bed (WardID, BedNumber) VALUES ((SELECT id FROM #ids WHERE k = N'W1'), N'T1');   -- all defaults
INSERT #ids VALUES (N'B1', SCOPE_IDENTITY());
INSERT dbo.Bed (WardID, BedNumber, Availability) VALUES ((SELECT id FROM #ids WHERE k = N'W1'), N'T2', 'A');
INSERT #ids VALUES (N'B2', SCOPE_IDENTITY());

INSERT dbo.Physician (FirstName, LastName, Street, City, Zip, Phone, Email)
VALUES (N'Test', N'Doctor', N'3 Main St', N'Tampa', '33620', N'813-555-0003', N'test.doc@example.test');
INSERT #ids VALUES (N'P1', SCOPE_IDENTITY());

-- Patient whose birthday is TOMORROW, 40 years ago: true age is 39 (v1 formula said 40)
INSERT dbo.Patient (FirstName, LastName, Gender, DOB, Street, Zip, Phone)
VALUES (N'Test', N'PatientA', 'F', DATEADD(DAY, 1, DATEADD(YEAR, -40, CAST(GETDATE() AS DATE))), N'4 Main St', '33620', N'813-555-0004');
INSERT #ids VALUES (N'PA', SCOPE_IDENTITY());
INSERT dbo.Patient (FirstName, LastName, Gender, DOB, Street, Zip, Phone)
VALUES (N'Test', N'PatientB', 'M', '1990-06-15', N'5 Main St', '33620', N'813-555-0005');
INSERT #ids VALUES (N'PB', SCOPE_IDENTITY());

INSERT dbo.Admission (PatientID, AdmitDate, AdmitPhysicianID)
VALUES ((SELECT id FROM #ids WHERE k = N'PA'), CAST(GETDATE() AS DATE), (SELECT id FROM #ids WHERE k = N'P1'));
INSERT #ids VALUES (N'A1', SCOPE_IDENTITY());
INSERT dbo.Admission (PatientID, AdmitDate, AdmitPhysicianID)
VALUES ((SELECT id FROM #ids WHERE k = N'PB'), CAST(GETDATE() AS DATE), (SELECT id FROM #ids WHERE k = N'P1'));
INSERT #ids VALUES (N'A2', SCOPE_IDENTITY());

INSERT dbo.BedAssignment (AdmissionID, BedID, StartDate)
VALUES ((SELECT id FROM #ids WHERE k = N'A1'), (SELECT id FROM #ids WHERE k = N'B1'), CAST(GETDATE() AS DATE));
INSERT #ids VALUES (N'BA1', SCOPE_IDENTITY());

INSERT dbo.Item (ItemName, UnitCharge) VALUES (N'Test Bandage', 4.25);
INSERT #ids VALUES (N'I1', SCOPE_IDENTITY());
INSERT dbo.Treatment (TreatmentName, StandardCharge) VALUES (N'Test Blood Panel', 50.00);
INSERT #ids VALUES (N'T1', SCOPE_IDENTITY());

INSERT dbo.NurseAssignment (NurseID, WardID, ShiftDate, HoursWorked)
VALUES ((SELECT id FROM #ids WHERE k = N'N2'), (SELECT id FROM #ids WHERE k = N'W1'), '2026-01-05', 8);

/* =============================================================================
   Positive tests: defaults, computed columns, allowed optionality
   ============================================================================= */
DECLARE @size CHAR(2), @type CHAR(1), @avail CHAR(1), @age INT, @city NVARCHAR(30), @state CHAR(2), @total DECIMAL(12,2);

SELECT @size = Size, @type = Type, @avail = Availability FROM dbo.Bed WHERE BedID = (SELECT id FROM #ids WHERE k = N'B1');
EXEC #expect_equal N'BR-12', N'Bed size defaults to L', @size, 'L';
EXEC #expect_equal N'BR-13', N'Bed type defaults to M (manual)', @type, 'M';
EXEC #expect_equal N'BR-14', N'Bed availability defaults to O (occupied)', @avail, 'O';

SELECT @age = Age, @city = City, @state = State FROM dbo.Patient WHERE PatientID = (SELECT id FROM #ids WHERE k = N'PA');
EXEC #expect_equal N'BR-17', N'Age is birthday-aware (birthday tomorrow -> 39, not 40)', @age, 39;
EXEC #expect_equal N'BR-15', N'Patient city defaults to Tampa', @city, N'Tampa';
EXEC #expect_equal N'BR-15', N'Patient state defaults to FL', @state, 'FL';

EXEC #expect_ok N'BR-33', N'Item charge accepted with price snapshot',
    N'INSERT dbo.ItemCharge (AdmissionID, ItemID, ChargeDate, Quantity, UnitCharge)
      VALUES ((SELECT id FROM #ids WHERE k=N''A1''), (SELECT id FROM #ids WHERE k=N''I1''), CAST(GETDATE() AS DATE), 3, 4.25)';
DECLARE @expectedTotal DECIMAL(12,2) = 12.75;   -- EXEC arguments can't be expressions
SELECT @total = LineTotal FROM dbo.ItemCharge WHERE AdmissionID = (SELECT id FROM #ids WHERE k = N'A1');
EXEC #expect_equal N'BR-33', N'LineTotal computed = 3 x 4.25', @total, @expectedTotal;

EXEC #expect_ok N'BR-29', N'Treatment WITHOUT a treating physician is allowed',
    N'INSERT dbo.TreatmentAdministration (AdmissionID, TreatmentID, PhysicianID, AdministeredAt, ChargedAmount)
      VALUES ((SELECT id FROM #ids WHERE k=N''A1''), (SELECT id FROM #ids WHERE k=N''T1''), NULL, SYSDATETIME(), 50.00)';

EXEC #expect_ok N'BR-05', N'Nurse rotates back to the same ward on a new date (v1 defect D2)',
    N'INSERT dbo.NurseAssignment (NurseID, WardID, ShiftDate, HoursWorked)
      VALUES ((SELECT id FROM #ids WHERE k=N''N2''), (SELECT id FROM #ids WHERE k=N''W1''), ''2026-01-06'', 12)';

EXEC #expect_ok N'BR-37', N'Same nurse logs several events for the same patient',
    N'INSERT dbo.NurseCareEvent (AdmissionID, NurseID, EventTypeCode, EventAt) VALUES
      ((SELECT id FROM #ids WHERE k=N''A1''), (SELECT id FROM #ids WHERE k=N''N2''), ''WC'',  ''2026-01-05 08:00''),
      ((SELECT id FROM #ids WHERE k=N''A1''), (SELECT id FROM #ids WHERE k=N''N2''), ''MED'', ''2026-01-05 08:30'')';

/* =============================================================================
   Negative tests: each must be rejected by the named constraint
   ============================================================================= */
-- Nurses
EXEC #expect_fail N'BR-03', N'Supervisor must be an existing nurse',
    N'UPDATE dbo.Nurse SET SupervisorID = -1 WHERE NurseID = (SELECT id FROM #ids WHERE k=N''N2'')', N'FK_Nurse_Nurse_Supervisor';
EXEC #expect_fail N'BR-04', N'Nurse cannot supervise themself',
    N'UPDATE dbo.Nurse SET SupervisorID = NurseID WHERE NurseID = (SELECT id FROM #ids WHERE k=N''N1'')', N'CK_Nurse_NotOwnSupervisor';
EXEC #expect_fail N'BR-01', N'Nurse email must be unique',
    N'INSERT dbo.Nurse (FirstName, LastName, Street, City, Zip, Phone, Email)
      VALUES (N''Dup'', N''Email'', N''x'', N''Tampa'', ''33620'', N''1'', N''test.nurse@example.test'')', N'UQ_Nurse_Email';
EXEC #expect_fail N'BR-01', N'Nurse zip must be 5 digits',
    N'UPDATE dbo.Nurse SET Zip = ''3362A'' WHERE NurseID = (SELECT id FROM #ids WHERE k=N''N1'')', N'CK_Nurse_Zip';
EXEC #expect_fail N'BR-05', N'Duplicate nurse/ward/date assignment rejected',
    N'INSERT dbo.NurseAssignment (NurseID, WardID, ShiftDate, HoursWorked)
      VALUES ((SELECT id FROM #ids WHERE k=N''N2''), (SELECT id FROM #ids WHERE k=N''W1''), ''2026-01-05'', 4)', N'UQ_NurseAssignment_Nurse_Ward_Date';
EXEC #expect_fail N'BR-06', N'Hours worked cannot exceed 24',
    N'INSERT dbo.NurseAssignment (NurseID, WardID, ShiftDate, HoursWorked)
      VALUES ((SELECT id FROM #ids WHERE k=N''N1''), (SELECT id FROM #ids WHERE k=N''W1''), ''2026-01-07'', 25)', N'CK_NurseAssignment_Hours';
EXEC #expect_fail N'BR-06', N'Hours worked must be > 0',
    N'INSERT dbo.NurseAssignment (NurseID, WardID, ShiftDate, HoursWorked)
      VALUES ((SELECT id FROM #ids WHERE k=N''N1''), (SELECT id FROM #ids WHERE k=N''W1''), ''2026-01-08'', 0)', N'CK_NurseAssignment_Hours';

-- Wards and beds
EXEC #expect_fail N'BR-08', N'Ward number must be unique',
    N'INSERT dbo.Ward (WardNumber, WardName, Location, Phone, ChargeNurseID)
      VALUES (N''T-01'', N''Dup'', N''x'', N''1'', (SELECT id FROM #ids WHERE k=N''N2''))', N'UQ_Ward_WardNumber';
EXEC #expect_fail N'BR-10', N'A nurse is charge nurse of at most one ward (v1 defect D5)',
    N'INSERT dbo.Ward (WardNumber, WardName, Location, Phone, ChargeNurseID)
      VALUES (N''T-02'', N''Second'', N''x'', N''1'', (SELECT id FROM #ids WHERE k=N''N1''))', N'UQ_Ward_ChargeNurseID';
EXEC #expect_fail N'BR-11', N'Bed must belong to an existing ward',
    N'INSERT dbo.Bed (WardID, BedNumber) VALUES (-1, N''X1'')', N'FK_Bed_Ward';
EXEC #expect_fail N'BR-12', N'Bed size limited to S/L/XL',
    N'INSERT dbo.Bed (WardID, BedNumber, Size) VALUES ((SELECT id FROM #ids WHERE k=N''W1''), N''X2'', ''M'')', N'CK_Bed_Size';
EXEC #expect_fail N'BR-13', N'Bed type limited to E/M',
    N'INSERT dbo.Bed (WardID, BedNumber, Type) VALUES ((SELECT id FROM #ids WHERE k=N''W1''), N''X3'', ''H'')', N'CK_Bed_Type';
EXEC #expect_fail N'BR-14', N'Bed availability limited to O/A',
    N'INSERT dbo.Bed (WardID, BedNumber, Availability) VALUES ((SELECT id FROM #ids WHERE k=N''W1''), N''X4'', ''R'')', N'CK_Bed_Availability';
EXEC #expect_fail N'BR-11', N'Ward with beds cannot be deleted',
    N'DELETE dbo.Ward WHERE WardID = (SELECT id FROM #ids WHERE k=N''W1'')', N'FK_Bed_Ward';

-- Patients
EXEC #expect_fail N'BR-15', N'Gender limited to F/M/X',
    N'UPDATE dbo.Patient SET Gender = ''Q'' WHERE PatientID = (SELECT id FROM #ids WHERE k=N''PA'')', N'CK_Patient_Gender';
EXEC #expect_fail N'BR-16', N'Date of birth cannot be in the future',
    N'UPDATE dbo.Patient SET DOB = DATEADD(DAY, 1, GETDATE()) WHERE PatientID = (SELECT id FROM #ids WHERE k=N''PA'')', N'CK_Patient_DOB';

-- Admissions
EXEC #expect_fail N'BR-19', N'Admitting physician must exist (v1 defect D1)',
    -- A past, already-discharged stay, so the open-stay index can't fire first
    N'INSERT dbo.Admission (PatientID, AdmitDate, AdmitPhysicianID, DischargeDate, DischargePhysicianID)
      VALUES ((SELECT id FROM #ids WHERE k=N''PB''), ''2025-01-01'', -1, ''2025-01-03'', (SELECT id FROM #ids WHERE k=N''P1''))', N'FK_Admission_Physician_Admit';
EXEC #expect_fail N'BR-20', N'Discharge date without discharging physician rejected',
    N'UPDATE dbo.Admission SET DischargeDate = CAST(GETDATE() AS DATE) WHERE AdmissionID = (SELECT id FROM #ids WHERE k=N''A2'')', N'CK_Admission_DischargePair';
EXEC #expect_fail N'BR-21', N'Discharge before admit rejected',
    N'UPDATE dbo.Admission SET DischargeDate = DATEADD(DAY, -1, AdmitDate), DischargePhysicianID = AdmitPhysicianID
      WHERE AdmissionID = (SELECT id FROM #ids WHERE k=N''A2'')', N'CK_Admission_DischargeAfterAdmit';
EXEC #expect_fail N'BR-22', N'Patient cannot have two open stays',
    N'INSERT dbo.Admission (PatientID, AdmitDate, AdmitPhysicianID)
      VALUES ((SELECT id FROM #ids WHERE k=N''PA''), CAST(GETDATE() AS DATE), (SELECT id FROM #ids WHERE k=N''P1''))', N'UX_Admission_OpenStayPerPatient';

-- Bed assignment
EXEC #expect_fail N'BR-24', N'Occupied bed cannot be given to a second patient (v1 defect D3)',
    N'INSERT dbo.BedAssignment (AdmissionID, BedID, StartDate)
      VALUES ((SELECT id FROM #ids WHERE k=N''A2''), (SELECT id FROM #ids WHERE k=N''B1''), CAST(GETDATE() AS DATE))', N'UX_BedAssignment_CurrentBed';
EXEC #expect_fail N'BR-25', N'A stay cannot hold two current beds',
    N'INSERT dbo.BedAssignment (AdmissionID, BedID, StartDate)
      VALUES ((SELECT id FROM #ids WHERE k=N''A1''), (SELECT id FROM #ids WHERE k=N''B2''), CAST(GETDATE() AS DATE))', N'UX_BedAssignment_CurrentStay';
EXEC #expect_fail N'BR-23', N'Bed assignment cannot end before it starts',
    N'UPDATE dbo.BedAssignment SET EndDate = DATEADD(DAY, -1, StartDate) WHERE BedAssignmentID = (SELECT id FROM #ids WHERE k=N''BA1'')', N'CK_BedAssignment_Dates';
EXEC #expect_ok N'BR-23', N'After the first stay ends, the bed can be reassigned (history kept)',
    N'UPDATE dbo.BedAssignment SET EndDate = StartDate WHERE BedAssignmentID = (SELECT id FROM #ids WHERE k=N''BA1'');
      INSERT dbo.BedAssignment (AdmissionID, BedID, StartDate)
      VALUES ((SELECT id FROM #ids WHERE k=N''A2''), (SELECT id FROM #ids WHERE k=N''B1''), CAST(GETDATE() AS DATE))';

-- Treatments, items, charges
EXEC #expect_fail N'BR-27', N'Treatment name must be unique',
    N'INSERT dbo.Treatment (TreatmentName, StandardCharge) VALUES (N''Test Blood Panel'', 10)', N'UQ_Treatment_Name';
EXEC #expect_fail N'BR-27', N'Treatment charge cannot be negative',
    N'INSERT dbo.Treatment (TreatmentName, StandardCharge) VALUES (N''Negative'', -1)', N'CK_Treatment_Charge';
EXEC #expect_fail N'BR-31', N'Item charge cannot be negative',
    N'INSERT dbo.Item (ItemName, UnitCharge) VALUES (N''Negative'', -0.01)', N'CK_Item_Charge';
EXEC #expect_fail N'BR-32', N'Charged quantity must be > 0',
    N'INSERT dbo.ItemCharge (AdmissionID, ItemID, ChargeDate, Quantity, UnitCharge)
      VALUES ((SELECT id FROM #ids WHERE k=N''A1''), (SELECT id FROM #ids WHERE k=N''I1''), CAST(GETDATE() AS DATE), 0, 4.25)', N'CK_ItemCharge_Quantity';
EXEC #expect_fail N'BR-28', N'Treatment must belong to an existing stay',
    N'INSERT dbo.TreatmentAdministration (AdmissionID, TreatmentID, AdministeredAt, ChargedAmount)
      VALUES (-1, (SELECT id FROM #ids WHERE k=N''T1''), SYSDATETIME(), 1)', N'FK_TreatmentAdministration_Admission';

-- Care events
EXEC #expect_fail N'BR-36', N'Care event type must be a known type',
    N'INSERT dbo.NurseCareEvent (AdmissionID, NurseID, EventTypeCode, EventAt)
      VALUES ((SELECT id FROM #ids WHERE k=N''A1''), (SELECT id FROM #ids WHERE k=N''N2''), ''XYZ'', SYSDATETIME())', N'FK_NurseCareEvent_CareEventType';

/* =============================================================================
   Report and clean up
   ============================================================================= */
DECLARE @r TABLE (TestNo INT, Rule_ NVARCHAR(10), Test NVARCHAR(120), Result CHAR(4), Detail NVARCHAR(400));
INSERT @r SELECT TestNo, Rule_, Test, Result, Detail FROM #results;

ROLLBACK TRANSACTION;   -- leave the database exactly as it was

-- Re-materialize outside the rolled-back transaction so the next batch can see it.
SELECT * INTO #final FROM @r;
SELECT TestNo AS [#], Rule_ AS [Rule], Test, Result, Detail FROM #final ORDER BY TestNo;
GO

-- Separate batch: the results table above is returned before the failure is raised.
DECLARE @pass INT = (SELECT COUNT(*) FROM #final WHERE Result = 'PASS'),
        @fail INT = (SELECT COUNT(*) FROM #final WHERE Result = 'FAIL');
PRINT CONCAT(N'Constraint tests: ', @pass, N' passed, ', @fail, N' failed.');
DROP TABLE #final;
IF @fail > 0 RAISERROR (N'%d constraint test(s) failed.', 16, 1, @fail);
GO

DROP PROCEDURE IF EXISTS #expect_fail;
DROP PROCEDURE IF EXISTS #expect_ok;
DROP PROCEDURE IF EXISTS #expect_equal;
GO
