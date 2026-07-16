/* ═══════════════════════════════════════════════════════════════════════════
   WORKSHOP 2 — SCRIPT 03
   STAGES, FILE FORMATS & GETTING DATA IN

   This is the script that teaches the thing most tutorials skip.

   ---------------------------------------------------------------------------
   WHAT IS A STAGE?
   ---------------------------------------------------------------------------

   A stage is a LANDING AREA for files. Not a table. A place where files sit
   before Snowflake parses them into rows.

   The flow is always two steps, and people constantly conflate them:

       PUT        : your laptop  ──────►  stage      (moves a FILE)
       COPY INTO  : stage        ──────►  table      (parses file into ROWS)

   PUT moves bytes. COPY INTO understands them. Two different verbs, two
   different failure modes. If PUT works and COPY fails, your file is fine and
   your PARSING is wrong. That distinction saves you a lot of guessing.

   ---------------------------------------------------------------------------
   THE FOUR STAGE TYPES — and when each is right
   ---------------------------------------------------------------------------

   ┌──────────────────┬──────────────┬──────────────────────────────────────────┐
   │ TYPE             │ SYNTAX       │ WHEN YOU USE IT                          │
   ├──────────────────┼──────────────┼──────────────────────────────────────────┤
   │ User stage       │ @~           │ Auto-exists. Private to YOU. Ad-hoc,     │
   │                  │              │ throwaway, "just get it in".             │
   │                  │              │ Cannot be shared. No config.             │
   ├──────────────────┼──────────────┼──────────────────────────────────────────┤
   │ Table stage      │ @%tablename  │ Auto-exists, one per table. Loading      │
   │                  │              │ straight into ONE table and nothing      │
   │                  │              │ else. Cannot set a file format on it.    │
   ├──────────────────┼──────────────┼──────────────────────────────────────────┤
   │ Named internal   │ @my_stage    │ ★ YOU CREATE IT. Reusable, shareable,    │
   │                  │              │ can carry a default file format.         │
   │                  │              │ This is what a team actually uses.       │
   │                  │              │ ★ WE USE THIS ONE.                       │
   ├──────────────────┼──────────────┼──────────────────────────────────────────┤
   │ External         │ @ext_stage   │ Points at S3 / Azure Blob / GCS.         │
   │                  │              │ PRODUCTION. The data is already in       │
   │                  │              │ cloud storage; Snowflake reads it in     │
   │                  │              │ place. No PUT step at all.               │
   └──────────────────┴──────────────┴──────────────────────────────────────────┘

   INTERVIEW NOTE: "internal vs external stage" is a real question. The answer
   is about WHERE THE BYTES LIVE — internal = inside Snowflake's storage;
   external = in your own cloud bucket, Snowflake just has a pointer and
   credentials. External is how virtually all production loading works, because
   the data is already landing in S3 from some upstream system anyway.

   ═══════════════════════════════════════════════════════════════════════════ */

USE ROLE      SYSADMIN;
USE WAREHOUSE mdp_wh;
USE DATABASE  childcare_audit;
USE SCHEMA    raw;


/* ───────────────────────────────────────────────────────────────────────────
   STEP 1 — THE FILE FORMAT
   ───────────────────────────────────────────────────────────────────────────

   A file format is a REUSABLE definition of "how do I parse this kind of file".
   Define it once. Reference it from every COPY INTO.

   The alternative — pasting parsing options inline into every single COPY
   statement — is how you end up with one table loaded with a different
   NULL convention than its neighbour, and nobody notices for six months.

   Go through these options one at a time. Each one is a decision:
*/

