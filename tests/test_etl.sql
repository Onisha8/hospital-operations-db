/* =============================================================================
   test_etl.sql
   Tests for the patient ETL (sql/05_etl_patient_import.sql):
     - batch audit counts for both files
     - every crafted defect in patient_import_batch2.csv is caught by the right rule,
       and nothing else is flagged
     - cleaned values are normalized correctly in dbo.Patient
     - reloading a file is idempotent (all rows skipped, nothing duplicated)

   The reload test runs inside a transaction that is rolled back.
   Fails the run (RAISERROR severity 16) if any test fails.
   ============================================================================= */

USE HospitalOps;
GO
SET NOCOUNT ON;

DROP TABLE IF EXISTS #results;
CREATE TABLE #results (TestNo INT IDENTITY, Test NVARCHAR(120), Result CHAR(4), Detail NVARCHAR(400));
GO

CREATE OR ALTER PROCEDURE #check @test NVARCHAR(120), @ok BIT, @detail NVARCHAR(400)
AS
    INSERT #results (Test, Result, Detail) VALUES (@test, CASE WHEN @ok = 1 THEN 'PASS' ELSE 'FAIL' END, @detail);
GO

/* ---------- Batch audit counts --------------------------------------------- */
DECLARE @ok BIT, @d NVARCHAR(400);

SELECT @ok = CASE WHEN Status = 'SUCCEEDED' AND RowsRead = 100 AND RowsLoaded = 100 AND RowsRejected = 0 AND RowsSkipped = 0 THEN 1 ELSE 0 END,
       @d  = CONCAT(N'read ', RowsRead, N', loaded ', RowsLoaded, N', rejected ', RowsRejected, N', skipped ', RowsSkipped)
FROM stg.LoadBatch WHERE SourceFile LIKE N'%[/\]patient_import.csv';
EXEC #check N'Course CSV: 100 read, 100 loaded, 0 rejected', @ok, @d;

SELECT @ok = CASE WHEN Status = 'SUCCEEDED' AND RowsRead = 15 AND RowsLoaded = 3 AND RowsRejected = 11 AND RowsSkipped = 1 THEN 1 ELSE 0 END,
       @d  = CONCAT(N'read ', RowsRead, N', loaded ', RowsLoaded, N', rejected ', RowsRejected, N', skipped ', RowsSkipped)
FROM stg.LoadBatch WHERE SourceFile LIKE N'%[/\]patient_import_batch2.csv';
EXEC #check N'Crafted batch: 15 read, 3 loaded, 11 rejected, 1 skipped', @ok, @d;

/* ---------- Exactly the expected errors, on the expected lines ------------- */
DECLARE @expected TABLE (SourceLine INT, ErrorCode CHAR(3));
INSERT @expected VALUES
    (4,'E01'), (5,'E02'), (6,'E03'), (7,'E04'), (8,'E05'), (9,'E06'), (10,'E07'), (11,'E09'),
    (12,'S01'), (13,'E10'), (14,'E08'), (15,'E01'), (15,'E05'), (15,'E07');

DECLARE @batch2 INT = (SELECT LoadBatchID FROM stg.LoadBatch WHERE SourceFile LIKE N'%[/\]patient_import_batch2.csv');
DECLARE @missing INT, @unexpected INT;
SELECT @missing = COUNT(*) FROM (SELECT SourceLine, ErrorCode FROM @expected
                                 EXCEPT SELECT SourceLine, ErrorCode FROM stg.PatientImportError WHERE LoadBatchID = @batch2) x;
SELECT @unexpected = COUNT(*) FROM (SELECT SourceLine, ErrorCode FROM stg.PatientImportError WHERE LoadBatchID = @batch2
                                    EXCEPT SELECT SourceLine, ErrorCode FROM @expected) x;
SET @ok = CASE WHEN @missing = 0 AND @unexpected = 0 THEN 1 ELSE 0 END;
SET @d  = CONCAT(N'missing ', @missing, N', unexpected ', @unexpected);
EXEC #check N'Every crafted defect caught by the right rule; nothing else flagged', @ok, @d;

/* ---------- Normalization of accepted rows --------------------------------- */
SELECT @ok = CASE WHEN COUNT(*) = 1 AND MIN(Gender) = 'M' AND MIN(State) = 'FL' AND MIN(Zip) = '33755'
                       AND MIN(Phone) = N'(727) 555-0199' AND MIN(DOB) = '1970-07-04' THEN 1 ELSE 0 END,
       @d  = CONCAT(N'gender ', MIN(Gender), N', state ', MIN(State), N', zip ', MIN(Zip), N', phone ', MIN(Phone))
