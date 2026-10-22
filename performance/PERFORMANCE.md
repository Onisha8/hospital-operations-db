# Performance Tuning

**Summary.** 10 targeted indexes cut logical reads by **7× to 2,498×** on 12 of the 15 measured queries. The worst report (R5 shift rotation) went from **2.6 s to 6 ms**. Two control queries stay flat as predicted. The cost is measured too: 51 MB of index storage and **3.6× more I/O on bulk inserts** into the busiest table. A separate demo reproduces **parameter sniffing** (a 108× read blow-up), fixes it with `OPTION (RECOMPILE)`, and shows **Query Store** catching both plans.

| | |
|---|---|
| Workload | 15 queries: 10 reports (R1–R9), 2 lookups, analytics, a full admit→discharge workflow, a bulk insert |
| Data | ~1.39M rows (86k stays, 467k care events, 430k item charges) |
| Platform | SQL Server 2022 Developer, 8 cores, warm cache |
| Scripts | [`run_benchmark.ps1`](run_benchmark.ps1) · [`benchmark.sql`](benchmark.sql) · [`../sql/09_performance_indexes.sql`](../sql/09_performance_indexes.sql) · [`parameter_sniffing_demo.sql`](parameter_sniffing_demo.sql) |
| Raw results | [`results.md`](results.md) · execution plans in [`plans/before`](plans/before) and [`plans/after`](plans/after) (open `.sqlplan` files in SSMS) |

---

## 1. Method

1. **Baseline first.** Drop every tuning index (`IX_*`), leaving only primary keys and the constraint-backed unique indexes. Clear the plan cache (`DBCC FREEPROCCACHE`).
2. **Measure each query** after one warm-up run, as the average of 5 runs:
   - **logical reads** and **CPU** from `sys.dm_exec_requests` for the session, read before and after each run;
   - elapsed time;
   - the **cached execution plan** from `sys.dm_exec_query_plan`.
3. **Read the plans** to find the expensive operators, then design one index per access path.
4. **Re-measure** with identical parameter values and compare.

Logical reads are the headline metric: they're deterministic (±2 pages across reruns), while milliseconds vary with machine load. Results go to a temp table, so network transfer isn't measured. A calibration query (W00) measures the fixed 170-read cost of `SELECT ... INTO #sink`, and the table shows reads **net** of it.

## 2. Results

| Query | What it does | Reads before | Reads after | Change | ms before | ms after |
|---|---|---:|---:|---:|---:|---:|
| W04 | **R5** shift rotation, one day | 1,403,891 | 562 | **2,498× fewer** | 2,624 | 6 |
| W05 | **R1** bed occupancy on a past date | 176,070 | 981 | **179× fewer** | 393 | 20 |
| W13 | Current census with ward and bed | 178,373 | 2,521 | **71× fewer** | 226 | 24 |
| W01 | **R6** charge summary, one stay | 5,852 | 100 | **59× fewer** | 125 | 5 |
| W09 | Nursing chart, one stay | 2,674 | 61 | **44× fewer** | 77 | 1 |
| W03 | **R2** weekly admissions / discharges | 180,588 | 6,817 | **26× fewer** | 243 | 33 |
| W02 | **R3** discharge treatments, one stay | 2,635 | 101 | **26× fewer** | 55 | 4 |
| W14 | Full stay workflow (admit → charge → discharge) | 3,340 | 166 | **20× fewer** | 85 | <1 |
| W06 | **R8** ward history, one patient | 1,010 | 90 | **11× fewer** | 40 | 4 |
| W08 | Patient search by name | 1,531 | 213 | **7× fewer** | 20 | 3 |
| W07 | **R9** treatments without a physician | 4,580 | 1,384 | **3× fewer** | 102 | 6 |
| W12 | **R7** ward schedule, one day | 564 | 269 | 2× fewer | 16 | 3 |
| W10 | Monthly revenue, 12 months *(not indexed)* | 6,322 | 6,319 | no change | 39 | 40 |
| W11 | **R4** physician admits, all history *(control)* | 8,718 | 8,718 | no change | 158 | 150 |
| W15 | Bulk insert 10,000 care events *(write cost)* | 49,461 | 175,742 | **3.6× more** | 290 | 563 |

## 3. Diagnosis: what the plans showed