CREATE OR REPLACE FILE FORMAT ff_csv_childcare
    TYPE                         = 'CSV'
    FIELD_DELIMITER              = ','
    SKIP_HEADER                  = 1              -- row 1 is column names, not data
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'            -- ★ handles "18,900.00" — the comma
                                                  --   inside quotes is DATA, not a
                                                  --   delimiter. Without this, that row
                                                  --   shatters into extra columns.
    NULL_IF                      = ('', 'NULL', 'null', 'N/A', '\\N')
                                                  -- what counts as NULL. BE EXPLICIT.
                                                  -- An empty string and a NULL are not
                                                  -- the same thing, and pretending they
                                                  -- are will bite you in aggregations.
    EMPTY_FIELD_AS_NULL          = TRUE
    TRIM_SPACE                   = FALSE          -- ★ DELIBERATE. We are NOT trimming.
                                                  --   The source data has whitespace in
                                                  --   operator names and we want to SEE
                                                  --   it, not silently paper over it.
                                                  --   Clean it later, on purpose, where
                                                  --   it's visible in code.
    ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE         -- ★ ragged rows are an ERROR, not a
                                                  --   shrug. Turning this off is how
                                                  --   you silently lose columns.
    COMPRESSION                  = 'AUTO'
    ENCODING                     = 'UTF8'
    COMMENT = 'Childcare CSVs. TRIM_SPACE off deliberately - we want to see the dirt.';

-- Look at what we made:
SHOW FILE FORMATS;
DESC FILE FORMAT ff_csv_childcare;


/* ───────────────────────────────────────────────────────────────────────────
   STEP 2 — THE NAMED INTERNAL STAGE
   ───────────────────────────────────────────────────────────────────────────

   We attach the file format to the stage as a DEFAULT. Now COPY INTO
   statements don't have to repeat it — but they still CAN override it,
   which we'll need later for the broken file.

   DIRECTORY = (ENABLE = TRUE) gives the stage a queryable file catalog.
   Nice for "what's actually in here?" without guessing.
*/

CREATE OR REPLACE STAGE stg_childcare
    FILE_FORMAT = ff_csv_childcare
    DIRECTORY   = (ENABLE = TRUE)
    COMMENT     = 'Named internal stage - childcare audit source files';

SHOW STAGES;


/* ═══════════════════════════════════════════════════════════════════════════
   STEP 3 — PUT: MOVE THE FILES  ⚠️ THIS RUNS IN SNOWSQL, NOT THE WEB UI
   ═══════════════════════════════════════════════════════════════════════════

   ⚠️  IMPORTANT — READ THIS OR YOU WILL GET STUCK:

   The PUT command is a CLIENT-SIDE command. It reads a file off YOUR LAPTOP.
   The Snowsight web UI runs in a browser and cannot reach your filesystem.

   ➤ PUT DOES NOT WORK IN THE SNOWSIGHT WORKSHEET. It will error.

   You have TWO options:

   ── OPTION A (recommended for this workshop) ────────────────────────────────
      Use the Snowsight UI to upload files directly to the stage:
        Data  ►  Databases  ►  CHILDCARE_AUDIT  ►  RAW  ►  Stages  ►  STG_CHILDCARE
        ►  "+ Files" button  ►  select all 6 CSVs  ►  Upload

      Same result. Zero install. This is the path of least resistance and it is
      what we will do live in the workshop.

   ── OPTION B (the "real" way, for those who want it) ────────────────────────
      Install SnowSQL (the CLI) and run the PUT commands below.
      This is what you'd actually do on a job, and it scripts/automates.

        snowsql -a <your_account> -u <your_user>

      Then run these (adjust the path to where your CSVs live):
*/

