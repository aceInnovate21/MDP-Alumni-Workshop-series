# Alberta Childcare Subsidy Audit — Dataset

**Workshop Series:** Applied Data Analytics — From Classroom to Industry (W2–W5)
**Platform:** Snowflake (load) → Power BI (report)
**Scenario:** A Ministry auditor suspects some licensed childcare operators are claiming
subsidies beyond their approved licensed capacity. Load the data, investigate, and report.

> ⚠️ **This is synthetic data.** Operators, facilities, license numbers, and claims are
> fabricated for teaching purposes. No real Alberta childcare provider is represented.

---

## Files

| File | Rows | Purpose |
|---|---|---|
| `operators.csv` | 40 | Licensed childcare providers — the master entity |
| `facilities.csv` | 53 | Physical sites; an operator may run several |
| `enrollment.csv` | 1,883 | Children enrolled, by facility / month / age band |
| `subsidy_claims.csv` | 613 | Monthly subsidy claims submitted per facility |
| `inspections.csv` | 79 | Compliance inspections and findings |
| `subsidy_claims_2026_Q1_BROKEN.csv` | 10 | **Deliberately malformed** — for the `ON_ERROR` demo |

Grain notes:
- `enrollment` grain = facility × month × age_band
- `subsidy_claims` grain = facility × month (**one duplicate is planted — see C**)
- `inspections` grain = one row per inspection event

---

## Schema

### operators.csv
| Column | Type | Notes |
|---|---|---|
| `operator_id` | TEXT | PK — `OP0001`… |
| `operator_name` | TEXT | ⚠️ some have leading/trailing whitespace |
| `operator_type` | TEXT | Non-Profit / Private / Municipal / School Board |
| `region` | TEXT | ⚠️ inconsistent casing + one typo |
| `license_number` | TEXT | `AB-######` |
| `license_status` | TEXT | Active / Probation / Expired |
| `licensed_capacity` | INT | ⚠️ 2 rows blank — the **denominator** of the whole audit |
| `license_start_date` | DATE | ⚠️ three different formats |
| `contact_email` | TEXT | |

### facilities.csv
| Column | Type | Notes |
|---|---|---|
| `facility_id` | TEXT | PK — `FAC0001`… |
| `operator_id` | TEXT | FK → operators ⚠️ one value doesn't exist |
| `facility_name` | TEXT | |
| `street_address` / `city` / `postal_code` | TEXT | |
| `room_count` | INT | |
| `opened_date` | DATE | |

### enrollment.csv
| Column | Type | Notes |
|---|---|---|
| `enrollment_id` | TEXT | PK |
| `facility_id` | TEXT | FK → facilities ⚠️ two rows orphaned |
| `enrollment_month` | TEXT | `YYYY-MM` |
| `age_band` | TEXT | Infant / Toddler / Preschool / Kindergarten / School-Age |
| `enrolled_count` | INT | ⚠️ contains negative and zero values |
| `subsidized_count` | INT | ⚠️ sometimes **exceeds** `enrolled_count` |
| `record_created` | DATE | ⚠️ mixed formats |

### subsidy_claims.csv
| Column | Type | Notes |
|---|---|---|
| `claim_id` | TEXT | PK |
| `facility_id` | TEXT | FK → facilities |
| `claim_month` | TEXT | `YYYY-MM` |
| `claimed_children` | INT | The audit numerator |
| `claim_amount` | TEXT | ⚠️ **not clean numeric** — some have `$` and `,` |
| `submitted_date` | DATE | ⚠️ mixed formats |
| `claim_status` | TEXT | Approved / Pending / Rejected |

### inspections.csv
| Column | Type | Notes |
|---|---|---|
| `inspection_id` | TEXT | PK |
| `operator_id` | TEXT | FK → operators |
| `inspection_date` | DATE | |
| `inspector_id` | TEXT | |
| `result` | TEXT | Pass / Conditional / Fail |
| `finding_summary` | TEXT | "Capacity exceeded" corroborates the audit finding |
| `follow_up_required` | TEXT | Y / N |

---

## Reference: subsidy rate by age band

| Age band | $/child/month |
|---|---|
| Infant | 1,100 |
| Toddler | 900 |
| Preschool | 700 |
| Kindergarten | 500 |
| School-Age | 300 |

---