### The optimizer was building its own index on every run (W03, W04, W05, W13)
All four hot spots had the same operator in their baseline plan: an **Eager Index Spool**. This is SQL Server compensating for a missing index. On *every execution* it scans the whole table, copies the rows into a temporary index in tempdb, then runs its per-row seeks against that copy. Writing that worktable is where the reads go. For example, W04's 1.4M reads are about 540 times the 2,614 pages of the table it spooled.

| Query | Per-row probe in the query | Table spooled on every run | Reads |
|---|---|---|---:|
| W04 R5 shift rotation | each shift → that nurse's events that day | all 467k `NurseCareEvent` rows | 1,403,891 |
| W05 R1 occupancy | each bed → assignment covering the date | all 86k `BedAssignment` rows | 176,070 |
| W03 / W13 "latest bed for a stay" (`OUTER APPLY TOP 1 … ORDER BY StartDate DESC`) | each stay → its newest bed assignment | all 86k `BedAssignment` rows | ~180,000 |

An eager index spool in a plan is effectively a missing-index warning. The fix is to build that index permanently, keyed the way the probe searches. After tuning, none of the four plans contains an eager spool:

```sql
CREATE INDEX IX_BedAssignment_AdmissionID ON dbo.BedAssignment (AdmissionID, StartDate DESC) INCLUDE (BedID, EndDate);
CREATE INDEX IX_BedAssignment_BedID       ON dbo.BedAssignment (BedID, StartDate) INCLUDE (EndDate);
CREATE INDEX IX_NurseCareEvent_NurseID_EventAt ON dbo.NurseCareEvent (NurseID, EventAt) INCLUDE (AdmissionID, EventTypeCode);
```

Key order follows the predicates: **equality column first** (`NurseID`), **range or sort column second** (`EventAt`, `StartDate DESC` to match `TOP 1 … ORDER BY StartDate DESC`). `INCLUDE` adds exactly the columns the query reads, so there are no key lookups.

### Point lookups that scanned (W01, W02, W06, W09)
Fetching one stay's charges, treatments or care events scanned the whole child table, because SQL Server does **not** index foreign keys automatically. One index per stay → child path fixed all four. Where the report only aggregates, the index includes just the summed column (for example `INCLUDE (LineTotal)`). That keeps it narrow; the itemized bill reads ~5 extra columns through cheap key lookups.

### The filtered-index gotcha (W07)
R9 lists treatments **without** a physician, about 5% of rows. A filtered index holding only those rows is the textbook fit:

```sql
CREATE INDEX IX_TreatmentAdministration_NoPhysician
    ON dbo.TreatmentAdministration (AdministeredAt)
    INCLUDE (PhysicianID, AdmissionID, TreatmentID, Results, ChargedAmount)
    WHERE PhysicianID IS NULL;
```

The first version left `PhysicianID` out of `INCLUDE`, and **the optimizer ignored the index**: the plan still showed a clustered index scan (W07 stayed at 4,091 reads). For an `IS NULL` filter, the optimizer only treats the index as covering when the filter column is in it. Adding the column made the index usable: 102 ms → 6 ms. The remaining reads are per-row joins to `Patient` and `Admission`.

A related design fix was needed first: the R9 view originally exposed only a `CASE` flag (`HasTreatingPhysician = 'N'`). A predicate on an expression can't seek any index, so the view now also exposes the raw `PhysicianID` column.

### Writes got faster too (W14)
Indexes are usually a write tax, but the admit → charge → discharge workflow dropped from 3,340 to 166 reads. The procedures **read** before they write: "does this stay have an item charge?" (BR-34) and "find the current bed assignment" both scanned before. The real insert tax shows up in bulk loads (W15, below).

## 4. Trade-offs and what I deliberately didn't index

| Cost | Measured | Assessment |
|---|---|---|
| Storage | +51 MB of indexes on 85 MB of data. On `NurseCareEvent`, the two indexes (24.7 MB) are larger than the table (20.4 MB). | Acceptable at this size; the largest single item to revisit |
| Bulk insert I/O | W15: 3.6× reads, ~2× time | 10,000 events is ~40 days of real volume, loaded in 0.56 s. Row-at-a-time inserts in the workflow are unaffected (W14). |

