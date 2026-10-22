# 6. Reports, Procedures and Queries

| Layer | Script | Contents |
|---|---|---|
| Reporting (`rpt`) | [`sql/07_reporting_views.sql`](../sql/07_reporting_views.sql) | One view or inline function per required report R1–R12 |
| Workflow (`dbo`) | [`sql/08_stored_procedures.sql`](../sql/08_stored_procedures.sql) | Admit, transfer, charge, treat, discharge, bill |
| Analytics | [`queries/business_queries.sql`](../queries/business_queries.sql) | 12 ad-hoc business questions |
| Tests | [`tests/test_procedures_and_reports.sql`](../tests/test_procedures_and_reports.sql) | 25 workflow tests + 16 report reconciliations |

---

## 6.1 Report catalog (R1–R12)

Reports with no parameters are **views**. Reports that take a date are **inline table-valued functions**. Unlike multi-statement functions, those are expanded into the calling query, so filters and indexes still apply. Views don't guarantee row order, so each report lists the `ORDER BY` to use.

| # | Report | Object | Usage |
|---|---|---|---|
| R1 | Beds occupied / available (today) | `rpt.vw_BedOccupancyByWard` | `ORDER BY WardNumber` |
| R1 | Beds occupied / available (any past date) | `rpt.fn_BedOccupancyOn(@AsOf)` | rebuilt from bed assignment history |
| R2 | Weekly admitted and discharged | `rpt.fn_AdmissionsDischarges(@From, @To)` | `ORDER BY AdmitDate, AdmittingPhysician, DischargingPhysician` |
| R3 | Discharge report: treatments, treating physician, date of service | `rpt.vw_DischargeTreatments` | filter on `AdmissionID` |
| R4 | Monthly physician admits (ranked, change vs prior month) | `rpt.vw_PhysicianMonthlyAdmits` | `ORDER BY MonthStart DESC, RankInMonth` |
| R5 | Shift rotation of nurse–patient care | `rpt.fn_ShiftRotation(@ShiftDate)` | one row per shift, events pivoted by type |
| R6 | Charges for a stay | `rpt.vw_StayCharges` / `dbo.usp_GetPatientBill` | summary / itemized bill |
| R7 | Ward schedule with charge nurse | `rpt.vw_WardSchedule` | `ORDER BY ShiftDate DESC, WardNumber` |
| R8 | Patient ward assignment | `rpt.vw_PatientWardAssignment` | full bed history, `IsCurrent` flag |
| R9 | Treatments with and without a treating physician | `rpt.vw_PatientTreatments` | `WHERE HasTreatingPhysician = 'N'` for the "without" list |
| R10 | Physician treatments: dates and types | `rpt.vw_PhysicianTreatments` | count, first/last date, revenue |
| R11 | Physicians and specialties | `rpt.vw_PhysicianSpecialties` | `STRING_AGG` list |
| R12 | Nurses: certifications, wards, supervisors | `rpt.vw_NurseRoster` + `rpt.vw_NurseHierarchy` | self-join; recursive CTE tree |

Shared base view: `rpt.vw_AdmissionDetail` gives one row per stay with patient and physician names, status, length of stay and the current or last bed.

### How the reports are tested
Each report's totals are reconciled against an independent count from the base tables. Examples:

| Check | Why it matters |
|---|---|
| R1 occupied beds = open bed assignments | The availability flag and the history agree |
| R3/R9 row counts include treatments with no physician | Catches an `INNER JOIN` that would silently drop them (BR-29) |
| R6 sum of all stay totals = all treatments + all items | No double counting from joining two child tables |
| R12 every nurse reachable in the hierarchy | No orphaned supervisor links |

### Sample: R1 `SELECT * FROM rpt.vw_BedOccupancyByWard ORDER BY WardNumber`

| WardNumber | WardName | TotalBeds | Occupied | Available | OccupancyPct |
|---|---|---:|---:|---:|---:|
| W-101 | Cardiology | 30 | 20 | 10 | 66.7 |
| W-102 | Intensive Care Unit | 30 | 18 | 12 | 60.0 |
| W-201 | Pediatrics | 30 | 22 | 8 | 73.3 |
| W-304 | Emergency Observation | 30 | 23 | 7 | 76.7 |
| … | | | | | |

### Sample: R7 ward schedule (one day)

