"""Calls every data function once and checks it returns rows. Run from the repo root:

    dashboard\\.venv\\Scripts\\python dashboard\\smoke_test.py
"""
import datetime as dt
import sys
import time

import db

today = dt.date.today()
yesterday = today - dt.timedelta(days=1)
stay = db.latest_discharged_stay()

checks = {
    "kpis": lambda: db.kpis(today),
    "R1 bed_occupancy (today)": lambda: db.bed_occupancy(None),
    "R1 bed_occupancy (past date)": lambda: db.bed_occupancy(today - dt.timedelta(days=365)),
    "daily_flow": lambda: db.daily_flow(today - dt.timedelta(days=182)),
    "R2 admissions_discharges": lambda: db.admissions_discharges(today - dt.timedelta(days=6), today),
    "R4 physician_admits": lambda: db.physician_admits(db.admit_months()["MonthStart"].iloc[1].date()),
    "R8 patient_ward_history": lambda: db.patient_ward_history(int(db.query(
        "SELECT PatientID FROM rpt.vw_AdmissionDetail WHERE AdmissionID = ?", (stay,)).iloc[0, 0])),
    "monthly_revenue": lambda: db.monthly_revenue(today.replace(day=1) - dt.timedelta(days=365)),
    "top_treatments": lambda: db.top_treatments(today - dt.timedelta(days=365)),
    "R6 patient_bill": lambda: db.patient_bill(stay),
    "R3 discharge_treatments": lambda: db.discharge_treatments(stay),
    "R5 shift_rotation": lambda: db.shift_rotation(yesterday),
    "R7 ward_schedule": lambda: db.ward_schedule(yesterday),
    "R12 nurse_roster": db.nurse_roster,
    "R12 nurse_hierarchy": db.nurse_hierarchy,
    "R9 treatments_physician_split": lambda: db.treatments_physician_split(today - dt.timedelta(days=30)),
    "R9 treatments_without_physician": lambda: db.treatments_without_physician(today - dt.timedelta(days=30)),
    "R11 physician_specialties": db.physician_specialties,
    "R10 physician_treatments": lambda: db.physician_treatments(1),
}

failed = 0
print(f"server: {db.SERVER}  sample stay: {stay}")
for name, fn in checks.items():
    t0 = time.perf_counter()
    try:
        result = fn()
        if isinstance(result, tuple):
            rows = [len(part) for part in result]
            ok = all(r > 0 for r in rows)
        elif isinstance(result, dict):
            rows, ok = len(result), all(v is not None for v in result.values())
        else:
            rows, ok = len(result), len(result) > 0
        status = "ok  " if ok else "EMPTY"
        failed += not ok
    except Exception as exc:  # noqa: BLE001 - report every failure, keep going
        rows, status = repr(exc)[:120], "FAIL"
        failed += 1
    print(f"{status} {name:<34} rows={rows}  {1000 * (time.perf_counter() - t0):6.0f} ms")

print(f"\n{len(checks) - failed} of {len(checks)} passed")
sys.exit(1 if failed else 0)
