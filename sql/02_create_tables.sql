/* =============================================================================
   02_create_tables.sql
   Creates all operational tables with columns, primary keys and computed
   columns. Foreign keys, unique, check and default constraints are added in
   03_constraints.sql so each one can be traced to a business rule (BR-xx).

   Re-runnable: drops tables in reverse dependency order first.
   WARNING: dropping a table deletes its data. Run against a dev database only.
   ============================================================================= */

USE HospitalOps;
GO

/* -----------------------------------------------------------------------------
   Drop in reverse dependency order (children before parents)
   ----------------------------------------------------------------------------- */
DROP TABLE IF EXISTS dbo.NurseCareEvent;
DROP TABLE IF EXISTS dbo.ItemCharge;
DROP TABLE IF EXISTS dbo.TreatmentAdministration;
DROP TABLE IF EXISTS dbo.BedAssignment;
DROP TABLE IF EXISTS dbo.Admission;
DROP TABLE IF EXISTS dbo.NurseAssignment;
DROP TABLE IF EXISTS dbo.Bed;
DROP TABLE IF EXISTS dbo.Ward;
DROP TABLE IF EXISTS dbo.NurseCertification;
DROP TABLE IF EXISTS dbo.PhysicianSpecialty;
DROP TABLE IF EXISTS dbo.Patient;
DROP TABLE IF EXISTS dbo.Physician;
DROP TABLE IF EXISTS dbo.Nurse;
DROP TABLE IF EXISTS dbo.Item;
DROP TABLE IF EXISTS dbo.Treatment;
DROP TABLE IF EXISTS dbo.CareEventType;
DROP TABLE IF EXISTS dbo.Specialty;
DROP TABLE IF EXISTS dbo.Certification;
GO

/* =============================================================================
   Reference / lookup tables
   ============================================================================= */
CREATE TABLE dbo.Certification (
    CertCode        NVARCHAR(20)    NOT NULL,
    CertName        NVARCHAR(100)   NULL,
    CONSTRAINT PK_Certification PRIMARY KEY (CertCode)
);

CREATE TABLE dbo.Specialty (
    SpecialtyID     INT IDENTITY(1,1) NOT NULL,
    SpecialtyName   NVARCHAR(50)    NOT NULL,
    CONSTRAINT PK_Specialty PRIMARY KEY (SpecialtyID)
);

CREATE TABLE dbo.CareEventType (
    EventTypeCode   CHAR(3)         NOT NULL,
    EventTypeName   NVARCHAR(30)    NOT NULL,
    CONSTRAINT PK_CareEventType PRIMARY KEY (EventTypeCode)
);
GO

/* =============================================================================
   People
   ============================================================================= */
CREATE TABLE dbo.Nurse (
    NurseID         INT IDENTITY(1,1) NOT NULL,
    FirstName       NVARCHAR(30)    NOT NULL,
    LastName        NVARCHAR(40)    NOT NULL,
    Street          NVARCHAR(100)   NOT NULL,
    City            NVARCHAR(30)    NOT NULL,
    State           CHAR(2)         NOT NULL,
    Zip             CHAR(5)         NOT NULL,
    Phone           NVARCHAR(20)    NOT NULL,
    AltPhone        NVARCHAR(20)    NULL,
    Email           NVARCHAR(100)   NOT NULL,
    SupervisorID    INT             NULL,
    CONSTRAINT PK_Nurse PRIMARY KEY (NurseID)
);

CREATE TABLE dbo.NurseCertification (
    NurseID         INT             NOT NULL,
    CertCode        NVARCHAR(20)    NOT NULL,
    CONSTRAINT PK_NurseCertification PRIMARY KEY (NurseID, CertCode)
);

CREATE TABLE dbo.Physician (
    PhysicianID     INT IDENTITY(1,1) NOT NULL,
    FirstName       NVARCHAR(30)    NOT NULL,
    LastName        NVARCHAR(40)    NOT NULL,
    Street          NVARCHAR(100)   NOT NULL,
    City            NVARCHAR(30)    NOT NULL,
    State           CHAR(2)         NOT NULL,
    Zip             CHAR(5)         NOT NULL,
    Phone           NVARCHAR(20)    NOT NULL,
    AltPhone        NVARCHAR(20)    NULL,
    Email           NVARCHAR(100)   NOT NULL,
    CONSTRAINT PK_Physician PRIMARY KEY (PhysicianID)
);

CREATE TABLE dbo.PhysicianSpecialty (
    PhysicianID     INT             NOT NULL,
    SpecialtyID     INT             NOT NULL,
    CONSTRAINT PK_PhysicianSpecialty PRIMARY KEY (PhysicianID, SpecialtyID)
);

CREATE TABLE dbo.Patient (
    PatientID       INT IDENTITY(1,1) NOT NULL,
    FirstName       NVARCHAR(30)    NOT NULL,
    LastName        NVARCHAR(40)    NOT NULL,
    Gender          CHAR(1)         NOT NULL,
    DOB             DATE            NOT NULL,
    -- BR-17: age in whole years, birthday-aware. DATEDIFF(YEAR, ...) alone counts
    -- calendar-year boundaries and over-states age before the birthday (v1 defect D8).
    -- Not persisted: it depends on GETDATE(), which is non-deterministic.
    Age AS (
        DATEDIFF(YEAR, DOB, CAST(GETDATE() AS DATE))
        - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, DOB, CAST(GETDATE() AS DATE)), DOB)
                    > CAST(GETDATE() AS DATE)
               THEN 1 ELSE 0 END
    ),
    Street          NVARCHAR(100)   NOT NULL,
    City            NVARCHAR(30)    NOT NULL,
    State           CHAR(2)         NOT NULL,
    Zip             CHAR(5)         NOT NULL,
    Phone           NVARCHAR(20)    NOT NULL,
    AltPhone        NVARCHAR(20)    NULL,
    Email           NVARCHAR(100)   NULL,
    CONSTRAINT PK_Patient PRIMARY KEY (PatientID)
);
GO

