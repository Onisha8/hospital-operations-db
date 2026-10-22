"""HospitalOps operations dashboard (Streamlit).

Covers all 12 required reports (R1-R12) by reading the rpt schema through db.py.
Run from the dashboard folder, so .streamlit/config.toml (pinned light theme) is picked up:

    cd dashboard
    .venv\\Scripts\\streamlit run app.py
"""
from __future__ import annotations

import datetime as dt

import pandas as pd
import streamlit as st

import charts
import db

st.set_page_config(page_title="HospitalOps Dashboard", page_icon="🏥", layout="wide")

TODAY = dt.date.today()
YESTERDAY = TODAY - dt.timedelta(days=1)
CACHE = st.cache_data(ttl=300, show_spinner=False)   # 5 minutes: reports are operational, not real-time


def theme() -> dict:
    # Chart colors are baked in server-side, so they follow the CONFIGURED theme
    # (.streamlit/config.toml pins light; run with --theme.base dark for the dark variant).
    # Guessing from the viewer's browser was unreliable: a dark OS preference produced
    # dark-mode chart colors on a light page.
    return charts.TOKENS["dark" if st.get_option("theme.base") == "dark" else "light"]


def money(v: float) -> str:
    return f"${v:,.0f}"


def plot(fig) -> None:
    # theme=None: keep charts.py styling (validated palette); Streamlit's own Plotly theme would override it
    st.plotly_chart(fig, theme=None, config={"displayModeBar": False})   # stretches to the column by default


# Cached wrappers (the arguments are the cache key)
kpis = CACHE(db.kpis)
bed_occupancy = CACHE(db.bed_occupancy)
daily_flow = CACHE(db.daily_flow)
admissions_discharges = CACHE(db.admissions_discharges)
admit_months = CACHE(db.admit_months)
physician_admits = CACHE(db.physician_admits)
patient_ward_history = CACHE(db.patient_ward_history)
monthly_revenue = CACHE(db.monthly_revenue)
top_treatments = CACHE(db.top_treatments)
latest_discharged_stay = CACHE(db.latest_discharged_stay)
patient_of_stay = CACHE(db.patient_of_stay)
patient_bill = CACHE(db.patient_bill)
discharge_treatments = CACHE(db.discharge_treatments)
shift_rotation = CACHE(db.shift_rotation)
ward_schedule = CACHE(db.ward_schedule)
nurse_roster = CACHE(db.nurse_roster)
nurse_hierarchy = CACHE(db.nurse_hierarchy)
treatments_physician_split = CACHE(db.treatments_physician_split)
treatments_without_physician = CACHE(db.treatments_without_physician)
physician_specialties = CACHE(db.physician_specialties)
physician_treatments = CACHE(db.physician_treatments)

DATE = st.column_config.DateColumn(format="YYYY-MM-DD")
USD = st.column_config.NumberColumn(format="dollar")   # $1,234.56

# ---------------------------------------------------------------------------
st.title("HospitalOps Operations Dashboard")
st.caption(f"SQL Server reporting layer (`rpt` schema) · data as of {TODAY:%B %d, %Y} · "
           "synthetic data generated for this portfolio project")

try:
    k = kpis(TODAY)
except Exception as exc:  # noqa: BLE001 - show a readable message instead of a stack trace
    st.error(f"Can't reach the HospitalOps database on '{db.SERVER}'. Build it first with `.\\run_sql.ps1`.\n\n{exc}")
    st.stop()

t = theme()
tab_overview, tab_admissions, tab_billing, tab_nursing, tab_clinical = st.tabs(
    ["Overview", "Admissions", "Billing", "Nursing", "Clinical"])

