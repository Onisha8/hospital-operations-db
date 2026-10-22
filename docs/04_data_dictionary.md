# 4. Data Dictionary (v2)

Target platform: **SQL Server 2022**. Schemas: `dbo` (operational tables), `stg` (ETL staging), `rpt` (reporting views).

Conventions:
- Surrogate keys are `INT IDENTITY(1,1)` named `<Table>ID`. Lookup tables use short natural codes.
- Text is `NVARCHAR`. Money is `DECIMAL(10,2)` (not `MONEY`, which loses precision in division).
- Constraint names follow `PK_`, `FK_<Child>_<Parent>[_role]`, `UQ_`, `CK_`, `DF_`, `UX_` (filtered unique index).
- BR-xx references point to [02_business_rules.md](02_business_rules.md).

---

## Reference / lookup tables

### `Certification`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| CertCode | NVARCHAR(20) | N | PK | Certification abbreviation, e.g. `CCRN`, `ACLS` |
| CertName | NVARCHAR(100) | Y | | Full name of the certification |

### `Specialty`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| SpecialtyID | INT IDENTITY | N | PK | |
| SpecialtyName | NVARCHAR(50) | N | UQ | e.g. Cardiology, Oncology |

### `CareEventType`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| EventTypeCode | CHAR(3) | N | PK | `WC`, `MED`, `FS`, `AS`, `TA`, `O` |
| EventTypeName | NVARCHAR(30) | N | UQ | Wellness Check, Medication, Food Service, Assistance, Treatment Admin, Other |

---

## People

### `Nurse`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| NurseID | INT IDENTITY | N | PK | |
| FirstName | NVARCHAR(30) | N | | |
| LastName | NVARCHAR(40) | N | | |
| Street | NVARCHAR(100) | N | | |
| City | NVARCHAR(30) | N | | |
| State | CHAR(2) | N | CK `[A-Z][A-Z]`, DF `'FL'` | |
| Zip | CHAR(5) | N | CK 5 digits | |
| Phone | NVARCHAR(20) | N | | Primary phone |
| AltPhone | NVARCHAR(20) | Y | | Alternate phone |
| Email | NVARCHAR(100) | N | UQ | |
| SupervisorID | INT | Y | FK → Nurse.NurseID; CK ≠ NurseID | Supervising nurse (BR-03, BR-04) |

### `NurseCertification`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| NurseID | INT | N | PK, FK → Nurse | |
| CertCode | NVARCHAR(20) | N | PK, FK → Certification | |

### `Physician`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| PhysicianID | INT IDENTITY | N | PK | |
| FirstName | NVARCHAR(30) | N | | |
| LastName | NVARCHAR(40) | N | | |
| Street, City, State, Zip | as Nurse | N | same CKs as Nurse; DF State `'FL'` | |
| Phone | NVARCHAR(20) | N | | |
| AltPhone | NVARCHAR(20) | Y | | |
| Email | NVARCHAR(100) | N | UQ | |

### `PhysicianSpecialty`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| PhysicianID | INT | N | PK, FK → Physician | |
| SpecialtyID | INT | N | PK, FK → Specialty | |

### `Patient`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| PatientID | INT IDENTITY | N | PK | |
| FirstName | NVARCHAR(30) | N | | |
| LastName | NVARCHAR(40) | N | | |
| Gender | CHAR(1) | N | CK IN (`F`,`M`,`X`) | |
| DOB | DATE | N | CK `<= GETDATE()` | Date of birth (BR-16) |
| Age | *computed* | — | CC | `DATEDIFF(YEAR, DOB, GETDATE())` minus 1 if the birthday hasn't happened yet this year (BR-17). Not persisted because it depends on `GETDATE()`. |
| Street | NVARCHAR(100) | N | | |
| City | NVARCHAR(30) | N | DF `'Tampa'` | |
| State | CHAR(2) | N | CK `[A-Z][A-Z]`, DF `'FL'` | |
| Zip | CHAR(5) | N | CK 5 digits | |
| Phone | NVARCHAR(20) | N | | |
| AltPhone | NVARCHAR(20) | Y | | |
| Email | NVARCHAR(100) | Y | | |

---

## Facilities

### `Ward`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| WardID | INT IDENTITY | N | PK | |
| WardNumber | NVARCHAR(10) | N | UQ | Designated ward number (BR-08) |
| WardName | NVARCHAR(50) | N | | e.g. Cardiology, ICU |
| Location | NVARCHAR(50) | N | | Building / floor |
| Phone | NVARCHAR(20) | N | | |
| ChargeNurseID | INT | N | FK → Nurse; **UQ** | Exactly one per ward; a nurse is in charge of at most one ward (BR-09, BR-10) |