FROM dbo.Patient WHERE FirstName = N'James' AND LastName = N'O''Neil';
EXEC #check N'Lowercase gender/state, ZIP+4 and phone format normalized', @ok, @d;

SELECT @ok = CASE WHEN COUNT(*) = 1 AND MIN(DOB) = '1985-03-22' AND MIN(Phone) = N'(813) 555-0142' THEN 1 ELSE 0 END,
       @d  = CONCAT(COUNT(*), N' row(s), DOB ', MIN(DOB), N', phone ', MIN(Phone))
FROM dbo.Patient WHERE FirstName = N'Maria' AND LastName = N'Lopez' AND DOB = '1985-03-22';
EXEC #check N'ISO date accepted; in-file duplicate loaded only once', @ok, @d;

SELECT @ok = CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END, @d = CONCAT(COUNT(*), N' row(s)')
FROM dbo.Patient WHERE LastName = N'Smith, Jr.' AND City = N'Sarasota';
EXEC #check N'Quoted field containing a comma parsed correctly', @ok, @d;

SELECT @ok = CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END, @d = CONCAT(COUNT(*), N' row(s)')
FROM dbo.Patient WHERE FirstName = N'Joelle' AND LastName = N'Grant' AND DOB = '1961-10-15';
EXEC #check N'Patient present in both files exists once', @ok, @d;

-- Rejected rows must not appear in dbo.Patient (matched on name, DOB and street).
SELECT @ok = CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END, @d = CONCAT(COUNT(*), N' leaked row(s)')
FROM stg.vw_PatientImportClean c
JOIN dbo.Patient p
  ON p.FirstName = c.FirstName AND p.LastName = c.LastName AND p.DOB = c.DOB AND p.Street = c.Street
WHERE c.LoadBatchID = @batch2
  AND EXISTS (SELECT 1 FROM stg.PatientImportError e WHERE e.StagingRowID = c.StagingRowID AND e.Severity = 'REJECT')
  -- the in-file duplicate (line 13) legitimately matches the accepted original on line 2
  AND NOT EXISTS (SELECT 1 FROM stg.PatientImportError e WHERE e.StagingRowID = c.StagingRowID AND e.ErrorCode = 'E10');
EXEC #check N'No rejected row leaked into dbo.Patient', @ok, @d;
GO

/* ---------- Idempotent reload (rolled back) -------------------------------- */
DECLARE @before INT = (SELECT COUNT(*) FROM dbo.Patient), @after INT, @ok BIT, @d NVARCHAR(400);

BEGIN TRANSACTION;
    EXEC stg.usp_LoadPatientFile @FilePath = N'$(DataDir)/patient_import.csv';
    SET @after = (SELECT COUNT(*) FROM dbo.Patient);
    SELECT @ok = CASE WHEN RowsRead = 100 AND RowsLoaded = 0 AND RowsSkipped = 100 AND @after = @before THEN 1 ELSE 0 END,
           @d  = CONCAT(N'loaded ', RowsLoaded, N', skipped ', RowsSkipped, N', patients ', @before, N' -> ', @after)
    FROM stg.LoadBatch WHERE LoadBatchID = (SELECT MAX(LoadBatchID) FROM stg.LoadBatch);
ROLLBACK TRANSACTION;

EXEC #check N'Reloading the same file adds nothing (all 100 skipped)', @ok, @d;
GO

/* ---------- Report ----------------------------------------------------------- */
SELECT TestNo AS [#], Test, Result, Detail FROM #results ORDER BY TestNo;

DECLARE @pass INT = (SELECT COUNT(*) FROM #results WHERE Result = 'PASS'),
        @fail INT = (SELECT COUNT(*) FROM #results WHERE Result = 'FAIL');
PRINT CONCAT(N'ETL tests: ', @pass, N' passed, ', @fail, N' failed.');
GO
DECLARE @fail INT = (SELECT COUNT(*) FROM #results WHERE Result = 'FAIL');
DROP TABLE #results;
DROP PROCEDURE #check;
IF @fail > 0 RAISERROR (N'%d ETL test(s) failed.', 16, 1, @fail);
GO
