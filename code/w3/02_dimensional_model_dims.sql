/* ═══════════════════════════════════════════════════════════════════════════
   WORKSHOP 3 — SCRIPT 02
   BUILDING THE DIMENSIONS  (surrogate keys + SCD Type 2)

   ---------------------------------------------------------------------------
   THE TWO WORDS: FACT and DIMENSION
   ---------------------------------------------------------------------------

   A dimensional model splits the world into exactly two kinds of table:

     FACT       — the EVENTS you measure.        "A subsidy claim happened."
                  Numbers you add up (measures) + links to the who/what/when.
                  Long, narrow, grows forever.

     DIMENSION  — the CONTEXT you slice by.       "This operator, this month."
                  Descriptive attributes. Who, what, where, when.
                  Wide, short, changes slowly.

   Every business question is: "add up some FACT, sliced by some DIMENSIONS."
     "excess claims BY operator BY month"  → fact=claims, dims=operator,date
     "funding BY region"                   → fact=claims, dims=operator(region)

   ---------------------------------------------------------------------------
   TWO IDEAS WE'LL USE WHILE BUILDING
   ---------------------------------------------------------------------------

   SURROGATE KEYS
     The source gives us 'OP0001' as an operator id. That's a BUSINESS key —
     it comes from the source system and we don't control it. If the source
     renumbers, merges, or reuses ids, our whole model breaks.

     So the model mints its OWN key — a meaningless integer, operator_key —
     and everything joins on THAT. The business key becomes just another
     attribute. This is a surrogate key, and it is standard practice.

   SLOWLY CHANGING DIMENSIONS (SCD)
     An operator's licensed_capacity can CHANGE. They expand, they get
     downgraded after an inspection. What do we do when it changes?

       SCD Type 1 — OVERWRITE. Keep only the current value. History is lost.
       SCD Type 2 — ADD A ROW. Keep the old value AND the new one, each with
                    a valid-from / valid-to date and an is_current flag.

     ★ For an AUDIT, Type 2 is not optional. If an operator was licensed for
       50 in January and 80 in June, a January claim must be judged against
       50 — the capacity THAT MONTH, not today's. Type 1 would make you
       audit the past against the present. That's how you accuse someone
       wrongly, or miss a real breach.

   ═══════════════════════════════════════════════════════════════════════════ */

USE ROLE      SYSADMIN;
USE WAREHOUSE mdp_wh;
USE DATABASE  childcare_audit;
USE SCHEMA    analytics;         -- ★ the clean layer we created in W2, never used. Now it earns its place.

-- Reminder of the layering:
--   RAW       = source as-is, messy, never touched.       (bronze)
--   ANALYTICS = clean, modelled, trustworthy, reportable.  (silver/gold)
-- We build FROM raw INTO analytics. Raw is never modified.


/* ═══════════════════════════════════════════════════════════════════════════
   DIM 1 — dim_date
   ═══════════════════════════════════════════════════════════════════════════
   The simplest dimension, and every model has one. Our grain is monthly, so
   one row per month. A date dimension lets you slice by year, quarter, month
   name — without writing date functions in every query.
*/

CREATE OR REPLACE TABLE dim_date (
    date_key        INT,            -- surrogate key: YYYYMM as an integer
    claim_month     VARCHAR,        -- business key: 'YYYY-MM' (matches source)
    year            INT,
    month_num       INT,
    month_name      VARCHAR,
    quarter         VARCHAR
);

INSERT INTO dim_date
WITH months AS (
    SELECT DISTINCT claim_month FROM raw.raw_subsidy_claims
    WHERE claim_month IS NOT NULL
)
SELECT
    CAST(REPLACE(claim_month, '-', '') AS INT)                 AS date_key,   -- '2025-07' → 202507
    claim_month,
    CAST(SPLIT_PART(claim_month, '-', 1) AS INT)               AS year,
    CAST(SPLIT_PART(claim_month, '-', 2) AS INT)               AS month_num,
    MONTHNAME(TO_DATE(claim_month || '-01', 'YYYY-MM-DD'))     AS month_name,
    'Q' || CEIL(CAST(SPLIT_PART(claim_month,'-',2) AS INT)/3.0) AS quarter
