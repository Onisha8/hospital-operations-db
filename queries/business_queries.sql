/* =============================================================================
   business_queries.sql
   Analytical questions an administrator would ask, beyond the fixed reports.
   Each query names the question and the T-SQL technique it demonstrates.

     Q1  Revenue trend by month with running total and MoM change   window SUM, LAG
     Q2  Top 3 revenue-generating treatments per year              CTE, DENSE_RANK
     Q3  Average length of stay by ward and age band               CASE, age at admission
     Q4  Bed utilization by ward over the last 90 days             date-range overlap arithmetic
     Q5  Nurse workload quartiles (hours vs care events)           NTILE, ratios
     Q6  Care events by type per ward                              PIVOT
     Q7  Busiest hours for nursing care                            DATEPART, share of total
     Q8  Physicians who admit but never treat, and vice versa       EXCEPT
     Q9  Stays that had both a chest X-ray and a chest CT          INTERSECT
     Q10 Catalog entries never used                                NOT EXISTS
     Q11 Price drift: charged price vs today's list price by year  snapshot vs catalog
     Q12 Longest back-to-back occupancy streak per ward            gaps and islands

   Read-only. Run after the build:  .\run_sql.ps1 -Files queries\business_queries.sql
   ============================================================================= */

USE HospitalOps;
GO
SET NOCOUNT ON;
GO

/* -----------------------------------------------------------------------------
   Q1  How is revenue trending month to month over the last 12 months?
   ----------------------------------------------------------------------------- */
DECLARE @From DATE = DATEADD(MONTH, -12, DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1));

WITH charges AS (
    SELECT CAST(AdministeredAt AS DATE) AS ServiceDate, ChargedAmount AS Amount FROM dbo.TreatmentAdministration
    UNION ALL
    SELECT ChargeDate, LineTotal FROM dbo.ItemCharge
),
monthly AS (
    SELECT DATEFROMPARTS(YEAR(ServiceDate), MONTH(ServiceDate), 1) AS MonthStart, SUM(Amount) AS Revenue
    FROM charges
    WHERE ServiceDate >= @From
    GROUP BY DATEFROMPARTS(YEAR(ServiceDate), MONTH(ServiceDate), 1)
)
SELECT TOP (13)
    'Q1' AS Q,
    CONCAT(FORMAT(MonthStart, 'yyyy-MM'),
           CASE WHEN MonthStart = DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1) THEN ' (MTD)' END) AS [Month],
    FORMAT(Revenue, 'C0', 'en-US')                                                 AS Revenue,
    FORMAT(SUM(Revenue) OVER (ORDER BY MonthStart ROWS UNBOUNDED PRECEDING), 'C0', 'en-US') AS RunningTotal,
    FORMAT((Revenue - LAG(Revenue) OVER (ORDER BY MonthStart)) / LAG(Revenue) OVER (ORDER BY MonthStart), 'P1') AS MoMChange
FROM monthly
ORDER BY MonthStart;
GO

/* -----------------------------------------------------------------------------
   Q2  Which three treatments earned the most each year?
   ----------------------------------------------------------------------------- */
WITH yearly AS (
    SELECT YEAR(ta.AdministeredAt) AS [Year], t.TreatmentName,
           COUNT(*) AS TimesGiven, SUM(ta.ChargedAmount) AS Revenue
    FROM dbo.TreatmentAdministration ta
    JOIN dbo.Treatment t ON t.TreatmentID = ta.TreatmentID
    GROUP BY YEAR(ta.AdministeredAt), t.TreatmentName
),
ranked AS (
    SELECT *, DENSE_RANK() OVER (PARTITION BY [Year] ORDER BY Revenue DESC) AS RevenueRank
    FROM yearly
)
SELECT 'Q2' AS Q, [Year], RevenueRank, TreatmentName, TimesGiven, FORMAT(Revenue, 'C0', 'en-US') AS Revenue
FROM ranked
WHERE RevenueRank <= 3
ORDER BY [Year] DESC, RevenueRank;
GO

/* -----------------------------------------------------------------------------
   Q3  How does length of stay vary by ward and patient age band?
       Age is computed AT ADMISSION (birthday-aware), not today's age.
   ----------------------------------------------------------------------------- */
