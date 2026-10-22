/* =============================================================================
   08_stored_procedures.sql
   Transactional procedures for the patient-stay workflow
   (docs/01_requirements.md, section 1.5) and the itemized bill (R6).

     dbo.usp_AdmitPatient       open a stay, assign a bed, mark the bed occupied
     dbo.usp_TransferPatient    move a stay to another bed (bed history kept)
     dbo.usp_RecordItemCharge   charge an item to a stay at today's list price
     dbo.usp_RecordTreatment    record a treatment at today's list price
     dbo.usp_DischargePatient   close the stay and bed assignment, release the bed
     dbo.usp_GetPatientBill     itemized bill for a stay (read-only)

   Transaction pattern (used by every procedure that writes):
   - If the caller has no open transaction, the procedure begins and commits its own.
   - If the caller already has one, it sets a SAVEPOINT instead. On error it rolls
     back only its own work and re-throws, so procedures can be composed inside a
     larger transaction (the tests rely on this).
   - XACT_ABORT is left OFF on purpose: with it ON, every error dooms the caller's
     whole transaction, which would defeat the savepoint.

   Concurrency:
   - Checks that are then acted on ("is the bed free?") read with UPDLOCK, HOLDLOCK,
     so two admissions can't both see the same bed as available. Under READ
     COMMITTED SNAPSHOT a plain SELECT would read a version and not block.
   - Automatic bed choice uses UPDLOCK, READPAST: concurrent admissions skip beds
     another session is taking instead of queueing behind it.
   - The filtered unique indexes from 03_constraints.sql are the last line of defence.

   Errors are raised with THROW 500xx (catalog in docs/06_reports_and_procedures.md).
   Re-runnable: CREATE OR ALTER.
   ============================================================================= */

USE HospitalOps;
GO

