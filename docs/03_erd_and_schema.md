# 3. ERD and Relational Schema (v2)

The original v1 Chen-notation diagrams from the course are kept in [`original/`](original/) for comparison:
[ERD](original/v1_erd.png) · [EERD](original/v1_eerd.png) · [Relational schema](original/v1_relational_schema.png).
[05_design_review.md](05_design_review.md) explains what changed between v1 and v2.

## 3.1 Conceptual ERD

The design is centered on the **Admission** (one hospital stay). In v1, treatments, charges, bed and care events hung directly off `Patient`. Hanging them off the stay means a returning patient's bills and bed history stay separate per visit (report R6).

```mermaid
erDiagram
    NURSE ||--o{ NURSE : "supervises"
    NURSE ||--o| WARD : "is charge nurse of"
    NURSE ||--o{ NURSE_ASSIGNMENT : "works"
    WARD ||--o{ NURSE_ASSIGNMENT : "is staffed by"
    NURSE ||--o{ NURSE_CERTIFICATION : "holds"
    CERTIFICATION ||--o{ NURSE_CERTIFICATION : "held by"

    WARD ||--|{ BED : "contains"
    BED ||--o{ BED_ASSIGNMENT : "assigned in"

    PATIENT ||--o{ ADMISSION : "has stays"
    PHYSICIAN ||--o{ ADMISSION : "admits"
    PHYSICIAN |o--o{ ADMISSION : "discharges"
    ADMISSION ||--|{ BED_ASSIGNMENT : "occupies"

    PHYSICIAN ||--|{ PHYSICIAN_SPECIALTY : "has"
    SPECIALTY ||--o{ PHYSICIAN_SPECIALTY : "of"

    ADMISSION ||--o{ TREATMENT_ADMINISTRATION : "receives"
    TREATMENT ||--o{ TREATMENT_ADMINISTRATION : "given as"
    PHYSICIAN |o--o{ TREATMENT_ADMINISTRATION : "treats"

    ADMISSION ||--|{ ITEM_CHARGE : "incurs"
    ITEM ||--o{ ITEM_CHARGE : "charged as"

    ADMISSION ||--o{ NURSE_CARE_EVENT : "cared for in"
    NURSE ||--o{ NURSE_CARE_EVENT : "performs"
    CARE_EVENT_TYPE ||--o{ NURSE_CARE_EVENT : "classifies"
```

**Reading the crow's feet:** `||` exactly one · `|o` zero or one · `|{` one or many · `o{` zero or many.

## 3.2 Logical model with attributes

```mermaid
erDiagram
    NURSE {
        int NurseID PK
        nvarchar FirstName
        nvarchar LastName
        nvarchar Street
        nvarchar City
        char State
        char Zip
        nvarchar Phone
        nvarchar AltPhone
        nvarchar Email UK
        int SupervisorID FK
    }
    CERTIFICATION {
        nvarchar CertCode PK
        nvarchar CertName
    }
    NURSE_CERTIFICATION {
        int NurseID PK, FK
        nvarchar CertCode PK, FK
    }
    WARD {
        int WardID PK
        nvarchar WardNumber UK
        nvarchar WardName
        nvarchar Location
        nvarchar Phone
        int ChargeNurseID FK, UK
    }
    BED {
        int BedID PK
        int WardID FK
        nvarchar BedNumber
        char Size "S | L | XL, default L"
        char Type "E | M, default M"
        char Availability "O | A, default O"
    }
    NURSE_ASSIGNMENT {
        int NurseAssignmentID PK
        int NurseID FK
        int WardID FK
        date ShiftDate
        decimal HoursWorked "0 < h <= 24"
    }
    PHYSICIAN {
        int PhysicianID PK
        nvarchar FirstName
        nvarchar LastName
        nvarchar Street
        nvarchar City
        char State
        char Zip
        nvarchar Phone
        nvarchar AltPhone
        nvarchar Email UK
    }
    SPECIALTY {
        int SpecialtyID PK
        nvarchar SpecialtyName UK
    }
    PHYSICIAN_SPECIALTY {
        int PhysicianID PK, FK
        int SpecialtyID PK, FK
    }
    PATIENT {
        int PatientID PK
        nvarchar FirstName
        nvarchar LastName
        char Gender
        date DOB
        int Age "computed"
        nvarchar Street
        nvarchar City
        char State
        char Zip
        nvarchar Phone
        nvarchar AltPhone
        nvarchar Email
    }
    ADMISSION {
        int AdmissionID PK
        int PatientID FK
        date AdmitDate
        int AdmitPhysicianID FK
        date DischargeDate
        int DischargePhysicianID FK
    }
    BED_ASSIGNMENT {
        int BedAssignmentID PK
        int AdmissionID FK
        int BedID FK
        date StartDate
        date EndDate "NULL = current"
    }
    TREATMENT {
        int TreatmentID PK
        nvarchar TreatmentName UK
        nvarchar Description
        decimal StandardCharge
    }
    TREATMENT_ADMINISTRATION {
        int TreatmentAdminID PK
        int AdmissionID FK
        int TreatmentID FK
        int PhysicianID FK "nullable"
        datetime2 AdministeredAt
        nvarchar Results
        decimal ChargedAmount
    }
    ITEM {
        int ItemID PK
        nvarchar ItemName UK
        decimal UnitCharge
    }
    ITEM_CHARGE {
        int ItemChargeID PK
        int AdmissionID FK
        int ItemID FK
        date ChargeDate
        int Quantity
        decimal UnitCharge
        decimal LineTotal "computed, persisted"
    }
    CARE_EVENT_TYPE {
        char EventTypeCode PK
        nvarchar EventTypeName UK
    }
    NURSE_CARE_EVENT {
        int CareEventID PK
        int AdmissionID FK
        int NurseID FK
        char EventTypeCode FK
        datetime2 EventAt
        nvarchar Notes
    }

    NURSE ||--o{ NURSE : supervises
    NURSE ||--o| WARD : "charge nurse"
    NURSE ||--o{ NURSE_ASSIGNMENT : ""
    WARD ||--o{ NURSE_ASSIGNMENT : ""
    NURSE ||--o{ NURSE_CERTIFICATION : ""
    CERTIFICATION ||--o{ NURSE_CERTIFICATION : ""
    WARD ||--|{ BED : ""
    BED ||--o{ BED_ASSIGNMENT : ""
    PATIENT ||--o{ ADMISSION : ""
    PHYSICIAN ||--o{ ADMISSION : "admit / discharge"
    ADMISSION ||--|{ BED_ASSIGNMENT : ""
    PHYSICIAN ||--|{ PHYSICIAN_SPECIALTY : ""
    SPECIALTY ||--o{ PHYSICIAN_SPECIALTY : ""
    ADMISSION ||--o{ TREATMENT_ADMINISTRATION : ""
    TREATMENT ||--o{ TREATMENT_ADMINISTRATION : ""
    PHYSICIAN |o--o{ TREATMENT_ADMINISTRATION : ""
    ADMISSION ||--|{ ITEM_CHARGE : ""
    ITEM ||--o{ ITEM_CHARGE : ""
    ADMISSION ||--o{ NURSE_CARE_EVENT : ""
    NURSE ||--o{ NURSE_CARE_EVENT : ""
    CARE_EVENT_TYPE ||--o{ NURSE_CARE_EVENT : ""
```

