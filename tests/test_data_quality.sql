/* =============================================================================
   test_data_quality.sql
   Cross-table data-quality checks for rules that SQL Server can't enforce
   declaratively (see docs/05_design_review.md, section 5.4), plus temporal
   consistency of the loaded history.

   Every check counts violations; all must be 0. A short data profile follows.
   Read-only: safe to run against a live database at any time.
   Fails the run (RAISERROR severity 16) if any check fails.
   ============================================================================= */

USE HospitalOps;
GO
SET NOCOUNT ON;

DECLARE @Today DATE = CAST(GETDATE() AS DATE);
DROP TABLE IF EXISTS #checks;
CREATE TABLE #checks (Code CHAR(4), Rule_ NVARCHAR(10), [Check] NVARCHAR(100), Violations INT);

/* ---------- Minimum cardinality --------------------------------------------- */
INSERT #checks SELECT 'DQ01', N'BR-07', N'Nurses with no ward assignment',
    COUNT(*) FROM dbo.Nurse n WHERE NOT EXISTS (SELECT 1 FROM dbo.NurseAssignment a WHERE a.NurseID = n.NurseID);

INSERT #checks SELECT 'DQ02', N'BR-07', N'Wards with no nurse assignment',
    COUNT(*) FROM dbo.Ward w WHERE NOT EXISTS (SELECT 1 FROM dbo.NurseAssignment a WHERE a.WardID = w.WardID);

INSERT #checks SELECT 'DQ03', N'BR-34', N'Stays with no item charge',
    COUNT(*) FROM dbo.Admission a WHERE NOT EXISTS (SELECT 1 FROM dbo.ItemCharge c WHERE c.AdmissionID = a.AdmissionID);

/* ---------- No overlaps in time ----------------------------------------------
   Same-day turnover is allowed: the next stay may start on the day the last ended. */
WITH x AS (
    SELECT EndDate, NextStart = LEAD(StartDate) OVER (PARTITION BY BedID ORDER BY StartDate, BedAssignmentID)
    FROM dbo.BedAssignment
)
INSERT #checks SELECT 'DQ04', N'BR-24', N'Overlapping assignments on the same bed',
    COUNT(*) FROM x WHERE NextStart IS NOT NULL AND (EndDate IS NULL OR NextStart < EndDate);

WITH x AS (
    SELECT DischargeDate, NextAdmit = LEAD(AdmitDate) OVER (PARTITION BY PatientID ORDER BY AdmitDate, AdmissionID)
    FROM dbo.Admission
)
INSERT #checks SELECT 'DQ05', N'BR-22', N'Overlapping stays for the same patient',
    COUNT(*) FROM x WHERE NextAdmit IS NOT NULL AND (DischargeDate IS NULL OR NextAdmit < DischargeDate);

/* ---------- State consistency ------------------------------------------------ */
INSERT #checks SELECT 'DQ06', N'BR-26', N'Bed availability flag disagrees with occupancy',
    COUNT(*) FROM dbo.Bed b
    CROSS APPLY (SELECT Occupied = CASE WHEN EXISTS (SELECT 1 FROM dbo.BedAssignment ba
                                                     WHERE ba.BedID = b.BedID AND ba.EndDate IS NULL) THEN 1 ELSE 0 END) o
    WHERE (o.Occupied = 1 AND b.Availability <> 'O') OR (o.Occupied = 0 AND b.Availability <> 'A');

INSERT #checks SELECT 'DQ07', N'BR-23', N'Open stay without a current bed, or closed stay still holding one',
    COUNT(*) FROM dbo.Admission a
    WHERE (a.DischargeDate IS NULL     AND NOT EXISTS (SELECT 1 FROM dbo.BedAssignment ba WHERE ba.AdmissionID = a.AdmissionID AND ba.EndDate IS NULL))
       OR (a.DischargeDate IS NOT NULL AND     EXISTS (SELECT 1 FROM dbo.BedAssignment ba WHERE ba.AdmissionID = a.AdmissionID AND ba.EndDate IS NULL));

/* ---------- Temporal consistency --------------------------------------------- */
INSERT #checks SELECT 'DQ08', N'BR-16', N'Admitted before date of birth',
    COUNT(*) FROM dbo.Admission a JOIN dbo.Patient p ON p.PatientID = a.PatientID WHERE a.AdmitDate < p.DOB;

INSERT #checks SELECT 'DQ09', N'BR-30', N'Treatments outside their stay',
    COUNT(*) FROM dbo.TreatmentAdministration t JOIN dbo.Admission a ON a.AdmissionID = t.AdmissionID
    WHERE CAST(t.AdministeredAt AS DATE) NOT BETWEEN a.AdmitDate AND ISNULL(a.DischargeDate, @Today);

INSERT #checks SELECT 'DQ10', N'BR-32', N'Item charges outside their stay',
    COUNT(*) FROM dbo.ItemCharge c JOIN dbo.Admission a ON a.AdmissionID = c.AdmissionID
    WHERE c.ChargeDate NOT BETWEEN a.AdmitDate AND ISNULL(a.DischargeDate, @Today);

INSERT #checks SELECT 'DQ11', N'BR-35', N'Care events outside their stay',
    COUNT(*) FROM dbo.NurseCareEvent e JOIN dbo.Admission a ON a.AdmissionID = e.AdmissionID
    WHERE CAST(e.EventAt AS DATE) NOT BETWEEN a.AdmitDate AND ISNULL(a.DischargeDate, @Today);