--  ┌─ RUN IN SNOWSQL CLI ONLY — NOT IN THE WEB WORKSHEET ─────────────────────┐
--  │                                                                          │
--  │  PUT file:///path/to/childcare_dataset/operators.csv                     │
--  │      @stg_childcare AUTO_COMPRESS=TRUE;                                  │
--  │                                                                          │
--  │  PUT file:///path/to/childcare_dataset/facilities.csv                    │
--  │      @stg_childcare AUTO_COMPRESS=TRUE;                                  │
--  │                                                                          │
--  │  PUT file:///path/to/childcare_dataset/enrollment.csv                    │
--  │      @stg_childcare AUTO_COMPRESS=TRUE;                                  │
--  │                                                                          │
--  │  PUT file:///path/to/childcare_dataset/subsidy_claims.csv                │
--  │      @stg_childcare AUTO_COMPRESS=TRUE;                                  │
--  │                                                                          │
--  │  PUT file:///path/to/childcare_dataset/inspections.csv                   │
--  │      @stg_childcare AUTO_COMPRESS=TRUE;                                  │
--  │                                                                          │
--  │  PUT file:///path/to/childcare_dataset/subsidy_claims_2026_Q1_BROKEN.csv │
--  │      @stg_childcare AUTO_COMPRESS=TRUE;                                  │
--  │                                                                          │
--  │  Windows path example:                                                   │
--  │  PUT file://C:\Users\you\Downloads\operators.csv @stg_childcare;         │
--  └──────────────────────────────────────────────────────────────────────────┘

/*  WHAT PUT ACTUALLY DOES (worth knowing — it's an interview question):

      1. COMPRESSES the file (gzip) — AUTO_COMPRESS=TRUE, on by default
      2. ENCRYPTS it client-side, BEFORE it leaves your machine
      3. Uploads it to the stage

    So the file is encrypted in transit and at rest, and you didn't configure
    anything. That is a genuinely good answer to "how does Snowflake handle
    data security on ingest?"
*/


/* ───────────────────────────────────────────────────────────────────────────
   STEP 4 — LIST: WHAT IS ACTUALLY IN THE STAGE?
   ───────────────────────────────────────────────────────────────────────────
   Always look before you load. Two minutes here beats twenty minutes of
   "why did COPY INTO return 0 rows" later.
   (Answer: because the file wasn't there. It is ALWAYS because the file
    wasn't there.)
*/

LIST @stg_childcare;
--   EXPECT: 6 files, each ending in .csv (the UI upload does NOT compress).
--           If you used the PUT/SnowSQL path instead, they'd end in .csv.gz —
--           in that case add .gz to every filename in this script.
--           Note the size column. If a file is 0 bytes, stop and re-upload.

-- The DIRECTORY table gives you the same thing as queryable rows:
SELECT
    RELATIVE_PATH   AS file_name,
    SIZE            AS bytes,
    LAST_MODIFIED
FROM DIRECTORY(@stg_childcare)
ORDER BY file_name;


/* ───────────────────────────────────────────────────────────────────────────
   STEP 5 — PEEK AT A FILE WITHOUT LOADING IT
   ───────────────────────────────────────────────────────────────────────────

   ★ This is a genuinely useful trick that most people don't know.

   You can SELECT directly from a staged file. $1, $2, $3 are the columns
   BY POSITION (the file has no column names yet — it's just text).

   Use this to sanity-check the shape of a file BEFORE you commit to a load.
*/

SELECT
    $1 AS operator_id,
    $2 AS operator_name,
    $3 AS operator_type,
    $4 AS region,
    $7 AS licensed_capacity
FROM @stg_childcare/operators.csv
    (FILE_FORMAT => ff_csv_childcare)
LIMIT 10;

--   👀 LOOK AT THE region COLUMN IN THE OUTPUT.
--      You should already be able to SEE the casing inconsistencies.
--      We haven't loaded a single row yet and we've already found a problem.
--      THAT is what "profile before you trust" means.


/* ═══════════════════════════════════════════════════════════════════════════
   STEP 6 — COPY INTO: THE HAPPY PATH
   ═══════════════════════════════════════════════════════════════════════════

   Now we parse files into rows.

   METADATA$FILENAME is a pseudo-column Snowflake exposes during a COPY.
   We capture it into _source_file so every row knows where it came from.
   In a compliance context this is not optional — "which file did this
   number come from?" is a question you WILL be asked.
*/

