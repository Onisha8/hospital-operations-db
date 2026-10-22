/* =============================================================================
   07_reporting_views.sql
   Reporting layer (rpt schema): one view or inline table-valued function per
   required report R1-R12 (docs/01_requirements.md, section 1.6), plus shared
   base views.

   - Views hold reports with no parameters.
   - Inline TVFs (rpt.fn_*) hold reports that take a date. Unlike multi-statement
     functions, inline TVFs are expanded into the calling query, so the optimizer
     can use indexes and push filters down.
   - Views can't guarantee row order. Each header gives the ORDER BY a report
     should use.

   Re-runnable: CREATE OR ALTER.
   ============================================================================= */

USE HospitalOps;
GO

/* =============================================================================
   Base view: one row per stay with names, status, length of stay and the
   current (or last) bed. Used by R2 and R4.
   ============================================================================= */
CREATE OR ALTER VIEW rpt.vw_AdmissionDetail
AS
SELECT
    a.AdmissionID,
    a.PatientID,
    CONCAT(p.LastName, N', ', p.FirstName)                          AS PatientName,
    a.AdmitDate,
    a.AdmitPhysicianID,
    CONCAT(N'Dr. ', ap.FirstName, N' ', ap.LastName)                AS AdmittingPhysician,
    a.DischargeDate,
    a.DischargePhysicianID,
    CASE WHEN dp.PhysicianID IS NOT NULL
         THEN CONCAT(N'Dr. ', dp.FirstName, N' ', dp.LastName) END  AS DischargingPhysician,
    CASE WHEN a.DischargeDate IS NULL THEN 'Open' ELSE 'Discharged' END AS StayStatus,
    DATEDIFF(DAY, a.AdmitDate, ISNULL(a.DischargeDate, CAST(GETDATE() AS DATE))) AS LengthOfStayDays,
    lb.WardID,
    lb.WardName,
    lb.BedNumber
FROM dbo.Admission a
JOIN dbo.Patient   p  ON p.PatientID  = a.PatientID
JOIN dbo.Physician ap ON ap.PhysicianID = a.AdmitPhysicianID
LEFT JOIN dbo.Physician dp ON dp.PhysicianID = a.DischargePhysicianID
OUTER APPLY (                                   -- latest bed for the stay
    SELECT TOP (1) w.WardID, w.WardName, b.BedNumber
    FROM dbo.BedAssignment ba
    JOIN dbo.Bed  b ON b.BedID  = ba.BedID
    JOIN dbo.Ward w ON w.WardID = b.WardID
    WHERE ba.AdmissionID = a.AdmissionID
    ORDER BY ba.StartDate DESC, ba.BedAssignmentID DESC
) lb;
GO

/* =============================================================================
   R1  Daily report of beds occupied and available
   ============================================================================= */
-- Current status, from the Bed.Availability flag.  ORDER BY WardNumber
CREATE OR ALTER VIEW rpt.vw_BedOccupancyByWard
AS
SELECT
    w.WardID,
    w.WardNumber,
    w.WardName,
    COUNT(*)                                              AS TotalBeds,
    SUM(CASE WHEN b.Availability = 'O' THEN 1 ELSE 0 END) AS Occupied,
    SUM(CASE WHEN b.Availability = 'A' THEN 1 ELSE 0 END) AS Available,
    CAST(100.0 * SUM(CASE WHEN b.Availability = 'O' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,1)) AS OccupancyPct
FROM dbo.Ward w
JOIN dbo.Bed  b ON b.WardID = w.WardID
GROUP BY w.WardID, w.WardNumber, w.WardName;
GO

-- Any past date, rebuilt from bed assignment history ("occupied overnight on @AsOf").
-- Same-day turnover counts once: a stay ending on @AsOf has left, and the next has arrived.
-- Usage: SELECT * FROM rpt.fn_BedOccupancyOn('2025-01-15') ORDER BY WardNumber;
CREATE OR ALTER FUNCTION rpt.fn_BedOccupancyOn (@AsOf DATE)
RETURNS TABLE
AS
RETURN
SELECT
    w.WardID,
    w.WardNumber,
    w.WardName,
    COUNT(*)                     AS TotalBeds,
    COUNT(occ.BedID)             AS Occupied,
    COUNT(*) - COUNT(occ.BedID)  AS Available,
    CAST(100.0 * COUNT(occ.BedID) / COUNT(*) AS DECIMAL(5,1)) AS OccupancyPct
