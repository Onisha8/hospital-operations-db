/* =============================================================================
   05_etl_patient_import.sql
   ETL for patient CSV files:  file --BULK INSERT--> stg --validate--> dbo.Patient

     Extract   stg.usp_LoadPatientFile    BULK INSERT the raw file into stg.PatientImport
                                          (every column NVARCHAR, so a bad value never
                                          aborts the load)
     Transform stg.vw_PatientImportClean  one place that parses and normalizes every field
     Validate  stg.usp_ValidatePatientImport
                                          writes one row per broken rule to
                                          stg.PatientImportError
     Load      stg.usp_PublishPatientImport
                                          inserts only clean, new rows into dbo.Patient
     Audit     stg.LoadBatch              one row per file load with read / loaded /
                                          rejected / skipped counts

   Idempotent: a patient that already exists (same first name, last name and DOB)
   is SKIPPED, not duplicated, so the same file can be loaded twice safely.

   Uses the sqlcmd-style variable $(DataDir) (paths use "/", which works on Windows and Linux). run_sql.ps1 sets it to the repo's
   data folder. With sqlcmd, use -v DataDir="C:\path\to\data".
   ============================================================================= */

USE HospitalOps;
GO

/* =============================================================================
   Staging objects (rebuilt on every run)
   ============================================================================= */
DROP VIEW      IF EXISTS stg.vw_PatientImportClean;
DROP VIEW      IF EXISTS stg.vw_PatientImportLoad;
DROP PROCEDURE IF EXISTS stg.usp_LoadPatientFile;
DROP PROCEDURE IF EXISTS stg.usp_ValidatePatientImport;
DROP PROCEDURE IF EXISTS stg.usp_PublishPatientImport;
DROP TABLE     IF EXISTS stg.PatientImportError;
DROP TABLE     IF EXISTS stg.PatientImport;
DROP TABLE     IF EXISTS stg.LoadBatch;
DROP TABLE     IF EXISTS stg.UsState;
GO

CREATE TABLE stg.LoadBatch (
    LoadBatchID     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LoadBatch PRIMARY KEY,
    SourceFile      NVARCHAR(400)   NOT NULL,
    StartedAt       DATETIME2(0)    NOT NULL CONSTRAINT DF_LoadBatch_StartedAt DEFAULT (SYSDATETIME()),
    FinishedAt      DATETIME2(0)    NULL,
    Status          VARCHAR(10)     NOT NULL CONSTRAINT DF_LoadBatch_Status DEFAULT ('RUNNING'),
    RowsRead        INT             NULL,
    RowsLoaded      INT             NULL,
    RowsRejected    INT             NULL,
    RowsSkipped     INT             NULL,
    ErrorMessage    NVARCHAR(2000)  NULL,
    CONSTRAINT CK_LoadBatch_Status CHECK (Status IN ('RUNNING', 'SUCCEEDED', 'FAILED'))
);

-- Raw landing table: wide NVARCHAR columns, no constraints on the data itself.
CREATE TABLE stg.PatientImport (
    StagingRowID    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PatientImport PRIMARY KEY,
    LoadBatchID     INT             NULL CONSTRAINT FK_PatientImport_LoadBatch REFERENCES stg.LoadBatch (LoadBatchID),
    SourceLine      INT             NULL,    -- line number in the file (header = line 1)
    FirstName       NVARCHAR(400)   NULL,
    LastName        NVARCHAR(400)   NULL,
    Phone           NVARCHAR(400)   NULL,
    Gender          NVARCHAR(400)   NULL,
    DOB             NVARCHAR(400)   NULL,
    Street          NVARCHAR(400)   NULL,
    City            NVARCHAR(400)   NULL,
    State           NVARCHAR(400)   NULL,
    Zip             NVARCHAR(400)   NULL,
    BedNo           NVARCHAR(400)   NULL     -- v1 legacy column; in v2 beds belong to an admission, so it is not loaded
);

