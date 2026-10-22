/* =============================================================================
   09_performance_indexes.sql
   Performance indexes, each justified by a measured workload query
   (performance/benchmark.sql, results in performance/PERFORMANCE.md).

   Design rules
   - Index the access paths the workload actually uses, not every FK by habit.
   - Key columns: equality first, then range or sort columns. INCLUDE only what
     the target query reads, so the index covers it without bloating.
   - Every index on a high-insert table (ItemCharge, TreatmentAdministration,
     NurseCareEvent) costs write time; W14 measures that cost.
   - Indexes that enforce rules (PK_, UQ_, UX_) live in 03_constraints.sql.
     Everything here is named IX_ so performance/drop_tuning_indexes.sql can
     remove them for a clean "before" benchmark.

   Re-runnable: each index is dropped if it exists, then created.
   ============================================================================= */

USE HospitalOps;
GO

/* -----------------------------------------------------------------------------
   Stay -> child rows. Bills, discharge reports and charts look up one stay's
   rows. Without these, every lookup scans the whole child table (W01, W02, W09).
   ----------------------------------------------------------------------------- */

-- W01 (R6 summary): COUNT + SUM(LineTotal) per stay, fully covered.
-- The itemized bill reads a few more columns via key lookups (~5 rows per stay, cheap).
DROP INDEX IF EXISTS IX_ItemCharge_AdmissionID ON dbo.ItemCharge;
CREATE INDEX IX_ItemCharge_AdmissionID
    ON dbo.ItemCharge (AdmissionID) INCLUDE (LineTotal);

-- W01 (R6), W02 (R3): treatments per stay; SUM(ChargedAmount) covered.
DROP INDEX IF EXISTS IX_TreatmentAdministration_AdmissionID ON dbo.TreatmentAdministration;
CREATE INDEX IX_TreatmentAdministration_AdmissionID
    ON dbo.TreatmentAdministration (AdmissionID) INCLUDE (ChargedAmount);

-- W09 (nursing chart): all care events of one stay in time order, covered.
DROP INDEX IF EXISTS IX_NurseCareEvent_AdmissionID ON dbo.NurseCareEvent;
CREATE INDEX IX_NurseCareEvent_AdmissionID
    ON dbo.NurseCareEvent (AdmissionID, EventAt) INCLUDE (NurseID, EventTypeCode);

/* -----------------------------------------------------------------------------
   Bed history. The "latest bed for a stay" (OUTER APPLY TOP 1 ... ORDER BY
   StartDate DESC) and "who was in this bed on date X" probes ran a full scan of
   BedAssignment once per outer row (W03, W05, W06, W13).
   ----------------------------------------------------------------------------- */

-- W03 (R2), W06 (R8), W13 (census): seek by stay, newest first, covered.
DROP INDEX IF EXISTS IX_BedAssignment_AdmissionID ON dbo.BedAssignment;
CREATE INDEX IX_BedAssignment_AdmissionID
    ON dbo.BedAssignment (AdmissionID, StartDate DESC) INCLUDE (BedID, EndDate);

-- W05 (R1 on a past date): seek by bed and start date, EndDate checked from the leaf.
DROP INDEX IF EXISTS IX_BedAssignment_BedID ON dbo.BedAssignment;
CREATE INDEX IX_BedAssignment_BedID
    ON dbo.BedAssignment (BedID, StartDate) INCLUDE (EndDate);

-- W06 (R8): a patient's stays. The existing UX_Admission_OpenStayPerPatient is
-- filtered to open stays only, so it can't serve history.
DROP INDEX IF EXISTS IX_Admission_PatientID ON dbo.Admission;
CREATE INDEX IX_Admission_PatientID
    ON dbo.Admission (PatientID) INCLUDE (AdmitDate, DischargeDate);

/* -----------------------------------------------------------------------------
   Staffing. R5 joins each shift of the day to that nurse's care events that day.
   It was the worst query: 30 shifts x a 467k-row scan (W04).
   ----------------------------------------------------------------------------- */

-- W04 (R5), W12 (R7): the day's shifts, covered.
DROP INDEX IF EXISTS IX_NurseAssignment_ShiftDate ON dbo.NurseAssignment;
CREATE INDEX IX_NurseAssignment_ShiftDate
    ON dbo.NurseAssignment (ShiftDate) INCLUDE (NurseID, WardID, HoursWorked);

-- W04 (R5): one nurse's events in a datetime range: equality on NurseID, range on EventAt.
DROP INDEX IF EXISTS IX_NurseCareEvent_NurseID_EventAt ON dbo.NurseCareEvent;
CREATE INDEX IX_NurseCareEvent_NurseID_EventAt
    ON dbo.NurseCareEvent (NurseID, EventAt) INCLUDE (AdmissionID, EventTypeCode);

/* -----------------------------------------------------------------------------
   Targeted lookups
   ----------------------------------------------------------------------------- */

-- W08 (front-desk search): last name equality + first-name prefix, covered.
DROP INDEX IF EXISTS IX_Patient_LastName_FirstName ON dbo.Patient;
CREATE INDEX IX_Patient_LastName_FirstName
    ON dbo.Patient (LastName, FirstName) INCLUDE (DOB, Phone);

-- W07 (R9 "without physician"): a FILTERED index holding only the ~5% of
-- treatments with no physician. It's about 20x smaller than a full index, and
-- the query's PhysicianID IS NULL predicate matches the filter exactly.
-- Gotcha (measured): without PhysicianID in INCLUDE, the optimizer ignored this
-- index and kept scanning the table. With an IS NULL filter, the filter column
-- must be in the index for the optimizer to treat it as covering.
DROP INDEX IF EXISTS IX_TreatmentAdministration_NoPhysician ON dbo.TreatmentAdministration;
CREATE INDEX IX_TreatmentAdministration_NoPhysician
    ON dbo.TreatmentAdministration (AdministeredAt)
    INCLUDE (PhysicianID, AdmissionID, TreatmentID, Results, ChargedAmount)
    WHERE PhysicianID IS NULL;
GO

/* -----------------------------------------------------------------------------
   Deliberately NOT indexed
   - W03 weekly admissions/discharges: after IX_BedAssignment_AdmissionID it
     takes ~30 ms. The rest is a scan of the small Admission table (~400 pages)
     because the filter is "admitted OR discharged in the week". Serving that
     with seeks would need two more date indexes, for a weekly report.
   - W10 monthly revenue: reads ~20% of ItemCharge and TreatmentAdministration.
     A range scan would save little over the current parallel scan (~40 ms), and
     two more indexes on the two busiest insert tables would slow every charge.
     If analytics grows, a nonclustered columnstore index is the better tool.
   - W11 physician admits over all history: aggregates the whole Admission table;
     a scan is already the optimal plan.
   - Catalog FKs (ItemCharge.ItemID, TreatmentAdministration.TreatmentID,
     NurseCareEvent.EventTypeCode): only used when deleting a catalog entry,
     which is rare and administrative.
   ----------------------------------------------------------------------------- */

PRINT N'09_performance_indexes.sql completed.';
GO
