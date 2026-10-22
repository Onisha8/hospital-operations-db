# 2. Business Rules

Every rule has an ID and the mechanism that enforces it. The preferred order is **declarative constraint → unique/filtered index → stored procedure / trigger → data-quality check**. Rules that SQL Server cannot express declaratively (for example "at least one") are enforced in procedures and verified by a data-quality query.

Enforcement legend: **PK** primary key · **FK** foreign key · **UQ** unique constraint · **FUI** filtered unique index · **CK** check constraint · **DF** default · **CC** computed column · **SP** stored procedure · **DQ** data-quality query

## Nurses

| ID | Rule | Enforcement |
|---|---|---|
| BR-01 | A nurse has a name, address, phone, optional alternate phone and email. | NOT NULL, `CK` on State/Zip format |
| BR-02 | A nurse may hold zero or many certifications; a certification may be held by many nurses. | `NurseCertification` (PK `NurseID, CertCode`) |
| BR-03 | A nurse is supervised by **at most one** nurse; some nurses are unsupervised. | Nullable self-`FK` `Nurse.SupervisorID` |
| BR-04 | A nurse cannot supervise themself. | `CK SupervisorID <> NurseID` |
| BR-05 | A nurse is assigned to one or more wards and rotates; each assignment records date and hours worked. | `NurseAssignment` + `UQ (NurseID, WardID, ShiftDate)` |
| BR-06 | Hours worked on an assignment are greater than 0 and at most 24. | `CK` |
| BR-07 | Every nurse has at least one ward assignment; every ward has at least one assigned nurse. | `DQ` (min-cardinality cannot be declared) |

## Wards and beds

| ID | Rule | Enforcement |
|---|---|---|
| BR-08 | A ward has a unique designated number, a name, a location and a phone. | `UQ WardNumber` |
| BR-09 | Each ward has exactly one charge nurse (custodian of the ward's medical records). | `Ward.ChargeNurseID` NOT NULL `FK` |
| BR-10 | A nurse is charge nurse of **at most one** ward. | `UQ Ward.ChargeNurseID` |
| BR-11 | A bed is inventoried to exactly one ward. | `Bed.WardID` NOT NULL `FK` |
| BR-12 | Bed size ∈ {S, L, XL}; default **L**. | `CK` + `DF` |
| BR-13 | Bed type ∈ {E (electric), M (manual)}; default **M**. | `CK` + `DF` |
| BR-14 | Bed availability ∈ {O (occupied), A (available)}; default **O** so a new bed is never double-booked by mistake. | `CK` + `DF`, NOT NULL |

## Patients and admissions

| ID | Rule | Enforcement |
|---|---|---|
| BR-15 | A patient has name, gender, DOB, address, phone, optional alternate phone and optional email. | NOT NULL, `CK Gender IN ('F','M','X')` |
| BR-16 | Date of birth cannot be in the future. | `CK DOB <= GETDATE()` |
| BR-17 | Patient age is calculated, never typed in. | `CC` (accurate to the birthday) |
| BR-18 | A patient may have many admissions (stays) over time. | `Admission.PatientID` `FK` |
| BR-19 | Every admission has an admitting physician. | NOT NULL `FK` |
| BR-20 | Discharge date and discharging physician are recorded together, or neither is recorded. | `CK` |
| BR-21 | Discharge date is on or after admit date. | `CK` |
| BR-22 | A patient cannot have two open (undischarged) admissions. | `FUI` on `PatientID WHERE DischargeDate IS NULL` |

## Bed assignment

| ID | Rule | Enforcement |
|---|---|---|
| BR-23 | On admission a patient is assigned a bed. Assignment history is kept (start and end date). | `BedAssignment` |
| BR-24 | A bed may not be assigned to more than one patient at the same time. | `FUI` on `BedID WHERE EndDate IS NULL` |
| BR-25 | A stay has at most one current bed (moves close the old row first). | `FUI` on `AdmissionID WHERE EndDate IS NULL` |
| BR-26 | Only beds marked available (`A`) can be assigned. Assigning marks the bed `O`; discharge releases it. | `SP usp_AdmitPatient` / `usp_DischargePatient` in one transaction |

## Treatments, items and charges

| ID | Rule | Enforcement |
|---|---|---|
| BR-27 | A treatment has a unique name, a description and a standard charge ≥ 0. Some treatments are never used. | `UQ`, `CK`; optional participation |
| BR-28 | A stay may receive zero or many treatments, possibly from several physicians. | `TreatmentAdministration` |
| BR-29 | A treatment may be recorded **without** a treating physician (required by report R9). | Nullable `PhysicianID` |
| BR-30 | Each administered treatment records date/time and results. | NOT NULL `AdministeredAt` |
| BR-31 | An item has a unique name and a unit charge ≥ 0. Some items are never charged. | `UQ`, `CK` |
| BR-32 | Charges record the item, date and quantity (> 0) against a stay. | `CK Quantity > 0` |
| BR-33 | The price charged is frozen at the time of the charge, so later price changes don't rewrite old bills. | `UnitCharge` / `ChargedAmount` snapshot columns |
| BR-34 | Every stay incurs at least one consumable item charge. | `DQ` (checked at discharge in `SP`) |

## Nurse care events

| ID | Rule | Enforcement |
|---|---|---|
| BR-35 | Each nurse–patient interaction is an event with a type, date and time. | `NurseCareEvent` |
| BR-36 | Event type ∈ {Wellness Check, Medication, Food Service, Assistance, Treatment Admin, Other}. | `FK` to `CareEventType` lookup (replaces a hard-coded `CK`) |
| BR-37 | A patient is usually seen by many nurses, and a nurse may log many events for the same patient in one shift. | No uniqueness on (Nurse, Patient, Date) |

## Physicians

| ID | Rule | Enforcement |
|---|---|---|
| BR-38 | A physician has name, address, phone, optional alternate phone, email and one or more specialties. | `PhysicianSpecialty` (PK `PhysicianID, SpecialtyID`) |
| BR-39 | Some physicians admit patients and some treat patients; neither is required. | Optional participation |
