/* =============================================================================
   03_constraints.sql
   Adds the foreign key, unique, check and default constraints and the filtered
   unique indexes that enforce the business rules in docs/02_business_rules.md.
   Each block is tagged with the rule(s) it enforces.

   Run immediately after 02_create_tables.sql, which recreates the tables.

   Only indexes that enforce a rule are created here. Performance indexes
   (including indexes on FK columns) are added in 09_performance_indexes.sql based on measured
   execution plans.
   ============================================================================= */

USE HospitalOps;
GO

/* =============================================================================
   Lookups
   ============================================================================= */
ALTER TABLE dbo.Specialty     ADD CONSTRAINT UQ_Specialty_Name     UNIQUE (SpecialtyName);
ALTER TABLE dbo.CareEventType ADD CONSTRAINT UQ_CareEventType_Name UNIQUE (EventTypeName);
GO

/* =============================================================================
   Nurse  (BR-01 .. BR-04)
   ============================================================================= */
ALTER TABLE dbo.Nurse ADD
    CONSTRAINT DF_Nurse_State       DEFAULT ('FL') FOR State,
    CONSTRAINT CK_Nurse_State       CHECK (State LIKE '[A-Z][A-Z]'),
    CONSTRAINT CK_Nurse_Zip         CHECK (Zip   LIKE '[0-9][0-9][0-9][0-9][0-9]'),
    CONSTRAINT UQ_Nurse_Email       UNIQUE (Email),
    -- BR-03: at most one supervisor (nullable single-valued self reference)
    CONSTRAINT FK_Nurse_Nurse_Supervisor FOREIGN KEY (SupervisorID) REFERENCES dbo.Nurse (NurseID),
    -- BR-04: a nurse cannot supervise themself
    CONSTRAINT CK_Nurse_NotOwnSupervisor CHECK (SupervisorID IS NULL OR SupervisorID <> NurseID);

-- BR-02: many-to-many nurse <-> certification
ALTER TABLE dbo.NurseCertification ADD
    CONSTRAINT FK_NurseCertification_Nurse         FOREIGN KEY (NurseID)  REFERENCES dbo.Nurse (NurseID),
    CONSTRAINT FK_NurseCertification_Certification FOREIGN KEY (CertCode) REFERENCES dbo.Certification (CertCode);
GO

/* =============================================================================
   Physician  (BR-38)
   ============================================================================= */
ALTER TABLE dbo.Physician ADD
    CONSTRAINT DF_Physician_State   DEFAULT ('FL') FOR State,
    CONSTRAINT CK_Physician_State   CHECK (State LIKE '[A-Z][A-Z]'),
    CONSTRAINT CK_Physician_Zip     CHECK (Zip   LIKE '[0-9][0-9][0-9][0-9][0-9]'),
    CONSTRAINT UQ_Physician_Email   UNIQUE (Email);

ALTER TABLE dbo.PhysicianSpecialty ADD
    CONSTRAINT FK_PhysicianSpecialty_Physician FOREIGN KEY (PhysicianID) REFERENCES dbo.Physician (PhysicianID),
    CONSTRAINT FK_PhysicianSpecialty_Specialty FOREIGN KEY (SpecialtyID) REFERENCES dbo.Specialty (SpecialtyID);
GO

/* =============================================================================
   Patient  (BR-15, BR-16)
   ============================================================================= */
ALTER TABLE dbo.Patient ADD
    CONSTRAINT DF_Patient_City      DEFAULT (N'Tampa') FOR City,
    CONSTRAINT DF_Patient_State     DEFAULT ('FL') FOR State,
    CONSTRAINT CK_Patient_Gender    CHECK (Gender IN ('F', 'M', 'X')),
    CONSTRAINT CK_Patient_DOB       CHECK (DOB <= CAST(GETDATE() AS DATE)),
    CONSTRAINT CK_Patient_State     CHECK (State LIKE '[A-Z][A-Z]'),
    CONSTRAINT CK_Patient_Zip       CHECK (Zip   LIKE '[0-9][0-9][0-9][0-9][0-9]');
