/* ═══════════════════════════════════════════════════════════════════════════
   WORKSHOP 3 — SCRIPT 03
   BUILDING THE FACT TABLE

   ---------------------------------------------------------------------------
   THE FACT TABLE — the centre of the star
   ---------------------------------------------------------------------------

   fact_subsidy_claims is the heart of the model. Every row is ONE EVENT:
   a subsidy claim, for one facility, in one month.

   It holds two kinds of column:
     · MEASURES        — the numbers you add up (claimed_children, claim_amount)
     · SURROGATE KEYS  — integer links out to the dimensions (operator_key,
                          facility_key, date_key)

   That's it. No names, no regions, no descriptions — those live in the
   dimensions. The fact is long and narrow; the dimensions are wide and short.

   ---------------------------------------------------------------------------
   ★ GRAIN — the single most important decision in the whole model
   ---------------------------------------------------------------------------

   "Grain" = what ONE ROW of the fact table means. Decide it first, in words,
   before writing anything:

       "One row = one subsidy claim, for one facility, for one month."

   Every measure must be true AT THAT GRAIN. Every question you can ask is
   limited by it. Get the grain wrong and every number downstream is wrong.

   This is the SAME discipline as W2's "frame the question" — deciding grain
   IS deciding what question the table can answer.

   ---------------------------------------------------------------------------
   ★ THE GRAIN PROBLEM WE ALREADY KNOW ABOUT
   ---------------------------------------------------------------------------

   We found in W2 that FAC0003 / 2025-07 has TWO claims (the planted
   double-billing). If our grain is "one row per facility per month," that
   duplicate VIOLATES the grain.

   We do NOT silently sum it away. We keep every claim row (the fact is at
   claim grain, and the duplicate is a real event worth seeing) — but we FLAG
   it, so the model itself surfaces the anomaly. The model doesn't hide
   problems; it makes them visible.

   ═══════════════════════════════════════════════════════════════════════════ */

USE ROLE      SYSADMIN;
USE WAREHOUSE mdp_wh;
USE DATABASE  childcare_audit;
USE SCHEMA    analytics;


/* ───────────────────────────────────────────────────────────────────────────
   Create the fact table
   ─────────────────────────────────────────────────────────────────────────── */

CREATE OR REPLACE TABLE fact_subsidy_claims (
    claim_id            VARCHAR,      -- degenerate dimension: the source claim id,
                                      --   kept on the fact for traceability
    -- ── surrogate keys to the dimensions ──
    operator_key        INT,
    facility_key        INT,
    date_key            INT,
    -- ── measures ──
    claimed_children    INT,
    claim_amount        NUMBER(12,2),
    -- ── attributes specific to this event ──
    claim_status        VARCHAR,
    -- ── data-quality flags surfaced BY the model ──
    is_duplicate_grain  BOOLEAN       -- TRUE if this facility+month has >1 claim
);


/* ───────────────────────────────────────────────────────────────────────────
   Load the fact — resolving business keys to surrogate keys
   ───────────────────────────────────────────────────────────────────────────

   This is where the model comes together. For each raw claim we:
     1. clean the measures ($ and commas off the amount, text→number)
     2. look up the facility_key   (raw facility_id  → dim_facility)
     3. look up the date_key       (raw claim_month  → dim_date)
     4. ★ look up the operator_key — and this is the SCD-AWARE join ★

   ★ THE SCD-AWARE JOIN — the payoff of all that Type-2 work in script 02:

     dim_operator now has TWO rows for OP0004 (capacity 50 before June,
     40 after). We must attach each claim to the version that was IN FORCE
     in that claim's month. So we don't just join on operator_id — we also
     require the claim's month to fall between the dimension row's
     valid_from and valid_to.

     That single BETWEEN is what makes the audit judge each month against the
     capacity that actually applied.
*/

