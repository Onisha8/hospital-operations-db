/* =============================================================================
   06_generate_bulk_data.sql
   Generates ~1.2 million rows of realistic synthetic data across every table,
   so query plans and indexing choices (performance/) are tested at realistic volume.

   Design
   - Set-based: no loops or cursors. Every table is filled with INSERT ... SELECT
     over a numbers table.
   - Reproducible: "random" values come from stg.fn_Rand(n, salt), a hash of the
     row number. The same build always produces the same data (relative to the
     run date), so before/after performance comparisons are fair.
   - Consistent by construction. Hospital history is simulated as a timeline per
     bed, so stays on a bed never overlap. Each patient's stays are far apart.
     Every event falls inside its stay. Each care event is performed by a nurse
     who was on shift in that ward that day. Item and treatment prices drift
     upward over time, which exercises the price-snapshot columns.
   - Builds on the ETL: patients loaded by 05_etl_patient_import.sql are kept,
     and synthetic patients are added up to the target.

   Requires: tables empty except reference data and ETL-loaded patients
   (run 02 -> 05 first). tests/test_data_quality.sql verifies the result.
   ============================================================================= */

USE HospitalOps;
GO

-- Deterministic pseudo-random number in [0, 1) for a (row number, salt) pair.
-- Simple enough for SQL Server 2019+ to inline it into set-based queries.
CREATE OR ALTER FUNCTION stg.fn_Rand (@n BIGINT, @salt INT)
RETURNS FLOAT
WITH SCHEMABINDING
AS
BEGIN
    RETURN (CAST(SUBSTRING(HASHBYTES('MD5', CONCAT(@n, ':', @salt)), 1, 4) AS INT) & 2147483647) / 2147483648.0;
END;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* =============================================================================
   Parameters and guard
   ============================================================================= */
DECLARE @Today          DATE = CAST(GETDATE() AS DATE);
DECLARE @Start          DATE = DATEADD(YEAR, -5, @Today);   -- 5 years of history
DECLARE @Nurses         INT  = 200;
DECLARE @Physicians     INT  = 100;
DECLARE @BedsPerWard    INT  = 30;
DECLARE @PatientsTotal  INT  = 50000;
DECLARE @t0             DATETIME2 = SYSDATETIME();

IF EXISTS (SELECT 1 FROM dbo.Nurse) OR EXISTS (SELECT 1 FROM dbo.Admission)
BEGIN
    RAISERROR (N'Operational tables already contain data. Rebuild with 02_create_tables.sql first.', 16, 1);
    RETURN;
END;

/* =============================================================================
   Helpers: numbers table and name lists
   ============================================================================= */
DROP TABLE IF EXISTS #n;
WITH d AS (SELECT v FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS t (v))
SELECT n = a.v + 10 * b.v + 100 * c.v + 1000 * e.v + 10000 * f.v + 1
INTO #n
FROM d a CROSS JOIN d b CROSS JOIN d c CROSS JOIN d e CROSS JOIN d f;   -- 1 .. 100,000
CREATE UNIQUE CLUSTERED INDEX cx ON #n (n);

DROP TABLE IF EXISTS #FirstName, #LastName, #Street, #City, #Result;
SELECT i = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), Name, Gender
INTO #FirstName
FROM (VALUES
    (N'Olivia','F'),(N'Emma','F'),(N'Ava','F'),(N'Sophia','F'),(N'Isabella','F'),(N'Mia','F'),(N'Amelia','F'),
    (N'Harper','F'),(N'Evelyn','F'),(N'Abigail','F'),(N'Emily','F'),(N'Ella','F'),(N'Grace','F'),(N'Chloe','F'),
    (N'Camila','F'),(N'Priya','F'),(N'Aaliyah','F'),(N'Mei','F'),(N'Fatima','F'),(N'Lucia','F'),(N'Hannah','F'),
    (N'Zoe','F'),(N'Nora','F'),(N'Layla','F'),(N'Riley','F'),(N'Maya','F'),(N'Sofia','F'),(N'Ananya','F'),
    (N'Liam','M'),(N'Noah','M'),(N'Oliver','M'),(N'Elijah','M'),(N'James','M'),(N'William','M'),(N'Benjamin','M'),
    (N'Lucas','M'),(N'Henry','M'),(N'Alexander','M'),(N'Mateo','M'),(N'Daniel','M'),(N'Michael','M'),(N'Ethan','M'),
    (N'Jacob','M'),(N'Logan','M'),(N'Jackson','M'),(N'Sebastian','M'),(N'Arjun','M'),(N'Omar','M'),(N'Wei','M'),
    (N'Carlos','M'),(N'Andre','M'),(N'David','M'),(N'Joseph','M'),(N'Samuel','M'),(N'Rahul','M'),(N'Diego','M')
) AS v (Name, Gender);

