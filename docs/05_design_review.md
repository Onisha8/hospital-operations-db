# 5. Design Review: v1 (course build) → v2 (this project)

v1 is the database our team (Database Team 5) built during ISM 6218 *Advanced Database Management*, University of South Florida, Fall 2024. For v2 I audited that build directly from the SQL Server system catalog (`sys.tables`, `sys.foreign_keys`, `sys.check_constraints`, `sys.indexes`) and compared it against the original requirements.

The goal of v2 is not to throw v1 away. It keeps everything v1 got right and fixes the defects a production reviewer would flag.

## 5.1 What v1 got right (kept)

- Multi-valued attributes were already normalized: `NurseCert` and `PhysicianSpecialty` are separate tables, not comma lists.
- Catalog vs. event split for charges: `Item` / `ItemCharge` and `Treatment` / `TreatmentAdministration`.
- The bed rules are declarative: `CK` on Size / Type / Availability with defaults `L`, `M`, `O`.
- Address and zip format checks (`[A-Z][A-Z]`, five digits) and the nurse self-referencing supervisor FK.
- A computed `Age` column instead of a stored age.
- A staging table and trigger for the CSV patient import (ETL).

## 5.2 Defects found and how v2 fixes them

| # | Severity | v1 finding (from the catalog) | Impact | v2 fix |
|---|---|---|---|---|
| D1 | 🔴 High | `AdmitDischarge.AdmitDoc` has **no foreign key**. The constraint `FK_AdmitDischarge_AdmitDischarge` points `AdmitID → AdmitID` (the table to itself), so it enforces nothing. | Admissions can reference physicians that don't exist. | `FK_Admission_Physician_Admit` on `AdmitPhysicianID` |
| D2 | 🔴 High | `NurseAssignment` PK is `(NurseID, WardID)`. | A nurse can be assigned to a ward only **once, ever**, which breaks the rotation requirement. | Surrogate PK + `UQ (NurseID, WardID, ShiftDate)` |
| D3 | 🔴 High | The bed is stored on the patient (`Patient.BedNo NOT NULL`). | No bed history; every patient needs a bed forever, even after discharge; nothing prevents two patients sharing a bed. | `BedAssignment` table with start/end dates + **filtered unique index** `BedID WHERE EndDate IS NULL` |
| D4 | 🟠 Medium | Treatments, item charges and nurse events reference `PatientNo`, not the admission. | A returning patient's charges mix across stays, so "charges for a patient **stay**" (R6) can't be answered. | All event tables reference `AdmissionID` |
| D5 | 🟠 Medium | `Ward.ChargeNurse` has no unique constraint. | One nurse could be charge nurse of several wards (narrative says at most one). | `UQ_Ward_ChargeNurseID` |
| D6 | 🟠 Medium | `TreatmentAdministration.DoctorID` is `NOT NULL` and part of the PK. | Report R9 ("treatments *without* a treating physician") is impossible. | Surrogate PK, nullable `PhysicianID` |
| D7 | 🟠 Medium | `ItemCharge` and `TreatmentAdministration` store no price; bills join to the current catalog price. | Changing a price silently rewrites historical bills. | `UnitCharge` / `ChargedAmount` snapshot + persisted `LineTotal` |
| D8 | 🟡 Low | `Age = DATEDIFF(year, DOB, GETDATE())` | Off by one for everyone whose birthday hasn't happened yet this year (`DATEDIFF` counts year *boundaries*). | Birthday-aware formula |
| D9 | 🟡 Low | No check that discharge ≥ admit, or that discharge date and discharging doctor come together. | Impossible stays can be saved. | `CK_Admission_DischargeAfterAdmit`, `CK_Admission_DischargePair` |
| D10 | 🟡 Low | Nothing stops a patient having two open admissions. | Double-counted census. | Filtered unique index `PatientID WHERE DischargeDate IS NULL` |
| D11 | 🟡 Low | `IX_AdmitDischarge` duplicates the clustered PK on `AdmitID`. | Wasted writes and storage with no read benefit. | Removed; indexes are chosen from measured queries in [`sql/09_performance_indexes.sql`](../sql/09_performance_indexes.sql) |
| D12 | 🟡 Low | Event types are a hard-coded `CK` (`'O','TA','AS','FS','MED','WC'`) with no descriptions. | Adding a type requires DDL; reports show cryptic codes. | `CareEventType` lookup table + FK |
| D13 | 🟡 Low | `Ward` has no ward number or name (`Location` stores "ICU"); `Nurse`, `Physician` and `Patient` lack alternate phone and email that the narrative asks for. | Requirements gap. | Columns added |
| D14 | 🟡 Low | `MONEY` data type; `Treatment.Descrip NVARCHAR(40)`. | `MONEY` rounds intermediate results in division; 40 characters is too short. | `DECIMAL(10,2)`, `NVARCHAR(255)` |
| D15 | 🟡 Low | Staging tables (`patient_staging`, `patient_data`, `AdmissionsForView`) live in `dbo` next to production tables. | Clutter; risk of reports reading raw data. | Separate `stg` schema; reporting views in `rpt` schema |
| D16 | ⚪ Info | Inconsistent names: `PatientNo` / `NurseID` / `DoctorID`, `CK_Bed_Availibility` (typo), FK on patient named `FK_AdmitDischarge_Physician`. | Harder to read and maintain. | One naming convention (see data dictionary) |

## 5.3 Design-doc vs. build gaps (v1 document)

The v1 design document and the v1 database didn't fully agree. Examples: the document lists a `ChargeItem` table that mixes catalog and charge columns, stores admission columns on `Patient`, and uses the deprecated `TEXT` type. v2 has a single source of truth. The [data dictionary](04_data_dictionary.md) drives the DDL in `sql/`, and every rule traces to an ID in [02_business_rules.md](02_business_rules.md).

## 5.4 Rules that can't be declared and how they're handled

| Rule | Why not declarative | How v2 handles it |
|---|---|---|
| Every ward has ≥ 1 nurse; every nurse ≥ 1 ward (BR-07) | Minimum cardinality across tables needs deferred constraints, which SQL Server doesn't have | Checks DQ01–DQ02 in [`tests/test_data_quality.sql`](../tests/test_data_quality.sql) |
| Every stay has ≥ 1 item charge (BR-34) | Same | Checked inside `usp_DischargePatient`; check DQ03 |
| Only available beds can be assigned; bed flag stays in sync (BR-26) | Cross-table state change | `usp_AdmitPatient` / `usp_DischargePatient` in a single transaction; filtered unique index as the safety net; check DQ06 |

## 5.5 Trade-offs I considered

- **Keeping `Bed.Availability` even though occupancy can be derived from `BedAssignment`.** The narrative requires the flag and the admitting workflow reads it. A beds-in-maintenance status also can't be derived. The procedures keep it in sync, and data-quality check DQ06 detects drift.
- **Surrogate vs. natural keys.** I used surrogates for entities and event tables (stable, narrow clustered keys) and natural codes for small lookups (`CertCode`, `EventTypeCode`) so queries stay readable.
- **Non-persisted `Age`.** It depends on `GETDATE()`, so SQL Server won't allow it to be persisted or indexed. Queries that filter by age should filter on `DOB` ranges instead, which stays sargable (an index on `DOB` can be used).