FROM dbo.Ward w
JOIN dbo.Bed  b ON b.WardID = w.WardID
OUTER APPLY (
    SELECT TOP (1) ba.BedID
    FROM dbo.BedAssignment ba
    WHERE ba.BedID = b.BedID
      AND ba.StartDate <= @AsOf
      AND (ba.EndDate IS NULL OR ba.EndDate > @AsOf)
) occ
GROUP BY w.WardID, w.WardNumber, w.WardName;
GO

/* =============================================================================
   R2  Weekly report of patients admitted and discharged
   Usage: SELECT * FROM rpt.fn_AdmissionsDischarges('2026-10-05', '2026-10-11')
          ORDER BY AdmitDate, AdmittingPhysician, DischargingPhysician;
   ============================================================================= */
CREATE OR ALTER FUNCTION rpt.fn_AdmissionsDischarges (@From DATE, @To DATE)
RETURNS TABLE
AS
RETURN
SELECT
    d.AdmissionID,
    d.PatientName,
    d.AdmitDate,
    d.AdmittingPhysician,
    d.DischargeDate,
    d.DischargingPhysician,
    CASE WHEN d.AdmitDate     BETWEEN @From AND @To THEN 'Y' ELSE 'N' END AS AdmittedInPeriod,
    CASE WHEN d.DischargeDate BETWEEN @From AND @To THEN 'Y' ELSE 'N' END AS DischargedInPeriod,
    d.WardName,
    d.LengthOfStayDays
FROM rpt.vw_AdmissionDetail d
WHERE d.AdmitDate     BETWEEN @From AND @To
   OR d.DischargeDate BETWEEN @From AND @To;
GO

/* =============================================================================
   R3  Patient discharge report: name, treatments received, treating physician,
       date of service.          ORDER BY DischargeDate DESC, PatientName, DateOfService
   ============================================================================= */
CREATE OR ALTER VIEW rpt.vw_DischargeTreatments
AS
SELECT
    a.AdmissionID,
    CONCAT(p.LastName, N', ', p.FirstName)                               AS PatientName,
    a.AdmitDate,
    a.DischargeDate,
    t.TreatmentName,
    -- CASE, not ISNULL(CONCAT(...)): CONCAT turns NULLs into '' and never returns NULL
    CASE WHEN tp.PhysicianID IS NULL THEN N'(not recorded)'
         ELSE CONCAT(N'Dr. ', tp.FirstName, N' ', tp.LastName) END        AS TreatingPhysician,
    CAST(ta.AdministeredAt AS DATE)                                      AS DateOfService,
    ta.Results,
    ta.ChargedAmount
FROM dbo.Admission a
JOIN dbo.Patient p                  ON p.PatientID  = a.PatientID
JOIN dbo.TreatmentAdministration ta ON ta.AdmissionID = a.AdmissionID
JOIN dbo.Treatment t                ON t.TreatmentID = ta.TreatmentID
LEFT JOIN dbo.Physician tp          ON tp.PhysicianID = ta.PhysicianID
WHERE a.DischargeDate IS NOT NULL;
GO

/* =============================================================================
   R4  Monthly report of physician admits, ranked within each month
       ORDER BY MonthStart DESC, RankInMonth
   ============================================================================= */
CREATE OR ALTER VIEW rpt.vw_PhysicianMonthlyAdmits
AS
SELECT
    m.MonthStart,
    m.AdmitPhysicianID AS PhysicianID,
    CONCAT(N'Dr. ', ph.FirstName, N' ', ph.LastName) AS Physician,
    m.Admits,
    RANK() OVER (PARTITION BY m.MonthStart ORDER BY m.Admits DESC) AS RankInMonth,
    -- change vs the same physician's previous month (NULL in their first month)
    m.Admits - LAG(m.Admits) OVER (PARTITION BY m.AdmitPhysicianID ORDER BY m.MonthStart) AS ChangeVsPriorMonth
FROM (
    SELECT DATEFROMPARTS(YEAR(AdmitDate), MONTH(AdmitDate), 1) AS MonthStart,
           AdmitPhysicianID,
           COUNT(*) AS Admits
    FROM dbo.Admission
    GROUP BY DATEFROMPARTS(YEAR(AdmitDate), MONTH(AdmitDate), 1), AdmitPhysicianID
) m
JOIN dbo.Physician ph ON ph.PhysicianID = m.AdmitPhysicianID;
GO