SELECT i = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), Name
INTO #LastName
FROM (VALUES
    (N'Smith'),(N'Johnson'),(N'Williams'),(N'Brown'),(N'Jones'),(N'Garcia'),(N'Miller'),(N'Davis'),(N'Rodriguez'),
    (N'Martinez'),(N'Hernandez'),(N'Lopez'),(N'Gonzalez'),(N'Wilson'),(N'Anderson'),(N'Thomas'),(N'Taylor'),
    (N'Moore'),(N'Jackson'),(N'Martin'),(N'Lee'),(N'Perez'),(N'Thompson'),(N'White'),(N'Harris'),(N'Sanchez'),
    (N'Clark'),(N'Ramirez'),(N'Lewis'),(N'Robinson'),(N'Walker'),(N'Young'),(N'Allen'),(N'King'),(N'Wright'),
    (N'Scott'),(N'Torres'),(N'Nguyen'),(N'Hill'),(N'Flores'),(N'Green'),(N'Adams'),(N'Nelson'),(N'Baker'),
    (N'Hall'),(N'Rivera'),(N'Campbell'),(N'Mitchell'),(N'Carter'),(N'Roberts'),(N'Patel'),(N'Shah'),(N'Kim'),
    (N'Chen'),(N'Singh'),(N'Khan'),(N'Murphy'),(N'Cook'),(N'Rogers'),(N'Reyes')
) AS v (Name);

SELECT i = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), Name
INTO #Street
FROM (VALUES
    (N'Bayshore Blvd'),(N'Kennedy Blvd'),(N'Dale Mabry Hwy'),(N'Fowler Ave'),(N'Fletcher Ave'),(N'Bruce B Downs Blvd'),
    (N'Hillsborough Ave'),(N'Busch Blvd'),(N'Armenia Ave'),(N'Howard Ave'),(N'Florida Ave'),(N'Nebraska Ave'),
    (N'Gandy Blvd'),(N'Westshore Blvd'),(N'Swann Ave'),(N'Palm Ave'),(N'Bearss Ave'),(N'Linebaugh Ave'),
    (N'Waters Ave'),(N'Sligh Ave'),(N'Columbus Dr'),(N'Cypress St'),(N'Magnolia Dr'),(N'Oak St'),(N'Pine St'),
    (N'Central Ave'),(N'4th St N'),(N'Gulf Blvd'),(N'Ulmerton Rd'),(N'Bloomingdale Ave')
) AS v (Name);

SELECT i = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), City, Zip, AreaCode
INTO #City
FROM (VALUES
    (N'Tampa','33602','813'),(N'Tampa','33606','813'),(N'Tampa','33612','813'),(N'Tampa','33617','813'),
    (N'Tampa','33626','813'),(N'Brandon','33511','813'),(N'Riverview','33569','813'),(N'Temple Terrace','33617','813'),
    (N'St. Petersburg','33701','727'),(N'Clearwater','33755','727'),(N'Largo','33770','727'),
    (N'Lakeland','33801','863'),(N'Wesley Chapel','33544','813'),(N'Sarasota','34236','941'),(N'Bradenton','34205','941')
) AS v (City, Zip, AreaCode);

SELECT i = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), Result
INTO #Result
FROM (VALUES
    (N'Normal'),(N'Within expected range'),(N'Improved'),(N'No change'),
    (N'Abnormal - follow-up ordered'),(N'Completed without complications'),(N'Pending specialist review')
) AS v (Result);