WITH stays AS (
    SELECT w.WardName,
           DATEDIFF(DAY, a.AdmitDate, a.DischargeDate) AS LOS,
           DATEDIFF(YEAR, p.DOB, a.AdmitDate)
             - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DOB, a.AdmitDate), p.DOB) > a.AdmitDate THEN 1 ELSE 0 END AS AgeAtAdmit
    FROM dbo.Admission a
    JOIN dbo.Patient p        ON p.PatientID    = a.PatientID
    JOIN dbo.BedAssignment ba ON ba.AdmissionID = a.AdmissionID
    JOIN dbo.Bed b            ON b.BedID        = ba.BedID
    JOIN dbo.Ward w           ON w.WardID       = b.WardID
    WHERE a.DischargeDate IS NOT NULL
)
SELECT 'Q3' AS Q, WardName,
       CAST(AVG(CASE WHEN AgeAtAdmit < 18              THEN LOS * 1.0 END) AS DECIMAL(4,2)) AS [0-17],
       CAST(AVG(CASE WHEN AgeAtAdmit BETWEEN 18 AND 39 THEN LOS * 1.0 END) AS DECIMAL(4,2)) AS [18-39],
       CAST(AVG(CASE WHEN AgeAtAdmit BETWEEN 40 AND 64 THEN LOS * 1.0 END) AS DECIMAL(4,2)) AS [40-64],
       CAST(AVG(CASE WHEN AgeAtAdmit >= 65             THEN LOS * 1.0 END) AS DECIMAL(4,2)) AS [65+],
       CAST(AVG(LOS * 1.0) AS DECIMAL(4,2))                                                 AS AllAges,
       COUNT(*) AS Stays
FROM stays
GROUP BY WardName
ORDER BY AllAges DESC;
GO

/* -----------------------------------------------------------------------------
   Q4  How fully used was each ward over the last 90 days?
       Occupied bed-nights = overlap of each assignment with the window:
       MAX(0, MIN(end, windowEnd) - MAX(start, windowStart)).
   ----------------------------------------------------------------------------- */
DECLARE @WinEnd DATE = CAST(GETDATE() AS DATE), @WinStart DATE = DATEADD(DAY, -90, CAST(GETDATE() AS DATE));

SELECT 'Q4' AS Q, w.WardName,
       COUNT(DISTINCT b.BedID) * 90                                                  AS AvailableBedNights,
       ISNULL(SUM(ov.Nights), 0)                                                     AS OccupiedBedNights,
       FORMAT(ISNULL(SUM(ov.Nights), 0) * 1.0 / (COUNT(DISTINCT b.BedID) * 90), 'P1') AS Utilization
FROM dbo.Ward w
JOIN dbo.Bed b ON b.WardID = w.WardID
LEFT JOIN dbo.BedAssignment ba
       ON ba.BedID = b.BedID
      AND ba.StartDate < @WinEnd
      AND (ba.EndDate IS NULL OR ba.EndDate > @WinStart)
CROSS APPLY (
    SELECT Nights = CASE WHEN ba.BedID IS NULL THEN 0 ELSE
           DATEDIFF(DAY,
                    CASE WHEN ba.StartDate > @WinStart THEN ba.StartDate ELSE @WinStart END,
                    CASE WHEN ba.EndDate IS NULL OR ba.EndDate > @WinEnd THEN @WinEnd ELSE ba.EndDate END) END
) ov
GROUP BY w.WardName
ORDER BY ISNULL(SUM(ov.Nights), 0) * 1.0 / (COUNT(DISTINCT b.BedID) * 90) DESC;
GO

/* -----------------------------------------------------------------------------
   Q5  Which nurses carry the heaviest care load per hour worked (last 90 days)?
   ----------------------------------------------------------------------------- */
DECLARE @Since DATE = DATEADD(DAY, -90, CAST(GETDATE() AS DATE));