| WardNumber | ChargeNurse | NursesOnShift | TotalHours | Nurses |
|---|---|---:|---:|---|
| W-101 | Johnson, Lucia | 3 | 36 | Allen (12h), Green (12h), Wilson (12h) |
| W-102 | Baker, Lucas | 3 | 32 | Anderson (12h), Mitchell (12h), Robinson (8h) |

### Sample: R12 supervision tree (`rpt.vw_NurseHierarchy`)
```
Baker, Lucas                 level 1  (charge nurse, ICU)
    Kim, Arjun               level 2
        Allen, James         level 3
        Garcia, Daniel       level 3
```

---

## 6.2 Workflow procedures

| Procedure | Does | Key rules |
|---|---|---|
| `dbo.usp_AdmitPatient @PatientID, @AdmitPhysicianID, [@BedID], [@WardID], [@AdmitDate], @AdmissionID OUT, @AssignedBedID OUT` | Opens the stay, assigns a specific bed or the first free one (optionally within a ward), marks it occupied | BR-19, BR-22, BR-23, BR-26 |
| `dbo.usp_TransferPatient @AdmissionID, @NewBedID, [@TransferDate]` | Closes the current bed assignment, frees that bed, opens the new one | BR-23, BR-25, BR-26 |
| `dbo.usp_RecordItemCharge @AdmissionID, @ItemID, [@Quantity], [@ChargeDate], @ItemChargeID OUT` | Charges an item at **today's** list price (snapshot) | BR-32, BR-33 |
| `dbo.usp_RecordTreatment @AdmissionID, @TreatmentID, [@PhysicianID], [@AdministeredAt], [@Results], @TreatmentAdminID OUT` | Records a treatment, physician optional, price snapshot | BR-28 – BR-30, BR-33 |
| `dbo.usp_DischargePatient @AdmissionID, @DischargePhysicianID, [@DischargeDate]` | Closes the stay and bed assignment, releases the bed; refuses if there are no item charges | BR-20, BR-21, BR-26, BR-34 |
| `dbo.usp_GetPatientBill @AdmissionID` | Itemized bill: header, lines by date, totals (from the same view as R6) | R6 |

### Example: a full stay
```sql
DECLARE @stay INT, @bed INT;
EXEC dbo.usp_AdmitPatient     @PatientID = 42, @AdmitPhysicianID = 7, @WardID = 1,
                              @AdmissionID = @stay OUTPUT, @AssignedBedID = @bed OUTPUT;
EXEC dbo.usp_RecordItemCharge @AdmissionID = @stay, @ItemID = 3, @Quantity = 2;
EXEC dbo.usp_RecordTreatment  @AdmissionID = @stay, @TreatmentID = 19, @PhysicianID = 7, @Results = N'Normal';
EXEC dbo.usp_TransferPatient  @AdmissionID = @stay, @NewBedID = 45;
EXEC dbo.usp_DischargePatient @AdmissionID = @stay, @DischargePhysicianID = 7;
EXEC dbo.usp_GetPatientBill   @AdmissionID = @stay;
```

### Sample: `EXEC dbo.usp_GetPatientBill 83036`

| LineType | ServiceDate | Description | Qty | UnitPrice | Amount |
|---|---|---|---:|---:|---:|
| Treatment | 2026-08-22 | Basic Metabolic Panel | 1 | 59.61 | 59.61 |
| Item | 2026-08-23 | Hot Pack - Pack of 25 | 5 | 54.25 | 271.25 |
| Item | 2026-08-24 | Saline Flush 10 mL - Pack of 25 | 5 | 29.21 | 146.05 |
| Item | 2026-08-24 | Splint - Pack of 5 | 9 | 82.27 | 740.43 |
| Treatment | 2026-08-25 | Cardiac Stress Test | 1 | 1,093.13 | 1,093.13 |
| | | **Total** (2 treatments + 3 item lines) | | | **2,310.47** |

The unit prices are slightly below today's list prices (for example, the panel's list price is $60.00). That is the price snapshot (BR-33) at work: the bill shows what was charged at the time.

### Transaction design

**Savepoint pattern.** If the caller has no open transaction, a procedure begins and commits its own. If the caller already has one, the procedure sets a savepoint. On error it rolls back only to its savepoint and re-throws, so the caller's earlier work survives and procedures compose inside larger transactions. `XACT_ABORT` stays off on purpose: with it on, any error dooms the caller's whole transaction. The test suite verifies this: after 7 failed calls inside one transaction, `@@TRANCOUNT` is still 1 and no partial rows remain.