GO

/* =============================================================================
   Ward  (BR-08 .. BR-10)
   ============================================================================= */
ALTER TABLE dbo.Ward ADD
    CONSTRAINT UQ_Ward_WardNumber     UNIQUE (WardNumber),
    -- BR-09: exactly one charge nurse per ward (NOT NULL + FK)
    CONSTRAINT FK_Ward_Nurse_ChargeNurse FOREIGN KEY (ChargeNurseID) REFERENCES dbo.Nurse (NurseID),
    -- BR-10: a nurse is charge nurse of at most one ward (fixes v1 defect D5)
    CONSTRAINT UQ_Ward_ChargeNurseID  UNIQUE (ChargeNurseID);
GO

/* =============================================================================
   Bed  (BR-11 .. BR-14)
   ============================================================================= */
ALTER TABLE dbo.Bed ADD
    CONSTRAINT FK_Bed_Ward            FOREIGN KEY (WardID) REFERENCES dbo.Ward (WardID),
    CONSTRAINT UQ_Bed_Ward_BedNumber  UNIQUE (WardID, BedNumber),
    CONSTRAINT DF_Bed_Size            DEFAULT ('L') FOR Size,
    CONSTRAINT DF_Bed_Type            DEFAULT ('M') FOR Type,
    -- BR-14: default to Occupied so a new bed is never double-booked by mistake
    CONSTRAINT DF_Bed_Availability    DEFAULT ('O') FOR Availability,
    CONSTRAINT CK_Bed_Size            CHECK (Size IN ('S', 'L', 'XL')),
    CONSTRAINT CK_Bed_Type            CHECK (Type IN ('E', 'M')),
    CONSTRAINT CK_Bed_Availability    CHECK (Availability IN ('O', 'A'));
GO

/* =============================================================================
   NurseAssignment  (BR-05, BR-06)
   ============================================================================= */
ALTER TABLE dbo.NurseAssignment ADD
    CONSTRAINT FK_NurseAssignment_Nurse FOREIGN KEY (NurseID) REFERENCES dbo.Nurse (NurseID),
    CONSTRAINT FK_NurseAssignment_Ward  FOREIGN KEY (WardID)  REFERENCES dbo.Ward (WardID),
    -- BR-05: rotation allowed; one row per nurse/ward/day (fixes v1 defect D2)
    CONSTRAINT UQ_NurseAssignment_Nurse_Ward_Date UNIQUE (NurseID, WardID, ShiftDate),
    CONSTRAINT CK_NurseAssignment_Hours CHECK (HoursWorked > 0 AND HoursWorked <= 24);
GO

/* =============================================================================
   Admission  (BR-18 .. BR-22)
   ============================================================================= */
ALTER TABLE dbo.Admission ADD
    CONSTRAINT FK_Admission_Patient             FOREIGN KEY (PatientID)            REFERENCES dbo.Patient (PatientID),
    -- BR-19 (fixes v1 defect D1: admitting doctor had no FK)
    CONSTRAINT FK_Admission_Physician_Admit     FOREIGN KEY (AdmitPhysicianID)     REFERENCES dbo.Physician (PhysicianID),
    CONSTRAINT FK_Admission_Physician_Discharge FOREIGN KEY (DischargePhysicianID) REFERENCES dbo.Physician (PhysicianID),
    -- BR-20: discharge date and discharging physician recorded together or not at all
    CONSTRAINT CK_Admission_DischargePair CHECK (
        (DischargeDate IS NULL AND DischargePhysicianID IS NULL)
     OR (DischargeDate IS NOT NULL AND DischargePhysicianID IS NOT NULL)),
    -- BR-21
    CONSTRAINT CK_Admission_DischargeAfterAdmit CHECK (DischargeDate IS NULL OR DischargeDate >= AdmitDate);
GO

-- BR-22: a patient cannot have two open stays
CREATE UNIQUE NONCLUSTERED INDEX UX_Admission_OpenStayPerPatient
    ON dbo.Admission (PatientID)
    WHERE DischargeDate IS NULL;