FROM months;

SELECT * FROM dim_date ORDER BY date_key;
--   EXPECT: 12 rows, 202501 … 202512.


/* ═══════════════════════════════════════════════════════════════════════════
   DIM 2 — dim_operator  ★ WITH SCD TYPE 2 ★
   ═══════════════════════════════════════════════════════════════════════════
   This is the important one — the audit's context lives here.

   ★ ALL THE W2 CLEANING HAPPENS HERE, ONCE:
       TRIM(operator_name)   — the whitespace
       UPPER(TRIM(region))   — the 10 spellings of 5 regions
       fix the 'Nrth' typo   — a mapping CASE, because TRIM/UPPER can't
       TRY_TO_NUMBER(cap)    — text → real number

   After tonight, NO query ever cleans an operator again. They just read
   dim_operator and it is already clean. That is the entire point of a model.
*/

CREATE OR REPLACE TABLE dim_operator (
    operator_key      INT            AUTOINCREMENT START 1 INCREMENT 1,  -- ★ surrogate key
    operator_id       VARCHAR,        -- business key from source
    operator_name     VARCHAR,        -- cleaned
    operator_type     VARCHAR,
    region            VARCHAR,        -- cleaned + typo-fixed
    license_number    VARCHAR,
    license_status    VARCHAR,        -- SCD-tracked
    licensed_capacity INT,            -- SCD-tracked (the audit's denominator)
    -- ── SCD Type 2 bookkeeping ──
    valid_from        DATE,
    valid_to          DATE,           -- NULL / 9999-12-31 = still current
    is_current        BOOLEAN
);

-- Load the CURRENT version of every operator (valid from the start of our data).
INSERT INTO dim_operator
    (operator_id, operator_name, operator_type, region, license_number,
     license_status, licensed_capacity, valid_from, valid_to, is_current)
SELECT
    operator_id,
    TRIM(operator_name)                                  AS operator_name,
    operator_type,
    -- clean the region: trim, upper, then map the known typo
    CASE UPPER(TRIM(region))
        WHEN 'NRTH' THEN 'NORTH'
        ELSE UPPER(TRIM(region))
    END                                                  AS region,
    license_number,
    license_status,
    TRY_TO_NUMBER(licensed_capacity)                     AS licensed_capacity,
    '2025-01-01'::DATE                                   AS valid_from,
    '9999-12-31'::DATE                                   AS valid_to,
    TRUE                                                 AS is_current
FROM raw.raw_operators;

-- Confirm the clean region values — 5 groups now, not 10.
SELECT region, COUNT(*) AS operators FROM dim_operator GROUP BY 1 ORDER BY 1;
--   EXPECT: CALGARY, CENTRAL, EDMONTON, NORTH, SOUTH — exactly 5. No 'Nrth'.


/* ── 🔴 LIVE DEMO: SCD TYPE 2 IN ACTION ─────────────────────────────────────
   Scenario: after a June inspection, operator OP0004 (Chinook House) has its
   licensed capacity REDUCED from 50 to 40, effective 2025-06-01.

   With SCD Type 2 we do NOT overwrite. We:
     1. close out the old row (valid_to = 2025-05-31, is_current = FALSE)
     2. insert a NEW row with the new value (valid_from = 2025-06-01, current)

   Now the table holds BOTH truths, each stamped with when it applied.
*/

-- Step 1: close the current row.
UPDATE dim_operator
SET valid_to   = '2025-05-31'::DATE,
    is_current = FALSE
WHERE operator_id = 'OP0004'
  AND is_current  = TRUE;

-- Step 2: insert the new version (capacity 40 from June).
INSERT INTO dim_operator
    (operator_id, operator_name, operator_type, region, license_number,
     license_status, licensed_capacity, valid_from, valid_to, is_current)
SELECT
    operator_id, TRIM(operator_name), operator_type,
    CASE UPPER(TRIM(region)) WHEN 'NRTH' THEN 'NORTH' ELSE UPPER(TRIM(region)) END,
    license_number, license_status,
    40                                AS licensed_capacity,   -- the NEW capacity
    '2025-06-01'::DATE                AS valid_from,
    '9999-12-31'::DATE                AS valid_to,
    TRUE                              AS is_current
FROM raw.raw_operators
WHERE operator_id = 'OP0004';

-- Look at OP0004 now: TWO rows, the full history.
SELECT operator_key, operator_id, operator_name, licensed_capacity,
       valid_from, valid_to, is_current
FROM dim_operator
WHERE operator_id = 'OP0004'
ORDER BY valid_from;

/*  👀 TWO ROWS for one operator:
        cap 50, valid 2025-01-01 → 2025-05-31, is_current = FALSE
        cap 40, valid 2025-06-01 → 9999-12-31, is_current = TRUE

    ★ THIS is why SCD Type 2 matters for an audit. A claim from March 2025
      will join to the 50-capacity row (that's what applied in March). A claim
      from August will join to the 40-capacity row. Each month is judged
      against the capacity THAT WAS ACTUALLY IN FORCE.

    Overwrite (Type 1) would have thrown the 50 away, and you'd audit March
    against 40 — wrong. History matters when you're accusing people.
*/


/* ═══════════════════════════════════════════════════════════════════════════
   DIM 3 — dim_facility
   ═══════════════════════════════════════════════════════════════════════════
   Simple Type-1 dimension (facility attributes rarely change in ways we audit).
   Surrogate key + a link back to its operator's business key.
*/

CREATE OR REPLACE TABLE dim_facility (
    facility_key   INT      AUTOINCREMENT START 1 INCREMENT 1,   -- surrogate key
    facility_id    VARCHAR,        -- business key
    operator_id    VARCHAR,        -- link to operator (business key)
    facility_name  VARCHAR,
    city           VARCHAR,
    room_count     INT
);

INSERT INTO dim_facility (facility_id, operator_id, facility_name, city, room_count)
SELECT
    facility_id,
    operator_id,
    TRIM(facility_name)                 AS facility_name,
    INITCAP(TRIM(city))                 AS city,
    TRY_TO_NUMBER(room_count)           AS room_count
FROM raw.raw_facilities;

SELECT COUNT(*) AS facilities FROM dim_facility;   -- EXPECT: 53


/* ═══════════════════════════════════════════════════════════════════════════
   VERIFY THE DIMENSIONS
   ═══════════════════════════════════════════════════════════════════════════ */

SELECT 'dim_date'     AS dimension, COUNT(*) AS row_count FROM dim_date
UNION ALL SELECT 'dim_operator (incl. SCD history)', COUNT(*) FROM dim_operator
UNION ALL SELECT 'dim_facility', COUNT(*) FROM dim_facility
ORDER BY dimension;
--   EXPECT: dim_date 12, dim_operator 41 (40 + 1 SCD history row), dim_facility 53


/* ═══════════════════════════════════════════════════════════════════════════
   TAKEAWAYS

   ✔ FACT = events you measure. DIMENSION = context you slice by.
   ✔ SURROGATE KEYS: the model mints its own integer keys; source ids become
     mere attributes. Protects you when the source changes.
   ✔ ALL cleaning happens ONCE, here, in the dimension build. Downstream
     queries never clean again — they inherit clean data for free.
   ✔ SCD TYPE 2 keeps HISTORY: close the old row, add a new one, stamp both
     with valid_from / valid_to. For an audit, this is mandatory — you judge
     each month against the capacity that applied THAT month.

   NEXT: 03_dimensional_model_fact.sql — the fact table that ties it together.
   ═══════════════════════════════════════════════════════════════════════════ */