# ---------------------------------------------------------------------------
with tab_overview:
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Current census", f"{int(k['Census']):,}", help="Open stays (patients currently admitted)")
    c2.metric("Bed occupancy", f"{k['Occupied'] / k['TotalBeds']:.0%}",
              help=f"{int(k['Occupied'])} of {int(k['TotalBeds'])} beds occupied")
    c3.metric("Avg length of stay", f"{k['AvgLos90']:.1f} days", help="Stays discharged in the last 90 days")
    change = (k["Revenue30"] - k["RevenuePrior30"]) / k["RevenuePrior30"]
    c4.metric("Revenue, last 30 days", money(k["Revenue30"]), f"{change:+.1%} vs prior 30 days")

    left, right = st.columns([5, 6], gap="large")
    with left:
        st.subheader("Beds by ward (R1)")
        as_of = st.date_input("As of", value=TODAY, max_value=TODAY, key="occ_date",
                              help="Today uses the live availability flag; past dates are rebuilt from bed history.")
        occ = bed_occupancy(None if as_of == TODAY else as_of)
        plot(charts.bed_occupancy(occ, t))
    with right:
        st.subheader("Patient flow, last 26 weeks")
        since = TODAY - dt.timedelta(weeks=26)
        flow = daily_flow(since)
        weekly = (flow.set_index("FlowDate").resample("W-MON", label="left", closed="left")
                  [["Admissions", "Discharges"]].sum().reset_index().rename(columns={"FlowDate": "WeekStart"}))
        # complete weeks only: drop the partial first week (window starts mid-week) and the current week
        weekly = weekly[(weekly["WeekStart"] >= pd.Timestamp(since))
                        & (weekly["WeekStart"] + pd.Timedelta(days=6) < pd.Timestamp(TODAY))]
        plot(charts.patient_flow(weekly, t))
        with st.expander("Table view"):
            st.dataframe(weekly, hide_index=True, column_config={"WeekStart": DATE})

# ---------------------------------------------------------------------------
with tab_admissions:
    st.subheader("Admissions and discharges (R2)")
    period = st.date_input("Period", value=(TODAY - dt.timedelta(days=6), TODAY), max_value=TODAY, key="r2")
    if not (isinstance(period, tuple) and len(period) == 2):
        st.info("Pick an end date for the period.")          # the range picker returns one date mid-selection
    else:
        ad = admissions_discharges(*period)
        c1, c2, c3 = st.columns(3)
        c1.metric("Admitted in period", int((ad["AdmittedInPeriod"] == "Y").sum()))
        c2.metric("Discharged in period", int((ad["DischargedInPeriod"] == "Y").sum()))
        c3.metric("Stays touching period", len(ad))
        st.dataframe(ad, hide_index=True, width="stretch", height=320,
                     column_config={"AdmitDate": DATE, "DischargeDate": DATE})

    left, right = st.columns(2, gap="large")
    with left:
        st.subheader("Physician admits by month (R4)")
        months = admit_months()["MonthStart"].dt.date.tolist()
        month = st.selectbox("Month", months, index=1 if len(months) > 1 else 0,
                             format_func=lambda m: m.strftime("%B %Y") + (" (to date)" if m == months[0] else ""))
        pa = physician_admits(month)
        plot(charts.ranked_bars(pa.head(10), "Physician", "Admits", t, "Admissions"))
        with st.expander("All physicians"):
            st.dataframe(pa, hide_index=True, width="stretch")
    with right:
        st.subheader("Patient ward history (R8)")
        pid = st.number_input("Patient ID", min_value=1, value=patient_of_stay(latest_discharged_stay()), step=1)
        hist = patient_ward_history(int(pid))
        if hist.empty:
            st.info("No stays found for this patient.")
        else:
            st.markdown(f"**{hist['PatientName'].iloc[0]}** · {hist['AdmissionID'].nunique()} stay(s)")
            st.dataframe(hist.drop(columns="PatientName"), hide_index=True, width="stretch",
                         column_config={"StartDate": DATE, "EndDate": DATE})

