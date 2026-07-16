/* ═══════════════════════════════════════════════════════════════════════════
   WORKSHOP 2 — SCRIPT 05
   SNOWFLAKE DEEP DIVE — HOW THE PLATFORM ACTUALLY WORKS

   This is the SnowPro Core material. Everything here is testable, and more
   importantly, everything here is a thing you can SAY in an interview that
   most junior candidates cannot.

   ---------------------------------------------------------------------------
   THE ARCHITECTURE — three layers, and the separation IS the product
   ---------------------------------------------------------------------------

     ┌────────────────────────────────────────────────────────────┐
     │  CLOUD SERVICES          "the brain"                       │
     │  optimizer · metadata · security · ★ RESULT CACHE ★        │
     │  You don't size it. You barely pay for it.                 │
     ├────────────────────────────────────────────────────────────┤
     │  COMPUTE                 "virtual warehouses"              │
     │  Where queries actually run. YOU PAY FOR THIS, PER SECOND. │
     │  Multiple warehouses can hit the SAME data, independently. │
     ├────────────────────────────────────────────────────────────┤
     │  STORAGE                 "the data"                        │
     │  Micro-partitions in cloud object storage. Cheap.          │
     │  Sits there whether or not any compute is running.         │
     └────────────────────────────────────────────────────────────┘

   ★ WHY THE SEPARATION MATTERS — the answer to "why Snowflake?":

     In an old-school warehouse, storage and compute are welded together on
     the same box. Finance runs month-end, and the data science team's queries
     crawl, because they are fighting over the same CPU. Need more compute?
     Buy a bigger box — and pay for it 24/7, including nights and weekends
     when nobody is querying.

     In Snowflake, Finance gets their own warehouse. Data Science gets theirs.
     Same data. Zero contention. Both suspend when idle and cost nothing.

     ➤ THIS IS ALSO WHY SUSPENDING A WAREHOUSE LOSES YOU NOTHING.
       Your data is not "in" the warehouse. The warehouse is just rented CPU.
       Turn it off. The data doesn't care.

   ═══════════════════════════════════════════════════════════════════════════ */

USE ROLE      SYSADMIN;
USE WAREHOUSE mdp_wh;
USE DATABASE  childcare_audit;
USE SCHEMA    raw;


/* ═══════════════════════════════════════════════════════════════════════════
   PART 1 — MICRO-PARTITIONS: WHY THERE ARE NO INDEXES
   ═══════════════════════════════════════════════════════════════════════════

   "Where do I create the index?"  — you don't. There are none. On purpose.

   Snowflake automatically chops every table into MICRO-PARTITIONS:
       · 50–500 MB of uncompressed data each
       · columnar storage inside
       · IMMUTABLE — never edited, only replaced
       · and critically: Snowflake stores METADATA on each one —
         the MIN and MAX of every column in that partition

   ★ THAT METADATA IS THE WHOLE TRICK.

   When you query WHERE claim_month = '2025-07', Snowflake checks the min/max
   metadata and skips every partition that cannot possibly contain July.
   It never reads them. It doesn't decompress them. They cost you nothing.

   That is called PARTITION PRUNING, and it is the single most important
   performance concept in Snowflake.

   ➤ An index is something you MAINTAIN. Pruning is something you EARN by
     writing a WHERE clause that the metadata can actually use.
   ➤ W3 is largely about making pruning work HARDER for you (clustering).
*/

-- Look at the partition metadata Snowflake keeps for you, for free:
SELECT
    TABLE_NAME,
    ROW_COUNT,
    BYTES,
    ROUND(BYTES / 1024, 1) AS kb
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'RAW'
  AND TABLE_TYPE   = 'BASE TABLE'
ORDER BY ROW_COUNT DESC;

/*  ⚠️ HONEST NOTE: our dataset is TINY (a few thousand rows). It fits in a
    single micro-partition. So you will NOT see dramatic pruning numbers today.

    That is fine — today you learn the MECHANISM. In W3 we scale the data up
    and you will watch "partitions scanned" drop, and see the clock change.
    Feeling it beats being told about it.
*/