### `Bed`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| BedID | INT IDENTITY | N | PK | |
| WardID | INT | N | FK → Ward | BR-11 |
| BedNumber | NVARCHAR(10) | N | UQ (WardID, BedNumber) | Label on the bed within the ward |
| Size | CHAR(2) | N | CK IN (`S`,`L`,`XL`), DF `'L'` | BR-12 |
| Type | CHAR(1) | N | CK IN (`E`,`M`), DF `'M'` | BR-13 |
| Availability | CHAR(1) | N | CK IN (`O`,`A`), DF `'O'` | BR-14 |

### `NurseAssignment`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| NurseAssignmentID | INT IDENTITY | N | PK | |
| NurseID | INT | N | FK → Nurse | |
| WardID | INT | N | FK → Ward | |
| ShiftDate | DATE | N | UQ (NurseID, WardID, ShiftDate) | BR-05 |
| HoursWorked | DECIMAL(4,2) | N | CK `> 0 AND <= 24` | BR-06 |

---

## Patient stay (events)

### `Admission`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| AdmissionID | INT IDENTITY | N | PK | One hospital stay |
| PatientID | INT | N | FK → Patient | BR-18 |
| AdmitDate | DATE | N | | |
| AdmitPhysicianID | INT | N | FK → Physician (`_Admit`) | BR-19 |
| DischargeDate | DATE | Y | CK `>= AdmitDate` | BR-21 |
| DischargePhysicianID | INT | Y | FK → Physician (`_Discharge`) | |
| — | | | CK both discharge columns NULL or both NOT NULL | BR-20 |
| — | | | UX `PatientID WHERE DischargeDate IS NULL` | One open stay per patient (BR-22) |

### `BedAssignment`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| BedAssignmentID | INT IDENTITY | N | PK | |
| AdmissionID | INT | N | FK → Admission | |
| BedID | INT | N | FK → Bed | |
| StartDate | DATE | N | | |
| EndDate | DATE | Y | CK `>= StartDate` | NULL = current assignment |
| — | | | UX `BedID WHERE EndDate IS NULL` | No double booking (BR-24) |
| — | | | UX `AdmissionID WHERE EndDate IS NULL` | One current bed per stay (BR-25) |

### `Treatment`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| TreatmentID | INT IDENTITY | N | PK | Treatment catalog |
| TreatmentName | NVARCHAR(60) | N | UQ | |
| Description | NVARCHAR(255) | Y | | |
| StandardCharge | DECIMAL(10,2) | N | CK `>= 0` | Current list price |

### `TreatmentAdministration`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| TreatmentAdminID | INT IDENTITY | N | PK | |
| AdmissionID | INT | N | FK → Admission | |
| TreatmentID | INT | N | FK → Treatment | |
| PhysicianID | INT | **Y** | FK → Physician | NULL = no treating physician recorded (BR-29) |
| AdministeredAt | DATETIME2(0) | N | | BR-30 |
| Results | NVARCHAR(255) | Y | | |
| ChargedAmount | DECIMAL(10,2) | N | CK `>= 0` | Price frozen at time of service (BR-33) |

### `Item`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| ItemID | INT IDENTITY | N | PK | Consumable item catalog |
| ItemName | NVARCHAR(100) | N | UQ | |
| UnitCharge | DECIMAL(10,2) | N | CK `>= 0` | Current list price |

### `ItemCharge`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| ItemChargeID | INT IDENTITY | N | PK | |
| AdmissionID | INT | N | FK → Admission | |
| ItemID | INT | N | FK → Item | |
| ChargeDate | DATE | N | | |
| Quantity | INT | N | CK `> 0` | BR-32 |
| UnitCharge | DECIMAL(10,2) | N | CK `>= 0` | Snapshot of `Item.UnitCharge` (BR-33) |
| LineTotal | *computed, persisted* | — | CC `Quantity * UnitCharge` | Deterministic, so it can be persisted and indexed |

### `NurseCareEvent`
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| CareEventID | INT IDENTITY | N | PK | |
| AdmissionID | INT | N | FK → Admission | |
| NurseID | INT | N | FK → Nurse | |
| EventTypeCode | CHAR(3) | N | FK → CareEventType | BR-36 |
| EventAt | DATETIME2(0) | N | | Date + time of the event |
| Notes | NVARCHAR(255) | Y | | |

---

## Staging (`stg` schema)