# ---------------------------------------------------------------------------
with tab_billing:
    left, right = st.columns([6, 5], gap="large")
    with left:
        st.subheader("Revenue by month")
        first = (TODAY.replace(day=1) - pd.DateOffset(months=12)).date()
        rev = monthly_revenue(first)
        plot(charts.monthly_revenue(rev, t, pd.Timestamp(TODAY.replace(day=1))))
    with right:
        st.subheader("Top treatments by revenue, 12 months")
        tt = top_treatments(TODAY - dt.timedelta(days=365))
        plot(charts.ranked_bars(tt, "TreatmentName", "Revenue", t, "Revenue", money=True))

    st.subheader("Stay bill (R6) and discharge report (R3)")
    adm = st.number_input("Admission ID", min_value=1, value=latest_discharged_stay(), step=1)
    try:
        header, lines, totals = patient_bill(int(adm))
    except Exception as exc:  # noqa: BLE001 - procedure raises 50010 for an unknown stay
        st.warning(str(exc).split("]")[-1].strip() or "Stay not found.")
    else:
        h, tot = header.iloc[0], totals.iloc[0]
        discharged = "still admitted" if pd.isna(h["DischargeDate"]) else f"discharged {h['DischargeDate']:%Y-%m-%d}"
        st.markdown(f"**{h['PatientName']}** · {h['WardName']}, bed {h['BedNumber']} · "
                    f"admitted {h['AdmitDate']:%Y-%m-%d} by {h['AdmittingPhysician']} · {discharged}")
        c1, c2, c3 = st.columns(3)
        c1.metric(f"Treatments ({int(tot['TreatmentCount'])} lines)", money(tot["TreatmentTotal"]))
        c2.metric(f"Items ({int(tot['ItemLines'])} lines)", money(tot["ItemTotal"]))
        c3.metric("Total", money(tot["GrandTotal"]))
        st.dataframe(lines, hide_index=True, width="stretch",
                     column_config={"ServiceDate": DATE, "UnitPrice": USD, "Amount": USD})
        if not pd.isna(h["DischargeDate"]):
            with st.expander("Discharge treatment report (R3)"):
                st.dataframe(discharge_treatments(int(adm)), hide_index=True, width="stretch",
                             column_config={"DateOfService": DATE, "ChargedAmount": USD})

# ---------------------------------------------------------------------------
with tab_nursing:
    day = st.date_input("Shift date", value=YESTERDAY, max_value=TODAY, key="shift")
    rot = shift_rotation(day)
    sched = ward_schedule(day)
    if rot.empty:
        st.info("No shifts recorded for this date.")
    else:
        left, right = st.columns([6, 5], gap="large")
        with left:
            st.subheader("Care delivered by ward (R5)")
            cols = [c for c, _ in charts.CARE_TYPES] + ["TotalEvents"]
            by_ward = rot.groupby("WardName", as_index=False)[cols].sum()
            plot(charts.care_mix(by_ward, t))
            with st.expander("Table view"):
                st.dataframe(by_ward.rename(columns=dict(charts.CARE_TYPES)), hide_index=True, width="stretch")
        with right:
            st.subheader("Ward schedule (R7)")
            st.dataframe(sched, hide_index=True, width="stretch", height=390)
        st.subheader("Shift rotation detail (R5)")
        st.dataframe(rot, hide_index=True, width="stretch")

    st.subheader("Nurse roster (R12)")
    roster = nurse_roster()
    search = st.text_input("Filter by name, certification or ward", "")
    if search:
        mask = roster.astype(str).apply(lambda col: col.str.contains(search, case=False, na=False)).any(axis=1)
        roster = roster[mask]
    st.dataframe(roster, hide_index=True, width="stretch")
    with st.expander("Supervision hierarchy"):
        st.dataframe(nurse_hierarchy()[["NurseIndented", "Level"]].rename(columns={"NurseIndented": "Nurse"}),
                     hide_index=True, width="stretch", height=400)

# ---------------------------------------------------------------------------
with tab_clinical:
    st.subheader("Treatments without a treating physician (R9)")
    since = TODAY - dt.timedelta(days=30)
    split = treatments_physician_split(since)
    c1, c2 = st.columns(2)
    c1.metric("Without physician, last 30 days", f"{int(split['WithoutPhysician']):,}")
    c2.metric("Share of all treatments", f"{split['WithoutPhysician'] / split['Total']:.1%}",
              help="Records that need a treating physician assigned")
    st.dataframe(treatments_without_physician(since), hide_index=True, width="stretch", height=300,
                 column_config={"DateOfService": st.column_config.DatetimeColumn(format="YYYY-MM-DD HH:mm"),
                                "ChargedAmount": USD})

    left, right = st.columns(2, gap="large")
    specs = physician_specialties()
    with left:
        st.subheader("Physicians and specialties (R11)")
        st.dataframe(specs.drop(columns=["PhysicianID", "SpecialtyCount"]), hide_index=True,
                     width="stretch", height=420)
    with right:
        st.subheader("Physician treatment history (R10)")
        choice = st.selectbox("Physician", specs["PhysicianID"].tolist(),
                              format_func=lambda i: f"{specs.set_index('PhysicianID').at[i, 'Physician']} · "
                                                    f"{specs.set_index('PhysicianID').at[i, 'Specialties']}")
        st.dataframe(physician_treatments(int(choice)), hide_index=True, width="stretch", height=360,
                     column_config={"FirstDate": DATE, "LastDate": DATE, "TotalCharged": USD})