INSERT #checks SELECT 'DQ12', N'—', N'Clinical events dated in the future',
      (SELECT COUNT(*) FROM dbo.TreatmentAdministration WHERE AdministeredAt > SYSDATETIME())
    + (SELECT COUNT(*) FROM dbo.NurseCareEvent         WHERE EventAt        > SYSDATETIME())
    + (SELECT COUNT(*) FROM dbo.ItemCharge             WHERE ChargeDate     > @Today);

/* ---------- Staffing --------------------------------------------------------- */
-- The nurse on a care event must be on shift that day in the ward where the patient's bed was.
INSERT #checks SELECT 'DQ13', N'BR-35', N'Care event by a nurse not on shift in that ward that day',
    COUNT(*)
    FROM dbo.NurseCareEvent e
    JOIN dbo.BedAssignment ba ON ba.AdmissionID = e.AdmissionID
                             AND CAST(e.EventAt AS DATE) >= ba.StartDate
                             AND (ba.EndDate IS NULL OR CAST(e.EventAt AS DATE) <= ba.EndDate)
    JOIN dbo.Bed b ON b.BedID = ba.BedID
    WHERE NOT EXISTS (SELECT 1 FROM dbo.NurseAssignment na
                      WHERE na.NurseID = e.NurseID AND na.WardID = b.WardID AND na.ShiftDate = CAST(e.EventAt AS DATE));

INSERT #checks SELECT 'DQ14', N'BR-06', N'Nurses scheduled more than 24 hours in one day',
    COUNT(*) FROM (SELECT NurseID, ShiftDate FROM dbo.NurseAssignment
                   GROUP BY NurseID, ShiftDate HAVING SUM(HoursWorked) > 24) x;

-- Recursive CTE: walk up each nurse's supervisor chain; a chain longer than the
-- number of nurses must contain a cycle (A supervises B supervises ... A).
DECLARE @maxDepth INT = (SELECT COUNT(*) FROM dbo.Nurse);
WITH chain AS (
    SELECT NurseID AS StartNurse, SupervisorID AS Current_, 1 AS Depth
    FROM dbo.Nurse WHERE SupervisorID IS NOT NULL
    UNION ALL
    SELECT c.StartNurse, n.SupervisorID, c.Depth + 1
    FROM chain c JOIN dbo.Nurse n ON n.NurseID = c.Current_
    WHERE n.SupervisorID IS NOT NULL AND c.Depth <= @maxDepth
)
INSERT #checks SELECT 'DQ15', N'BR-03', N'Nurses inside a supervision cycle',
    COUNT(DISTINCT StartNurse) FROM chain WHERE Depth > @maxDepth
OPTION (MAXRECURSION 0);

/* ---------- Report ------------------------------------------------------------ */
SELECT Code, Rule_ AS [Rule], [Check], Violations,
       CASE WHEN Violations = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
FROM #checks ORDER BY Code;

-- Data profile (informational)
SELECT Metric, Value FROM (VALUES
    (1, N'Patients',                       FORMAT((SELECT COUNT(*) FROM dbo.Patient), 'N0')),
    (2, N'Stays (admissions)',             FORMAT((SELECT COUNT(*) FROM dbo.Admission), 'N0')),
    (3, N'Patients with 2+ stays',         FORMAT((SELECT COUNT(*) FROM (SELECT PatientID FROM dbo.Admission GROUP BY PatientID HAVING COUNT(*) > 1) x), 'N0')),
    (4, N'History covered',                CONCAT((SELECT MIN(AdmitDate) FROM dbo.Admission), N' to ', @Today)),
    (5, N'Current census (open stays)',    FORMAT((SELECT COUNT(*) FROM dbo.Admission WHERE DischargeDate IS NULL), 'N0')),
    (6, N'Current bed occupancy',          FORMAT((SELECT AVG(CASE WHEN Availability = 'O' THEN 1.0 ELSE 0 END) FROM dbo.Bed), 'P1')),
    (7, N'Average length of stay (days)',  FORMAT((SELECT AVG(DATEDIFF(DAY, AdmitDate, DischargeDate) * 1.0) FROM dbo.Admission WHERE DischargeDate IS NOT NULL), 'N2')),
    (8, N'Average bill per stay',          FORMAT(((SELECT SUM(LineTotal) FROM dbo.ItemCharge) + (SELECT SUM(ChargedAmount) FROM dbo.TreatmentAdministration))
                                                  / (SELECT COUNT(*) FROM dbo.Admission), 'C', 'en-US')),
    (9, N'Treatments without a physician', FORMAT((SELECT COUNT(*) FROM dbo.TreatmentAdministration WHERE PhysicianID IS NULL), 'N0')),
   (10, N'Never-used treatments / items',  CONCAT((SELECT COUNT(*) FROM dbo.Treatment t WHERE NOT EXISTS (SELECT 1 FROM dbo.TreatmentAdministration x WHERE x.TreatmentID = t.TreatmentID)),
                                                  N' / ',
                                                  (SELECT COUNT(*) FROM dbo.Item i WHERE NOT EXISTS (SELECT 1 FROM dbo.ItemCharge x WHERE x.ItemID = i.ItemID))))
) AS v (o, Metric, Value) ORDER BY o;

GO

-- Separate batch so the reports above are returned before any failure is raised.
DECLARE @fail INT = (SELECT COUNT(*) FROM #checks WHERE Violations > 0),
        @total INT = (SELECT COUNT(*) FROM #checks);
PRINT CONCAT(N'Data-quality checks: ', @total - @fail, N' passed, ', @fail, N' failed.');
DROP TABLE #checks;
IF @fail > 0 RAISERROR (N'%d data-quality check(s) failed.', 16, 1, @fail);
GO