/* =============================================================================
   Facilities
   ============================================================================= */
CREATE TABLE dbo.Ward (
    WardID          INT IDENTITY(1,1) NOT NULL,
    WardNumber      NVARCHAR(10)    NOT NULL,
    WardName        NVARCHAR(50)    NOT NULL,
    Location        NVARCHAR(50)    NOT NULL,
    Phone           NVARCHAR(20)    NOT NULL,
    ChargeNurseID   INT             NOT NULL,
    CONSTRAINT PK_Ward PRIMARY KEY (WardID)
);

CREATE TABLE dbo.Bed (
    BedID           INT IDENTITY(1,1) NOT NULL,
    WardID          INT             NOT NULL,
    BedNumber       NVARCHAR(10)    NOT NULL,
    Size            CHAR(2)         NOT NULL,
    Type            CHAR(1)         NOT NULL,
    Availability    CHAR(1)         NOT NULL,
    CONSTRAINT PK_Bed PRIMARY KEY (BedID)
);

CREATE TABLE dbo.NurseAssignment (
    NurseAssignmentID INT IDENTITY(1,1) NOT NULL,
    NurseID         INT             NOT NULL,
    WardID          INT             NOT NULL,
    ShiftDate       DATE            NOT NULL,
    HoursWorked     DECIMAL(4,2)    NOT NULL,
    CONSTRAINT PK_NurseAssignment PRIMARY KEY (NurseAssignmentID)
);
GO

/* =============================================================================
   Patient stay (events)
   ============================================================================= */
CREATE TABLE dbo.Admission (
    AdmissionID          INT IDENTITY(1,1) NOT NULL,
    PatientID            INT          NOT NULL,
    AdmitDate            DATE         NOT NULL,
    AdmitPhysicianID     INT          NOT NULL,
    DischargeDate        DATE         NULL,
    DischargePhysicianID INT          NULL,
    CONSTRAINT PK_Admission PRIMARY KEY (AdmissionID)
);

CREATE TABLE dbo.BedAssignment (
    BedAssignmentID INT IDENTITY(1,1) NOT NULL,
    AdmissionID     INT             NOT NULL,
    BedID           INT             NOT NULL,
    StartDate       DATE            NOT NULL,
    EndDate         DATE            NULL,          -- NULL = current assignment
    CONSTRAINT PK_BedAssignment PRIMARY KEY (BedAssignmentID)
);

CREATE TABLE dbo.Treatment (
    TreatmentID     INT IDENTITY(1,1) NOT NULL,
    TreatmentName   NVARCHAR(60)    NOT NULL,
    Description     NVARCHAR(255)   NULL,
    StandardCharge  DECIMAL(10,2)   NOT NULL,
    CONSTRAINT PK_Treatment PRIMARY KEY (TreatmentID)
);

CREATE TABLE dbo.TreatmentAdministration (
    TreatmentAdminID INT IDENTITY(1,1) NOT NULL,
    AdmissionID     INT             NOT NULL,
    TreatmentID     INT             NOT NULL,
    PhysicianID     INT             NULL,          -- BR-29: may be unrecorded
    AdministeredAt  DATETIME2(0)    NOT NULL,
    Results         NVARCHAR(255)   NULL,
    ChargedAmount   DECIMAL(10,2)   NOT NULL,      -- BR-33: price at time of service
    CONSTRAINT PK_TreatmentAdministration PRIMARY KEY (TreatmentAdminID)
);

CREATE TABLE dbo.Item (
    ItemID          INT IDENTITY(1,1) NOT NULL,
    ItemName        NVARCHAR(100)   NOT NULL,
    UnitCharge      DECIMAL(10,2)   NOT NULL,
    CONSTRAINT PK_Item PRIMARY KEY (ItemID)
);

CREATE TABLE dbo.ItemCharge (
    ItemChargeID    INT IDENTITY(1,1) NOT NULL,
    AdmissionID     INT             NOT NULL,
    ItemID          INT             NOT NULL,
    ChargeDate      DATE            NOT NULL,
    Quantity        INT             NOT NULL,
    UnitCharge      DECIMAL(10,2)   NOT NULL,      -- BR-33: price at time of charge
    -- Deterministic, so it can be PERSISTED (stored) and indexed.
    LineTotal AS CAST(Quantity * UnitCharge AS DECIMAL(12,2)) PERSISTED,
    CONSTRAINT PK_ItemCharge PRIMARY KEY (ItemChargeID)
);

CREATE TABLE dbo.NurseCareEvent (
    CareEventID     INT IDENTITY(1,1) NOT NULL,
    AdmissionID     INT             NOT NULL,
    NurseID         INT             NOT NULL,
    EventTypeCode   CHAR(3)         NOT NULL,
    EventAt         DATETIME2(0)    NOT NULL,
    Notes           NVARCHAR(255)   NULL,
    CONSTRAINT PK_NurseCareEvent PRIMARY KEY (CareEventID)
);
GO

PRINT N'02_create_tables.sql completed: 18 tables created.';
GO