DECLARE @nFirst INT = (SELECT COUNT(*) FROM #FirstName), @nLast INT = (SELECT COUNT(*) FROM #LastName),
        @nStreet INT = (SELECT COUNT(*) FROM #Street),   @nCity INT = (SELECT COUNT(*) FROM #City),
        @nResult INT = (SELECT COUNT(*) FROM #Result);

/* =============================================================================
   Nurses (200), supervision hierarchy and certifications
   ============================================================================= */
SET IDENTITY_INSERT dbo.Nurse ON;
WITH g AS (
    SELECT n,
           fi = 1 + FLOOR(stg.fn_Rand(n, 101) * @nFirst),
           li = 1 + FLOOR(stg.fn_Rand(n, 102) * @nLast),
           si = 1 + FLOOR(stg.fn_Rand(n, 103) * @nStreet),
           ci = 1 + FLOOR(stg.fn_Rand(n, 104) * @nCity),
           house = 100 + FLOOR(stg.fn_Rand(n, 105) * 9800),
           ph  = FLOOR(stg.fn_Rand(n, 106) * 10000),
           ph2 = FLOOR(stg.fn_Rand(n, 107) * 10000)
    FROM #n WHERE n <= @Nurses
)
INSERT dbo.Nurse (NurseID, FirstName, LastName, Street, City, State, Zip, Phone, AltPhone, Email, SupervisorID)
SELECT g.n, f.Name, l.Name, CONCAT(g.house, N' ', s.Name), c.City, 'FL', c.Zip,
       CONCAT(N'(', c.AreaCode, N') 555-', RIGHT(CONCAT(N'000', g.ph), 4)),
       CASE WHEN g.ph2 < 5000 THEN CONCAT(N'(', c.AreaCode, N') 555-', RIGHT(CONCAT(N'000', g.ph2), 4)) END,
       LOWER(CONCAT(f.Name, N'.', l.Name, N'.', g.n, N'@hospitalops.test')),
       NULL
FROM g
JOIN #FirstName f ON f.i = g.fi
JOIN #LastName  l ON l.i = g.li
JOIN #Street    s ON s.i = g.si
JOIN #City      c ON c.i = g.ci;
SET IDENTITY_INSERT dbo.Nurse OFF;

-- Hierarchy (BR-03): nurses 1-10 are the charge nurses (unsupervised); 11-50 report
-- to a charge nurse; 51-200 report to one of nurses 11-50.
UPDATE dbo.Nurse
SET SupervisorID = CASE WHEN NurseID <= 50 THEN ((NurseID - 11) % 10) + 1
                        ELSE 11 + ((NurseID - 51) % 40) END
WHERE NurseID > 10;

-- Certifications (BR-02): every nurse holds BLS, plus 1-3 more.
DROP TABLE IF EXISTS #Cert;
SELECT i = ROW_NUMBER() OVER (ORDER BY CertCode), CertCode INTO #Cert FROM dbo.Certification WHERE CertCode <> N'BLS';
DECLARE @nCert INT = (SELECT COUNT(*) FROM #Cert);

INSERT dbo.NurseCertification (NurseID, CertCode)
SELECT NurseID, N'BLS' FROM dbo.Nurse
UNION
SELECT nu.NurseID, c.CertCode
FROM dbo.Nurse nu
CROSS JOIN (VALUES (1), (2), (3)) AS k (k)
JOIN #Cert c ON c.i = 1 + FLOOR(stg.fn_Rand(nu.NurseID * 10 + k.k, 201) * @nCert)
WHERE k.k = 1 OR stg.fn_Rand(nu.NurseID * 10 + k.k, 202) < 0.5;

/* =============================================================================
   Physicians (100) and specialties
   ============================================================================= */
SET IDENTITY_INSERT dbo.Physician ON;
WITH g AS (
    SELECT n,
           fi = 1 + FLOOR(stg.fn_Rand(n, 301) * @nFirst),
           li = 1 + FLOOR(stg.fn_Rand(n, 302) * @nLast),
           si = 1 + FLOOR(stg.fn_Rand(n, 303) * @nStreet),
           ci = 1 + FLOOR(stg.fn_Rand(n, 304) * @nCity),
           house = 100 + FLOOR(stg.fn_Rand(n, 305) * 9800),
           ph  = FLOOR(stg.fn_Rand(n, 306) * 10000),
           ph2 = FLOOR(stg.fn_Rand(n, 307) * 10000)
    FROM #n WHERE n <= @Physicians
)
INSERT dbo.Physician (PhysicianID, FirstName, LastName, Street, City, State, Zip, Phone, AltPhone, Email)
SELECT g.n, f.Name, l.Name, CONCAT(g.house, N' ', s.Name), c.City, 'FL', c.Zip,
       CONCAT(N'(', c.AreaCode, N') 555-', RIGHT(CONCAT(N'000', g.ph), 4)),
       CASE WHEN g.ph2 < 7000 THEN CONCAT(N'(', c.AreaCode, N') 555-', RIGHT(CONCAT(N'000', g.ph2), 4)) END,
       LOWER(CONCAT(N'dr.', f.Name, N'.', l.Name, N'.', g.n, N'@hospitalops.test'))
FROM g
JOIN #FirstName f ON f.i = g.fi
JOIN #LastName  l ON l.i = g.li
JOIN #Street    s ON s.i = g.si
JOIN #City      c ON c.i = g.ci;
SET IDENTITY_INSERT dbo.Physician OFF;

DECLARE @nSpec INT = (SELECT COUNT(*) FROM dbo.Specialty);
INSERT dbo.PhysicianSpecialty (PhysicianID, SpecialtyID)
SELECT DISTINCT p.PhysicianID, 1 + FLOOR(stg.fn_Rand(p.PhysicianID * 10 + k.k, 401) * @nSpec)
FROM dbo.Physician p
CROSS JOIN (VALUES (1), (2)) AS k (k)
WHERE k.k = 1 OR stg.fn_Rand(p.PhysicianID, 402) < 0.3;      -- 30% have a second specialty

/* =============================================================================
   Wards (10) and beds (300)
   ============================================================================= */
SET IDENTITY_INSERT dbo.Ward ON;
INSERT dbo.Ward (WardID, WardNumber, WardName, Location, Phone, ChargeNurseID)
VALUES
    ( 1, N'W-101', N'Cardiology',            N'Tower A, Floor 1', N'(813) 555-0101',  1),
    ( 2, N'W-102', N'Intensive Care Unit',   N'Tower A, Floor 2', N'(813) 555-0102',  2),
    ( 3, N'W-103', N'Oncology',              N'Tower A, Floor 3', N'(813) 555-0103',  3),
    ( 4, N'W-201', N'Pediatrics',            N'Tower B, Floor 1', N'(813) 555-0104',  4),
    ( 5, N'W-202', N'Orthopedics',           N'Tower B, Floor 2', N'(813) 555-0105',  5),
    ( 6, N'W-203', N'Neurology',             N'Tower B, Floor 3', N'(813) 555-0106',  6),
    ( 7, N'W-301', N'Maternity',             N'Tower C, Floor 1', N'(813) 555-0107',  7),
    ( 8, N'W-302', N'Medical-Surgical',      N'Tower C, Floor 2', N'(813) 555-0108',  8),
    ( 9, N'W-303', N'Pulmonary',             N'Tower C, Floor 3', N'(813) 555-0109',  9),
    (10, N'W-304', N'Emergency Observation', N'Tower C, Floor 4', N'(813) 555-0110', 10);
SET IDENTITY_INSERT dbo.Ward OFF;

SET IDENTITY_INSERT dbo.Bed ON;
INSERT dbo.Bed (BedID, WardID, BedNumber, Size, Type, Availability)
SELECT (w.WardID - 1) * @BedsPerWard + k.n,
       w.WardID,
       CONCAT(w.WardNumber, N'-', RIGHT(CONCAT(N'0', k.n), 2)),
       CASE WHEN r.s < 0.10 THEN 'S' WHEN r.s < 0.85 THEN 'L' ELSE 'XL' END,     -- mostly Large (BR-12)
       CASE WHEN w.WardID = 2 OR r.t < 0.30 THEN 'E' ELSE 'M' END,               -- ICU is all electric
       'A'                                                                       -- set from occupancy below
FROM dbo.Ward w
JOIN #n k ON k.n <= @BedsPerWard
CROSS APPLY (SELECT s = stg.fn_Rand(w.WardID * 100 + k.n, 501),
                    t = stg.fn_Rand(w.WardID * 100 + k.n, 502)) AS r;
SET IDENTITY_INSERT dbo.Bed OFF;

/* =============================================================================
   Treatment catalog (100) and item catalog (200)
   ============================================================================= */
DROP TABLE IF EXISTS #TreatBase;
SELECT i = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), Name, Descr, Charge
INTO #TreatBase
FROM (VALUES
    (N'Complete Blood Count',        N'CBC with differential',                          45.00),
    (N'Basic Metabolic Panel',       N'Electrolytes, glucose, kidney function',         60.00),
    (N'Comprehensive Metabolic Panel',N'BMP plus liver function tests',                 85.00),
    (N'Lipid Panel',                 N'Cholesterol and triglycerides',                  55.00),
    (N'Blood Culture',               N'Culture for bloodstream infection',             120.00),
    (N'Urinalysis',                  N'Physical, chemical and microscopic urine exam',  35.00),
    (N'Troponin Test',               N'Cardiac injury marker',                          95.00),
    (N'Arterial Blood Gas',          N'Oxygenation and acid-base status',              150.00),
    (N'Chest X-Ray',                 N'Two-view chest radiograph',                     180.00),
    (N'Abdominal X-Ray',             N'Abdominal radiograph',                          160.00),
    (N'CT Scan - Head',              N'Non-contrast head CT',                          950.00),
    (N'CT Scan - Chest',             N'Chest CT with contrast',                       1200.00),
    (N'CT Scan - Abdomen',           N'Abdomen and pelvis CT with contrast',          1350.00),
    (N'MRI - Brain',                 N'Brain MRI with and without contrast',          2100.00),
    (N'MRI - Spine',                 N'Lumbar spine MRI',                             1900.00),
    (N'MRI - Knee',                  N'Knee MRI without contrast',                    1600.00),
    (N'Ultrasound - Abdomen',        N'Complete abdominal ultrasound',                 450.00),
    (N'Echocardiogram',              N'Transthoracic echocardiogram',                  900.00),
    (N'Electrocardiogram',           N'12-lead ECG',                                    75.00),
    (N'Cardiac Stress Test',         N'Exercise or pharmacologic stress test',        1100.00),
    (N'Cardiac Catheterization',     N'Diagnostic coronary angiography',              5200.00),
    (N'EEG',                         N'Electroencephalogram',                          650.00),
    (N'Lumbar Puncture',             N'Cerebrospinal fluid collection',                800.00),
    (N'IV Fluid Therapy',            N'Intravenous hydration',                         140.00),
    (N'IV Antibiotic Therapy',       N'Intravenous antibiotic course, per day',        260.00),
    (N'Blood Transfusion',           N'Packed red blood cell transfusion',             900.00),
    (N'Chemotherapy Infusion',       N'Outpatient-level chemotherapy session',        3800.00),
    (N'Radiation Therapy Session',   N'External beam radiation, per session',         1500.00),
    (N'Physical Therapy Session',    N'Inpatient PT evaluation or session',            160.00),
    (N'Occupational Therapy Session',N'Inpatient OT evaluation or session',            150.00),
    (N'Respiratory Therapy',         N'Nebulizer and airway clearance',                120.00),
    (N'Oxygen Therapy',              N'Supplemental oxygen, per day',                   90.00),
    (N'Mechanical Ventilation',      N'Ventilator support, per day',                  2400.00),
    (N'Dialysis Session',            N'Inpatient hemodialysis',                       1300.00),
    (N'Wound Debridement',           N'Removal of necrotic tissue',                    550.00),
    (N'Suture Repair',               N'Laceration repair',                             300.00),
    (N'Fracture Reduction',          N'Closed reduction and casting',                 1400.00),
    (N'Joint Injection',             N'Corticosteroid joint injection',                250.00),
    (N'Endoscopy',                   N'Upper GI endoscopy',                           1700.00),
    (N'Colonoscopy',                 N'Diagnostic colonoscopy',                       1900.00),
    (N'Bronchoscopy',                N'Diagnostic bronchoscopy',                      2000.00),
    (N'Pain Management Consult',     N'Pain specialist assessment',                    220.00),
    (N'Nutrition Consult',           N'Dietitian assessment',                          110.00),
    (N'Psychiatric Evaluation',      N'Inpatient psychiatric assessment',              350.00),
    (N'Neurology Consult',           N'Neurologist assessment',                        300.00),
    (N'Fetal Monitoring',            N'Continuous fetal heart monitoring',             280.00),
    (N'Vaccination',                 N'Inpatient immunization',                         60.00),
    (N'Allergy Testing',             N'Skin prick panel',                              240.00),
    (N'Pulmonary Function Test',     N'Spirometry and lung volumes',                   320.00),
    (N'Sleep Study',                 N'Overnight polysomnography',                    1500.00)
) AS v (Name, Descr, Charge);

SET IDENTITY_INSERT dbo.Treatment ON;
INSERT dbo.Treatment (TreatmentID, TreatmentName, Description, StandardCharge)
SELECT (v.v - 1) * 50 + b.i,
       CONCAT(b.Name, v.Suffix),
       CONCAT(b.Descr, v.DescrSuffix),
       ROUND(b.Charge * v.Factor, 2)
FROM #TreatBase b
CROSS JOIN (VALUES (1, N'', N'', 1.0), (2, N' (Follow-up)', N' - follow-up', 0.6)) AS v (v, Suffix, DescrSuffix, Factor);
SET IDENTITY_INSERT dbo.Treatment OFF;

DROP TABLE IF EXISTS #ItemBase;
SELECT i = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), Name, Price
INTO #ItemBase
FROM (VALUES
    (N'Gauze Pad 4x4',2.10),(N'Adhesive Bandage',0.60),(N'Elastic Bandage',4.50),(N'Medical Tape',3.20),
    (N'Exam Gloves (pair)',0.40),(N'Sterile Gloves (pair)',1.80),(N'Surgical Mask',0.75),(N'N95 Respirator',3.50),
    (N'Syringe 3 mL',0.45),(N'Syringe 10 mL',0.65),(N'Hypodermic Needle',0.30),(N'IV Catheter',4.80),
    (N'IV Start Kit',9.50),(N'IV Tubing Set',7.25),(N'Saline Flush 10 mL',1.40),(N'Normal Saline 1 L',8.90),
    (N'Alcohol Prep Pad',0.08),(N'Chlorhexidine Swab',0.95),(N'Blood Collection Tube',0.85),(N'Specimen Container',1.10),
    (N'Urinary Catheter',12.50),(N'Drainage Bag',6.40),(N'Oxygen Nasal Cannula',3.90),(N'Oxygen Face Mask',5.60),
    (N'Nebulizer Kit',8.75),(N'Suction Catheter',2.80),(N'ECG Electrodes',0.55),(N'Pulse Oximeter Sensor',6.20),
    (N'Disposable Thermometer Cover',0.12),(N'Bed Pad (underpad)',1.30),(N'Adult Brief',1.90),(N'Wound Dressing',7.80),
    (N'Hydrocolloid Dressing',9.40),(N'Cold Pack',2.40),(N'Hot Pack',2.60),(N'Splint',18.00),
    (N'Cervical Collar',32.00),(N'Patient Gown',4.20),(N'Non-slip Socks',3.10),(N'Hygiene Kit',6.50)
) AS v (Name, Price);

SET IDENTITY_INSERT dbo.Item ON;
INSERT dbo.Item (ItemID, ItemName, UnitCharge)
SELECT (b.i - 1) * 5 + p.p,
       CONCAT(b.Name, N' - ', p.Pack),
       ROUND(b.Price * p.Factor, 2)
FROM #ItemBase b
CROSS JOIN (VALUES (1, N'Single', 1.0), (2, N'Pack of 5', 4.6), (3, N'Pack of 10', 8.8),
                   (4, N'Pack of 25', 21.0), (5, N'Pack of 50', 40.0)) AS p (p, Pack, Factor);
SET IDENTITY_INSERT dbo.Item OFF;

/* =============================================================================
   Patients: keep ETL-loaded rows, add synthetic ones up to @PatientsTotal.
   Synthetic DOBs fall before the history window starts, so nobody is admitted
   before being born.
   ============================================================================= */
DECLARE @p0 INT = ISNULL((SELECT MAX(PatientID) FROM dbo.Patient), 0);
DECLARE @newPatients INT = @PatientsTotal - (SELECT COUNT(*) FROM dbo.Patient);

SET IDENTITY_INSERT dbo.Patient ON;
WITH g AS (
    SELECT n,
           fi = 1 + FLOOR(stg.fn_Rand(n, 601) * @nFirst),
           li = 1 + FLOOR(stg.fn_Rand(n, 602) * @nLast),
           si = 1 + FLOOR(stg.fn_Rand(n, 603) * @nStreet),
           ci = 1 + FLOOR(stg.fn_Rand(n, 604) * @nCity),
           house = 100 + FLOOR(stg.fn_Rand(n, 605) * 9800),
           ageDays = FLOOR(stg.fn_Rand(n, 606) * 365.25 * 85),
           ph  = FLOOR(stg.fn_Rand(n, 607) * 10000),
           ph2 = FLOOR(stg.fn_Rand(n, 608) * 10000),
           x   = stg.fn_Rand(n, 609)
    FROM #n WHERE n <= @newPatients
)
INSERT dbo.Patient (PatientID, FirstName, LastName, Gender, DOB, Street, City, State, Zip, Phone, AltPhone, Email)
SELECT @p0 + g.n, f.Name, l.Name,
       CASE WHEN g.x < 0.005 THEN 'X' ELSE f.Gender END,
       DATEADD(DAY, -g.ageDays, @Start),
       CONCAT(g.house, N' ', s.Name), c.City, 'FL', c.Zip,
       CONCAT(N'(', c.AreaCode, N') 555-', RIGHT(CONCAT(N'000', g.ph), 4)),
       CASE WHEN g.ph2 < 4000 THEN CONCAT(N'(', c.AreaCode, N') 555-', RIGHT(CONCAT(N'000', g.ph2), 4)) END,
       CASE WHEN g.x < 0.70 THEN LOWER(CONCAT(f.Name, N'.', l.Name, @p0 + g.n, N'@example.com')) END
FROM g
JOIN #FirstName f ON f.i = g.fi
JOIN #LastName  l ON l.i = g.li
JOIN #Street    s ON s.i = g.si
JOIN #City      c ON c.i = g.ci;
SET IDENTITY_INSERT dbo.Patient OFF;

/* =============================================================================
   Stays: simulate each bed's history as back-to-back stays separated by gaps.
     LOS (length of stay) is 1-10 days, skewed short; the gap between patients is 0-5 days.
   Because stays on a bed are laid end to end, they can never overlap (BR-24).
   A stay that runs past today is still open (no discharge yet).
   ============================================================================= */
DROP TABLE IF EXISTS #Stay;
WITH c AS (
    SELECT b.BedID, b.WardID, k.n AS k,
           LOS = 1 + CAST(FLOOR(POWER(stg.fn_Rand(b.BedID * 1000 + k.n, 701), 2) * 10) AS INT),
           Gap = CAST(FLOOR(stg.fn_Rand(b.BedID * 1000 + k.n, 702) * 6) AS INT)
    FROM dbo.Bed b
    JOIN #n k ON k.n <= 400
),
t AS (
    SELECT *, EndOffset = SUM(LOS + Gap) OVER (PARTITION BY BedID ORDER BY k ROWS UNBOUNDED PRECEDING)
    FROM c
)
SELECT BedID, WardID,
       AdmitDate     = DATEADD(DAY, EndOffset - LOS, @Start),
       PlannedEnd    = DATEADD(DAY, EndOffset, @Start)
INTO #Stay
FROM t
WHERE DATEADD(DAY, EndOffset - LOS, @Start) <= @Today;

-- Deal order: shuffled (hash) so age isn't correlated with admit date, except that
-- patients born inside the history window (a few ETL-loaded ones) go last. Their
-- first stay then lands about 3 years in, after they were born
-- (checked by tests/test_data_quality.sql).
DROP TABLE IF EXISTS #Pat;
SELECT i = ROW_NUMBER() OVER (ORDER BY CASE WHEN DOB > @Start THEN 1 ELSE 0 END, stg.fn_Rand(PatientID, 720)),
       PatientID
INTO #Pat
FROM dbo.Patient;
DECLARE @nPat INT = (SELECT COUNT(*) FROM #Pat);
DECLARE @nPhys INT = (SELECT COUNT(*) FROM dbo.Physician);

-- Admissions are numbered in admit-date order and dealt out to patients round-robin.
-- A patient's next stay is therefore ~@nPat admissions (about 3 years) later, so a
-- patient's stays never overlap and nobody has two open stays (BR-22).
DROP TABLE IF EXISTS #Adm;
SELECT AdmissionID = ROW_NUMBER() OVER (ORDER BY s.AdmitDate, s.BedID),
       s.BedID, s.WardID, s.AdmitDate,
       DischargeDate = CASE WHEN s.PlannedEnd <= @Today THEN s.PlannedEnd END
INTO #Adm
FROM #Stay s;

ALTER TABLE #Adm ADD PatientID INT, AdmitPhysicianID INT, DischargePhysicianID INT, LastEventOffset INT, LastChargeOffset INT;
UPDATE a
SET PatientID            = p.PatientID,
    AdmitPhysicianID     = 1 + FLOOR(stg.fn_Rand(a.AdmissionID, 711) * @nPhys),
    DischargePhysicianID = NULL,
    -- Clinical events (which have a time of day) happen on or before the discharge date,
    -- and never later than yesterday, so none is in the future. That covers open stays
    -- and stays discharged today (found by test_data_quality.sql check DQ12).
    LastEventOffset      = DATEDIFF(DAY, a.AdmitDate,
                                    CASE WHEN a.DischargeDate IS NULL OR a.DischargeDate >= @Today
                                         THEN DATEADD(DAY, -1, @Today) ELSE a.DischargeDate END),
    -- item charges may be posted today for an open stay, so every stay gets at least one (BR-34)
    LastChargeOffset     = DATEDIFF(DAY, a.AdmitDate, ISNULL(a.DischargeDate, @Today))
FROM #Adm a
JOIN #Pat p ON p.i = ((a.AdmissionID - 1) % @nPat) + 1;

UPDATE #Adm
SET DischargePhysicianID = CASE WHEN stg.fn_Rand(AdmissionID, 712) < 0.7 THEN AdmitPhysicianID
                                ELSE 1 + FLOOR(stg.fn_Rand(AdmissionID, 713) * @nPhys) END
WHERE DischargeDate IS NOT NULL;

CREATE UNIQUE CLUSTERED INDEX cx ON #Adm (AdmissionID);

SET IDENTITY_INSERT dbo.Admission ON;
INSERT dbo.Admission WITH (TABLOCK) (AdmissionID, PatientID, AdmitDate, AdmitPhysicianID, DischargeDate, DischargePhysicianID)
SELECT AdmissionID, PatientID, AdmitDate, AdmitPhysicianID, DischargeDate, DischargePhysicianID
FROM #Adm ORDER BY AdmissionID;
SET IDENTITY_INSERT dbo.Admission OFF;

SET IDENTITY_INSERT dbo.BedAssignment ON;
INSERT dbo.BedAssignment WITH (TABLOCK) (BedAssignmentID, AdmissionID, BedID, StartDate, EndDate)
SELECT AdmissionID AS BedAssignmentID, AdmissionID, BedID, AdmitDate, DischargeDate
FROM #Adm ORDER BY AdmissionID;
SET IDENTITY_INSERT dbo.BedAssignment OFF;

-- Bed availability flag mirrors current occupancy (BR-26)
UPDATE b
SET Availability = CASE WHEN EXISTS (SELECT 1 FROM dbo.BedAssignment ba WHERE ba.BedID = b.BedID AND ba.EndDate IS NULL)
                        THEN 'O' ELSE 'A' END
FROM dbo.Bed b;

/* =============================================================================
   Nurse shifts: every day, every ward is staffed by 3 nurses on rotation.
   NurseID = ((DayIndex * 30 + (WardID - 1) * 3 + Slot) % 200) + 1 gives 30 different
   nurses per day, and every nurse rotates through every ward (BR-05, BR-07).
   ============================================================================= */
DECLARE @Days INT = DATEDIFF(DAY, @Start, @Today) + 1;
DECLARE @nWard INT = (SELECT COUNT(*) FROM dbo.Ward);

INSERT dbo.NurseAssignment WITH (TABLOCK) (NurseID, WardID, ShiftDate, HoursWorked)
SELECT ((d.n - 1) * @nWard * 3 + (w.WardID - 1) * 3 + s.Slot) % @Nurses + 1,
       w.WardID,
       DATEADD(DAY, d.n - 1, @Start),
       CASE WHEN stg.fn_Rand(d.n * 1000 + w.WardID * 10 + s.Slot, 801) < 0.6 THEN 12 ELSE 8 END
FROM #n d
CROSS JOIN dbo.Ward w
CROSS JOIN (VALUES (0), (1), (2)) AS s (Slot)
WHERE d.n <= @Days
ORDER BY 3, 2;

/* =============================================================================
   Treatments: 0-5 per stay (BR-28). The last 5 catalog entries are never used (BR-27).
   5% have no recorded treating physician (BR-29). The price charged is the list
   price deflated by ~4% per year back in time (BR-33).
   ============================================================================= */
DECLARE @nTreatUsed INT = (SELECT COUNT(*) FROM dbo.Treatment) - 5;

INSERT dbo.TreatmentAdministration WITH (TABLOCK) (AdmissionID, TreatmentID, PhysicianID, AdministeredAt, Results, ChargedAmount)
SELECT a.AdmissionID,
       t.TreatmentID,
       CASE WHEN r.phys < 0.05 THEN NULL
            WHEN r.phys < 0.65 THEN a.AdmitPhysicianID
            ELSE 1 + FLOOR(stg.fn_Rand(x.seed, 905) * @nPhys) END,
       DATEADD(MINUTE, 360 + FLOOR(r.tm * 960), CAST(x.EventDate AS DATETIME2(0))),     -- 06:00-22:00
       res.Result,
       ROUND(t.StandardCharge * (1 - 0.04 * DATEDIFF(DAY, x.EventDate, @Today) / 365.25), 2)
FROM #Adm a
JOIN #n k ON k.n <= FLOOR(stg.fn_Rand(a.AdmissionID, 901) * 6)
CROSS APPLY (SELECT seed = CAST(a.AdmissionID AS BIGINT) * 16 + k.n) AS s0
CROSS APPLY (SELECT tr   = stg.fn_Rand(s0.seed, 902),
                    dayPos  = stg.fn_Rand(s0.seed, 903),
                    phys = stg.fn_Rand(s0.seed, 904),
                    tm   = stg.fn_Rand(s0.seed, 906),
                    rs   = stg.fn_Rand(s0.seed, 907)) AS r
CROSS APPLY (SELECT seed = s0.seed,
                    EventDate = DATEADD(DAY, FLOOR(r.dayPos * (a.LastEventOffset + 1)), a.AdmitDate)) AS x
JOIN dbo.Treatment t ON t.TreatmentID = 1 + FLOOR(POWER(r.tr, 1.5) * @nTreatUsed)     -- low IDs more common
JOIN #Result res     ON res.i = 1 + FLOOR(r.rs * @nResult)
WHERE a.LastEventOffset >= 0;

/* =============================================================================
   Item charges: 1-9 per stay, so every stay has at least one (BR-34).
   The last 10 catalog items are never charged (BR-31).
   ============================================================================= */
DECLARE @nItemUsed INT = (SELECT COUNT(*) FROM dbo.Item) - 10;

INSERT dbo.ItemCharge WITH (TABLOCK) (AdmissionID, ItemID, ChargeDate, Quantity, UnitCharge)
SELECT a.AdmissionID,
       i.ItemID,
       x.ChargeDate,
       1 + FLOOR(POWER(r.q, 3) * 10),                                                     -- mostly 1-2
       ROUND(i.UnitCharge * (1 - 0.04 * DATEDIFF(DAY, x.ChargeDate, @Today) / 365.25), 2)
FROM #Adm a
JOIN #n k ON k.n <= 1 + FLOOR(stg.fn_Rand(a.AdmissionID, 1001) * 9)
CROSS APPLY (SELECT seed = CAST(a.AdmissionID AS BIGINT) * 16 + k.n) AS s0
CROSS APPLY (SELECT it  = stg.fn_Rand(s0.seed, 1002),
                    dayPos = stg.fn_Rand(s0.seed, 1003),
                    q   = stg.fn_Rand(s0.seed, 1004)) AS r
CROSS APPLY (SELECT ChargeDate = DATEADD(DAY, FLOOR(r.dayPos * (a.LastChargeOffset + 1)), a.AdmitDate)) AS x
JOIN dbo.Item i ON i.ItemID = 1 + FLOOR(r.it * @nItemUsed);

/* =============================================================================
   Nurse care events: 2 to (LOS + 5) per stay. Each event is performed by one of
   the 3 nurses on shift in the stay's ward that day (same formula as the shifts).
   ============================================================================= */
INSERT dbo.NurseCareEvent WITH (TABLOCK) (AdmissionID, NurseID, EventTypeCode, EventAt, Notes)
SELECT a.AdmissionID,
       (DATEDIFF(DAY, @Start, x.EventDate) * @nWard * 3 + (a.WardID - 1) * 3 + CAST(FLOOR(r.slot * 3) AS INT)) % @Nurses + 1,
       CASE WHEN r.typ < 0.30 THEN 'WC'  WHEN r.typ < 0.55 THEN 'MED' WHEN r.typ < 0.75 THEN 'FS'
            WHEN r.typ < 0.87 THEN 'AS'  WHEN r.typ < 0.95 THEN 'TA'  ELSE 'O' END,
       DATEADD(MINUTE, FLOOR(r.tm * 1440), CAST(x.EventDate AS DATETIME2(0))),
       CASE WHEN r.typ >= 0.95 THEN N'See chart' END
FROM #Adm a
JOIN #n k ON k.n <= 2 + FLOOR(stg.fn_Rand(a.AdmissionID, 1101) * (a.LastEventOffset + 4))
CROSS APPLY (SELECT seed = CAST(a.AdmissionID AS BIGINT) * 64 + k.n) AS s0
CROSS APPLY (SELECT dayPos  = stg.fn_Rand(s0.seed, 1102),
                    slot = stg.fn_Rand(s0.seed, 1103),
                    typ  = stg.fn_Rand(s0.seed, 1104),
                    tm   = stg.fn_Rand(s0.seed, 1105)) AS r
CROSS APPLY (SELECT EventDate = DATEADD(DAY, FLOOR(r.dayPos * (a.LastEventOffset + 1)), a.AdmitDate)) AS x
WHERE a.LastEventOffset >= 0;

/* =============================================================================
   Summary
   ============================================================================= */
DROP TABLE IF EXISTS #n, #FirstName, #LastName, #Street, #City, #Result, #Cert, #TreatBase, #ItemBase, #Stay, #Pat, #Adm;

SELECT t.name AS [Table], FORMAT(SUM(p.rows), 'N0') AS [Rows]
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE t.schema_id = SCHEMA_ID('dbo')
GROUP BY t.name
ORDER BY SUM(p.rows) DESC;

DECLARE @totalRows BIGINT = (SELECT SUM(p.rows) FROM sys.tables t
                             JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
                             WHERE t.schema_id = SCHEMA_ID('dbo'));
PRINT CONCAT(N'06_generate_bulk_data.sql completed in ', DATEDIFF(SECOND, @t0, SYSDATETIME()), N' s. Total rows: ',
             FORMAT(@totalRows, 'N0'));
GO