## 🔒 INSTRUCTOR NOTES — Planted Issues

*(Do not distribute this section to students.)*

### The headline finding (A) — capacity breach

Three operators were **deliberately** built to over-claim persistently:

| Operator | Licensed capacity | Months in breach | Peak claimed |
|---|---|---|---|
| **OP0004** | 50 | 9 | 121 |
| **OP0017** | 50 | 9 | 86 |
| **OP0029** | 50 | 7 | 100 |

**The teaching moment:** a handful of *other* operators (OP0003, OP0018, OP0025, OP0026,
OP0032) breach in only **1–2 months** — natural noise from random generation. This is a gift.
Students must decide: *is a one-month breach a finding, or is it noise?* A persistent
9-month pattern is a finding. A single month is a question. **Don't hand them the answer —
make them argue it.** This is exactly the judgment call a real analyst makes.

**Corroboration:** OP0004 and OP0029 also have `Capacity exceeded` inspection findings.
Two independent sources agreeing is what turns a hypothesis into a report. Note OP0017
does *not* — so evidence is uneven, which is realistic.

### Data quality issues

| # | Issue | Where | Why it's there |
|---|---|---|---|
| **B** | Orphaned facility | `FAC0053` → `OP9999` | Referential integrity; breaks an inner join silently |
| **C** | Duplicate claim | `FAC0003` / `2025-07` | Double-billing; inflates totals if not de-duped |
| **D** | Orphaned enrollment | `FAC8888` (2 rows) | FK violation from the other direction |
| **E** | Dirty region values | `edmonton`, `EDMONTON`, `" Calgary"`, `"calgary "`, `Nrth` | A naive `GROUP BY region` produces 10 groups instead of 5 |
| **F** | Mixed date formats | `03/14/2019`, `2020/07/01`, `15-08-2018` | Parse hazard on load |
| **G** | NULL `licensed_capacity` | `OP0008`, `OP0023` | The audit's **denominator** is missing — what do you do? |
| **H** | Impossible values | negative & zero `enrolled_count`; `subsidized_count > enrolled_count` | Validation rules that should exist but don't |
| **I** | Text `claim_amount` | `$12,450.00`, `9,150.00` | `SUM()` fails or silently coerces |
| **J** | Whitespace in names | 2 operators | Breaks joins and `GROUP BY` on name |
| **K** | Enrollment, no claims | `FAC0013` | **Under**-claiming — the opposite anomaly. Nobody looks for this. |
| **L** | Broken CSV | `subsidy_claims_2026_Q1_BROKEN.csv` | 4 of 10 rows bad → the `COPY INTO` / `ON_ERROR` demo |

### The broken file (L) — what's wrong with each row

| Row | Defect |
|---|---|
| `CLM900003` | `claimed_children = NOT_A_NUMBER` (bad int) |
| `CLM900004` | Too few columns (6 of 7) |
| `CLM900005` | Too many columns (8 of 7) |
| `CLM900006` | `submitted_date = not-a-date` |
| `CLM900008` | NULL `claimed_children` |
| `CLM900009` | Quoted comma inside `claim_amount` — **valid CSV, tests quoting** |

**Demo arc:** run `COPY INTO` → it fails → `VALIDATE` to inspect → discuss `ON_ERROR`
options (`ABORT_STATEMENT` / `CONTINUE` / `SKIP_FILE`) → **make the point that
`ON_ERROR = CONTINUE` silently drops 4 subsidy claims, and in a compliance context that is
not a shortcut, it's a defect.** Fix the file properly instead.

---

## Arc across the workshop series

| Workshop | What this data does |
|---|---|
| **W2** | Raw + flat. Stages, `COPY INTO`, `ON_ERROR`, profiling, first capacity-breach query. **Ends on the pain:** 4 joins, slow, brittle, rerun monthly. |
| **W3** | Model it. Star schema (fact: claims, enrollment; dims: operator, facility, date, age band, region), clustering, pruning, materialized views. |
| **W4** | Visualize it. Power BI on the modeled layer — breach dashboard, region slicers, trend. |
| **W5** | Present it. The audit finding to a Deputy Minister: what we found, how confident we are, what we recommend. |

The planted anomalies are not just W2 exercises — they are the **narrative payload** that
survives to the W5 presentation. That's what makes this one project instead of four labs.