GO

/* =============================================================================
   BedAssignment  (BR-23 .. BR-25)
   ============================================================================= */
ALTER TABLE dbo.BedAssignment ADD
    CONSTRAINT FK_BedAssignment_Admission FOREIGN KEY (AdmissionID) REFERENCES dbo.Admission (AdmissionID),
    CONSTRAINT FK_BedAssignment_Bed       FOREIGN KEY (BedID)       REFERENCES dbo.Bed (BedID),
    CONSTRAINT CK_BedAssignment_Dates     CHECK (EndDate IS NULL OR EndDate >= StartDate);
GO

-- BR-24: a bed can't be assigned to two patients at once (fixes v1 defect D3)
CREATE UNIQUE NONCLUSTERED INDEX UX_BedAssignment_CurrentBed
    ON dbo.BedAssignment (BedID)
    WHERE EndDate IS NULL;

-- BR-25: a stay has at most one current bed
CREATE UNIQUE NONCLUSTERED INDEX UX_BedAssignment_CurrentStay
    ON dbo.BedAssignment (AdmissionID)
    WHERE EndDate IS NULL;
GO

/* =============================================================================
   Treatment  (BR-27 .. BR-30, BR-33)
   ============================================================================= */
ALTER TABLE dbo.Treatment ADD
    CONSTRAINT UQ_Treatment_Name   UNIQUE (TreatmentName),
    CONSTRAINT CK_Treatment_Charge CHECK (StandardCharge >= 0);

ALTER TABLE dbo.TreatmentAdministration ADD
    CONSTRAINT FK_TreatmentAdministration_Admission FOREIGN KEY (AdmissionID) REFERENCES dbo.Admission (AdmissionID),
    CONSTRAINT FK_TreatmentAdministration_Treatment FOREIGN KEY (TreatmentID) REFERENCES dbo.Treatment (TreatmentID),
    -- BR-29: nullable FK, so treatments without a treating physician are allowed (fixes v1 defect D6)
    CONSTRAINT FK_TreatmentAdministration_Physician FOREIGN KEY (PhysicianID) REFERENCES dbo.Physician (PhysicianID),
    CONSTRAINT CK_TreatmentAdministration_Charge    CHECK (ChargedAmount >= 0);
GO

/* =============================================================================
   Item / ItemCharge  (BR-31 .. BR-33)
   ============================================================================= */
ALTER TABLE dbo.Item ADD
    CONSTRAINT UQ_Item_Name   UNIQUE (ItemName),
    CONSTRAINT CK_Item_Charge CHECK (UnitCharge >= 0);

ALTER TABLE dbo.ItemCharge ADD
    CONSTRAINT FK_ItemCharge_Admission FOREIGN KEY (AdmissionID) REFERENCES dbo.Admission (AdmissionID),
    CONSTRAINT FK_ItemCharge_Item      FOREIGN KEY (ItemID)      REFERENCES dbo.Item (ItemID),
    CONSTRAINT CK_ItemCharge_Quantity  CHECK (Quantity > 0),
    CONSTRAINT CK_ItemCharge_UnitCharge CHECK (UnitCharge >= 0);
GO

/* =============================================================================
   NurseCareEvent  (BR-35 .. BR-37)
   ============================================================================= */
ALTER TABLE dbo.NurseCareEvent ADD
    CONSTRAINT FK_NurseCareEvent_Admission     FOREIGN KEY (AdmissionID)   REFERENCES dbo.Admission (AdmissionID),
    CONSTRAINT FK_NurseCareEvent_Nurse         FOREIGN KEY (NurseID)       REFERENCES dbo.Nurse (NurseID),
    -- BR-36: lookup table instead of a hard-coded CHECK list (fixes v1 defect D12)
    CONSTRAINT FK_NurseCareEvent_CareEventType FOREIGN KEY (EventTypeCode) REFERENCES dbo.CareEventType (EventTypeCode);
GO

PRINT N'03_constraints.sql completed.';
GO