COPY INTO raw_operators (
    operator_id, operator_name, operator_type, region, license_number,
    license_status, licensed_capacity, license_start_date, contact_email,
    _source_file
)
FROM (
    SELECT
        $1, $2, $3, $4, $5, $6, $7, $8, $9,
        METADATA$FILENAME            -- ★ lineage
    FROM @stg_childcare/operators.csv
)
FILE_FORMAT = (FORMAT_NAME = ff_csv_childcare)
ON_ERROR     = 'ABORT_STATEMENT';    -- strict. If anything is wrong, load NOTHING.
--   EXPECT: status=LOADED, rows_parsed=40, rows_loaded=40, errors=0


COPY INTO raw_facilities (
    facility_id, operator_id, facility_name, street_address, city,
    postal_code, room_count, opened_date, _source_file
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8, METADATA$FILENAME
    FROM @stg_childcare/facilities.csv
)
FILE_FORMAT = (FORMAT_NAME = ff_csv_childcare)
ON_ERROR     = 'ABORT_STATEMENT';
--   EXPECT: 53 rows


COPY INTO raw_enrollment (
    enrollment_id, facility_id, enrollment_month, age_band,
    enrolled_count, subsidized_count, record_created, _source_file
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, METADATA$FILENAME
    FROM @stg_childcare/enrollment.csv
)
FILE_FORMAT = (FORMAT_NAME = ff_csv_childcare)
ON_ERROR     = 'ABORT_STATEMENT';
--   EXPECT: 1,883 rows


COPY INTO raw_subsidy_claims (
    claim_id, facility_id, claim_month, claimed_children,
    claim_amount, submitted_date, claim_status, _source_file
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, METADATA$FILENAME
    FROM @stg_childcare/subsidy_claims.csv
)
FILE_FORMAT = (FORMAT_NAME = ff_csv_childcare)
ON_ERROR     = 'ABORT_STATEMENT';
--   EXPECT: 613 rows


COPY INTO raw_inspections (
    inspection_id, operator_id, inspection_date, inspector_id,
    result, finding_summary, follow_up_required, _source_file
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, METADATA$FILENAME
    FROM @stg_childcare/inspections.csv
)
FILE_FORMAT = (FORMAT_NAME = ff_csv_childcare)
ON_ERROR     = 'ABORT_STATEMENT';
--   EXPECT: 79 rows


-- ── Confirm the loads ──────────────────────────────────────────────────────
SELECT 'operators'      AS table_name, COUNT(*) AS row_count FROM raw_operators
UNION ALL SELECT 'facilities',      COUNT(*) FROM raw_facilities
UNION ALL SELECT 'enrollment',      COUNT(*) FROM raw_enrollment
UNION ALL SELECT 'subsidy_claims',  COUNT(*) FROM raw_subsidy_claims
UNION ALL SELECT 'inspections',     COUNT(*) FROM raw_inspections
ORDER BY table_name;

/*   EXPECT EXACTLY:
       enrollment       1883
       facilities         53
       inspections        79
       operators          40
       subsidy_claims    613

     If your numbers differ — STOP. Do not proceed. Something loaded wrong,
     and every downstream number will be wrong too. Diagnose it now.
*/


/* ═══════════════════════════════════════════════════════════════════════════
   STEP 7 — ★ LOAD METADATA / IDEMPOTENCY  ★
   ═══════════════════════════════════════════════════════════════════════════

   Run the operators COPY again. Exactly the same statement.
   Predict what happens BEFORE you run it.
*/

COPY INTO raw_operators (
    operator_id, operator_name, operator_type, region, license_number,
    license_status, licensed_capacity, license_start_date, contact_email,
    _source_file
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, METADATA$FILENAME
    FROM @stg_childcare/operators.csv
)
FILE_FORMAT = (FORMAT_NAME = ff_csv_childcare)
ON_ERROR     = 'ABORT_STATEMENT';

--   RESULT: "Copy executed with 0 files processed."
--           NOTHING LOADED. No duplicates. Zero rows added.

SELECT COUNT(*) AS still_40 FROM raw_operators;   -- still 40. Not 80.