/* ═══════════════════════════════════════════════════════════════════════════
   PART 2 — ★ THE THREE CACHES ★ (a guaranteed cert question)
   ═══════════════════════════════════════════════════════════════════════════

   ┌────────────────────┬──────────────────┬──────────────────────────────────┐
   │ CACHE              │ LIVES IN         │ WHAT IT DOES                     │
   ├────────────────────┼──────────────────┼──────────────────────────────────┤
   │ 1. RESULT CACHE    │ Cloud Services   │ ★ Identical query, same data?    │
   │                    │                  │   Returns the SAVED RESULT.      │
   │                    │                  │   Warehouse doesn't even wake up.│
   │                    │                  │   ★ COSTS ZERO CREDITS. 24 hrs.  │
   ├────────────────────┼──────────────────┼──────────────────────────────────┤
   │ 2. LOCAL DISK      │ The warehouse    │ Data this warehouse recently     │
   │    (warehouse)     │ (SSD)            │ read. Gone when it suspends.     │
   ├────────────────────┼──────────────────┼──────────────────────────────────┤
   │ 3. METADATA        │ Cloud Services   │ Row counts, min/max. That's why  │
   │                    │                  │ SELECT COUNT(*) is instant and   │
   │                    │                  │ free — it never touches storage. │
   └────────────────────┴──────────────────┴──────────────────────────────────┘

   ★ THE RESULT CACHE IS FREE MONEY and most people don't know it exists.
     A dashboard that 50 people open runs the query ONCE. The other 49 get
     the cached result. Zero credits. This is a real cost-optimisation lever.
*/

-- ── 🔴 LIVE DEMO: run this TWICE. Watch the clock. ─────────────────────────
SELECT
    UPPER(TRIM(o.region))                         AS region,
    o.operator_type,
    COUNT(DISTINCT o.operator_id)                 AS operators,
    COUNT(DISTINCT f.facility_id)                 AS facilities,
    SUM(TRY_TO_NUMBER(c.claimed_children))        AS total_children_claimed,
    ROUND(AVG(TRY_TO_NUMBER(o.licensed_capacity)), 1) AS avg_licensed_capacity
FROM raw_subsidy_claims c
LEFT JOIN raw_facilities f ON c.facility_id = f.facility_id
LEFT JOIN raw_operators  o ON f.operator_id = o.operator_id
WHERE o.operator_id IS NOT NULL
GROUP BY 1, 2
ORDER BY total_children_claimed DESC;

/*  ▶ FIRST RUN:  takes a moment. Warehouse spins up, reads data, computes.
    ▶ SECOND RUN: ~0ms. INSTANT.

    ★ The second run did not use the warehouse AT ALL.
      It did not cost a single credit.
      Cloud Services recognised the identical query against unchanged data
      and handed back the stored result.

    RULES — the result cache is invalidated if ANY of these change:
      · the query text (even ONE character — a space, a comment)
      · the underlying data
      · certain session parameters
      · 24 hours pass without a hit

    ⚠️ AND IT IS BYPASSED ENTIRELY BY NON-DETERMINISTIC FUNCTIONS:
       CURRENT_TIMESTAMP(), RANDOM(), CURRENT_DATE()...
       Put CURRENT_TIMESTAMP() in a dashboard query and you have quietly
       disabled the result cache for every user, forever. People do this.
*/

-- Prove it: change ONE character (add a comment) and the cache misses.
SELECT   -- this comment alone busts the cache
    UPPER(TRIM(o.region))                         AS region,
    o.operator_type,
    COUNT(DISTINCT o.operator_id)                 AS operators,
    COUNT(DISTINCT f.facility_id)                 AS facilities,
    SUM(TRY_TO_NUMBER(c.claimed_children))        AS total_children_claimed,
    ROUND(AVG(TRY_TO_NUMBER(o.licensed_capacity)), 1) AS avg_licensed_capacity
FROM raw_subsidy_claims c
LEFT JOIN raw_facilities f ON c.facility_id = f.facility_id
LEFT JOIN raw_operators  o ON f.operator_id = o.operator_id
WHERE o.operator_id IS NOT NULL
GROUP BY 1, 2
ORDER BY total_children_claimed DESC;
--   ▶ SLOW AGAIN. One comment character = a different query = a cache miss.

-- Turn the cache off (for honest benchmarking — turn it back ON after):
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
--  ... run a query, time it honestly ...
ALTER SESSION SET USE_CACHED_RESULT = TRUE;
--   ⚠️ Leave this FALSE and you will burn credits re-running identical queries
--      all evening. Turn it back on.