WITH hours AS (
    SELECT NurseID, SUM(HoursWorked) AS Hours, COUNT(*) AS Shifts
    FROM dbo.NurseAssignment WHERE ShiftDate >= @Since GROUP BY NurseID
),
events AS (
    SELECT NurseID, COUNT(*) AS Events
    FROM dbo.NurseCareEvent WHERE EventAt >= @Since GROUP BY NurseID
),
load_ AS (
    SELECT n.NurseID, CONCAT(n.LastName, N', ', n.FirstName) AS Nurse, h.Shifts, h.Hours,
           ISNULL(e.Events, 0) AS Events,
           CAST(ISNULL(e.Events, 0) / h.Hours AS DECIMAL(5,2)) AS EventsPerHour
    FROM hours h
    JOIN dbo.Nurse n ON n.NurseID = h.NurseID
    LEFT JOIN events e ON e.NurseID = h.NurseID
)
SELECT TOP (10) 'Q5' AS Q, Nurse, Shifts, Hours, Events, EventsPerHour,
       NTILE(4) OVER (ORDER BY EventsPerHour DESC) AS LoadQuartile   -- 1 = busiest quarter
FROM load_
ORDER BY EventsPerHour DESC;
GO

/* -----------------------------------------------------------------------------
   Q6  What kind of nursing care does each ward need? (last 12 months)
   ----------------------------------------------------------------------------- */
SELECT 'Q6' AS Q, WardName, [Wellness Check], [Medication], [Food Service], [Assistance], [Treatment Admin], [Other]
FROM (
    SELECT w.WardName, et.EventTypeName, e.CareEventID
    FROM dbo.NurseCareEvent e
    JOIN dbo.CareEventType et ON et.EventTypeCode = e.EventTypeCode
    JOIN dbo.BedAssignment ba ON ba.AdmissionID   = e.AdmissionID
    JOIN dbo.Bed b            ON b.BedID          = ba.BedID
    JOIN dbo.Ward w           ON w.WardID         = b.WardID
    WHERE e.EventAt >= DATEADD(MONTH, -12, GETDATE())
) src
PIVOT (COUNT(CareEventID) FOR EventTypeName IN
       ([Wellness Check], [Medication], [Food Service], [Assistance], [Treatment Admin], [Other])) pvt
ORDER BY WardName;
GO

/* -----------------------------------------------------------------------------
   Q7  When during the day is nursing care busiest?
   ----------------------------------------------------------------------------- */
SELECT TOP (5) 'Q7' AS Q,
       FORMAT(DATEPART(HOUR, EventAt), '00') + ':00' AS HourOfDay,
       COUNT(*) AS Events,
       FORMAT(COUNT(*) * 1.0 / SUM(COUNT(*)) OVER (), 'P1') AS ShareOfDay
FROM dbo.NurseCareEvent
GROUP BY DATEPART(HOUR, EventAt)
ORDER BY Events DESC;
GO

/* -----------------------------------------------------------------------------
   Q8  Which physicians admit patients but have never treated one, and vice versa?
   ----------------------------------------------------------------------------- */
SELECT 'Q8' AS Q, 'Admits, never treats' AS Category, COUNT(*) AS Physicians
FROM (SELECT AdmitPhysicianID FROM dbo.Admission
      EXCEPT
      SELECT PhysicianID FROM dbo.TreatmentAdministration) x
UNION ALL
SELECT 'Q8', 'Treats, never admits', COUNT(*)
FROM (SELECT PhysicianID FROM dbo.TreatmentAdministration WHERE PhysicianID IS NOT NULL
      EXCEPT
      SELECT AdmitPhysicianID FROM dbo.Admission) x
UNION ALL
SELECT 'Q8', 'Neither admits nor treats', COUNT(*)
FROM (SELECT PhysicianID FROM dbo.Physician
      EXCEPT SELECT AdmitPhysicianID FROM dbo.Admission
      EXCEPT SELECT PhysicianID FROM dbo.TreatmentAdministration WHERE PhysicianID IS NOT NULL) x;
GO

/* -----------------------------------------------------------------------------
   Q9  How many stays had both a chest X-ray and a chest CT (possible duplicate imaging)?
   ----------------------------------------------------------------------------- */