**Check-then-act races.** "Is the bed free? Then take it" is unsafe if two sessions run it together. Under read committed snapshot (enabled on this database), a plain `SELECT` reads a row version and doesn't block, so both sessions could see the bed as free. The procedures read it with `UPDLOCK, HOLDLOCK`. The second session waits, then sees the bed as occupied.

**Automatic bed choice** uses `UPDLOCK, READPAST`, so concurrent admissions skip a bed another session is in the middle of taking instead of queueing behind it.

**Safety net.** If application code bypasses the procedures, the filtered unique indexes (`UX_BedAssignment_CurrentBed`, `UX_Admission_OpenStayPerPatient`) still make double-booking impossible.

Single-statement procedures (`usp_RecordItemCharge`, `usp_RecordTreatment`) need no explicit transaction, because one `INSERT` is atomic.

### Error catalog

| Number | Meaning | Raised by |
|---|---|---|
| 50001 | Patient not found | Admit |
| 50002 | Physician not found | Admit, Treatment, Discharge |
| 50003 | Patient already has an open stay | Admit |
| 50004 | Bed is not available | Admit, Transfer |
| 50005 | No available bed (in the requested ward) | Admit |
| 50006 | Bed not found | Admit, Transfer |
| 50007 | Date in the future | Admit, Transfer, Discharge |
| 50010 | Stay not found | Transfer, Charge, Treatment, Discharge, Bill |
| 50011 | Stay already discharged | Transfer, Discharge |
| 50012 | Date before the admission or current bed assignment | Transfer, Discharge |
| 50013 | Stay has no item charges (BR-34) | Discharge |
| 50014 | Patient already in that bed | Transfer |
| 50015 | Item or treatment not found | Charge, Treatment |
| 50016 | Quantity must be > 0 | Charge |
| 50017 | Date/time outside the stay | Charge, Treatment |

---

## 6.3 Analytical queries

[`queries/business_queries.sql`](../queries/business_queries.sql) answers 12 questions. Each one is tagged with the technique it demonstrates. Run it after the build with `.\run_sql.ps1 -Files queries\business_queries.sql`; it takes about 8 s on 1.4M rows, before any tuning indexes.

| # | Question | Technique |
|---|---|---|
| Q1 | Monthly revenue, running total, month-over-month change | `SUM() OVER`, `LAG` |
| Q2 | Top 3 treatments by revenue each year | CTE + `DENSE_RANK` |
| Q3 | Length of stay by ward and age band (age **at admission**) | conditional aggregation |
| Q4 | Ward bed utilization, last 90 days | interval-overlap arithmetic |
| Q5 | Nurse care load per hour worked | `NTILE` quartiles |
| Q6 | Care event mix per ward | `PIVOT` |
| Q7 | Busiest hours for nursing care | share of total via `SUM(COUNT(*)) OVER ()` |
| Q8 | Physicians who admit but never treat (and vice versa) | `EXCEPT` |
| Q9 | Stays with both a chest X-ray and a chest CT | `INTERSECT` |
| Q10 | Catalog entries never used | `NOT EXISTS` |
| Q11 | Old bills re-priced at today's prices (why snapshots matter) | snapshot vs catalog |
| Q12 | Longest continuous occupancy streak per ward | gaps and islands |

Sample, Q11: re-pricing history from the current catalog would overstate older revenue by up to 24%.

| Year | Billed at time of service | If re-priced at today's list | Overstatement |
|---|---:|---:|---:|
| 2022 | $15,681,344 | $18,944,620 | 20.8% |
| 2024 | $17,373,860 | $19,136,355 | 10.1% |
| 2026 | $15,262,776 | $15,511,176 | 1.6% |

> **Known limitation of the synthetic data.** The generator draws most attributes uniformly, so some answers come out flat: Q3 shows a similar length of stay in every ward, Q7 spreads care events evenly across all 24 hours, and Q8 finds every physician both admits and treats. The queries are correct (the reconciliation tests prove it), but the data has no real-world skew yet. Adding ward-specific length of stay, daytime peaks and specialty-matched physicians is a planned improvement before the dashboard phase.