-- Metadata cache: instant, free, never touches storage.
SELECT COUNT(*) FROM raw_enrollment;
--   ▶ Instant. Snowflake already knows. It didn't read a single row.


/* ═══════════════════════════════════════════════════════════════════════════
   PART 3 — QUERY HISTORY & THE QUERY PROFILE
   ═══════════════════════════════════════════════════════════════════════════
   "The query is slow" is not a diagnosis. The profile tells you WHY.
*/

SELECT
    QUERY_ID,
    LEFT(QUERY_TEXT, 60)                  AS query_preview,
    WAREHOUSE_SIZE,
    EXECUTION_STATUS,
    TOTAL_ELAPSED_TIME / 1000             AS seconds,
    BYTES_SCANNED,
    ROWS_PRODUCED
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    END_TIME_RANGE_START => DATEADD(hour, -2, CURRENT_TIMESTAMP()),
    RESULT_LIMIT         => 30
))
ORDER BY START_TIME DESC;

/*  ★ THE QUERY PROFILE — the visual one. Do this in the UI, live:

      Snowsight ► Activity ► Query History ► click any query ► "Query Profile"

    What to point at, and what it means:

      · The DAG      — the actual execution plan. Read it bottom-up.
      · TableScan    — "Partitions scanned: 3 / 47" ← ★ PRUNING. Lower = better.
                        If it says 47/47, your WHERE clause pruned NOTHING.
      · Join         — look at the ROW COUNTS on the arrows. A join that goes
                        IN with 600 rows and comes OUT with 60,000 is a
                        ★ ROW EXPLOSION — your join key isn't unique.
                        This is the #1 cause of "my numbers are too big."
      · Spilling     — "Bytes spilled to local/remote storage" ← ★ BAD.
                        The warehouse ran out of memory and started using disk.
                        THIS is the legitimate reason to size up. Not vibes.
      · Most Expensive Node — Snowflake literally tells you where the time went.

    ➤ INTERVIEW GOLD: "How do you troubleshoot a slow Snowflake query?"
      Weak answer:   "Make the warehouse bigger."
      Strong answer: "I read the query profile first. I check partitions
                      scanned to see if pruning is working, look for row
                      explosion at the joins, and check for spilling. Sizing
                      up only helps if I'm actually spilling — otherwise I'm
                      just paying double for the same plan."
*/


/* ═══════════════════════════════════════════════════════════════════════════
   PART 4 — SCALE UP vs SCALE OUT  (★ classic cert + interview question)
   ═══════════════════════════════════════════════════════════════════════════

     SCALE UP   (bigger warehouse: XS → S → M → L)
       → makes ONE SLOW QUERY faster
       → more memory, more threads. Fixes SPILLING.
       → ★ EACH SIZE DOUBLES THE CREDIT RATE:
             XS=1  S=2  M=4  L=8  XL=16  2XL=32  ... per hour

     SCALE OUT  (multi-cluster: MIN_CLUSTER_COUNT / MAX_CLUSTER_COUNT)
       → handles MORE CONCURRENT USERS
       → does NOT make a single query faster. At all.
       → for the 9am dashboard stampede, not for one heavy report

   ➤ THE TRAP: "the query is slow, make it bigger."
     If the query is slow because of a bad join or no pruning, a bigger
     warehouse just costs 2× to be slow. Fix the query. Read the profile.
*/