WITH both_ AS (
    SELECT ta.AdmissionID FROM dbo.TreatmentAdministration ta
    JOIN dbo.Treatment t ON t.TreatmentID = ta.TreatmentID WHERE t.TreatmentName = N'Chest X-Ray'
    INTERSECT
    SELECT ta.AdmissionID FROM dbo.TreatmentAdministration ta
    JOIN dbo.Treatment t ON t.TreatmentID = ta.TreatmentID WHERE t.TreatmentName = N'CT Scan - Chest'
)
SELECT 'Q9' AS Q, COUNT(*) AS StaysWithBoth,
       FORMAT(COUNT(*) * 1.0 / (SELECT COUNT(*) FROM dbo.Admission), 'P2') AS ShareOfAllStays
FROM both_;
GO

/* -----------------------------------------------------------------------------
   Q10 Which catalog entries have never been used (candidates for cleanup)?
   ----------------------------------------------------------------------------- */
SELECT 'Q10' AS Q, N'Treatment' AS Catalog, t.TreatmentName AS Entry, t.StandardCharge AS ListPrice
FROM dbo.Treatment t
WHERE NOT EXISTS (SELECT 1 FROM dbo.TreatmentAdministration ta WHERE ta.TreatmentID = t.TreatmentID)
UNION ALL
SELECT 'Q10', N'Item', i.ItemName, i.UnitCharge
FROM dbo.Item i
WHERE NOT EXISTS (SELECT 1 FROM dbo.ItemCharge ic WHERE ic.ItemID = i.ItemID)
ORDER BY Catalog, Entry;
GO

/* -----------------------------------------------------------------------------
   Q11 How far do historical charges differ from today's list prices?
       Shows why prices are snapshotted (BR-33): re-pricing old bills from the
       catalog would overstate them.
   ----------------------------------------------------------------------------- */
SELECT 'Q11' AS Q, YEAR(ic.ChargeDate) AS [Year],
       FORMAT(SUM(ic.LineTotal), 'C0', 'en-US')                   AS BilledAtTimeOfService,
       FORMAT(SUM(ic.Quantity * i.UnitCharge), 'C0', 'en-US')     AS IfRepricedAtToday,
       FORMAT(SUM(ic.Quantity * i.UnitCharge) / SUM(ic.LineTotal) - 1, 'P1') AS Overstatement
FROM dbo.ItemCharge ic
JOIN dbo.Item i ON i.ItemID = ic.ItemID
GROUP BY YEAR(ic.ChargeDate)
ORDER BY [Year];
GO

/* -----------------------------------------------------------------------------
   Q12 What is the longest stretch each ward kept a bed continuously occupied?
       Gaps and islands: a new "island" starts whenever a stay begins after the
       previous stay on that bed ended. The running count of island starts
       labels each island.
   ----------------------------------------------------------------------------- */
WITH ordered AS (
    SELECT ba.BedID, b.WardID, ba.StartDate, ISNULL(ba.EndDate, CAST(GETDATE() AS DATE)) AS EndDate,
           LAG(ISNULL(ba.EndDate, CAST(GETDATE() AS DATE))) OVER (PARTITION BY ba.BedID ORDER BY ba.StartDate) AS PrevEnd
    FROM dbo.BedAssignment ba
    JOIN dbo.Bed b ON b.BedID = ba.BedID
),
flagged AS (
    SELECT *, SUM(CASE WHEN PrevEnd IS NULL OR StartDate > PrevEnd THEN 1 ELSE 0 END)
                  OVER (PARTITION BY BedID ORDER BY StartDate ROWS UNBOUNDED PRECEDING) AS IslandNo
    FROM ordered
),
islands AS (
    SELECT BedID, WardID, IslandNo, MIN(StartDate) AS FromDate, MAX(EndDate) AS ToDate, COUNT(*) AS Stays
    FROM flagged
    GROUP BY BedID, WardID, IslandNo
),
best AS (
    SELECT i.*, DATEDIFF(DAY, FromDate, ToDate) AS Days,
           ROW_NUMBER() OVER (PARTITION BY WardID ORDER BY DATEDIFF(DAY, FromDate, ToDate) DESC, FromDate) AS rn
    FROM islands i
)
SELECT 'Q12' AS Q, w.WardName, b.BedNumber, best.FromDate, best.ToDate, best.Days, best.Stays AS ConsecutiveStays
FROM best
JOIN dbo.Ward w ON w.WardID = best.WardID
JOIN dbo.Bed  b ON b.BedID  = best.BedID
WHERE best.rn = 1
ORDER BY best.Days DESC;
GO