Built by `sql/05_etl_patient_import.sql`. The ETL flow is **file → `stg.PatientImport` → validate → `dbo.Patient`**, with every load audited.

### `stg.LoadBatch` (audit log, one row per file load)
| Column | Type | Null | Key / Constraint | Description |
|---|---|---|---|---|
| LoadBatchID | INT IDENTITY | N | PK | |
| SourceFile | NVARCHAR(400) | N | | Full path of the loaded file |
| StartedAt / FinishedAt | DATETIME2(0) | N / Y | DF `SYSDATETIME()` | |
| Status | VARCHAR(10) | N | CK IN (`RUNNING`,`SUCCEEDED`,`FAILED`) | |
| RowsRead / RowsLoaded / RowsRejected / RowsSkipped | INT | Y | | Counts for the batch |
| ErrorMessage | NVARCHAR(2000) | Y | | Set when the load fails |

### `stg.PatientImport` (raw landing table)
Same columns as the CSV (`FirstName … BedNo`), all `NVARCHAR(400)`, so a malformed value never aborts the load. It also has `StagingRowID` (PK, IDENTITY, which preserves file order), `LoadBatchID` (FK) and `SourceLine` (line number in the file). `BedNo` is a v1 legacy column: in v2 a bed belongs to an admission, so it is not loaded. `BULK INSERT` targets the view `stg.vw_PatientImportLoad`, which exposes only the file's columns.

### `stg.vw_PatientImportClean` (transform)
The single place where fields are parsed and normalized. Validation and publishing both read it, so the two can't drift apart:

| Field | Rule |
|---|---|
| Names, street, city | Trimmed; empty → NULL |
| Gender | `F`/`M`/`X` in any case, or `Male`/`Female` |
| DOB | `Oct 15, 1961` (style 107), `1985-03-22` (ISO) or `03/22/1985` (US) |
| State | Upper-cased |
| Zip | 5 digits, or ZIP+4 truncated to 5 |
| Phone | Digits only, 10 digits (or 11 with leading 1), stored as `(813) 555-0142` |

### `stg.PatientImportError` (one row per broken rule per source row)
| Column | Type | Description |
|---|---|---|
| ErrorID | INT IDENTITY, PK | |
| LoadBatchID, StagingRowID | INT, FK | Which batch and staging row |
| SourceLine | INT | Line number in the file, so a data steward can fix the source |
| Severity | VARCHAR(6) | `REJECT` (not loaded) or `SKIP` (already exists, not an error) |
| ErrorCode | CHAR(3) | See below |
| ErrorMessage, RawValue | NVARCHAR | Human-readable reason and the offending raw value |

| Code | Rule |
|---|---|
| E01 | Required field missing (first/last name, street, city) |
| E02 | DOB missing or not a valid date |
| E03 | DOB in the future |
| E04 | DOB more than 120 years ago |
| E05 | Gender not F/M/X |
| E06 | State not a valid US code (`stg.UsState`) |
| E07 | Zip not 5 digits or ZIP+4 |
| E08 | Value longer than the target column (would be truncated) |
| E09 | Phone doesn't have 10 digits |
| E10 | Duplicate of an earlier line in the same file (same name + DOB) |
| S01 | Patient already in `dbo.Patient`: skipped, which makes reloads idempotent |

### `stg.UsState`
50 states + DC + PR, used by rule E06.

### `stg.fn_Rand(@n, @salt)`
A deterministic pseudo-random number in [0, 1) from an MD5 hash of the inputs, used by `sql/06_generate_bulk_data.sql` so the synthetic data is reproducible.

---

## Table summary

Row counts after a full build (`sql/06_generate_bulk_data.sql`, 5 years of history ending on the build date):

| Table | Type | Rows |
|---|---|---|
| Certification, Specialty, CareEventType | Lookup | 24 / 12 / 6 |
| Nurse, NurseCertification | Master | 200 / 611 |
| Physician, PhysicianSpecialty | Master | 100 / 130 |
| Ward, Bed | Master | 10 / 300 |
| Patient | Master | 50,000 (103 via ETL + 49,897 synthetic) |
| Treatment, Item | Catalog | 100 / 200 |
| Admission | Event | ~86,000 |
| BedAssignment | Event | ~86,000 (one per stay) |
| NurseAssignment | Event | ~55,000 (3 nurses × 10 wards × every day) |
| TreatmentAdministration | Event | ~216,000 |
| ItemCharge | Event | ~430,000 |
| NurseCareEvent | Event | ~467,000 |
| **Total** | | **~1.39 million** |

Counts vary slightly with the build date because the history window ends "today".
