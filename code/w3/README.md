# Workshop 3 — Dimensional Modelling
### Star Schema · Surrogate Keys · SCD Type 2 · Two Views on One Model

**Applied Data Analytics: From Classroom to Industry** — MDP Workshop Series
Duration: 2 hours · Platform: Snowflake · Builds directly on Workshop 2

---

## The story

W2 ended on a cliffhanger: the audit query worked but was a **liability** — three
joins rewritten every time, cleaning scattered everywhere, fragile, run monthly by
hand, business logic trapped in a `HAVING` clause.

W3 fixes it properly. We reshape the raw data into a **star schema**, then build
**two views** on top — proving the core value of a model: *build once, ask anything.*

---

## Run order

| # | Script | Time | What it does |
|---|---|---|---|
| **01** | `01_recap_and_problem.sql` | 15 min | Re-run the W2 audit mess. Name the fix: separate *cleaning* (the model) from *the question* (the view). |
| **02** | `02_dimensional_model_dims.sql` | 40 min | Build the dimensions. **Surrogate keys**, all W2 cleaning done once, and **SCD Type 2** on operator capacity. |
| **03** | `03_dimensional_model_fact.sql` | 30 min | Build the fact table. **Grain**, the duplicate-grain flag, and the **SCD-aware join**. |
| **04** | `04_two_views.sql` | 25 min | **The payoff.** Two views — audit (compliance) + funding equity (policy) — on one model. View vs materialized view. |

Plus ~10 min bridge to W4. Total ≈ 2 hours.

---

## Prerequisite

The W2 `RAW` schema must be loaded (`RAW_OPERATORS`, `RAW_FACILITIES`,
`RAW_SUBSIDY_CLAIMS`, etc.). If it isn't, re-run W2 scripts 02–03 first. W3 builds
the `ANALYTICS` schema **from** `RAW` and never touches `RAW`.

---

## What gets built

```
                         dim_date  (12 rows: 2025-01 … 2025-12)
                            │
     dim_operator ──── fact_subsidy_claims ──── dim_facility  (53)
     (41 rows: 40 +      (613 rows =              (surrogate keys)
      1 SCD history)      measures + keys)
```

- **dim_operator** — the star of the show. Surrogate key (`operator_key`), all cleaning
  done here once (region → 5 clean values, capacity → real number), and **SCD Type 2**:
  OP0004's capacity changes 50 → 40 mid-year, kept as *two* rows with valid-from/to.
- **fact_subsidy_claims** — grain = one row per facility per month. Measures + surrogate
  keys. Flags the planted duplicate (FAC0003/2025-07) instead of hiding it. Joins to the
  **SCD-correct** operator version per month.

---

## Expected results (verified against the real data)

**View 1 — `v_capacity_audit`:** the persistent breachers, now SCD-aware.
Note Chinook House appears **twice** — 4 months breaching against capacity 50 (Jan–May)
and 7 months against 40 (Jun–Dec), because its licence was cut mid-year. That's the SCD
model working. Maple Place (~$149K) and Harmony (~$89K) as before.

**View 2 — `v_funding_by_region`:** funding-per-child by region, ranging roughly
$671 (Edmonton) to $720 (South) — a real fairness question for a policymaker.

---

## Instructor notes — the beats that matter

**① The "why a model" moment (Script 01).** Re-run the W2 audit. Point at every `TRIM`,
`UPPER`, `TRY_TO_NUMBER`, and join — *all inside the question logic*. The fix is to split
the two jobs: clean/structure the data (the model) vs ask the question (the view).

**② Surrogate keys (Script 02).** The model mints its own integer keys; the source
`OP0001` becomes just an attribute. Protects you when the source changes.

**③ SCD Type 2 (Script 02) — the centrepiece.** Run the OP0004 capacity change live.
Two rows, each stamped with when it applied. The line to land: *for an audit, you judge
each month against the capacity that was in force THAT month — overwrite (Type 1) would
make you audit the past against the present, and that's how you accuse someone wrongly.*

**④ Grain (Script 03).** Decide it in words first: "one row = one facility, one month."
The duplicate FAC0003/2025-07 violates the grain — the model **flags** it, doesn't hide it.

**⑤ The SCD-aware join (Script 03).** The `month BETWEEN valid_from AND valid_to` clause
is what attaches each claim to the right capacity version. Prove it with the OP0004 query —
watch `capacity_in_force` flip 50 → 40 at June.

**⑥ Two views, one model (Script 04) — the whole point.** Same star answers a compliance
question and a policy question, each in a few clean lines. Contrast with W2's 30-line
single-purpose mess. And neither view cleans anything — it was all done once, upstream.

**⑦ View vs materialized view.** Regular view = always fresh, recomputed each read (right
for a monthly audit). Materialized = precomputed, fast for many readers (right for a
dashboard). Let them choose per view.

---

## The bridge to W4

Everything's fixed — clean, repeatable, logic in named objects, answers more than we asked.
But it's still a **grid of numbers in a SQL worksheet**. The Deputy Minister doesn't open
Snowflake. W4: connect Power BI to these two views — a breach dashboard and a regional
funding map.

---

*Synthetic data. No real Alberta childcare operator is represented.*