INSERT INTO fact_subsidy_claims
WITH cleaned AS (
    SELECT
        c.claim_id,
        f.operator_id,
        c.facility_id,
        c.claim_month,
        TRY_TO_NUMBER(c.claimed_children)                                      AS claimed_children,
        TRY_TO_NUMBER(REPLACE(REPLACE(c.claim_amount, '$', ''), ',', ''))      AS claim_amount,
        c.claim_status
    FROM raw.raw_subsidy_claims c
    LEFT JOIN raw.raw_facilities f ON c.facility_id = f.facility_id
),
flagged AS (
    SELECT
        cleaned.*,
        COUNT(*) OVER (PARTITION BY facility_id, claim_month) > 1  AS is_duplicate_grain
    FROM cleaned
)
SELECT
    fl.claim_id,
    op.operator_key,                 -- ★ SCD-resolved below
    fa.facility_key,
    dd.date_key,
    fl.claimed_children,
    fl.claim_amount,
    fl.claim_status,
    fl.is_duplicate_grain
FROM flagged fl
LEFT JOIN dim_facility fa
       ON fl.facility_id = fa.facility_id
LEFT JOIN dim_date dd
       ON fl.claim_month = dd.claim_month
LEFT JOIN dim_operator op
       ON  fl.operator_id = op.operator_id
       -- ★ SCD Type 2 join: pick the operator version in force that month
       AND TO_DATE(fl.claim_month || '-01', 'YYYY-MM-DD')
           BETWEEN op.valid_from AND op.valid_to;


/* ───────────────────────────────────────────────────────────────────────────
   VERIFY THE FACT
   ─────────────────────────────────────────────────────────────────────────── */

-- Row count — should match the source claims exactly (we keep every event).
SELECT COUNT(*) AS fact_rows FROM fact_subsidy_claims;
--   EXPECT: 613

-- Did every claim resolve all three keys? (No NULL keys = clean model.)
SELECT
    COUNT(*)                                                    AS total,
    COUNT(operator_key)                                         AS has_operator,
    COUNT(facility_key)                                         AS has_facility,
    COUNT(date_key)                                             AS has_date
FROM fact_subsidy_claims;
--   EXPECT: all four numbers = 613. If has_operator < 613, an SCD window
--           has a gap — a claim month fell outside every valid_from/valid_to.

-- The duplicate-grain flag caught our planted double-billing:
SELECT claim_id, facility_key, date_key, claimed_children, is_duplicate_grain
FROM fact_subsidy_claims
WHERE is_duplicate_grain = TRUE
ORDER BY date_key;
--   EXPECT: 2 rows — both claims for FAC0003 / 2025-07. The model SURFACES
--           the anomaly instead of hiding it.

-- ★ Prove the SCD join worked: OP0004's claims should link to different
--   capacities depending on month.
SELECT
    dd.claim_month,
    o.operator_id,
    o.licensed_capacity      AS capacity_in_force,   -- 50 before June, 40 after
    SUM(f.claimed_children)  AS children_claimed
FROM fact_subsidy_claims f
JOIN dim_operator o ON f.operator_key = o.operator_key
JOIN dim_date     dd ON f.date_key     = dd.date_key
WHERE o.operator_id = 'OP0004'
GROUP BY 1, 2, 3
ORDER BY dd.claim_month;
--   👀 Watch capacity_in_force flip from 50 to 40 at 2025-06. The fact is
--      wired to the right history automatically. That's the model working.


/* ═══════════════════════════════════════════════════════════════════════════
   WHAT WE'VE BUILT — the STAR
   ═══════════════════════════════════════════════════════════════════════════

                         dim_date
                            │
        dim_operator ── fact_subsidy_claims ── dim_facility
        (SCD Type 2)        │
                     (measures + keys)

   One fact in the middle. Dimensions radiating out. Join on clean integer
   keys. No TRIM, no UPPER, no TRY_TO_NUMBER anywhere — that all happened once,
   upstream, in the dimensions.

   This shape is a STAR SCHEMA. Next we put it to work.

   TAKEAWAYS
   ✔ The fact holds MEASURES + surrogate KEYS. Descriptions live in dims.
   ✔ GRAIN is decided first, in words. Every measure must hold at that grain.
   ✔ The model SURFACES data-quality problems (duplicate flag) — never hides them.
   ✔ The SCD-aware join (month BETWEEN valid_from AND valid_to) attaches each
     fact to the dimension version that was true at the time.

   NEXT: 04_two_views.sql — one model, two very different questions.
   ═══════════════════════════════════════════════════════════════════════════ */
