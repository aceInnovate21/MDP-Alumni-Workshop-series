/* ═══════════════════════════════════════════════════════════════════════════
   WORKSHOP 3 — SCRIPT 04
   ONE MODEL, TWO QUESTIONS — THE PAYOFF

   ---------------------------------------------------------------------------
   THIS IS THE WHOLE POINT OF TONIGHT
   ---------------------------------------------------------------------------

   We built a star schema. Now watch what it buys us.

   Last week's audit was a 3-join, patch-everywhere, 30-line query that only
   answered ONE question and that nobody could reuse.

   Tonight we answer TWO COMPLETELY DIFFERENT questions —
       · a COMPLIANCE question (who is over capacity? — the audit)
       · a POLICY question    (is funding fair across regions?)
   — and each is a short, clean query against the same model. No cleaning.
   No patches. Just join the star on keys and ask.

   And we save each as a VIEW: a named, saved query the Ministry can run every
   month forever. The business logic finally lives in a real object, not in a
   HAVING clause on someone's laptop.

   ---------------------------------------------------------------------------
   VIEW vs MATERIALIZED VIEW — the "how do we make it repeatable" answer
   ---------------------------------------------------------------------------

     VIEW (regular)
       A saved query. Runs against live data EVERY time it's called.
       Always current. Costs nothing to store. Recomputes on each read.
       ➤ Right when data changes and you always want the latest — like a
         monthly audit over freshly-loaded claims.

     MATERIALIZED VIEW
       A saved query whose RESULT is precomputed and stored. Fast to read,
       but costs storage and must refresh as base data changes.
       ➤ Right for an expensive aggregation hit by many users/dashboards.

   Both our views are REGULAR views: the Ministry wants the latest numbers
   each month, and the queries are cheap. We'll note where a materialized view
   would be the better call instead.

   ═══════════════════════════════════════════════════════════════════════════ */

USE ROLE      SYSADMIN;
USE WAREHOUSE mdp_wh;
USE DATABASE  childcare_audit;
USE SCHEMA    analytics;


/* ═══════════════════════════════════════════════════════════════════════════
   VIEW 1 — THE CAPACITY AUDIT   (compliance lens)
   ═══════════════════════════════════════════════════════════════════════════

   The same question as W2: which operators claim beyond their licensed
   capacity, persistently? But look how it reads now — the cleaning is gone,
   the SCD history is handled by the model, and the logic is legible.

   ★ Because the fact is wired to the SCD-correct capacity, each month is
     automatically judged against the capacity that applied THAT month.
*/

CREATE OR REPLACE VIEW v_capacity_audit AS
WITH monthly AS (
    SELECT
        o.operator_id,
        o.operator_name,
        o.region,
        dd.claim_month,
        o.licensed_capacity                 AS capacity_in_force,   -- SCD-correct
        SUM(f.claimed_children)             AS children_claimed,
        SUM(f.claim_amount)                 AS amount_claimed
    FROM fact_subsidy_claims f
    JOIN dim_operator o  ON f.operator_key = o.operator_key
    JOIN dim_date     dd ON f.date_key      = dd.date_key
    WHERE o.licensed_capacity IS NOT NULL
    GROUP BY 1, 2, 3, 4, 5
)
SELECT
    operator_id,
    operator_name,
    region,
    capacity_in_force,
    COUNT(*)                                                   AS months_in_breach,
    MAX(children_claimed)                                      AS peak_claimed,
    SUM(children_claimed - capacity_in_force)                 AS total_excess_children,
    ROUND(SUM(amount_claimed
        * (children_claimed - capacity_in_force)
        / NULLIF(children_claimed, 0)), 2)                    AS est_excess_value
FROM monthly
WHERE children_claimed > capacity_in_force
GROUP BY 1, 2, 3, 4
HAVING COUNT(*) >= 3                     -- persistent breaches only (the W2 judgment)
ORDER BY est_excess_value DESC;

-- Run it. Same finding as W2 — but now it's ONE named object, reusable forever.
SELECT * FROM v_capacity_audit;
--   EXPECT: the persistent breachers (Chinook, Maple Place, Harmony …),
--           with dollar values. The Ministry runs this monthly by typing
--           one line:  SELECT * FROM v_capacity_audit;


