/* =============================================================================
   04_reference_data.sql
   Loads the lookup tables that the schema itself depends on.
   (Operational and bulk data are loaded in Phase 3.)

   Re-runnable: MERGE inserts missing rows and updates changed names,
   so running it twice changes nothing.
   ============================================================================= */

USE HospitalOps;
GO

/* -----------------------------------------------------------------------------
   Care event types  (BR-36)
   ----------------------------------------------------------------------------- */
MERGE dbo.CareEventType AS tgt
USING (VALUES
    ('WC',  N'Wellness Check'),
    ('MED', N'Medication'),
    ('FS',  N'Food Service'),
    ('AS',  N'Assistance'),
    ('TA',  N'Treatment Admin'),
    ('O',   N'Other')
) AS src (EventTypeCode, EventTypeName)
    ON tgt.EventTypeCode = src.EventTypeCode
WHEN MATCHED AND tgt.EventTypeName <> src.EventTypeName THEN
    UPDATE SET EventTypeName = src.EventTypeName
WHEN NOT MATCHED BY TARGET THEN
    INSERT (EventTypeCode, EventTypeName) VALUES (src.EventTypeCode, src.EventTypeName);
GO

/* -----------------------------------------------------------------------------
   Physician specialties  (BR-38)
   ----------------------------------------------------------------------------- */
MERGE dbo.Specialty AS tgt
USING (VALUES
    (N'Cardiology'), (N'Dermatology'), (N'Emergency Medicine'), (N'General Surgery'),
    (N'Internal Medicine'), (N'Neurology'), (N'Oncology'), (N'Orthopedics'),
    (N'Pediatrics'), (N'Psychiatry'), (N'Pulmonology'), (N'Radiology')
) AS src (SpecialtyName)
    ON tgt.SpecialtyName = src.SpecialtyName
WHEN NOT MATCHED BY TARGET THEN
    INSERT (SpecialtyName) VALUES (src.SpecialtyName);
GO

/* -----------------------------------------------------------------------------
   Nursing certifications  (BR-02)
   ----------------------------------------------------------------------------- */
MERGE dbo.Certification AS tgt
USING (VALUES
    (N'ACLS',   N'Advanced Cardiovascular Life Support'),
    (N'BLS',    N'Basic Life Support'),
    (N'PALS',   N'Pediatric Advanced Life Support'),
    (N'NRP',    N'Neonatal Resuscitation Program'),
    (N'TNCC',   N'Trauma Nursing Core Course'),
    (N'ENPC',   N'Emergency Nursing Pediatric Course'),
    (N'CCRN',   N'Critical Care Registered Nurse'),
    (N'CEN',    N'Certified Emergency Nurse'),
    (N'CMSRN',  N'Certified Medical-Surgical Registered Nurse'),
    (N'PCCN',   N'Progressive Care Certified Nurse'),
    (N'OCN',    N'Oncology Certified Nurse'),
    (N'CNOR',   N'Certified Perioperative Nurse'),
    (N'CPN',    N'Certified Pediatric Nurse'),
    (N'RNC-OB', N'Inpatient Obstetric Nursing'),
    (N'RNC-NIC',N'Neonatal Intensive Care Nursing'),
    (N'CRNI',   N'Certified Registered Nurse Infusion'),
    (N'WOCN',   N'Wound, Ostomy and Continence Nurse'),
    (N'SANE',   N'Sexual Assault Nurse Examiner'),
    (N'CNL',    N'Clinical Nurse Leader'),
    (N'NPD-BC', N'Nursing Professional Development - Board Certified'),
    (N'FNP-BC', N'Family Nurse Practitioner - Board Certified'),
    (N'PMHNP',  N'Psychiatric-Mental Health Nurse Practitioner'),
    (N'CRNA',   N'Certified Registered Nurse Anesthetist'),
    (N'CNM',    N'Certified Nurse Midwife')
) AS src (CertCode, CertName)
    ON tgt.CertCode = src.CertCode
WHEN MATCHED AND ISNULL(tgt.CertName, N'') <> src.CertName THEN
    UPDATE SET CertName = src.CertName
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CertCode, CertName) VALUES (src.CertCode, src.CertName);
GO

PRINT N'04_reference_data.sql completed.';
GO
