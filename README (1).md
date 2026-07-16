# Workshop 2 — Script Package
### SQL Foundations & Problem Framing · Snowflake

**Applied Data Analytics: From Classroom to Industry** — MDP Workshop Series
Duration: 2 hours · Platform: Snowflake (free trial) · Dataset: Alberta childcare subsidy audit

---

## ⚠️ Read this first

> ### **NEVER ADD A CREDIT CARD TO YOUR SNOWFLAKE TRIAL.**
>
> A trial account has **no payment method attached**. When free credits run out,
> the account simply stops. It cannot bill you — there is nothing to charge.
>
> The moment you add a card, that protection is gone.
>
> Do not add a card. Not "just to be safe." Not because a prompt asks nicely.

Your real risk is **running out of trial credits before Workshops 3, 4 and 5** — usually
by leaving a warehouse running overnight. Script 01 exists to make that impossible.

---

## Run order — do not skip, do not reorder

| # | Script | Time | What it does |
|---|---|---|---|
| **01** | `01_cost_control.sql` | 10 min | **RUN FIRST.** X-Small warehouse, 60s auto-suspend, resource monitors with hard caps. |
| **02** | `02_setup_and_context.sql` | 10 min | Database, schemas, RAW tables. Context-as-state (breaks on purpose). |
| **03** | `03_stages_and_loading.sql` | 25 min | Stages, file formats, `COPY INTO`, idempotency, **the `ON_ERROR` arc**. |
| **04** | `04_profiling_and_audit.sql` | 40 min | Profile the data, frame the question, find the fraud, judge the evidence. |
| **05** | `05_snowflake_deep_dive.sql` | 30 min | Caching, query profile, scale-up vs out, **Time Travel**, **zero-copy clone**, RBAC. |

**Total ≈ 115 min.** Trim Part 7 (RBAC) in Script 05 if you're short.

---

## Setup before the session

1. Students create a **free Snowflake trial** at `signup.snowflake.com`
   → Standard edition is fine. **No credit card.**
2. Download the dataset (6 CSVs) — see `childcare_dataset/`
3. Have `01_cost_control.sql` ready to paste **before anything else happens**

### Loading the files — use the Snowsight UI

`PUT` is a **client-side** command and **does not work in the Snowsight web worksheet.**
It cannot reach a browser's filesystem. Don't fight this live.

**Do this instead:**

> Data ► Databases ► `CHILDCARE_AUDIT` ► `RAW` ► Stages ► `STG_CHILDCARE`
> ► **+ Files** ► select all 6 CSVs ► Upload

Same result, zero install. Script 03 includes the SnowSQL `PUT` commands as reference
for anyone who wants the "real" CLI path afterwards.

---

## Expected row counts — verify before proceeding

| Table | Rows |
|---|---|
| `raw_operators` | **40** |
| `raw_facilities` | **53** |
| `raw_enrollment` | **1,883** |
| `raw_subsidy_claims` | **613** |
| `raw_inspections` | **79** |

**If the numbers differ, stop.** Something loaded wrong and every downstream number will
be wrong too. Diagnose it before moving on.

---

## 🔒 Instructor notes — the beats that matter