/* ═══════════════════════════════════════════════════════════════════════════
   VIEW 2 — FUNDING EQUITY BY REGION   (policy lens)
   ═══════════════════════════════════════════════════════════════════════════

   A COMPLETELY different question, for a completely different audience.
   Not "who is cheating?" but "is public money distributed fairly?"

   Same star. Same dimensions. No new cleaning. We just slice the fact by a
   different dimension (region) and ask a different thing.

   ★ THIS is the argument for dimensional modelling in one gesture: build the
     model once, and questions you didn't anticipate become easy.
*/

CREATE OR REPLACE VIEW v_funding_by_region AS
SELECT
    o.region,
    COUNT(DISTINCT o.operator_id)                        AS operators,
    COUNT(DISTINCT f.facility_key)                       AS facilities,
    SUM(f.claimed_children)                              AS total_children_claimed,
    ROUND(SUM(f.claim_amount), 2)                        AS total_funding,
    -- the equity metric: funding per child. Are some regions funded more
    -- generously per child than others?
    ROUND(SUM(f.claim_amount) / NULLIF(SUM(f.claimed_children), 0), 2)
                                                         AS funding_per_child
FROM fact_subsidy_claims f
JOIN dim_operator o ON f.operator_key = o.operator_key
WHERE f.claim_status = 'Approved'        -- only money actually approved
GROUP BY o.region
ORDER BY total_funding DESC;

SELECT * FROM v_funding_by_region;
--   EXPECT: 5 regions, with total funding and funding-per-child. The
--           per-child column is the interesting one — it turns a raw total
--           into a fairness question a Deputy Minister can act on.


/* ═══════════════════════════════════════════════════════════════════════════
   THE TWO VIEWS, SIDE BY SIDE — why this matters
   ═══════════════════════════════════════════════════════════════════════════

   v_capacity_audit      — COMPLIANCE. Catches wrongdoing. For investigators.
   v_funding_by_region   — POLICY. Informs fairness. For decision-makers.

   Two different audiences. Two different purposes. Two different questions.
   ONE model underneath, and each view is a handful of readable lines.

   Compare that to W2, where ONE question took 30 lines of patched SQL and
   couldn't be reused. THAT is the return on building a model.

   And notice what we did NOT have to do in either view:
     ✗ no TRIM / UPPER — the region was cleaned once, in dim_operator
     ✗ no TRY_TO_NUMBER — capacity and amount were typed once, upstream
     ✗ no 3-way join gymnastics — we join the star on clean integer keys
     ✗ no worrying about capacity history — the SCD model handled it

   ---------------------------------------------------------------------------
   WHERE A MATERIALIZED VIEW WOULD FIT
   ---------------------------------------------------------------------------
   If v_funding_by_region powered a dashboard opened by 50 people every
   morning, recomputing the full aggregation on every open would be wasteful.
   THAT is when you'd switch it to a MATERIALIZED VIEW — precompute once,
   serve many. For a monthly audit run by a handful of analysts, a regular
   view is exactly right.

     -- (illustrative — needs Enterprise edition)
     -- CREATE MATERIALIZED VIEW mv_funding_by_region AS SELECT ... ;
*/


/* ═══════════════════════════════════════════════════════════════════════════
   THE BRIDGE TO WORKSHOP 4
   ═══════════════════════════════════════════════════════════════════════════

   We fixed everything we complained about last week:
     ✔ no more repeated joins        — the model joins once, on keys
     ✔ no more scattered cleaning     — done once, in the dimensions
     ✔ not fragile                    — the model absorbs source changes
     ✔ repeatable                     — SELECT * FROM v_capacity_audit;
     ✔ logic lives in a real object   — a named VIEW, not a laptop file
     ✔ and it answers MORE than we asked — funding equity, for free

   But look at what we're still handing over: a grid of numbers in a SQL
   worksheet.

   The Deputy Minister does not open Snowflake. The investigator does not read
   SQL. A regional funding table means nothing to most of the people who need
   to ACT on it.

   NEXT WEEK — WORKSHOP 4: we connect Power BI straight to these two views and
   turn them into something a decision-maker can actually see — a breach
   dashboard and a regional funding map. Same model. Same views. A human face.

   ═══════════════════════════════════════════════════════════════════════════ */