/* =============================================================================
   R5  Shift rotation report of nurse-patient care for one day
   Usage: SELECT * FROM rpt.fn_ShiftRotation('2026-10-20') ORDER BY WardNumber, Nurse;
   ============================================================================= */
CREATE OR ALTER FUNCTION rpt.fn_ShiftRotation (@ShiftDate DATE)
RETURNS TABLE
AS
RETURN
SELECT
    w.WardNumber,
    w.WardName,
    CONCAT(n.LastName, N', ', n.FirstName) AS Nurse,
    na.HoursWorked,
    ISNULL(ev.PatientsSeen, 0) AS PatientsSeen,
    ISNULL(ev.TotalEvents, 0)  AS TotalEvents,
    ISNULL(ev.WC,  0) AS WellnessChecks,
    ISNULL(ev.MED, 0) AS Medication,
    ISNULL(ev.FS,  0) AS FoodService,
    ISNULL(ev.AS_, 0) AS Assistance,
    ISNULL(ev.TA,  0) AS TreatmentAdmin,
    ISNULL(ev.O,   0) AS Other
FROM dbo.NurseAssignment na
JOIN dbo.Nurse n ON n.NurseID = na.NurseID
JOIN dbo.Ward  w ON w.WardID  = na.WardID
OUTER APPLY (                                  -- conditional aggregation = pivot by event type
    SELECT COUNT(DISTINCT e.AdmissionID) AS PatientsSeen,
           COUNT(*) AS TotalEvents,
           SUM(CASE WHEN e.EventTypeCode = 'WC'  THEN 1 ELSE 0 END) AS WC,
           SUM(CASE WHEN e.EventTypeCode = 'MED' THEN 1 ELSE 0 END) AS MED,
           SUM(CASE WHEN e.EventTypeCode = 'FS'  THEN 1 ELSE 0 END) AS FS,
           SUM(CASE WHEN e.EventTypeCode = 'AS'  THEN 1 ELSE 0 END) AS AS_,
           SUM(CASE WHEN e.EventTypeCode = 'TA'  THEN 1 ELSE 0 END) AS TA,
           SUM(CASE WHEN e.EventTypeCode = 'O'   THEN 1 ELSE 0 END) AS O
    FROM dbo.NurseCareEvent e
    WHERE e.NurseID = na.NurseID
      AND e.EventAt >= CAST(@ShiftDate AS DATETIME2(0))                 -- sargable day range
      AND e.EventAt <  DATEADD(DAY, 1, CAST(@ShiftDate AS DATETIME2(0)))
) ev
WHERE na.ShiftDate = @ShiftDate;
GO

/* =============================================================================
   R6  Summary of charges for a patient stay (treatments + items)
       ORDER BY AdmitDate DESC.  Itemized bill: EXEC dbo.usp_GetPatientBill @AdmissionID
   ============================================================================= */
CREATE OR ALTER VIEW rpt.vw_StayCharges
AS
SELECT
    a.AdmissionID,
    a.PatientID,
    CONCAT(p.LastName, N', ', p.FirstName) AS PatientName,
    a.AdmitDate,
    a.DischargeDate,
    ISNULL(t.TreatmentCount, 0)            AS TreatmentCount,
    ISNULL(t.TreatmentTotal, 0)            AS TreatmentTotal,
    ISNULL(i.ItemLines, 0)                 AS ItemLines,
    ISNULL(i.ItemTotal, 0)                 AS ItemTotal,
    ISNULL(t.TreatmentTotal, 0) + ISNULL(i.ItemTotal, 0) AS GrandTotal
FROM dbo.Admission a
JOIN dbo.Patient p ON p.PatientID = a.PatientID
OUTER APPLY (SELECT COUNT(*) AS TreatmentCount, SUM(ChargedAmount) AS TreatmentTotal
             FROM dbo.TreatmentAdministration WHERE AdmissionID = a.AdmissionID) t
OUTER APPLY (SELECT COUNT(*) AS ItemLines, SUM(LineTotal) AS ItemTotal
             FROM dbo.ItemCharge WHERE AdmissionID = a.AdmissionID) i;
GO

/* =============================================================================
   R7  Ward scheduling report with name of charge nurse
       ORDER BY ShiftDate DESC, WardNumber
   ============================================================================= */