*(Don't distribute this section.)*

### The three moments the workshop is actually built around

**① The `ON_ERROR = CONTINUE` moment** — Script 03, Step 8

Load the broken file with `CONTINUE`. It reports **SUCCESS**. It also silently discarded
four subsidy claims — *public money, submitted by real operators*. Stop the room here.

> "That COPY said SUCCESS and threw away four claims. If you build a dashboard on this,
> the total is wrong, there is no error, and it goes to a Deputy Minister with your name
> on it. `ON_ERROR = CONTINUE` is not a fix. It is a decision to lose data."

Then show the quarantine pattern. **This is the professional's answer and almost no junior
candidate knows it.**

**② The threshold moment** — Script 04, Section 3.2b

The query returns **8 operators** over capacity. Only **3** are findings.

Run the distribution query. The data is **bimodal** — 4 operators breach once, 1 breaches
twice, then *nothing at 3, 4, 5, 6*, then 1 at seven months and 2 at nine.

> "There is a hole in the distribution. I didn't pick 3 because it felt right —
> I put the line in the empty space the data gave me."

Make them sit with it: **if you report all 8 as fraud, you have accused five legitimate
childcare non-profits of defrauding the province.** That's not a technical error. That's a
professional failure.

> **The query returns 8 rows. The analysis decides 3 of them matter.
> A machine can do the first. Only you can do the second. That's why you have a job.**

**③ Time Travel / `UNDROP`** — Script 05, Part 5

Delete most of a year's subsidy claims with a missing `WHERE`. Let the panic land.
Then `UNDROP TABLE` — one word. Then clone the whole database instantly, for free.

This is the "wow." Anyone who's used Postgres will feel it.

### The validated findings

| Operator | Name | Cap | Months | Peak | Est. excess $ | Inspection |
|---|---|---|---|---|---|---|
| **OP0004** | Chinook House | 50 | **9** | 121 | **$206,081** | Conditional — *Capacity exceeded* ✓ |
| **OP0017** | Maple Place | 50 | **9** | 86 | **$149,098** | Pass — *No findings* ✗ |
| **OP0029** | Harmony Beginnings | 50 | **7** | 100 | **$88,754** | Fail ×2 — *Capacity exceeded* ✓✓ |

**≈ $444K total.** Note the evidence is **deliberately uneven**: OP0017 breached nine months
but passed inspection clean. Students must report that honestly rather than overclaiming.
That contradiction is the point — it's what a real case looks like.

### Other planted issues

- **Region column** → 5 real Alberta regions appear as **10 groups** (`edmonton`, `EDMONTON`, `" Calgary"`, `Nrth`…). The fastest possible proof of why you profile first.
- **NULL `licensed_capacity`** (OP0008, OP0023) → the audit's *denominator* is missing. `claimed > NULL` is NULL, so `WHERE` **drops them silently**. They vanish from the audit and nobody is told. **The gap is itself a finding.**
- **Orphans both ways** — `FAC0053 → OP9999` (no such operator), enrollment → `FAC8888` (no such facility). An `INNER JOIN` hides both.
- **Duplicate claim** — `FAC0003 / 2025-07`, two claim IDs. Double-billing.
- **Text `claim_amount`** — `$12,450.00`, `9,150.00`. `SUM()` fails or misleads.
- **Under-claiming** — `FAC0013` enrolled **485** subsidy-eligible children and filed **zero** claims. *Nobody asked them to look for this.* Finding it is how you stop being "the person who runs queries."

---

## The bridge to Workshop 3 — end on this

Run the final audit query. Then be honest about it:

- **Three joins** to answer one question — and you rewrite them *every time*
- `TRIM()` / `UPPER()` / `TRY_TO_NUMBER()` **scattered through the logic** — forget one in one query and two queries return different answers, both looking correct
- **Fragile** — someone renames a column and everything breaks silently
- **Monthly** — you'll rerun this forever
- **The business logic is trapped in a query** — "what is a breach?" is a *policy decision* living in a `HAVING` clause on your laptop

> *"This is not a SQL problem. We already won the SQL. This is a **structure** problem.
> The data is organised for the system that collected it — not for the questions we keep
> asking. Next week we fix that properly."*

**W3:** dimensional modelling · clustering & pruning · materialized views · streams & tasks.
That query becomes ~4 lines, runs faster, and survives a schema change.

---

## SnowPro Core coverage

Say this out loud — it's a resume line and it's true.

**Covered in W2:** three-layer architecture · virtual warehouses & sizing · credit model &
resource monitors · micro-partitions · the three caches · stages (all four types) · file
formats · `COPY INTO` & load metadata · `ON_ERROR` · `VALIDATE` · Time Travel · `UNDROP` ·
zero-copy cloning · RBAC & future grants · query profile

**Coming in W3:** clustering keys · pruning · materialized views · streams & tasks ·
semi-structured data (`VARIANT`) · dimensional modelling

> *"After next week you'll have touched most of what SnowPro Core covers. If you want the
> cert, you'll be revising — not starting from zero."*

---

## Cost safety recap

| Layer | Setting |
|---|---|
| Warehouse size | `XSMALL` — 1 credit/hr, the floor |
| Auto-suspend | **60 seconds** — the line that actually saves you |
| Auto-resume | `TRUE` — so suspending costs nothing |
| Warehouse monitor | 5 credits → `SUSPEND` @100%, `SUSPEND_IMMEDIATE` @110% |
| Account monitor | 10 credits → catches `COMPUTE_WH` and anything you forgot |

**Panic button:**
```sql
ALTER WAREHOUSE mdp_wh SUSPEND;
ALTER WAREHOUSE IF EXISTS COMPUTE_WH SUSPEND;
```

Suspending loses **nothing**. Storage is separate from compute — that's the whole
architectural point, and it's the first thing Script 05 teaches.

---

*Synthetic data. No real Alberta childcare operator is represented.*