/*  WHY?

    Snowflake keeps LOAD METADATA on every table — a record of which files it
    has already ingested (tracked for 64 days). It saw operators.csv before.
    It refuses to load it twice.

    ★ COPY INTO IS IDEMPOTENT BY DEFAULT. ★

    This is a big deal. It means a pipeline that retries after a network blip
    does not silently double your revenue numbers. Most databases do not give
    you this for free.

    TO FORCE A RELOAD (know this exists, and know that it's dangerous):
        COPY INTO ... FORCE = TRUE;
    That bypasses the check and WILL create duplicates. Use it when you have
    truncated the table and genuinely want a fresh load — not as a reflex
    when something looks wrong.
*/


/* ═══════════════════════════════════════════════════════════════════════════
   ★★★ STEP 8 — THE BROKEN FILE. THIS IS THE MOST IMPORTANT PART. ★★★
   ═══════════════════════════════════════════════════════════════════════════

   subsidy_claims_2026_Q1_BROKEN.csv has 10 rows. Four of them are defective:

       CLM900003  claimed_children = "NOT_A_NUMBER"
       CLM900004  only 6 columns (should be 7)
       CLM900005  8 columns (should be 7)
       CLM900006  submitted_date = "not-a-date"
       CLM900008  claimed_children is empty
       CLM900009  claim_amount = "18,900.00"  ← quoted comma. This one is VALID.

   We are going to load it three ways and watch what happens.
*/

-- ── A staging table so we don't pollute the real one ───────────────────────
CREATE OR REPLACE TABLE raw_subsidy_claims_2026 LIKE raw_subsidy_claims;


/* ── ATTEMPT 1: ON_ERROR = ABORT_STATEMENT (the strict default) ───────────── */

COPY INTO raw_subsidy_claims_2026 (
    claim_id, facility_id, claim_month, claimed_children,
    claim_amount, submitted_date, claim_status, _source_file
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, METADATA$FILENAME
    FROM @stg_childcare/subsidy_claims_2026_Q1_BROKEN.csv
)
FILE_FORMAT = (FORMAT_NAME = ff_csv_childcare)
ON_ERROR     = 'ABORT_STATEMENT';

--   ❌ THIS FAILS. Read the error message — it names the row and the reason.
--      Zero rows loaded. The good rows did NOT load either.
--
--   Is that bad? NO. That is CORRECT behaviour.
--   A partial load is worse than no load, because a partial load looks like
--   a successful one.

SELECT COUNT(*) AS should_be_zero FROM raw_subsidy_claims_2026;   -- 0


/* ── DIAGNOSE: see exactly which rows are broken, and why ─────────────────── */

/*  ★ There are two ways to inspect load errors. Know both.

    NOTE ON VALIDATION_MODE:
      Snowflake has a VALIDATION_MODE = 'RETURN_ALL_ERRORS' option that runs a
      COPY as a pure dry run. BUT it has one hard limitation:

          VALIDATION_MODE does NOT work on a "transform" COPY.

      A transform is any COPY of the form  FROM (SELECT $1, $2, ... ) — which is
      exactly what we use (to capture METADATA$FILENAME for lineage). So we
      CANNOT use VALIDATION_MODE here. If you try, Snowflake errors with:
          "VALIDATION_MODE does not support COPY with transform."

    So instead we use the tool that ALWAYS works: the VALIDATE() table function.
    It reads the error log of the LAST copy you ran into this table and hands
    back one row per rejected record. Run it right after a load.

    We already ran a load above (ATTEMPT 1, which aborted). Inspect it:
*/

SELECT
    ERROR,
    FILE,
    LINE,
    CHARACTER,
    REJECTED_RECORD          -- ★ the raw text of the offending row
FROM TABLE(VALIDATE(raw_subsidy_claims_2026, JOB_ID => '_last'))
ORDER BY LINE;