CREATE TABLE stg.PatientImportError (
    ErrorID         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PatientImportError PRIMARY KEY,
    LoadBatchID     INT             NOT NULL CONSTRAINT FK_PatientImportError_LoadBatch REFERENCES stg.LoadBatch (LoadBatchID),
    StagingRowID    INT             NOT NULL CONSTRAINT FK_PatientImportError_PatientImport REFERENCES stg.PatientImport (StagingRowID),
    SourceLine      INT             NOT NULL,
    Severity        VARCHAR(6)      NOT NULL CONSTRAINT CK_PatientImportError_Severity CHECK (Severity IN ('REJECT', 'SKIP')),
    ErrorCode       CHAR(3)         NOT NULL,
    ErrorMessage    NVARCHAR(200)   NOT NULL,
    RawValue        NVARCHAR(400)   NULL
);

CREATE TABLE stg.UsState (
    StateCode       CHAR(2)         NOT NULL CONSTRAINT PK_UsState PRIMARY KEY
);
INSERT stg.UsState (StateCode) VALUES
    ('AL'),('AK'),('AZ'),('AR'),('CA'),('CO'),('CT'),('DE'),('DC'),('FL'),('GA'),('HI'),('ID'),('IL'),('IN'),
    ('IA'),('KS'),('KY'),('LA'),('ME'),('MD'),('MA'),('MI'),('MN'),('MS'),('MO'),('MT'),('NE'),('NV'),('NH'),
    ('NJ'),('NM'),('NY'),('NC'),('ND'),('OH'),('OK'),('OR'),('PA'),('RI'),('SC'),('SD'),('TN'),('TX'),('UT'),
    ('VT'),('VA'),('WA'),('WV'),('WI'),('WY'),('PR');
GO

-- BULK INSERT target: exposes only the file's columns so IDENTITY numbers rows in file order.
CREATE VIEW stg.vw_PatientImportLoad
AS
SELECT FirstName, LastName, Phone, Gender, DOB, Street, City, State, Zip, BedNo
FROM stg.PatientImport;
GO

/* =============================================================================
   Transform: one view that parses and normalizes every field.
   Validation and publishing both read from here, so the rules can't drift apart.
   ============================================================================= */
CREATE VIEW stg.vw_PatientImportClean
AS
SELECT
    s.StagingRowID,
    s.LoadBatchID,
    s.SourceLine,
    s.FirstName  AS RawFirstName,  s.LastName AS RawLastName, s.Phone AS RawPhone,
    s.Gender     AS RawGender,     s.DOB      AS RawDOB,      s.Street AS RawStreet,
    s.City       AS RawCity,       s.State    AS RawState,    s.Zip AS RawZip,
    NULLIF(TRIM(s.FirstName), N'')  AS FirstName,
    NULLIF(TRIM(s.LastName),  N'')  AS LastName,
    NULLIF(TRIM(s.Street),    N'')  AS Street,
    NULLIF(TRIM(s.City),      N'')  AS City,
    UPPER(NULLIF(TRIM(s.State), N'')) AS State,
    -- Gender: accept M/F/X in any case, or the words Male/Female
    CASE UPPER(TRIM(s.Gender))
        WHEN 'F' THEN 'F' WHEN 'FEMALE' THEN 'F'
        WHEN 'M' THEN 'M' WHEN 'MALE'   THEN 'M'
        WHEN 'X' THEN 'X'
    END AS Gender,
    -- DOB: accept "Oct 15, 1961" (style 107), ISO "1985-03-22" (style 23) and US "03/22/1985" (style 101)
    COALESCE(TRY_CONVERT(DATE, TRIM(s.DOB), 107),
             TRY_CONVERT(DATE, TRIM(s.DOB), 23),
             TRY_CONVERT(DATE, TRIM(s.DOB), 101)) AS DOB,
    -- Zip: 5 digits, or ZIP+4 truncated to 5
    CASE WHEN TRIM(s.Zip) LIKE '[0-9][0-9][0-9][0-9][0-9]'
           OR TRIM(s.Zip) LIKE '[0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]'
         THEN LEFT(TRIM(s.Zip), 5) END AS Zip,
    ph.Digits AS PhoneDigits,
    -- Phone: normalized to (813) 555-0142 when it has exactly 10 digits (or 11 with a leading 1)
    CASE WHEN LEN(ph.Digits10) = 10
         THEN CONCAT(N'(', LEFT(ph.Digits10, 3), N') ', SUBSTRING(ph.Digits10, 4, 3), N'-', RIGHT(ph.Digits10, 4))
    END AS Phone