CREATE OR ALTER VIEW rpt.vw_WardSchedule
AS
SELECT
    na.ShiftDate,
    w.WardNumber,
    w.WardName,
    CONCAT(cn.LastName, N', ', cn.FirstName) AS ChargeNurse,
    COUNT(*)                                 AS NursesOnShift,
    SUM(na.HoursWorked)                      AS TotalHours,
    STRING_AGG(CONCAT(n.LastName, N' (', CAST(na.HoursWorked AS INT), N'h)'), N', ')
        WITHIN GROUP (ORDER BY n.LastName)   AS Nurses
FROM dbo.NurseAssignment na
JOIN dbo.Ward  w  ON w.WardID   = na.WardID
JOIN dbo.Nurse cn ON cn.NurseID = w.ChargeNurseID
JOIN dbo.Nurse n  ON n.NurseID  = na.NurseID
GROUP BY na.ShiftDate, w.WardNumber, w.WardName, cn.LastName, cn.FirstName;
GO

/* =============================================================================
   R8  Patient ward assignment report (full bed history)
       ORDER BY PatientName, StartDate
   ============================================================================= */
CREATE OR ALTER VIEW rpt.vw_PatientWardAssignment
AS
SELECT
    p.PatientID,
    CONCAT(p.LastName, N', ', p.FirstName) AS PatientName,
    ba.AdmissionID,
    w.WardNumber,
    w.WardName,
    b.BedNumber,
    ba.StartDate,
    ba.EndDate,
    CASE WHEN ba.EndDate IS NULL THEN 'Y' ELSE 'N' END AS IsCurrent
FROM dbo.BedAssignment ba
JOIN dbo.Admission a ON a.AdmissionID = ba.AdmissionID
JOIN dbo.Patient   p ON p.PatientID   = a.PatientID
JOIN dbo.Bed       b ON b.BedID       = ba.BedID
JOIN dbo.Ward      w ON w.WardID      = b.WardID;
GO

/* =============================================================================
   R9  Patient treatment report WITH and WITHOUT treating physician
       LEFT JOIN keeps treatments that have no physician (BR-29).
       Filter on HasTreatingPhysician = 'N' for the "without" list.
       ORDER BY PatientName, DateOfService
   ============================================================================= */
CREATE OR ALTER VIEW rpt.vw_PatientTreatments
AS
SELECT
    ta.TreatmentAdminID,
    a.PatientID,
    CONCAT(p.LastName, N', ', p.FirstName) AS PatientName,
    ta.AdmissionID,
    t.TreatmentName,
    ta.AdministeredAt                      AS DateOfService,
    ta.Results,
    CASE WHEN ph.PhysicianID IS NULL THEN 'N' ELSE 'Y' END AS HasTreatingPhysician,
    CASE WHEN ph.PhysicianID IS NULL THEN N'(not recorded)'
         ELSE CONCAT(N'Dr. ', ph.FirstName, N' ', ph.LastName) END AS TreatingPhysician,
    ta.ChargedAmount
FROM dbo.TreatmentAdministration ta
JOIN dbo.Admission a  ON a.AdmissionID = ta.AdmissionID
JOIN dbo.Patient   p  ON p.PatientID   = a.PatientID
JOIN dbo.Treatment t  ON t.TreatmentID = ta.TreatmentID
LEFT JOIN dbo.Physician ph ON ph.PhysicianID = ta.PhysicianID;
GO

/* =============================================================================
   R10 Physician treatment report: dates and types of treatments
       ORDER BY Physician, TreatmentName
   ============================================================================= */
CREATE OR ALTER VIEW rpt.vw_PhysicianTreatments
AS
SELECT
    ph.PhysicianID,
    CONCAT(N'Dr. ', ph.FirstName, N' ', ph.LastName) AS Physician,
    t.TreatmentName,
    COUNT(*)                                AS TimesAdministered,
    MIN(CAST(ta.AdministeredAt AS DATE))    AS FirstDate,
    MAX(CAST(ta.AdministeredAt AS DATE))    AS LastDate,
    SUM(ta.ChargedAmount)                   AS TotalCharged
FROM dbo.TreatmentAdministration ta
JOIN dbo.Physician ph ON ph.PhysicianID = ta.PhysicianID
JOIN dbo.Treatment t  ON t.TreatmentID  = ta.TreatmentID
GROUP BY ph.PhysicianID, ph.FirstName, ph.LastName, t.TreatmentName;
GO