--   👀 READ THE OUTPUT CAREFULLY. You get one row per error:
--        ERROR           — what went wrong
--        LINE            — exactly where
--        REJECTED_RECORD — the raw text of the offending row
--
--   Now you KNOW what's wrong. You are not guessing.
--
--   ⚠️ If this returns nothing, it means the last COPY into this table did not
--      log rejects (e.g. it aborted before logging, or already succeeded). In
--      that case, just run ATTEMPT 2 below and inspect THAT job — VALIDATE
--      always reflects the most recent load.


/* ── ATTEMPT 2: ON_ERROR = CONTINUE  ⚠️ THE DANGEROUS ONE ⚠️ ──────────────── */

COPY INTO raw_subsidy_claims_2026 (
    claim_id, facility_id, claim_month, claimed_children,
    claim_amount, submitted_date, claim_status, _source_file
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, METADATA$FILENAME
    FROM @stg_childcare/subsidy_claims_2026_Q1_BROKEN.csv
)
FILE_FORMAT = (FORMAT_NAME = ff_csv_childcare)
ON_ERROR     = 'CONTINUE';

--   ✅ "SUCCESS." Some rows loaded. The bad ones were skipped.

SELECT COUNT(*) AS loaded FROM raw_subsidy_claims_2026;

/*  ═══════════════════════════════════════════════════════════════════════
    🛑 STOP. THIS IS THE MOMENT OF THE WHOLE WORKSHOP. 🛑
    ═══════════════════════════════════════════════════════════════════════

    That COPY said SUCCESS.

    It also SILENTLY DISCARDED SUBSIDY CLAIMS.

    Those are not "bad rows." Those are public money. Each one is a childcare
    operator who submitted a claim to the Government of Alberta. Snowflake
    just threw several of them in the bin and told you everything was fine.

    If you build a dashboard on this table, the total will be WRONG.
    Nobody will know. There will be no error. The number will just be wrong,
    and it will be presented to a Deputy Minister with your name on it.

    ON_ERROR = 'CONTINUE' IS NOT A FIX. IT IS A DECISION TO LOSE DATA.

    Sometimes that decision is correct — clickstream logs, IoT telemetry,
    where one dropped row out of a billion genuinely does not matter.

    In a compliance and audit context, it is almost never correct.

    The professional move is:
        1. VALIDATE to see exactly what's broken
        2. QUARANTINE the bad rows so they are visible, not vanished
        3. Go back to the SOURCE and get a corrected file
        4. Reload

    ══════════════════════════════════════════════════════════════════════ */


/* ── SEE THE SKIPPED ROWS: they are recoverable, if you look ─────────────── */

SELECT
    ERROR,
    FILE,
    LINE,
    CHARACTER,
    REJECTED_RECORD          -- ★ the actual text of the row that was dropped
FROM TABLE(VALIDATE(raw_subsidy_claims_2026, JOB_ID => '_last'))
ORDER BY LINE;

--   These rows were NOT destroyed — but they are only visible if you go
--   looking. And nobody goes looking, because the COPY said SUCCESS.


/* ── ATTEMPT 3: QUARANTINE — the professional pattern ─────────────────────── */

/*  Load what's good. KEEP what's bad, in a table, where a human can see it.
    Nothing is silently lost. The bad rows have a home and an owner.
*/

