# 1. Requirements

## 1.1 Problem statement

A hospital administrator needs one system of record for day-to-day ward operations. Today that information sits in separate logs, which makes it hard to answer basic operational questions:

- Which beds are free right now, and in which ward?
- Which nurses worked which ward on a given day, and for how many hours?
- Who admitted and discharged each patient, and what did each stay cost?
- Which treatments and care events did a patient receive, and from whom?

The goal is a normalized relational database (SQL Server) that captures these facts with integrity enforced *in the database*, plus a reporting layer the administrator can query directly.

## 1.2 Scope

| In scope | Out of scope |
|---|---|
| Nurses, certifications, supervision hierarchy | Payroll, HR, scheduling optimization |
| Wards, charge nurses, beds | Real-time bed-sensor / occupancy feeds |
| Patients, admissions and discharges | Insurance claims, payments, EHR clinical notes |
| Bed assignment **history** per stay | Pharmacy inventory |
| Treatments administered (with or without a treating physician) | |
| Consumable item charges per stay | |
| Nurse–patient care events | |

## 1.3 Actors

| Actor | What they need from the system |
|---|---|
| **Hospital Administrator** (primary) | Operational and financial reports across all wards |
| **Admitting Official** | See available beds, admit a patient and assign a bed |
| **Physicians** | Record admissions, discharges and treatments |
| **Nurses / Charge Nurses** | Record care events and see ward assignments |
| **Billing Staff** | Itemized charges per patient stay |
| **DBA / Data Analyst** | Maintain integrity and performance, and build reports |

## 1.4 Core entities

`Nurse`, `Certification`, `Ward`, `Bed`, `Patient`, `Physician`, `Specialty`, `Admission`, `Treatment`, `Item`, `CareEventType`.

Associative / event entities: `NurseCertification`, `PhysicianSpecialty`, `NurseAssignment`, `BedAssignment`, `TreatmentAdministration`, `ItemCharge`, `NurseCareEvent`.

## 1.5 Workflow: admitting a patient

1. The admitting official reviews beds that are **available** (`A`).
2. The patient record is created (or found, for returning patients).
3. An **admission** (one stay) is opened with the admitting physician.
4. A **bed assignment** is opened for that stay; the bed is marked occupied (`O`).
5. During the stay, treatments, item charges and nurse care events are recorded against the admission.
6. On discharge, the discharging physician and date are recorded, the bed assignment is closed and the bed is released.

## 1.6 Required reports

Each report maps to a view, inline function or procedure in `sql/07_reporting_views.sql` and `sql/08_stored_procedures.sql`. The catalog is in [06 Reports and procedures](06_reports_and_procedures.md).

| # | Report | Frequency |
|---|---|---|
| R1 | Beds occupied vs. available, by ward | Daily |
| R2 | Patients admitted and discharged, sorted by admit date, admitting and discharging physician | Weekly |
| R3 | Patient discharge report: name, treatments, treating physician, date of service | Per discharge |
| R4 | Physician admits | Monthly |
| R5 | Shift rotation report of nurse–patient care | Per shift |
| R6 | Summary of charges for a patient stay (treatments + items) | Per stay |
| R7 | Ward schedule with charge nurse name | Weekly |
| R8 | Patient ward assignment | On demand |
| R9 | Patient treatments **with and without** a treating physician | On demand |
| R10 | Physician treatment report: dates and types of treatment | On demand |
| R11 | Physicians and their specialties | On demand |
| R12 | Nurses with certifications and ward assignments, including supervisors | On demand |