FROM stg.PatientImport AS s
CROSS APPLY (
    SELECT REPLACE(TRANSLATE(ISNULL(s.Phone, N''), N'()-.+', N'     '), N' ', N'') AS Digits
) AS d
CROSS APPLY (
    SELECT d.Digits,
           CASE WHEN d.Digits LIKE N'%[^0-9]%' THEN NULL
                WHEN LEN(d.Digits) = 11 AND LEFT(d.Digits, 1) = N'1' THEN RIGHT(d.Digits, 10)
                ELSE d.Digits END AS Digits10
) AS ph;
GO

/* =============================================================================
   Validate: one error row per broken rule (a row can have several)
   ============================================================================= */
CREATE PROCEDURE stg.usp_ValidatePatientImport
    @LoadBatchID INT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE stg.PatientImportError WHERE LoadBatchID = @LoadBatchID;

    INSERT stg.PatientImportError (LoadBatchID, StagingRowID, SourceLine, Severity, ErrorCode, ErrorMessage, RawValue)
    SELECT c.LoadBatchID, c.StagingRowID, c.SourceLine, 'REJECT', e.ErrorCode, e.ErrorMessage, e.RawValue
    FROM stg.vw_PatientImportClean AS c
    CROSS APPLY (VALUES
        -- E01 required fields
        (CASE WHEN c.FirstName IS NULL THEN 'E01' END, N'FirstName is required',              c.RawFirstName),
        (CASE WHEN c.LastName  IS NULL THEN 'E01' END, N'LastName is required',               c.RawLastName),
        (CASE WHEN c.Street    IS NULL THEN 'E01' END, N'Street is required',                 c.RawStreet),
        (CASE WHEN c.City      IS NULL THEN 'E01' END, N'City is required',                   c.RawCity),
        -- E02-E04 date of birth
        (CASE WHEN c.DOB IS NULL THEN 'E02' END,       N'DOB is missing or not a valid date', c.RawDOB),
        (CASE WHEN c.DOB > CAST(GETDATE() AS DATE) THEN 'E03' END,
                                                       N'DOB is in the future',               c.RawDOB),
        (CASE WHEN c.DOB < DATEADD(YEAR, -120, CAST(GETDATE() AS DATE)) THEN 'E04' END,
                                                       N'DOB is more than 120 years ago',     c.RawDOB),
        -- E05-E07 coded values
        (CASE WHEN c.Gender IS NULL THEN 'E05' END,    N'Gender must be F, M or X',           c.RawGender),
        (CASE WHEN c.State IS NULL
                OR NOT EXISTS (SELECT 1 FROM stg.UsState AS u WHERE u.StateCode = c.State) THEN 'E06' END,
                                                       N'State is not a valid US state code', c.RawState),
        (CASE WHEN c.Zip IS NULL THEN 'E07' END,       N'Zip must be 5 digits or ZIP+4',      c.RawZip),
        -- E08 lengths that would be truncated in dbo.Patient
        (CASE WHEN LEN(c.FirstName) > 30 THEN 'E08' END, N'FirstName longer than 30 characters', c.RawFirstName),
        (CASE WHEN LEN(c.LastName)  > 40 THEN 'E08' END, N'LastName longer than 40 characters',  c.RawLastName),
        (CASE WHEN LEN(c.Street)   > 100 THEN 'E08' END, N'Street longer than 100 characters',   c.RawStreet),
        (CASE WHEN LEN(c.City)      > 30 THEN 'E08' END, N'City longer than 30 characters',      c.RawCity),
        -- E09 phone
        (CASE WHEN c.Phone IS NULL THEN 'E09' END,     N'Phone must have 10 digits',          c.RawPhone)
    ) AS e (ErrorCode, ErrorMessage, RawValue)
    WHERE c.LoadBatchID = @LoadBatchID
      AND e.ErrorCode IS NOT NULL;

    -- E10 duplicate inside the same file: keep the first occurrence, reject the rest
    WITH d AS (
        SELECT c.*,
               ROW_NUMBER()      OVER (PARTITION BY c.FirstName, c.LastName, c.DOB ORDER BY c.StagingRowID) AS rn,
               MIN(c.SourceLine) OVER (PARTITION BY c.FirstName, c.LastName, c.DOB) AS FirstLine
        FROM stg.vw_PatientImportClean AS c
        WHERE c.LoadBatchID = @LoadBatchID
          AND c.FirstName IS NOT NULL AND c.LastName IS NOT NULL AND c.DOB IS NOT NULL
    )
    INSERT stg.PatientImportError (LoadBatchID, StagingRowID, SourceLine, Severity, ErrorCode, ErrorMessage, RawValue)
    SELECT d.LoadBatchID, d.StagingRowID, d.SourceLine, 'REJECT', 'E10',
           CONCAT(N'Duplicate of line ', d.FirstLine, N' in the same file'),
           CONCAT(d.FirstName, N' ', d.LastName, N' ', d.RawDOB)
    FROM d
    WHERE d.rn > 1;

    -- S01 already in dbo.Patient: skip quietly (makes reloading a file safe)
    INSERT stg.PatientImportError (LoadBatchID, StagingRowID, SourceLine, Severity, ErrorCode, ErrorMessage, RawValue)
    SELECT c.LoadBatchID, c.StagingRowID, c.SourceLine, 'SKIP', 'S01',
           CONCAT(N'Already exists as PatientID ', p.PatientID),
           CONCAT(c.FirstName, N' ', c.LastName, N' ', c.RawDOB)
    FROM stg.vw_PatientImportClean AS c
    JOIN dbo.Patient AS p
      ON p.FirstName = c.FirstName AND p.LastName = c.LastName AND p.DOB = c.DOB
    WHERE c.LoadBatchID = @LoadBatchID
      AND NOT EXISTS (SELECT 1 FROM stg.PatientImportError AS x
                      WHERE x.StagingRowID = c.StagingRowID AND x.Severity = 'REJECT');