CREATE OR REPLACE TABLE raw_claims_quarantine (
    error_message    VARCHAR,
    source_file      VARCHAR,
    line_number      NUMBER,
    rejected_record  VARCHAR,
    quarantined_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

TRUNCATE TABLE raw_subsidy_claims_2026;

-- Load the good rows...
COPY INTO raw_subsidy_claims_2026 (
    claim_id, facility_id, claim_month, claimed_children,
    claim_amount, submitted_date, claim_status, _source_file
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, METADATA$FILENAME
    FROM @stg_childcare/subsidy_claims_2026_Q1_BROKEN.csv
)
FILE_FORMAT = (FORMAT_NAME = ff_csv_childcare)
ON_ERROR     = 'CONTINUE'
FORCE        = TRUE;

-- ...and immediately capture what got rejected.
INSERT INTO raw_claims_quarantine (error_message, source_file, line_number, rejected_record)
SELECT ERROR, FILE, LINE, REJECTED_RECORD
FROM TABLE(VALIDATE(raw_subsidy_claims_2026, JOB_ID => '_last'));

-- Now BOTH halves are accounted for. Nothing vanished.
SELECT 'loaded'      AS outcome, COUNT(*) AS row_count FROM raw_subsidy_claims_2026
UNION ALL
SELECT 'quarantined', COUNT(*)              FROM raw_claims_quarantine;

SELECT * FROM raw_claims_quarantine;

/*  ★ THIS is the pattern you describe in an interview:

      "I don't use ON_ERROR = CONTINUE and move on, because it silently drops
       records. I validate first, then load the clean rows and quarantine the
       rejects into a table so they're visible and someone can go back to the
       source. In a compliance context, a claim that vanishes without a trace
       is a defect, not a rounding error."

    Almost nobody says that. Say it.
*/


/* ── OTHER ON_ERROR OPTIONS (know they exist) ─────────────────────────────── */
/*
      ABORT_STATEMENT   Fail everything. Load nothing.        ← default, and usually right
      CONTINUE          Skip bad rows. Load the rest.         ← DATA LOSS. Choose it consciously.
      SKIP_FILE         One bad row = skip the WHOLE file.
      SKIP_FILE_<n>     Skip the file after n errors.
      SKIP_FILE_<n>%    Skip the file if >n% of rows fail.    ← useful for bulk loads
*/


/* ═══════════════════════════════════════════════════════════════════════════
   STEP 9 — THE LOAD AUDIT TRAIL
   ═══════════════════════════════════════════════════════════════════════════
   Every COPY is logged. This is how you prove what happened, and when.
*/

SELECT
    FILE_NAME,
    TABLE_NAME,
    STATUS,
    ROW_COUNT,
    ROW_PARSED,
    ERROR_COUNT,
    FIRST_ERROR_MESSAGE,
    LAST_LOAD_TIME
FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
WHERE TABLE_CATALOG = 'CHILDCARE_AUDIT'
  AND LAST_LOAD_TIME >= DATEADD(hour, -3, CURRENT_TIMESTAMP())
ORDER BY LAST_LOAD_TIME DESC;

--   ⚠️ ACCOUNT_USAGE views lag by up to ~45 minutes. On a brand-new account this
--      may return nothing yet. That is latency, not failure.
--
--   For an immediate view, use the INFORMATION_SCHEMA function instead:

SELECT
    FILE_NAME, STATUS, ROW_COUNT, ROW_PARSED, ERROR_COUNT, FIRST_ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME  => 'RAW_SUBSIDY_CLAIMS',
    START_TIME  => DATEADD(hour, -3, CURRENT_TIMESTAMP())
));


/* ═══════════════════════════════════════════════════════════════════════════
   TAKEAWAYS

   ✔ PUT moves a FILE. COPY INTO parses it into ROWS. Different verbs.
   ✔ Four stage types. Named internal for teams; EXTERNAL for production.
   ✔ File formats are reusable. Define once, don't inline-paste everywhere.
   ✔ FIELD_OPTIONALLY_ENCLOSED_BY is what saves "18,900.00" from shattering.
   ✔ LIST and SELECT-from-stage let you look BEFORE you load. Do it.
   ✔ COPY INTO is IDEMPOTENT by default — it will not reload the same file.
   ✔ VALIDATE(table, JOB_ID => '_last') = shows the rejected rows after a load.
     (VALIDATION_MODE dry-run does NOT work on transform COPYs — use VALIDATE.)
   ✔ ★ ON_ERROR = CONTINUE silently loses records. In compliance work that is
       a DEFECT, not a shortcut. Validate → load clean → QUARANTINE the rest.

   NEXT: 04_profiling_and_audit.sql — now we actually investigate.
   ═══════════════════════════════════════════════════════════════════════════ */