-- 🔴 LIVE: resize, rerun, compare. (We'll go straight back down.)
ALTER WAREHOUSE mdp_wh SET WAREHOUSE_SIZE = 'SMALL';   -- now 2 credits/hr

ALTER SESSION SET USE_CACHED_RESULT = FALSE;           -- honest comparison
SELECT COUNT(*) AS rows_scanned
FROM raw_enrollment e
JOIN raw_facilities f ON e.facility_id = f.facility_id
JOIN raw_operators  o ON f.operator_id = o.operator_id;
ALTER SESSION SET USE_CACHED_RESULT = TRUE;

/*  👀 Barely any faster. Why? Our dataset is TINY.
    A bigger warehouse on a small dataset is pure waste — you doubled the
    cost and bought nothing. THAT is the lesson, and it's more valuable
    than seeing it get faster would have been.
*/

-- ⚠️ GO BACK TO X-SMALL. RIGHT NOW. Don't forget this line.
ALTER WAREHOUSE mdp_wh SET WAREHOUSE_SIZE = 'XSMALL';
SHOW WAREHOUSES LIKE 'mdp_wh';   -- confirm: X-Small


/* ═══════════════════════════════════════════════════════════════════════════
   PART 5 — ★★★ TIME TRAVEL — THE APPLAUSE MOMENT ★★★
   ═══════════════════════════════════════════════════════════════════════════

   Snowflake retains the previous state of your data for a retention window
   (1 day on Standard by default; up to 90 on Enterprise).

   You can query the PAST. You can UNDO a DROP. You can recover from the
   thing that would end your week on any other database.
*/

-- ── 5.1 Break something. On purpose. ───────────────────────────────────────
SELECT COUNT(*) AS before_disaster FROM raw_subsidy_claims;   -- 613

-- 😱 The classic 5pm mistake: forgot the WHERE clause.
DELETE FROM raw_subsidy_claims WHERE claim_month LIKE '2025-0%';

SELECT COUNT(*) AS after_disaster FROM raw_subsidy_claims;
--   ▶ Most of the year's subsidy claims are GONE. This is a very bad day.


-- ── 5.2 Query the past ─────────────────────────────────────────────────────
-- What did the table look like 5 minutes ago, before I did that?
SELECT COUNT(*) AS rows_5_min_ago
FROM raw_subsidy_claims AT(OFFSET => -60 * 1);
--   ▶ 613. The old data is still there. It is just not the CURRENT version.

-- You can also travel to a precise moment:
-- SELECT * FROM raw_subsidy_claims AT(TIMESTAMP => '2026-07-02 18:30:00'::TIMESTAMP_LTZ);

-- Or to just BEFORE a specific statement — using its query_id:
-- SELECT * FROM raw_subsidy_claims BEFORE(STATEMENT => '01a2b3c4-...');


-- ── 5.3 RESTORE. Undo the damage. ──────────────────────────────────────────
CREATE OR REPLACE TABLE raw_subsidy_claims AS
SELECT * FROM raw_subsidy_claims AT(OFFSET => -60 * 5);

SELECT COUNT(*) AS restored FROM raw_subsidy_claims;   -- ▶ 613. Fixed.


-- ── 5.4 ★ UNDROP — the one that gets the reaction ──────────────────────────
CREATE OR REPLACE TABLE demo_undrop AS SELECT * FROM raw_operators;
SELECT COUNT(*) FROM demo_undrop;   -- 40

DROP TABLE demo_undrop;
-- SELECT COUNT(*) FROM demo_undrop;   -- ❌ "does not exist". It's gone. Gone gone.

-- 😌 Except it isn't.
UNDROP TABLE demo_undrop;

SELECT COUNT(*) AS its_back FROM demo_undrop;   -- ▶ 40. All of it.

/*  ★ SAY THIS OUT LOUD IN THE ROOM:

    On Postgres, on SQL Server, on MySQL — DROP TABLE means you are now
    restoring from last night's backup, and explaining to your manager why
    today's data is gone.

    On Snowflake it is ONE WORD.

    ➤ WHY IT WORKS: micro-partitions are IMMUTABLE. A DELETE doesn't erase
      anything — it writes NEW partitions and marks the old ones as
      historical. They're still sitting there for the retention window.
      Time Travel is just Snowflake letting you point at the old ones.

    ⚠️ AND IT IS NOT FREE: you pay STORAGE on those historical partitions.
      A 90-day retention window on a huge, frequently-updated table gets
      expensive. That is a real trade-off a data engineer makes on purpose.

    Cleanup:
*/
DROP TABLE IF EXISTS demo_undrop;

-- Retention settings:
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN DATABASE childcare_audit;
-- ALTER TABLE raw_subsidy_claims SET DATA_RETENTION_TIME_IN_DAYS = 7;   -- Enterprise+


/* ═══════════════════════════════════════════════════════════════════════════
   PART 6 — ★★★ ZERO-COPY CLONING — THE SECOND APPLAUSE MOMENT ★★★
   ═══════════════════════════════════════════════════════════════════════════

   Clone an entire database. INSTANTLY. Using NO ADDITIONAL STORAGE.
*/

-- 🔴 Clone the whole database. Watch the clock.
CREATE OR REPLACE DATABASE childcare_dev CLONE childcare_audit;

--   ▶ Done. Instantly. A full copy of every table.

SELECT COUNT(*) AS cloned_rows FROM childcare_dev.raw.raw_subsidy_claims;   -- 613

/*  ★ HOW IS THIS INSTANT, AND HOW IS IT FREE?

    It did not copy any data. It copied POINTERS to the same immutable
    micro-partitions. Two databases, one set of underlying bytes.

    Storage cost of the clone at this moment: ZERO.

    ➤ You only start paying when you CHANGE something. Then — and only then —
      Snowflake writes new partitions for the changed data. You pay for the
      DELTA, not the copy. This is copy-on-write.
*/

-- Modify the clone. The original must not move.
DELETE FROM childcare_dev.raw.raw_subsidy_claims;

SELECT
    (SELECT COUNT(*) FROM childcare_dev.raw.raw_subsidy_claims)  AS clone_rows,   -- 0
    (SELECT COUNT(*) FROM childcare_audit.raw.raw_subsidy_claims) AS prod_rows;   -- 613
--   ▶ Fully independent. We nuked the clone. Production is untouched.

/*  ★ WHY THIS CHANGES HOW TEAMS WORK — this is the real point:

    "Can I test this migration against production data?"

    Every other platform:  No. Copying 40TB takes all weekend and doubles
                           the storage bill. Use a 1% sample and hope.

    Snowflake:             CREATE DATABASE dev CLONE prod;
                           Done. Full production data. Instant. Free.
                           Break it as hard as you like. Drop it after.

    ➤ Say this in an interview and the person opposite you will know you have
      actually used the platform, not just read about it.
*/

DROP DATABASE IF EXISTS childcare_dev;


/* ═══════════════════════════════════════════════════════════════════════════
   PART 7 — RBAC: WHY YOU DON'T GET ACCOUNTADMIN AT WORK
   ═══════════════════════════════════════════════════════════════════════════

   Snowflake's default role hierarchy:

       ACCOUNTADMIN        ← billing, resource monitors. The nuclear codes.
        ├── SYSADMIN       ← creates and owns databases/warehouses. ★ real work happens here
        │    └── (custom roles: ANALYST, ENGINEER, ...)
        ├── SECURITYADMIN  ← manages users, roles, grants
        │    └── USERADMIN
        └── PUBLIC         ← everyone gets this. Grant it almost nothing.

   ★ You are ACCOUNTADMIN today ONLY because it's a trial account and you had
     to create a resource monitor. On a real job you will not be, and you
     should not be. Principle of least privilege.

   In a GOVERNMENT context this is not bureaucracy — it is the entire point.
   The analyst investigating subsidy fraud must NOT be able to EDIT the
   subsidy claims. That separation is what makes the audit credible.
*/

USE ROLE SECURITYADMIN;

-- A read-only analyst role — what you'd actually be given on the job.
CREATE ROLE IF NOT EXISTS childcare_analyst
    COMMENT = 'Read-only. Can investigate. Cannot alter the evidence.';

GRANT USAGE  ON WAREHOUSE mdp_wh                     TO ROLE childcare_analyst;
GRANT USAGE  ON DATABASE  childcare_audit            TO ROLE childcare_analyst;
GRANT USAGE  ON SCHEMA    childcare_audit.raw        TO ROLE childcare_analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA childcare_audit.raw TO ROLE childcare_analyst;

-- ★ FUTURE GRANTS — the one people forget and then debug for an hour:
GRANT SELECT ON FUTURE TABLES IN SCHEMA childcare_audit.raw TO ROLE childcare_analyst;
--   Without this, any table created TOMORROW is invisible to this role.
--   "It works for me but not for her" is almost always a missing future grant.

GRANT ROLE childcare_analyst TO USER IDENTIFIER(CURRENT_USER());

-- Try it on:
USE ROLE childcare_analyst;
USE WAREHOUSE mdp_wh;
USE DATABASE childcare_audit;
USE SCHEMA raw;

SELECT COUNT(*) AS i_can_read FROM raw_subsidy_claims;   -- ✅ works

-- ❌ But this is refused — as it should be:
-- DELETE FROM raw_subsidy_claims;
--    "Insufficient privileges to operate on table"
--    ★ The analyst can INVESTIGATE the evidence. They cannot ALTER it.
--      In an audit, that constraint is what makes your findings believable.

USE ROLE SYSADMIN;   -- back to normal


/* ═══════════════════════════════════════════════════════════════════════════
   PART 8 — WHAT DID TONIGHT COST?
   ═══════════════════════════════════════════════════════════════════════════ */

SELECT
    WAREHOUSE_NAME,
    ROUND(SUM(CREDITS_USED), 4)  AS credits_used_today
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD(day, -1, CURRENT_TIMESTAMP())
GROUP BY 1;
--   ⚠️ ACCOUNT_USAGE lags up to ~45 min. Empty result = latency, not an error.

-- Check the guardrails held:
SHOW RESOURCE MONITORS;

-- ── 🔒 END OF SESSION HABIT — do this every single time ────────────────────
ALTER WAREHOUSE mdp_wh SUSPEND;
--   Auto-suspend would do it in 60s anyway. Build the habit regardless.


/* ═══════════════════════════════════════════════════════════════════════════
   ★★★ THE BRIDGE TO WORKSHOP 3 ★★★
   ═══════════════════════════════════════════════════════════════════════════

   INSTRUCTOR: end the session on this. Run it. Let them look at it.

   Here is the audit query we wrote tonight. LOOK AT IT.
*/

WITH monthly_claims AS (
    SELECT
        o.operator_id,
        TRIM(o.operator_name)                    AS operator_name,
        UPPER(TRIM(o.region))                    AS region,
        c.claim_month,
        TRY_TO_NUMBER(o.licensed_capacity)       AS licensed_capacity,
        SUM(TRY_TO_NUMBER(c.claimed_children))   AS children_claimed
    FROM raw_subsidy_claims c
    LEFT JOIN raw_facilities f ON c.facility_id = f.facility_id
    LEFT JOIN raw_operators  o ON f.operator_id = o.operator_id
    WHERE o.operator_id IS NOT NULL
      AND o.licensed_capacity IS NOT NULL
    GROUP BY 1,2,3,4,5
)
SELECT operator_id, operator_name, COUNT(*) AS months_in_breach
FROM monthly_claims
WHERE children_claimed > licensed_capacity
GROUP BY 1,2
HAVING COUNT(*) >= 3
ORDER BY months_in_breach DESC;


/*  🛑 NOW BE HONEST ABOUT WHAT WE JUST BUILT.

    It works. It found the fraud. And it is a LIABILITY.

    ① THREE JOINS to answer ONE question.
       And I have to write those same three joins EVERY TIME. Every question.
       Forever.

    ② TRIM() and UPPER() and TRY_TO_NUMBER() SCATTERED THROUGH THE LOGIC.
       If I forget TRIM() in one query and remember it in another, those two
       queries return DIFFERENT ANSWERS. Both look correct. Nobody notices.

    ③ IT IS FRAGILE.
       Someone renames a column in the source. Every query I have ever written
       breaks at once, silently, and I find out when a Deputy Minister asks
       why the number moved.

    ④ I RUN THIS EVERY MONTH.
       Rewriting it, re-checking it, re-explaining it. Forever.

    ⑤ THE BUSINESS LOGIC IS TRAPPED INSIDE A QUERY.
       "What is a breach?" is a POLICY DECISION. Right now it lives buried in
       a HAVING clause in a file on my laptop. When I leave, it leaves with me.

    ★ THIS IS NOT A SQL PROBLEM. WE ALREADY WON THE SQL.
      THIS IS A STRUCTURE PROBLEM.

    The data is organised for the SYSTEM THAT COLLECTED IT.
    It is not organised for the QUESTIONS WE KEEP ASKING.

    ═══════════════════════════════════════════════════════════════════════

    NEXT WEEK — WORKSHOP 3: we fix it properly.

      · DIMENSIONAL MODELLING — facts and dimensions. Clean the mess ONCE,
        in ONE place, and every query downstream inherits it.
      · CLUSTERING & PRUNING — make Snowflake skip the data it doesn't need,
        and watch "partitions scanned" actually drop.
      · MATERIALIZED VIEWS — compute it once, not every month.
      · STREAMS & TASKS — make it run itself.

    And when we're done, that query above becomes about four lines — and it
    will be FASTER, and it will still be right when someone renames a column.

    ═══════════════════════════════════════════════════════════════════════

    ★ ALSO: what you covered tonight — architecture, warehouses, caching,
      stages and loading, Time Travel, cloning, RBAC — is a real chunk of the
      SNOWPRO CORE certification surface area.

      After next week you will have touched most of it. If you want the cert,
      you will be REVISING, not starting from zero. Put it on your resume.

   ═══════════════════════════════════════════════════════════════════════════ */