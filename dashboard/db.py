"""Data access for the HospitalOps dashboard.

Every function reads the ``rpt`` reporting schema (views, inline functions and
the bill procedure), never the base tables, so the dashboard and the SQL reports
can't disagree. Functions return pandas DataFrames and have no Streamlit
dependency, so ``smoke_test.py`` can call them directly.

Connection: Windows authentication to HOSPITALOPS_SERVER (default: localhost).
Driver: Microsoft's ``mssql-python`` package, which bundles its own driver, so
nothing needs installing system-wide. (The ODBC driver built into Windows can't
complete the TLS handshake with SQL Server 2022.)
"""
from __future__ import annotations

import datetime as dt
import os
from decimal import Decimal

import mssql_python
import pandas as pd

SERVER = os.environ.get("HOSPITALOPS_SERVER", "localhost")
DATABASE = "HospitalOps"


def _connect():
    return mssql_python.connect(
        f"Server={SERVER};Database={DATABASE};Trusted_Connection=yes;Encrypt=yes;TrustServerCertificate=yes;"
    )


def _frame(cursor, dates: tuple[str, ...]) -> pd.DataFrame:
    cols = [c[0] for c in cursor.description]
    df = pd.DataFrame.from_records([tuple(r) for r in cursor.fetchall()], columns=cols)
    for col in df.columns:
        # DECIMAL arrives as Python Decimal; convert so pandas and plotly treat it as numeric
        if df[col].map(lambda v: isinstance(v, Decimal)).any():
            df[col] = df[col].astype(float)
    # DATE arrives as datetime.date; make it a pandas datetime for charting and formatting
    for col in dates:
        if col in df.columns:
            df[col] = pd.to_datetime(df[col])
    return df


def query(sql: str, params: tuple = (), dates: tuple[str, ...] = ()) -> pd.DataFrame:
    conn = _connect()
    try:
        cur = conn.cursor()
        cur.execute(sql, params) if params else cur.execute(sql)
        return _frame(cur, dates)
    finally:
        conn.close()


def _iso(d: dt.date) -> str:
    return d.isoformat()   # ISO text; SQL Server converts it to DATE implicitly


# ---------------------------------------------------------------------------
# Overview
# ---------------------------------------------------------------------------
def kpis(today: dt.date) -> dict:
    df = query(
        """
        SELECT
          (SELECT COUNT(*) FROM rpt.vw_AdmissionDetail WHERE DischargeDate IS NULL)                  AS Census,
          (SELECT SUM(Occupied) FROM rpt.vw_BedOccupancyByWard)                                      AS Occupied,
          (SELECT SUM(TotalBeds) FROM rpt.vw_BedOccupancyByWard)                                     AS TotalBeds,
          (SELECT AVG(CAST(LengthOfStayDays AS FLOAT)) FROM rpt.vw_AdmissionDetail
            WHERE DischargeDate > DATEADD(DAY, -90, CAST(? AS DATE)))                                AS AvgLos90,
          (SELECT SUM(TotalRevenue) FROM rpt.vw_DailyRevenue
            WHERE ServiceDate >  DATEADD(DAY, -30, CAST(? AS DATE)))                                 AS Revenue30,
          (SELECT SUM(TotalRevenue) FROM rpt.vw_DailyRevenue
            WHERE ServiceDate >  DATEADD(DAY, -60, CAST(? AS DATE))
              AND ServiceDate <= DATEADD(DAY, -30, CAST(? AS DATE)))                                 AS RevenuePrior30
        """,
        (_iso(today),) * 4,
    )
    return df.iloc[0].to_dict()


def bed_occupancy(as_of: dt.date | None) -> pd.DataFrame:
    """R1. Current flag-based status, or rebuilt from history for a past date."""
    if as_of is None:
        return query("SELECT * FROM rpt.vw_BedOccupancyByWard ORDER BY WardNumber")
    return query("SELECT * FROM rpt.fn_BedOccupancyOn(?) ORDER BY WardNumber", (_iso(as_of),))


def daily_flow(since: dt.date) -> pd.DataFrame:
    return query(
        "SELECT FlowDate, Admissions, Discharges FROM rpt.vw_DailyFlow WHERE FlowDate >= ? ORDER BY FlowDate",
        (_iso(since),), dates=("FlowDate",),
    )


# ---------------------------------------------------------------------------
# Admissions
# ---------------------------------------------------------------------------
def admissions_discharges(start: dt.date, end: dt.date) -> pd.DataFrame:
    """R2."""
    return query(
        """SELECT * FROM rpt.fn_AdmissionsDischarges(?, ?)
           ORDER BY AdmitDate, AdmittingPhysician, DischargingPhysician""",
        (_iso(start), _iso(end)), dates=("AdmitDate", "DischargeDate"),
    )


def admit_months() -> pd.DataFrame:
    return query("SELECT DISTINCT TOP (24) MonthStart FROM rpt.vw_PhysicianMonthlyAdmits ORDER BY MonthStart DESC",
                 dates=("MonthStart",))


def physician_admits(month_start: dt.date) -> pd.DataFrame:
    """R4."""
    return query(
        """SELECT Physician, Admits, RankInMonth, ChangeVsPriorMonth
           FROM rpt.vw_PhysicianMonthlyAdmits WHERE MonthStart = ? ORDER BY RankInMonth, Physician""",
        (_iso(month_start),),
    )


