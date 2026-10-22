"""Plotly figure builders for the dashboard.

Colors come from a validated reference palette (categorical slots in fixed order,
checked for color-vision-deficiency separation and contrast in both light and dark
mode). Mark specs: 2px lines, 4px rounded bar ends, a 2px surface-colored gap
between stacked segments, hairline gridlines, one y-axis per chart, hover
tooltips on every mark, and text in ink colors (never the series color).
"""
from __future__ import annotations

import pandas as pd
import plotly.graph_objects as go

TOKENS = {
    "light": {
        "surface": "#fcfcfb", "ink": "#0b0b0b", "ink2": "#52514e", "muted": "#898781",
        "grid": "#e1e0d9", "axis": "#c3c2b7", "capacity": "#d6d5ce",
        "series": ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300"],
    },
    "dark": {
        "surface": "#1a1a19", "ink": "#f0efec", "ink2": "#c3c2b7", "muted": "#898781",
        "grid": "#2c2c2a", "axis": "#383835", "capacity": "#3a3a37",
        "series": ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300"],
    },
}

FONT = 'system-ui, -apple-system, "Segoe UI", sans-serif'


def _layout(fig: go.Figure, t: dict, height: int, legend: bool = True) -> go.Figure:
    fig.update_layout(
        height=height,
        margin=dict(l=8, r=16, t=36 if legend else 8, b=8),
        paper_bgcolor="rgba(0,0,0,0)",
        plot_bgcolor="rgba(0,0,0,0)",
        font=dict(family=FONT, size=13, color=t["ink2"]),
        showlegend=legend,
        legend=dict(orientation="h", x=0, xanchor="left", y=1.02, yanchor="bottom",
                    font=dict(color=t["ink2"]), bgcolor="rgba(0,0,0,0)", traceorder="normal"),
        hoverlabel=dict(bgcolor=t["surface"], bordercolor=t["axis"], font=dict(family=FONT, color=t["ink"])),
        barcornerradius=4,
    )
    axis = dict(gridcolor=t["grid"], gridwidth=1, linecolor=t["axis"], zeroline=False, automargin=True,
                tickfont=dict(color=t["muted"]), title_font=dict(color=t["ink2"]))
    fig.update_xaxes(**axis)
    fig.update_yaxes(**axis)
    return fig


def bed_occupancy(df: pd.DataFrame, t: dict) -> go.Figure:
    """R1: occupied vs available beds per ward (part of a fixed 30-bed capacity)."""
    d = df.sort_values("OccupancyPct")              # plotly draws the first category at the bottom
    fig = go.Figure()
    fig.add_bar(y=d["WardName"], x=d["Occupied"], name="Occupied", orientation="h",
                marker=dict(color=t["series"][0], line=dict(color=t["surface"], width=2)),
                customdata=d[["OccupancyPct", "TotalBeds"]],
                hovertemplate="<b>%{y}</b><br>Occupied: %{x} of %{customdata[1]} beds (%{customdata[0]:.1f}%)<extra></extra>")
    fig.add_bar(y=d["WardName"], x=d["Available"], name="Available", orientation="h",
                marker=dict(color=t["capacity"], line=dict(color=t["surface"], width=2)),
                hovertemplate="<b>%{y}</b><br>Available: %{x} beds<extra></extra>")
    for _, r in d.iterrows():                       # selective direct label: occupancy % at the bar end
        fig.add_annotation(x=r["TotalBeds"], y=r["WardName"], text=f"{r['OccupancyPct']:.0f}%",
                           showarrow=False, xanchor="left", xshift=6, font=dict(color=t["ink2"], size=12))
    fig.update_layout(barmode="stack", bargap=0.35)
    fig.update_xaxes(title_text="Beds", range=[0, float(d["TotalBeds"].max()) * 1.12])
    fig.update_yaxes(showgrid=False)
    return _layout(fig, t, height=380)