END;
GO

/* =============================================================================
   Load: insert rows that have no REJECT or SKIP entries
   ============================================================================= */
CREATE PROCEDURE stg.usp_PublishPatientImport
    @LoadBatchID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;

    INSERT dbo.Patient (FirstName, LastName, Gender, DOB, Street, City, State, Zip, Phone)
    SELECT c.FirstName, c.LastName, c.Gender, c.DOB, c.Street, c.City, c.State, c.Zip, c.Phone
    FROM stg.vw_PatientImportClean AS c
    WHERE c.LoadBatchID = @LoadBatchID
      AND NOT EXISTS (SELECT 1 FROM stg.PatientImportError AS e WHERE e.StagingRowID = c.StagingRowID)
    ORDER BY c.SourceLine;

    DECLARE @loaded INT = @@ROWCOUNT;

    UPDATE stg.LoadBatch
    SET RowsLoaded   = @loaded,
        RowsRejected = (SELECT COUNT(DISTINCT StagingRowID) FROM stg.PatientImportError
                        WHERE LoadBatchID = @LoadBatchID AND Severity = 'REJECT'),
        RowsSkipped  = (SELECT COUNT(DISTINCT StagingRowID) FROM stg.PatientImportError
                        WHERE LoadBatchID = @LoadBatchID AND Severity = 'SKIP')
    WHERE LoadBatchID = @LoadBatchID;

    COMMIT TRANSACTION;