def patient_ward_history(patient_id: int) -> pd.DataFrame:
    """R8."""
    return query(
        """SELECT PatientName, AdmissionID, WardNumber, WardName, BedNumber, StartDate, EndDate, IsCurrent
           FROM rpt.vw_PatientWardAssignment WHERE PatientID = ? ORDER BY StartDate""",
        (patient_id,), dates=("StartDate", "EndDate"),
    )


# ---------------------------------------------------------------------------
# Billing
# ---------------------------------------------------------------------------
def monthly_revenue(since: dt.date) -> pd.DataFrame:
    return query(
        """SELECT DATEFROMPARTS(YEAR(ServiceDate), MONTH(ServiceDate), 1) AS MonthStart,
                  SUM(TreatmentRevenue) AS Treatments, SUM(ItemRevenue) AS Items
           FROM rpt.vw_DailyRevenue WHERE ServiceDate >= ?
           GROUP BY DATEFROMPARTS(YEAR(ServiceDate), MONTH(ServiceDate), 1)
           ORDER BY MonthStart""",
        (_iso(since),), dates=("MonthStart",),
    )


def top_treatments(since: dt.date, n: int = 10) -> pd.DataFrame:
    return query(
        """SELECT TOP (?) TreatmentName, COUNT(*) AS TimesGiven, SUM(ChargedAmount) AS Revenue
           FROM rpt.vw_PatientTreatments WHERE DateOfService >= ?
           GROUP BY TreatmentName ORDER BY Revenue DESC""",
        (n, _iso(since)),
    )


def latest_discharged_stay() -> int:
    return int(query("SELECT MAX(AdmissionID) AS id FROM rpt.vw_AdmissionDetail WHERE DischargeDate IS NOT NULL").iloc[0, 0])


def patient_of_stay(admission_id: int) -> int:
    return int(query("SELECT PatientID FROM rpt.vw_AdmissionDetail WHERE AdmissionID = ?", (admission_id,)).iloc[0, 0])


def patient_bill(admission_id: int) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """R6 itemized bill: (header, lines, totals) from dbo.usp_GetPatientBill's three result sets."""
    conn = _connect()
    try:
        cur = conn.cursor()
        cur.execute("EXEC dbo.usp_GetPatientBill @AdmissionID = ?", (admission_id,))
        header = _frame(cur, ("AdmitDate", "DischargeDate"))
        cur.nextset()
        lines = _frame(cur, ("ServiceDate",))
        cur.nextset()
        totals = _frame(cur, ())
    finally:
        conn.close()
    return header, lines, totals


def discharge_treatments(admission_id: int) -> pd.DataFrame:
    """R3."""
    return query(
        """SELECT DateOfService, TreatmentName, TreatingPhysician, Results, ChargedAmount
           FROM rpt.vw_DischargeTreatments WHERE AdmissionID = ? ORDER BY DateOfService, TreatmentName""",
        (admission_id,), dates=("DateOfService",),
    )


# ---------------------------------------------------------------------------
# Nursing
# ---------------------------------------------------------------------------
def shift_rotation(day: dt.date) -> pd.DataFrame:
    """R5."""
    return query("SELECT * FROM rpt.fn_ShiftRotation(?) ORDER BY WardNumber, Nurse", (_iso(day),))


def ward_schedule(day: dt.date) -> pd.DataFrame:
    """R7."""
    return query(
        """SELECT WardNumber, WardName, ChargeNurse, NursesOnShift, TotalHours, Nurses
           FROM rpt.vw_WardSchedule WHERE ShiftDate = ? ORDER BY WardNumber""",
        (_iso(day),),
    )


def nurse_roster() -> pd.DataFrame:
    """R12."""
    return query("SELECT * FROM rpt.vw_NurseRoster ORDER BY Nurse")


def nurse_hierarchy() -> pd.DataFrame:
    """R12 supervision tree."""
    return query("SELECT NurseIndented, Level, HierarchyPath FROM rpt.vw_NurseHierarchy ORDER BY HierarchyPath")


# ---------------------------------------------------------------------------
# Clinical
# ---------------------------------------------------------------------------
def treatments_physician_split(since: dt.date) -> dict:
    df = query(
        """SELECT COUNT(*) AS Total, SUM(CASE WHEN PhysicianID IS NULL THEN 1 ELSE 0 END) AS WithoutPhysician
           FROM rpt.vw_PatientTreatments WHERE DateOfService >= ?""",
        (_iso(since),),
    )
    return df.iloc[0].to_dict()


def treatments_without_physician(since: dt.date) -> pd.DataFrame:
    """R9 ("without" list). Filters on PhysicianID so it can use the filtered index."""
    return query(
        """SELECT DateOfService, PatientName, AdmissionID, TreatmentName, Results, ChargedAmount
           FROM rpt.vw_PatientTreatments
           WHERE PhysicianID IS NULL AND DateOfService >= ?
           ORDER BY DateOfService DESC""",
        (_iso(since),), dates=("DateOfService",),
    )


def physician_specialties() -> pd.DataFrame:
    """R11."""
    return query("SELECT PhysicianID, Physician, Specialties, SpecialtyCount, Phone, Email FROM rpt.vw_PhysicianSpecialties ORDER BY Physician")


def physician_treatments(physician_id: int) -> pd.DataFrame:
    """R10."""
    return query(
        """SELECT TreatmentName, TimesAdministered, FirstDate, LastDate, TotalCharged
           FROM rpt.vw_PhysicianTreatments WHERE PhysicianID = ? ORDER BY TimesAdministered DESC, TreatmentName""",
        (physician_id,), dates=("FirstDate", "LastDate"),
    )