## 3.3 Relational schema (text notation)

Primary keys are <u>underlined</u>; foreign keys are *italic* and point to the referenced relation.

- **Certification** (<u>CertCode</u>, CertName)
- **Specialty** (<u>SpecialtyID</u>, SpecialtyName)
- **CareEventType** (<u>EventTypeCode</u>, EventTypeName)
- **Nurse** (<u>NurseID</u>, FirstName, LastName, Street, City, State, Zip, Phone, AltPhone, Email, *SupervisorID* → Nurse)
- **NurseCertification** (<u>*NurseID*</u> → Nurse, <u>*CertCode*</u> → Certification)
- **Physician** (<u>PhysicianID</u>, FirstName, LastName, Street, City, State, Zip, Phone, AltPhone, Email)
- **PhysicianSpecialty** (<u>*PhysicianID*</u> → Physician, <u>*SpecialtyID*</u> → Specialty)
- **Patient** (<u>PatientID</u>, FirstName, LastName, Gender, DOB, [Age], Street, City, State, Zip, Phone, AltPhone, Email)
- **Ward** (<u>WardID</u>, WardNumber, WardName, Location, Phone, *ChargeNurseID* → Nurse)
- **Bed** (<u>BedID</u>, *WardID* → Ward, BedNumber, Size, Type, Availability)
- **NurseAssignment** (<u>NurseAssignmentID</u>, *NurseID* → Nurse, *WardID* → Ward, ShiftDate, HoursWorked)
- **Admission** (<u>AdmissionID</u>, *PatientID* → Patient, AdmitDate, *AdmitPhysicianID* → Physician, DischargeDate, *DischargePhysicianID* → Physician)
- **BedAssignment** (<u>BedAssignmentID</u>, *AdmissionID* → Admission, *BedID* → Bed, StartDate, EndDate)
- **Treatment** (<u>TreatmentID</u>, TreatmentName, Description, StandardCharge)
- **TreatmentAdministration** (<u>TreatmentAdminID</u>, *AdmissionID* → Admission, *TreatmentID* → Treatment, *PhysicianID* → Physician, AdministeredAt, Results, ChargedAmount)
- **Item** (<u>ItemID</u>, ItemName, UnitCharge)
- **ItemCharge** (<u>ItemChargeID</u>, *AdmissionID* → Admission, *ItemID* → Item, ChargeDate, Quantity, UnitCharge, [LineTotal])
- **NurseCareEvent** (<u>CareEventID</u>, *AdmissionID* → Admission, *NurseID* → Nurse, *EventTypeCode* → CareEventType, EventAt, Notes)

`[ ]` = derived / computed attribute.

## 3.4 Normal form

All tables are in **3NF** (and BCNF):

- **1NF:** multi-valued attributes from the narrative (nurse certifications, physician specialties) are moved to associative tables instead of comma-separated columns. Composite attributes (name, address) are split into atomic columns.
- **2NF:** every associative table with a composite key (`NurseCertification`, `PhysicianSpecialty`) has no non-key columns, so there are no partial dependencies.
- **3NF:** there are no transitive dependencies. `Age` depends on `DOB` and is computed, not stored. `LineTotal` is computed from `Quantity × UnitCharge`. Ward details live only in `Ward`, not repeated on `Bed` or `NurseAssignment`.
- **Deliberate snapshot:** `ItemCharge.UnitCharge` and `TreatmentAdministration.ChargedAmount` look like copies of catalog prices, but they record the *historical* price at the time of service. That is a separate fact from the current list price, so it does not violate 3NF.