**Not indexed, on purpose:**
- **W10 monthly revenue** reads about 20% of the two largest tables. A range scan would save little over the current parallel scan (40 ms), and it would put two more indexes on the two busiest insert tables. If analytics grows, a **nonclustered columnstore** index is the right tool, not more rowstore indexes.
- **W11 physician admits** aggregates all of history; a full scan is already optimal (control query).
- **W03 date filters**: the remaining cost is a 400-page scan of `Admission` caused by "admitted **or** discharged this week". Two more date indexes for a weekly report isn't worth it.
- **Catalog FKs** (`ItemID`, `TreatmentID`, `EventTypeCode`): only used when deleting a catalog entry.

**Considered:** clustering `NurseCareEvent` on `(AdmissionID, EventAt)` instead of the identity key. The nursing chart would become a clustered range seek with no secondary index, saving ~12 MB. I rejected it for now: inserts would land all over the table instead of at the end, causing page splits on the busiest insert table. It's worth re-testing with W15.

---

## 5. Parameter sniffing, RECOMPILE, index hints and Query Store

[`parameter_sniffing_demo.sql`](parameter_sniffing_demo.sql) creates a deliberately **non-covering** index on `NurseCareEvent (EventAt)` and a procedure that selects events in a date range. For 1 hour (21 rows), the best plan is Index Seek + Key Lookup. For 5 years (467k rows), it's a scan: 467k key lookups cost far more than reading the table once.

A procedure compiles for the parameters of its **first** call and reuses that plan:

| Scenario | Call | Rows | Plan used | Logical reads | ms |
|---|---|---:|---|---:|---:|
| A. Compiled for 1 hour | 1 hour | 21 | Seek + Key Lookup | 242 | 8 |
| | **5 years** | 467,095 | Seek + Key Lookup ❌ | **1,404,707** | **1,400** |
| B. Compiled for 5 years | 5 years | 467,095 | Clustered Index Scan | 12,955 | 170 |
| | **1 hour** | 21 | Clustered Index Scan ❌ | **17,289** | 171 |
| C. `OPTION (RECOMPILE)` | 1 hour | 21 | Seek + Key Lookup ✅ | 256 | 12 |
| | 5 years | 467,095 | Clustered Index Scan ✅ | 12,979 | 158 |
| D. `WITH (INDEX(...))` forced | 5 years | 467,095 | Seek + Key Lookup ❌ | 1,500,123 | 299 |

- **Sniffing:** the wrong cached plan costs **108×** more reads for the wide range (A), and **68×** more reads than needed for the narrow one (B).
- **`OPTION (RECOMPILE)`** picks the right plan every time. The price is a compile per call (a few ms of CPU). That's fine for a report run a few times a day, but wrong for a query called thousands of times a second; alternatives there are `OPTIMIZE FOR`, splitting into two procedures, or Query Store plan forcing.
- **Forcing an index hint** pins the plan no matter what the data says. It reproduced the worst case (D), which is why hints are a last resort.
- **Query Store** recorded the same query with both plans and their real costs, which is how a DBA would spot this regression in production:

| QueryID | PlanID | Plan | Executions | Avg reads | Min | Max |
|---|---|---|---:|---:|---:|---:|
| 657 | 330 | Index Seek + Key Lookup | 2 | 702,406 | 162 | 1,404,650 |
| 657 | 331 | Clustered Index Scan | 2 | 15,042 | 12,871 | 17,213 |

The demo removes its index and procedures when it finishes.

---

## 6. Reproduce

```powershell
.\run_sql.ps1                                        # full build (includes sql/09 indexes)
.\performance\run_benchmark.ps1                      # drop indexes -> before -> create -> after; writes results.md + plans
.\run_sql.ps1 -Files performance\parameter_sniffing_demo.sql
```

## 7. Course topics demonstrated

| ISM 6218 topic | Where |
|---|---|
| Execution plans, reading operator costs and executions | §3; `plans/before` vs `plans/after` |
| Indexing strategy, covering indexes with `INCLUDE` | `sql/09_performance_indexes.sql`, §3 |
| Filtered indexes | W07 and the IS NULL gotcha, §3 |
| Forcing index hints | Scenario D, §5 |
| `RECOMPILE` for query performance | Scenario C, §5 |
| Query Store | §5 |
| Clearing the cache between measurements | `DBCC FREEPROCCACHE` in `benchmark.sql` |