/* =============================================================================
   usp_AdmitPatient  (BR-19, BR-22, BR-23, BR-26)
   Pass @BedID for a specific bed, or leave it NULL to take the first available
   bed (optionally within @WardID).
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_AdmitPatient
    @PatientID        INT,
    @AdmitPhysicianID INT,
    @BedID            INT  = NULL,
    @WardID           INT  = NULL,
    @AdmitDate        DATE = NULL,
    @AdmissionID      INT  = NULL OUTPUT,
    @AssignedBedID    INT  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(2048), @open INT, @avail CHAR(1);
    SET @AdmitDate = ISNULL(@AdmitDate, CAST(GETDATE() AS DATE));

    BEGIN TRY
        IF @tc = 0 BEGIN TRANSACTION; ELSE SAVE TRANSACTION sp_AdmitPatient;

        IF @AdmitDate > CAST(GETDATE() AS DATE)
            THROW 50007, N'Admit date cannot be in the future.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Patient WHERE PatientID = @PatientID)
        BEGIN
            SET @msg = CONCAT(N'Patient ', @PatientID, N' not found.'); THROW 50001, @msg, 1;
        END;
        IF NOT EXISTS (SELECT 1 FROM dbo.Physician WHERE PhysicianID = @AdmitPhysicianID)
        BEGIN
            SET @msg = CONCAT(N'Physician ', @AdmitPhysicianID, N' not found.'); THROW 50002, @msg, 1;
        END;

        -- BR-22: one open stay per patient. HOLDLOCK keeps a concurrent admit of the
        -- same patient from slipping in between this check and the insert.
        SELECT @open = AdmissionID
        FROM dbo.Admission WITH (UPDLOCK, HOLDLOCK)
        WHERE PatientID = @PatientID AND DischargeDate IS NULL;
        IF @open IS NOT NULL
        BEGIN
            SET @msg = CONCAT(N'Patient ', @PatientID, N' is already admitted (AdmissionID ', @open, N').'); THROW 50003, @msg, 1;
        END;

        -- BR-26: only an available bed can be assigned
        IF @BedID IS NULL
        BEGIN
            SELECT TOP (1) @BedID = BedID
            FROM dbo.Bed WITH (UPDLOCK, READPAST, ROWLOCK)
            WHERE Availability = 'A' AND (@WardID IS NULL OR WardID = @WardID)
            ORDER BY WardID, BedID;
            IF @BedID IS NULL
            BEGIN
                SET @msg = CONCAT(N'No available bed', CASE WHEN @WardID IS NOT NULL THEN CONCAT(N' in ward ', @WardID) END, N'.');
                THROW 50005, @msg, 1;
            END;
        END
        ELSE
        BEGIN
            SELECT @avail = Availability FROM dbo.Bed WITH (UPDLOCK, HOLDLOCK) WHERE BedID = @BedID;
            IF @avail IS NULL
            BEGIN
                SET @msg = CONCAT(N'Bed ', @BedID, N' not found.'); THROW 50006, @msg, 1;
            END;
            IF @avail <> 'A'
            BEGIN
                SET @msg = CONCAT(N'Bed ', @BedID, N' is not available.'); THROW 50004, @msg, 1;
            END;
        END;

        INSERT dbo.Admission (PatientID, AdmitDate, AdmitPhysicianID)
        VALUES (@PatientID, @AdmitDate, @AdmitPhysicianID);
        SET @AdmissionID = SCOPE_IDENTITY();

        INSERT dbo.BedAssignment (AdmissionID, BedID, StartDate)
        VALUES (@AdmissionID, @BedID, @AdmitDate);

        UPDATE dbo.Bed SET Availability = 'O' WHERE BedID = @BedID;
        SET @AssignedBedID = @BedID;

        IF @tc = 0 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION;                       -- doomed: only a full rollback is possible
        ELSE IF XACT_STATE() = 1 AND @tc = 0 ROLLBACK TRANSACTION;       -- our own transaction
        ELSE IF XACT_STATE() = 1 ROLLBACK TRANSACTION sp_AdmitPatient;   -- caller's: undo only our work
        SET @AdmissionID = NULL; SET @AssignedBedID = NULL;
        THROW;
    END CATCH;
END;
GO

/* =============================================================================
   usp_TransferPatient  (BR-23, BR-25, BR-26)
   Closes the current bed assignment and opens a new one on the same date.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_TransferPatient
    @AdmissionID  INT,
    @NewBedID     INT,
    @TransferDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(2048), @exists BIT = 0, @discharged DATE,
            @curAssign INT, @curBed INT, @curStart DATE, @avail CHAR(1);
    SET @TransferDate = ISNULL(@TransferDate, CAST(GETDATE() AS DATE));

    BEGIN TRY
        IF @tc = 0 BEGIN TRANSACTION; ELSE SAVE TRANSACTION sp_TransferPatient;

        SELECT @exists = 1, @discharged = DischargeDate
        FROM dbo.Admission WITH (UPDLOCK, HOLDLOCK) WHERE AdmissionID = @AdmissionID;
        IF @exists = 0
        BEGIN
            SET @msg = CONCAT(N'Stay ', @AdmissionID, N' not found.'); THROW 50010, @msg, 1;
        END;
        IF @discharged IS NOT NULL
        BEGIN
            SET @msg = CONCAT(N'Stay ', @AdmissionID, N' is already discharged.'); THROW 50011, @msg, 1;
        END;

        SELECT @curAssign = BedAssignmentID, @curBed = BedID, @curStart = StartDate
        FROM dbo.BedAssignment WITH (UPDLOCK, HOLDLOCK)
        WHERE AdmissionID = @AdmissionID AND EndDate IS NULL;

        IF @NewBedID = @curBed
            THROW 50014, N'Patient is already in that bed.', 1;
        IF @TransferDate > CAST(GETDATE() AS DATE)
            THROW 50007, N'Transfer date cannot be in the future.', 1;
        IF @TransferDate < @curStart
            THROW 50012, N'Transfer date is before the current bed assignment started.', 1;

        SELECT @avail = Availability FROM dbo.Bed WITH (UPDLOCK, HOLDLOCK) WHERE BedID = @NewBedID;
        IF @avail IS NULL
        BEGIN
            SET @msg = CONCAT(N'Bed ', @NewBedID, N' not found.'); THROW 50006, @msg, 1;
        END;
        IF @avail <> 'A'
        BEGIN
            SET @msg = CONCAT(N'Bed ', @NewBedID, N' is not available.'); THROW 50004, @msg, 1;
        END;

        -- Close first: the filtered unique index allows only one current bed per stay (BR-25).
        UPDATE dbo.BedAssignment SET EndDate = @TransferDate WHERE BedAssignmentID = @curAssign;
        UPDATE dbo.Bed SET Availability = 'A' WHERE BedID = @curBed;

        INSERT dbo.BedAssignment (AdmissionID, BedID, StartDate) VALUES (@AdmissionID, @NewBedID, @TransferDate);
        UPDATE dbo.Bed SET Availability = 'O' WHERE BedID = @NewBedID;

        IF @tc = 0 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION;
        ELSE IF XACT_STATE() = 1 AND @tc = 0 ROLLBACK TRANSACTION;
        ELSE IF XACT_STATE() = 1 ROLLBACK TRANSACTION sp_TransferPatient;
        THROW;
    END CATCH;
END;
GO

/* =============================================================================
   usp_RecordItemCharge  (BR-32, BR-33)
   The unit price is copied from the catalog at the time of the charge.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_RecordItemCharge
    @AdmissionID  INT,
    @ItemID       INT,
    @Quantity     INT  = 1,
    @ChargeDate   DATE = NULL,
    @ItemChargeID INT  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @msg NVARCHAR(2048), @admit DATE, @discharge DATE, @price DECIMAL(10,2), @found BIT = 0;
    SET @ChargeDate = ISNULL(@ChargeDate, CAST(GETDATE() AS DATE));

    SELECT @found = 1, @admit = AdmitDate, @discharge = DischargeDate FROM dbo.Admission WHERE AdmissionID = @AdmissionID;
    IF @found = 0
    BEGIN
        SET @msg = CONCAT(N'Stay ', @AdmissionID, N' not found.'); THROW 50010, @msg, 1;
    END;
    SELECT @price = UnitCharge FROM dbo.Item WHERE ItemID = @ItemID;
    IF @price IS NULL
    BEGIN
        SET @msg = CONCAT(N'Item ', @ItemID, N' not found.'); THROW 50015, @msg, 1;
    END;
    IF @Quantity IS NULL OR @Quantity <= 0
        THROW 50016, N'Quantity must be greater than zero.', 1;
    IF @ChargeDate < @admit OR @ChargeDate > ISNULL(@discharge, CAST(GETDATE() AS DATE))
        THROW 50017, N'Charge date is outside the stay.', 1;

    -- A single INSERT is atomic, so no explicit transaction is needed.
    INSERT dbo.ItemCharge (AdmissionID, ItemID, ChargeDate, Quantity, UnitCharge)
    VALUES (@AdmissionID, @ItemID, @ChargeDate, @Quantity, @price);
    SET @ItemChargeID = SCOPE_IDENTITY();
END;
GO

/* =============================================================================
   usp_RecordTreatment  (BR-28, BR-29, BR-30, BR-33)
   @PhysicianID may be NULL (treating physician not recorded).
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_RecordTreatment
    @AdmissionID      INT,
    @TreatmentID      INT,
    @PhysicianID      INT           = NULL,
    @AdministeredAt   DATETIME2(0)  = NULL,
    @Results          NVARCHAR(255) = NULL,
    @TreatmentAdminID INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @msg NVARCHAR(2048), @admit DATE, @discharge DATE, @price DECIMAL(10,2), @found BIT = 0;
    SET @AdministeredAt = ISNULL(@AdministeredAt, CAST(SYSDATETIME() AS DATETIME2(0)));

    SELECT @found = 1, @admit = AdmitDate, @discharge = DischargeDate FROM dbo.Admission WHERE AdmissionID = @AdmissionID;
    IF @found = 0
    BEGIN
        SET @msg = CONCAT(N'Stay ', @AdmissionID, N' not found.'); THROW 50010, @msg, 1;
    END;
    SELECT @price = StandardCharge FROM dbo.Treatment WHERE TreatmentID = @TreatmentID;
    IF @price IS NULL
    BEGIN
        SET @msg = CONCAT(N'Treatment ', @TreatmentID, N' not found.'); THROW 50015, @msg, 1;
    END;
    IF @PhysicianID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Physician WHERE PhysicianID = @PhysicianID)
    BEGIN
        SET @msg = CONCAT(N'Physician ', @PhysicianID, N' not found.'); THROW 50002, @msg, 1;
    END;
    -- Compare against the clock at the SAME precision as the column. CAST to
    -- DATETIME2(0) rounds to the nearest second, so a default taken at hh:mm:ss.6
    -- becomes hh:mm:ss+1 and would look "in the future" next to the raw
    -- SYSDATETIME(). That was an intermittent bug caught by the test suite.
    IF CAST(@AdministeredAt AS DATE) < @admit
       OR (@discharge IS NOT NULL AND CAST(@AdministeredAt AS DATE) > @discharge)
       OR @AdministeredAt > CAST(SYSDATETIME() AS DATETIME2(0))
        THROW 50017, N'Treatment time is outside the stay.', 1;

    INSERT dbo.TreatmentAdministration (AdmissionID, TreatmentID, PhysicianID, AdministeredAt, Results, ChargedAmount)
    VALUES (@AdmissionID, @TreatmentID, @PhysicianID, @AdministeredAt, @Results, @price);
    SET @TreatmentAdminID = SCOPE_IDENTITY();
END;
GO

/* =============================================================================
   usp_DischargePatient  (BR-20, BR-21, BR-26, BR-34)
   Refuses to discharge a stay with no item charges (BR-34).
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_DischargePatient
    @AdmissionID          INT,
    @DischargePhysicianID INT,
    @DischargeDate        DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(2048), @found BIT = 0, @admit DATE, @discharged DATE, @bedStart DATE;
    DECLARE @released TABLE (BedID INT);
    SET @DischargeDate = ISNULL(@DischargeDate, CAST(GETDATE() AS DATE));

    BEGIN TRY
        IF @tc = 0 BEGIN TRANSACTION; ELSE SAVE TRANSACTION sp_DischargePatient;

        SELECT @found = 1, @admit = AdmitDate, @discharged = DischargeDate
        FROM dbo.Admission WITH (UPDLOCK, HOLDLOCK) WHERE AdmissionID = @AdmissionID;
        IF @found = 0
        BEGIN
            SET @msg = CONCAT(N'Stay ', @AdmissionID, N' not found.'); THROW 50010, @msg, 1;
        END;
        IF @discharged IS NOT NULL
        BEGIN
            SET @msg = CONCAT(N'Stay ', @AdmissionID, N' was already discharged on ', @discharged, N'.'); THROW 50011, @msg, 1;
        END;
        IF NOT EXISTS (SELECT 1 FROM dbo.Physician WHERE PhysicianID = @DischargePhysicianID)
        BEGIN
            SET @msg = CONCAT(N'Physician ', @DischargePhysicianID, N' not found.'); THROW 50002, @msg, 1;
        END;
        IF @DischargeDate > CAST(GETDATE() AS DATE)
            THROW 50007, N'Discharge date cannot be in the future.', 1;

        SELECT @bedStart = StartDate FROM dbo.BedAssignment WHERE AdmissionID = @AdmissionID AND EndDate IS NULL;
        IF @DischargeDate < @admit OR @DischargeDate < @bedStart
            THROW 50012, N'Discharge date is before the admission or the current bed assignment.', 1;

        -- BR-34: every stay incurs at least one consumable item charge
        IF NOT EXISTS (SELECT 1 FROM dbo.ItemCharge WHERE AdmissionID = @AdmissionID)
        BEGIN
            SET @msg = CONCAT(N'Stay ', @AdmissionID, N' has no item charges; record at least one before discharge (BR-34).');
            THROW 50013, @msg, 1;
        END;

        UPDATE dbo.BedAssignment
        SET EndDate = @DischargeDate
        OUTPUT inserted.BedID INTO @released
        WHERE AdmissionID = @AdmissionID AND EndDate IS NULL;

        UPDATE dbo.Bed SET Availability = 'A' WHERE BedID IN (SELECT BedID FROM @released);

        UPDATE dbo.Admission
        SET DischargeDate = @DischargeDate, DischargePhysicianID = @DischargePhysicianID
        WHERE AdmissionID = @AdmissionID;

        IF @tc = 0 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION;
        ELSE IF XACT_STATE() = 1 AND @tc = 0 ROLLBACK TRANSACTION;
        ELSE IF XACT_STATE() = 1 ROLLBACK TRANSACTION sp_DischargePatient;
        THROW;
    END CATCH;
END;
GO

/* =============================================================================
   usp_GetPatientBill  (R6)
   Result sets: 1) header  2) itemized lines (treatments + items, by date)  3) totals
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_GetPatientBill
    @AdmissionID INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.Admission WHERE AdmissionID = @AdmissionID)
    BEGIN
        DECLARE @msg NVARCHAR(2048) = CONCAT(N'Stay ', @AdmissionID, N' not found.');
        THROW 50010, @msg, 1;
    END;

    SELECT AdmissionID, PatientName, AdmitDate, DischargeDate, StayStatus, LengthOfStayDays,
           AdmittingPhysician, DischargingPhysician, WardName, BedNumber
    FROM rpt.vw_AdmissionDetail
    WHERE AdmissionID = @AdmissionID;

    SELECT LineType, ServiceDate, Description, Quantity, UnitPrice, Amount
    FROM (
        SELECT N'Treatment' AS LineType, CAST(ta.AdministeredAt AS DATE) AS ServiceDate,
               t.TreatmentName AS Description, 1 AS Quantity, ta.ChargedAmount AS UnitPrice, ta.ChargedAmount AS Amount,
               ta.AdministeredAt AS SortKey
        FROM dbo.TreatmentAdministration ta JOIN dbo.Treatment t ON t.TreatmentID = ta.TreatmentID
        WHERE ta.AdmissionID = @AdmissionID
        UNION ALL
        SELECT N'Item', ic.ChargeDate, i.ItemName, ic.Quantity, ic.UnitCharge, ic.LineTotal,
               CAST(ic.ChargeDate AS DATETIME2(0))
        FROM dbo.ItemCharge ic JOIN dbo.Item i ON i.ItemID = ic.ItemID
        WHERE ic.AdmissionID = @AdmissionID
    ) lines
    ORDER BY SortKey, LineType, Description;

    -- Totals come from the same view as report R6, so the bill and the report always agree.
    SELECT TreatmentCount, TreatmentTotal, ItemLines, ItemTotal, GrandTotal
    FROM rpt.vw_StayCharges
    WHERE AdmissionID = @AdmissionID;
END;
GO

PRINT N'08_stored_procedures.sql completed.';
GO