END;
GO

/* =============================================================================
   Orchestrator: extract a file, then validate and publish it, with audit logging
   ============================================================================= */
CREATE PROCEDURE stg.usp_LoadPatientFile
    @FilePath NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @batch INT, @firstRow INT, @sql NVARCHAR(MAX);

    INSERT stg.LoadBatch (SourceFile) VALUES (@FilePath);
    SET @batch = SCOPE_IDENTITY();

    BEGIN TRY
        -- Extract. BULK INSERT doesn't accept a variable path, so it runs as dynamic SQL
        -- with embedded quotes escaped.
        -- ROWTERMINATOR 0x0a (LF) accepts both Windows (CRLF) and Unix (LF) files; with CRLF
        -- the stray CR lands in the last column (BedNo), which is not loaded.
        -- CODEPAGE = 65001 (UTF-8) is only valid on Windows; SQL Server on Linux (the Docker
        -- build) rejects it, so it's added only there. The files are ASCII either way.
        SET @firstRow = ISNULL((SELECT MAX(StagingRowID) FROM stg.PatientImport), 0) + 1;
        SET @sql = N'BULK INSERT stg.vw_PatientImportLoad FROM N''' + REPLACE(@FilePath, N'''', N'''''') + N'''
                     WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDQUOTE = ''"'', ROWTERMINATOR = ''0x0a'', TABLOCK'
                 + CASE WHEN @@VERSION LIKE N'%Linux%' THEN N'' ELSE N', CODEPAGE = ''65001''' END
                 + N');';
        EXEC sys.sp_executesql @sql;

        -- Tag the new rows with the batch and their line number in the file (header is line 1).
        UPDATE stg.PatientImport
        SET LoadBatchID = @batch,
            SourceLine  = StagingRowID - @firstRow + 2
        WHERE LoadBatchID IS NULL;

        UPDATE stg.LoadBatch SET RowsRead = @@ROWCOUNT WHERE LoadBatchID = @batch;

        EXEC stg.usp_ValidatePatientImport @LoadBatchID = @batch;
        EXEC stg.usp_PublishPatientImport  @LoadBatchID = @batch;

        UPDATE stg.LoadBatch SET Status = 'SUCCEEDED', FinishedAt = SYSDATETIME() WHERE LoadBatchID = @batch;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE stg.LoadBatch
        SET Status = 'FAILED', FinishedAt = SYSDATETIME(), ErrorMessage = ERROR_MESSAGE()
        WHERE LoadBatchID = @batch;
        THROW;
    END CATCH;

    SELECT LoadBatchID, RIGHT(SourceFile, 40) AS SourceFile, Status, RowsRead, RowsLoaded, RowsRejected, RowsSkipped
    FROM stg.LoadBatch WHERE LoadBatchID = @batch;
END;
GO

/* =============================================================================
   Run the ETL
     batch 1: the course's patient extract (100 rows, clean)
     batch 2: a crafted extract with deliberate defects, to exercise every rule
   ============================================================================= */
EXEC stg.usp_LoadPatientFile @FilePath = N'$(DataDir)/patient_import.csv';
EXEC stg.usp_LoadPatientFile @FilePath = N'$(DataDir)/patient_import_batch2.csv';
GO

SELECT e.LoadBatchID AS Batch, e.SourceLine AS Line, e.Severity, e.ErrorCode AS Code, e.ErrorMessage, e.RawValue
FROM stg.PatientImportError AS e
ORDER BY e.LoadBatchID, e.SourceLine, e.ErrorCode;
GO

PRINT N'05_etl_patient_import.sql completed.';
GO
