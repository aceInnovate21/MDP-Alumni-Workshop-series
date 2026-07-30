/* ═══════════════════════════════════════════════════════════════════════════
   WORKSHOP 3 — SCRIPT 01
   WHERE WE LEFT OFF: THE REPEATABLE-AUDIT PROBLEM

   Prerequisite: Workshop 2 completed. The RAW schema is loaded:
     CHILDCARE_AUDIT.RAW.RAW_OPERATORS      (40)
     CHILDCARE_AUDIT.RAW.RAW_FACILITIES     (53)
     CHILDCARE_AUDIT.RAW.RAW_ENROLLMENT     (1,883)
     CHILDCARE_AUDIT.RAW.RAW_SUBSIDY_CLAIMS (613)
     CHILDCARE_AUDIT.RAW.RAW_INSPECTIONS    (79)

   If RAW isn't there, re-run W2 scripts 02–03 first.

   ---------------------------------------------------------------------------
   THE STORY SO FAR
   ---------------------------------------------------------------------------

   Last week we cracked a real audit: three childcare operators claiming
   subsidies beyond their licensed capacity, ~$444K in excess claims.

   And we ended on an uncomfortable truth. The query that found it was a
   LIABILITY:
       · three joins, rewritten every single time
       · TRIM / UPPER / TRY_TO_NUMBER scattered everywhere
       · fragile — one renamed column breaks everything
       · run monthly, by hand, forever
       · the business logic ("what IS a breach?") trapped in a HAVING clause
         in a file on someone's laptop

   ---------------------------------------------------------------------------
   TONIGHT'S QUESTION
   ---------------------------------------------------------------------------

   The Ministry doesn't run this audit ONCE. They run it EVERY MONTH. Forever.
   New claims arrive, the question stays the same.

   So the real problem isn't "can I find the breach?" — we did that.
   The problem is: HOW DO WE MAKE THIS REPEATABLE?

   ➤ The answer is a VIEW — a saved, named query the Ministry can just run.
   ➤ But a view is only as clean as the data underneath it.
   ➤ So first, we have to reshape the data properly. That's DIMENSIONAL
     MODELLING — and it's the whole workshop.

   And once the model exists, we get a bonus: the SAME model answers
   COMPLETELY DIFFERENT questions. We'll build TWO views on one model —
   one for compliance (the audit), one for policy (funding fairness).

   ═══════════════════════════════════════════════════════════════════════════ */

USE ROLE      SYSADMIN;
USE WAREHOUSE mdp_wh;
USE DATABASE  childcare_audit;
USE SCHEMA    raw;


/* ───────────────────────────────────────────────────────────────────────────
   FEEL THE PAIN ONE MORE TIME
   ───────────────────────────────────────────────────────────────────────────
   Run last week's audit query. It works. Look at how much machinery it takes
   to answer one question — and remember you rewrite ALL of it every month.
*/

WITH monthly_claims AS (
    SELECT
        o.operator_id,
        TRIM(o.operator_name)                    AS operator_name,   -- patch: whitespace
        UPPER(TRIM(o.region))                    AS region,          -- patch: 10 spellings
        c.claim_month,
        TRY_TO_NUMBER(o.licensed_capacity)       AS licensed_capacity, -- patch: text→number
        SUM(TRY_TO_NUMBER(c.claimed_children))   AS children_claimed
    FROM raw_subsidy_claims c
    LEFT JOIN raw_facilities f ON c.facility_id = f.facility_id       -- join #1
    LEFT JOIN raw_operators  o ON f.operator_id = o.operator_id       -- join #2
    WHERE o.operator_id       IS NOT NULL
      AND o.licensed_capacity IS NOT NULL
    GROUP BY 1, 2, 3, 4, 5
)
SELECT operator_id, operator_name, COUNT(*) AS months_in_breach
FROM monthly_claims
WHERE children_claimed > licensed_capacity
GROUP BY 1, 2
HAVING COUNT(*) >= 3
ORDER BY months_in_breach DESC;

/*  👀 Every TRIM, every UPPER, every TRY_TO_NUMBER, every JOIN is a patch over
    a data-quality defect — and it lives INSIDE the question logic.

    Mix "how do I clean the data" with "what is a breach" in one query and you
    get something nobody can reuse, nobody can trust, and nobody but you can
    maintain.

    ➤ The fix is to SEPARATE the two jobs:
        1. Clean and structure the data  → the MODEL (dimensions + facts)
        2. Ask the business question      → the VIEW (short, clean, named)

    That separation is what the rest of tonight builds.

    NEXT: 02_dimensional_model_dims.sql — we build the dimensions.
   ═══════════════════════════════════════════════════════════════════════════ */
