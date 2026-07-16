/* ═══════════════════════════════════════════════════════════════════════════
   WORKSHOP 2 — SCRIPT 02
   SETUP, CONTEXT & THE OBJECT HIERARCHY

   Prerequisite: 01_cost_control.sql has been run. If it hasn't, go back.

   ---------------------------------------------------------------------------
   THE BIG IDEA: CONTEXT IS STATE
   ---------------------------------------------------------------------------

   Every query you run in Snowflake executes inside a CONTEXT made of four things:

       ROLE       — who am I, and what am I allowed to do?
       WAREHOUSE  — which compute cluster is paying for this?
       DATABASE   — which database?
       SCHEMA     — which schema inside it?

   If any of those is wrong or unset, your query fails — or worse, it succeeds
   against the WRONG THING.

   When someone says "it worked yesterday and now it doesn't," the answer is
   almost always context drift. They opened a new worksheet and it defaulted
   somewhere else.

   We are going to break this ON PURPOSE in a moment so you feel it.

   ---------------------------------------------------------------------------
   THE HIERARCHY
   ---------------------------------------------------------------------------

       ACCOUNT                         (your whole Snowflake account)
         └── DATABASE                  (CHILDCARE_AUDIT)
               └── SCHEMA              (RAW, then later ANALYTICS)
                     ├── TABLE
                     ├── VIEW
                     ├── STAGE         (where files land before loading)
                     └── FILE FORMAT   (how to parse those files)

   A fully-qualified name walks that tree:
       CHILDCARE_AUDIT.RAW.OPERATORS
       ^database       ^schema ^table

   ═══════════════════════════════════════════════════════════════════════════ */


/* ───────────────────────────────────────────────────────────────────────────
   STEP 1 — Set your context explicitly. Every session. Every time.
   ─────────────────────────────────────────────────────────────────────────── */

USE ROLE      SYSADMIN;     -- SYSADMIN owns objects. ACCOUNTADMIN was only for billing.
USE WAREHOUSE mdp_wh;       -- the X-Small, cost-capped warehouse from script 01

-- Confirm. Look at the output.
SELECT
    CURRENT_ROLE()      AS role,
    CURRENT_WAREHOUSE() AS warehouse,
    CURRENT_DATABASE()  AS database,   -- expect NULL — we haven't created it yet
    CURRENT_SCHEMA()    AS schema;     -- expect NULL


/* ───────────────────────────────────────────────────────────────────────────
   STEP 2 — Build the database and schemas
   ───────────────────────────────────────────────────────────────────────────

   Two schemas, and the split is deliberate:

     RAW       — data exactly as it arrived. Warts, typos, broken rows and all.
                 You do NOT clean data in place. You never destroy the original.
                 If an auditor asks "what did the source actually say?" you must
                 be able to answer.

     ANALYTICS — cleaned, typed, trustworthy. Built FROM raw, never instead of it.

   This RAW -> ANALYTICS separation is a real industry pattern (you'll hear it
   called bronze/silver/gold, or staging/curated). It exists because
   reproducibility matters more than convenience.
*/

CREATE DATABASE IF NOT EXISTS childcare_audit
  COMMENT = 'MDP Workshop Series - Alberta childcare subsidy audit (synthetic data)';

USE DATABASE childcare_audit;

CREATE SCHEMA IF NOT EXISTS raw
  COMMENT = 'Landing zone. Source data as-is. Never cleaned in place.';

CREATE SCHEMA IF NOT EXISTS analytics
  COMMENT = 'Cleaned, typed, reportable. Built from RAW.';

USE SCHEMA raw;

-- Confirm the full context is now set.
SELECT
    CURRENT_ROLE()      AS role,
    CURRENT_WAREHOUSE() AS warehouse,
    CURRENT_DATABASE()  AS database,     -- CHILDCARE_AUDIT
    CURRENT_SCHEMA()    AS schema;       -- RAW


/* ───────────────────────────────────────────────────────────────────────────
   STEP 3 — 🔴 LIVE DEMO: BREAK THE CONTEXT ON PURPOSE
   ───────────────────────────────────────────────────────────────────────────

   Instructor: run these two blocks live. Let the first one FAIL.
   This is the single most common Snowflake frustration and 30 seconds of
   feeling it now saves them an hour of confusion later.
*/

-- Unset the schema, then try to work.
USE SCHEMA PUBLIC;

-- ❌ This FAILS. There is no OPERATORS table in the PUBLIC schema.
--    The table exists! Just not HERE. Your context is pointing at the wrong place.
--    Uncomment to demonstrate:
-- SELECT * FROM operators LIMIT 5;

-- ✅ Two ways to fix it:

-- Fix A — fully qualify the name. Always works, regardless of context.
--         (Will error until we load the table — that's fine, it's the NEXT script.)
-- SELECT * FROM childcare_audit.raw.operators LIMIT 5;

-- Fix B — set the context correctly. Cleaner for a working session.
USE SCHEMA raw;