def patient_flow(weekly: pd.DataFrame, t: dict) -> go.Figure:
    """Admissions vs discharges per week: two lines, one axis, crosshair hover, end labels."""
    fig = go.Figure()
    last = weekly.iloc[-1]
    # End labels: the higher line's label goes up, the lower one's down, so they never overlap
    upper = "Admissions" if last["Admissions"] >= last["Discharges"] else "Discharges"
    for i, col in enumerate(["Admissions", "Discharges"]):
        fig.add_scatter(x=weekly["WeekStart"], y=weekly[col], name=col, mode="lines",
                        line=dict(color=t["series"][i], width=2),
                        hovertemplate=f"{col}: %{{y:,}}<extra></extra>")
        fig.add_annotation(x=last["WeekStart"], y=last[col], text=col, showarrow=False,
                           xanchor="left", xshift=8, yshift=9 if col == upper else -9,
                           font=dict(color=t["ink2"], size=12))
    fig.update_layout(hovermode="x unified")
    fig.update_xaxes(showgrid=False, showspikes=True, spikemode="across", spikethickness=1,
                     spikecolor=t["axis"], spikedash="solid", hoverformat="Week of %b %d, %Y")
    fig.update_yaxes(title_text="Stays per week", rangemode="tozero")
    _layout(fig, t, height=340)
    fig.update_layout(margin=dict(l=8, r=90, t=36, b=8))   # room for the end-of-line labels
    return fig


def monthly_revenue(df: pd.DataFrame, t: dict, current_month: pd.Timestamp) -> go.Figure:
    """Revenue per month, stacked by source."""
    # short labels so 13 months fit without rotating; the current month is flagged as month-to-date
    labels = [m.strftime("%b '%y") + ("<br>(MTD)" if m == current_month else "") for m in df["MonthStart"]]
    fig = go.Figure()
    for i, col in enumerate(["Treatments", "Items"]):
        fig.add_bar(x=labels, y=df[col], name=col,
                    marker=dict(color=t["series"][i], line=dict(color=t["surface"], width=2)),
                    customdata=df[["Treatments", "Items"]].sum(axis=1),
                    hovertemplate=f"<b>%{{x}}</b><br>{col}: $%{{y:,.0f}}<br>Month total: $%{{customdata:,.0f}}<extra></extra>")
    fig.update_layout(barmode="stack", bargap=0.3)
    fig.update_yaxes(title_text="Revenue", tickprefix="$", tickformat="~s")
    fig.update_xaxes(showgrid=False, tickangle=0)
    return _layout(fig, t, height=360)


def ranked_bars(df: pd.DataFrame, label: str, value: str, t: dict, value_title: str,
                money: bool = False, height: int = 360) -> go.Figure:
    """Single-series ranking, largest at the top. No legend: the title names the series."""
    d = df.sort_values(value)
    fmt = "$%{x:,.0f}" if money else "%{x:,}"
    fig = go.Figure(go.Bar(y=d[label], x=d[value], orientation="h",
                           marker=dict(color=t["series"][0]),
                           hovertemplate=f"<b>%{{y}}</b><br>{value_title}: {fmt}<extra></extra>"))
    fig.update_layout(bargap=0.35)
    fig.update_xaxes(title_text=value_title, tickprefix="$" if money else "", tickformat="~s" if money else ",")
    fig.update_yaxes(showgrid=False)
    return _layout(fig, t, height=height, legend=False)


CARE_TYPES = [   # fixed order = fixed color slot, so a type keeps its color everywhere
    ("WellnessChecks", "Wellness check"), ("Medication", "Medication"), ("FoodService", "Food service"),
    ("Assistance", "Assistance"), ("TreatmentAdmin", "Treatment admin"), ("Other", "Other"),
]


def care_mix(by_ward: pd.DataFrame, t: dict) -> go.Figure:
    """R5: nurse care events by type per ward for one day (6 series, fixed slots, legend + table view)."""
    d = by_ward.sort_values("TotalEvents")
    fig = go.Figure()
    for i, (col, name) in enumerate(CARE_TYPES):
        fig.add_bar(y=d["WardName"], x=d[col], name=name, orientation="h",
                    marker=dict(color=t["series"][i], line=dict(color=t["surface"], width=2)),
                    hovertemplate=f"<b>%{{y}}</b><br>{name}: %{{x}}<extra></extra>")
    fig.update_layout(barmode="stack", bargap=0.35)
    fig.update_xaxes(title_text="Care events")
    fig.update_yaxes(showgrid=False)
    return _layout(fig, t, height=380)