/* =============================================================================
   R11 Physicians and their specialties
       ORDER BY Physician
   ============================================================================= */
CREATE OR ALTER VIEW rpt.vw_PhysicianSpecialties
AS
SELECT
    ph.PhysicianID,
    CONCAT(N'Dr. ', ph.FirstName, N' ', ph.LastName) AS Physician,
    COUNT(ps.SpecialtyID) AS SpecialtyCount,
    STRING_AGG(s.SpecialtyName, N', ') WITHIN GROUP (ORDER BY s.SpecialtyName) AS Specialties,
    ph.Phone,
    ph.Email
FROM dbo.Physician ph
LEFT JOIN dbo.PhysicianSpecialty ps ON ps.PhysicianID = ph.PhysicianID
LEFT JOIN dbo.Specialty s           ON s.SpecialtyID  = ps.SpecialtyID
GROUP BY ph.PhysicianID, ph.FirstName, ph.LastName, ph.Phone, ph.Email;
GO

/* =============================================================================
   R12 Nurses with certifications and ward assignments, including supervisors
       ORDER BY Nurse
   ============================================================================= */
CREATE OR ALTER VIEW rpt.vw_NurseRoster
AS
SELECT
    n.NurseID,
    CONCAT(n.LastName, N', ', n.FirstName)           AS Nurse,
    CASE WHEN sup.NurseID IS NOT NULL
         THEN CONCAT(sup.LastName, N', ', sup.FirstName) END AS Supervisor,   -- self-join
    (SELECT COUNT(*) FROM dbo.Nurse r WHERE r.SupervisorID = n.NurseID) AS DirectReports,
    cw.WardName                                      AS ChargeNurseOf,
    (SELECT STRING_AGG(nc.CertCode, N', ') WITHIN GROUP (ORDER BY nc.CertCode)
     FROM dbo.NurseCertification nc WHERE nc.NurseID = n.NurseID)       AS Certifications,
    -- distinct wards worked in the last 30 days (STRING_AGG has no DISTINCT, so dedupe first)
    (SELECT STRING_AGG(d.WardNumber, N', ') WITHIN GROUP (ORDER BY d.WardNumber)
     FROM (SELECT DISTINCT w.WardNumber
           FROM dbo.NurseAssignment na JOIN dbo.Ward w ON w.WardID = na.WardID
           WHERE na.NurseID = n.NurseID
             AND na.ShiftDate >= DATEADD(DAY, -30, CAST(GETDATE() AS DATE))) d) AS WardsLast30Days,
    (SELECT SUM(na.HoursWorked) FROM dbo.NurseAssignment na
     WHERE na.NurseID = n.NurseID
       AND na.ShiftDate >= DATEADD(DAY, -30, CAST(GETDATE() AS DATE)))           AS HoursLast30Days
FROM dbo.Nurse n
LEFT JOIN dbo.Nurse sup ON sup.NurseID      = n.SupervisorID
LEFT JOIN dbo.Ward  cw  ON cw.ChargeNurseID = n.NurseID;
GO

-- Supporting view for R12: the supervision tree, built with a recursive CTE.
-- ORDER BY HierarchyPath
CREATE OR ALTER VIEW rpt.vw_NurseHierarchy
AS
WITH tree AS (
    SELECT n.NurseID, n.SupervisorID, 1 AS Level,
           CAST(CONCAT(n.LastName, N', ', n.FirstName) AS NVARCHAR(1000)) AS HierarchyPath
    FROM dbo.Nurse n
    WHERE n.SupervisorID IS NULL                      -- anchor: top of each chain
    UNION ALL
    SELECT n.NurseID, n.SupervisorID, t.Level + 1,
           CAST(CONCAT(t.HierarchyPath, N' > ', n.LastName, N', ', n.FirstName) AS NVARCHAR(1000))
    FROM dbo.Nurse n
    JOIN tree t ON n.SupervisorID = t.NurseID         -- recursive step: direct reports
)
SELECT t.NurseID,
       CONCAT(REPLICATE(N'    ', t.Level - 1), n.LastName, N', ', n.FirstName) AS NurseIndented,
       t.Level,
       t.HierarchyPath
FROM tree t
JOIN dbo.Nurse n ON n.NurseID = t.NurseID;
GO

PRINT N'07_reporting_views.sql completed.';
GO