/*  LESSON:
    Fully-qualified names are bulletproof but verbose.
    Setting context is convenient but stateful — and state is what bites you.

    Rule of thumb used in real teams:
      - Set context at the TOP of every worksheet / script.
      - Fully qualify inside anything that will be RUN BY SOMEONE ELSE
        or scheduled (a task, a stored proc, a pipeline).
*/


/* ───────────────────────────────────────────────────────────────────────────
   STEP 4 — Create the RAW tables
   ───────────────────────────────────────────────────────────────────────────

   ⚠️ LOOK CLOSELY AT THE DATA TYPES. Almost everything is VARCHAR.

   That is INTENTIONAL, and it is what a professional does on a landing table.

   Why not type these properly right now?
   Because if you declare `claimed_children INTEGER` and the source file
   contains the text "NOT_A_NUMBER", the whole load DIES. You lose the
   good rows along with the bad one, and you learn nothing about what was wrong.

   Land it as text. Load succeeds. THEN inspect, THEN cast, THEN quarantine
   what won't cast. You keep the evidence.

   This is a "fail loudly, but fail LATER" strategy — and it is the right one
   when the data is someone else's and you don't control the source.
*/

USE SCHEMA raw;

-- ── operators ──────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE raw_operators (
    operator_id        VARCHAR,
    operator_name      VARCHAR,   -- ⚠️ some values carry leading/trailing spaces
    operator_type      VARCHAR,
    region             VARCHAR,   -- ⚠️ inconsistent casing + a typo live here
    license_number     VARCHAR,
    license_status     VARCHAR,
    licensed_capacity  VARCHAR,   -- ⚠️ TEXT, not INT — two rows are blank
    license_start_date VARCHAR,   -- ⚠️ TEXT — three different date formats
    contact_email      VARCHAR,
    -- Load lineage. Non-negotiable in a compliance context: you must be able
    -- to say WHICH FILE a row came from and WHEN it landed.
    _loaded_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _source_file       VARCHAR
);

-- ── facilities ─────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE raw_facilities (
    facility_id     VARCHAR,
    operator_id     VARCHAR,   -- ⚠️ one value points at an operator that doesn't exist
    facility_name   VARCHAR,
    street_address  VARCHAR,
    city            VARCHAR,
    postal_code     VARCHAR,
    room_count      VARCHAR,
    opened_date     VARCHAR,
    _loaded_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _source_file    VARCHAR
);

-- ── enrollment ─────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE raw_enrollment (
    enrollment_id    VARCHAR,
    facility_id      VARCHAR,   -- ⚠️ two rows point at a facility that doesn't exist
    enrollment_month VARCHAR,
    age_band         VARCHAR,
    enrolled_count   VARCHAR,   -- ⚠️ contains negatives and zeros
    subsidized_count VARCHAR,   -- ⚠️ sometimes EXCEEDS enrolled_count (impossible)
    record_created   VARCHAR,
    _loaded_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _source_file     VARCHAR
);

-- ── subsidy_claims ─────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE raw_subsidy_claims (
    claim_id         VARCHAR,
    facility_id      VARCHAR,
    claim_month      VARCHAR,
    claimed_children VARCHAR,   -- the AUDIT NUMERATOR
    claim_amount     VARCHAR,   -- ⚠️ some values are "$12,450.00" — SUM() will not work
    submitted_date   VARCHAR,
    claim_status     VARCHAR,
    _loaded_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _source_file     VARCHAR
);

-- ── inspections ────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE raw_inspections (
    inspection_id     VARCHAR,
    operator_id       VARCHAR,
    inspection_date   VARCHAR,
    inspector_id      VARCHAR,
    result            VARCHAR,
    finding_summary   VARCHAR,   -- "Capacity exceeded" will corroborate our audit
    follow_up_required VARCHAR,
    _loaded_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _source_file      VARCHAR
);


/* ───────────────────────────────────────────────────────────────────────────
   VERIFY
   ─────────────────────────────────────────────────────────────────────────── */

SHOW TABLES IN SCHEMA childcare_audit.raw;
--   EXPECT: 5 tables, all with 0 rows. We haven't loaded anything yet.

-- Inspect one table's structure:
DESC TABLE raw_operators;


/* ═══════════════════════════════════════════════════════════════════════════
   TAKEAWAYS

   ✔ Context = ROLE + WAREHOUSE + DATABASE + SCHEMA. Set it explicitly.
   ✔ "It worked yesterday" = context drift, 9 times out of 10.
   ✔ RAW schema holds the source AS-IS. You never clean in place.
   ✔ Land messy data as VARCHAR so the load SUCCEEDS, then cast deliberately.
     Strict types on a landing table throw away the evidence.
   ✔ Track lineage (_source_file, _loaded_at). In an audit, "where did this
     row come from?" is a question you WILL be asked.

   NEXT: 03_stages_and_loading.sql — get the files in.
   ═══════════════════════════════════════════════════════════════════════════ */
