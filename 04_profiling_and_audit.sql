/* ═══════════════════════════════════════════════════════════════════════════
   WORKSHOP 2 — SCRIPT 04
   PROFILING & THE AUDIT INVESTIGATION

   ---------------------------------------------------------------------------
   THE BRIEF
   ---------------------------------------------------------------------------

   A Ministry auditor has a suspicion:

     "Some licensed childcare operators may be claiming subsidies for more
      children than their licence permits. Find out if that's true."

   That is a BUSINESS PROBLEM. It is not a query. You cannot type it into
   Snowflake.

   Getting from that sentence to a defensible number is the actual job.

   ---------------------------------------------------------------------------
   THE FUNNEL — do not skip steps
   ---------------------------------------------------------------------------

     Business problem   "Are operators over-claiming?"
            ▼
     Analytical question "For each operator and month, does the number of
                         children claimed exceed licensed capacity?"
            ▼
     Data question      "claimed_children (subsidy_claims, via facility)
                         vs licensed_capacity (operators) — grouped how?"
            ▼
     Query
            ▼
     Finding            "Three operators breach persistently. Five breach once."
            ▼
     Recommendation     "Investigate these three. The other five are noise."

   ★ Most people jump straight to the query. That's why they produce answers
     nobody asked for, and miss the answer somebody needed.

   ═══════════════════════════════════════════════════════════════════════════ */

USE ROLE      SYSADMIN;
USE WAREHOUSE mdp_wh;
USE DATABASE  childcare_audit;
USE SCHEMA    raw;


/* ═══════════════════════════════════════════════════════════════════════════
   PART 1 — PROFILE FIRST. ALWAYS. NO EXCEPTIONS.
   ═══════════════════════════════════════════════════════════════════════════

   Before you answer ANY question with this data, you must know what's in it.

   An analyst who queries before profiling is an analyst who will confidently
   present a wrong number. And confidence plus wrong is how careers end.
*/

-- ── 1.1 Shape: how much of what? ────────────────────────────────────────────
SELECT 'operators'      AS tbl, COUNT(*) AS row_count FROM raw_operators
UNION ALL SELECT 'facilities',     COUNT(*) FROM raw_facilities
UNION ALL SELECT 'enrollment',     COUNT(*) FROM raw_enrollment
UNION ALL SELECT 'subsidy_claims', COUNT(*) FROM raw_subsidy_claims
UNION ALL SELECT 'inspections',    COUNT(*) FROM raw_inspections
ORDER BY tbl;


-- ── 1.2 Time coverage: what period are we even looking at? ──────────────────
SELECT
    MIN(claim_month)             AS first_month,
    MAX(claim_month)             AS last_month,
    COUNT(DISTINCT claim_month)  AS distinct_months,
    COUNT(DISTINCT facility_id)  AS facilities_claiming
FROM raw_subsidy_claims;
--   👀 12 months of 2025. Good — a full year. Seasonality won't fool us.


-- ── 1.3 ★ THE REGION PROBLEM — a 30-second lesson in why profiling matters ──
SELECT
    region,
    COUNT(*) AS operators
FROM raw_operators
GROUP BY region
ORDER BY region;

/*  👀 LOOK AT THIS OUTPUT.

    You will see something like:
        " Calgary"    1
        "Calgary"     6
        "EDMONTON"    1
        "Edmonton"    7
        "Nrth"        1        ← a typo
        "calgary "    1
        "edmonton"    1
        ...

    THERE ARE 5 REGIONS IN ALBERTA. This query returned about 10 groups.

    If you had built a regional dashboard on this without looking first,
    you would have shipped a chart with "Edmonton" appearing three separate
    times, and someone senior would have noticed before you did.

    THIS IS WHY YOU PROFILE.
*/

-- The fix — but note we are DIAGNOSING here, not yet cleaning:
SELECT
    UPPER(TRIM(region))  AS region_normalized,
    COUNT(*)             AS operators
FROM raw_operators
GROUP BY 1
ORDER BY 1;
--   Better. But "NRTH" is still there — TRIM and UPPER cannot fix a typo.
--   Some dirt needs a human decision. That's a mapping table, not a function.


-- ── 1.4 ★ NULLs in the DENOMINATOR — the one that would sink the audit ──────
SELECT
    COUNT(*)                                               AS total_operators,
    COUNT(licensed_capacity)                               AS capacity_present,
    SUM(CASE WHEN licensed_capacity IS NULL THEN 1 ELSE 0 END) AS capacity_missing
FROM raw_operators;

-- Who are they?
SELECT operator_id, operator_name, license_status, licensed_capacity
FROM raw_operators
WHERE licensed_capacity IS NULL;

/*  🛑 STOP AND THINK. This matters more than it looks.

    Our entire audit is:   claimed_children  >  licensed_capacity

    For two operators, licensed_capacity IS NULL.

    In SQL, `50 > NULL` is not TRUE. It is not FALSE. It is NULL.
    A WHERE clause treats NULL as "not true" — so the row is DROPPED.

    ➤ These two operators will SILENTLY VANISH from your audit.
    ➤ They will never appear in your results.
    ➤ Nobody will tell you.

    If one of them is the biggest fraudster in the province, you will have
    missed them — and your report will say "we found three."

    WHAT DO YOU ACTUALLY DO?

      ❌ Ignore it                    — you just hid two operators
      ❌ Assume a default capacity    — you invented public-policy data. Never.
      ✅ REPORT IT SEPARATELY:
            "Two operators could not be assessed because licensed capacity
             is missing from the source system. This is itself a finding —
             the Ministry cannot audit what it has not recorded. Recommend
             data remediation before conclusions are drawn on these two."

    ★ THAT ANSWER IS THE WHOLE JOB. The gap in the data IS a finding.
      A junior analyst reports what the query returned.
      A good analyst reports what the query COULDN'T SEE.
*/


-- ── 1.5 Impossible values ───────────────────────────────────────────────────
SELECT
    'negative enrolled_count'          AS issue,
    COUNT(*)                           AS row_count
FROM raw_enrollment WHERE TRY_TO_NUMBER(enrolled_count) < 0

UNION ALL
SELECT 'zero enrolled_count', COUNT(*)
FROM raw_enrollment WHERE TRY_TO_NUMBER(enrolled_count) = 0

UNION ALL
SELECT 'subsidized > enrolled (impossible)', COUNT(*)
FROM raw_enrollment
WHERE TRY_TO_NUMBER(subsidized_count) > TRY_TO_NUMBER(enrolled_count)

UNION ALL
SELECT 'claim_amount not numeric', COUNT(*)
FROM raw_subsidy_claims
WHERE TRY_TO_NUMBER(claim_amount) IS NULL AND claim_amount IS NOT NULL;

/*  ★ TRY_TO_NUMBER vs TO_NUMBER — learn this distinction, it's on the cert:

      TO_NUMBER('abc')      → ERROR. Query dies.
      TRY_TO_NUMBER('abc')  → NULL. Query survives. You can COUNT the failures.

    The TRY_ family (TRY_TO_NUMBER, TRY_TO_DATE, TRY_CAST...) is how you
    PROFILE dirty data without your session exploding every time you hit a
    bad value. Use TRY_ to investigate; use strict casts once you know it's clean.
*/

-- Look at the actual offenders:
SELECT claim_id, claim_amount
FROM raw_subsidy_claims
WHERE TRY_TO_NUMBER(claim_amount) IS NULL
  AND claim_amount IS NOT NULL;
--   👀 "$12,450.00" — dollar signs and thousands separators.
--      SUM(claim_amount) on this column would fail or mislead.


-- ── 1.6 Referential integrity — do the joins actually hold? ─────────────────

-- Facilities pointing at an operator that does not exist:
SELECT f.facility_id, f.operator_id, f.facility_name
FROM raw_facilities f
LEFT JOIN raw_operators o ON f.operator_id = o.operator_id
WHERE o.operator_id IS NULL;
--   👀 FAC0053 → OP9999. That operator does not exist.

-- Enrollment pointing at a facility that does not exist:
SELECT e.enrollment_id, e.facility_id, e.enrollment_month
FROM raw_enrollment e
LEFT JOIN raw_facilities f ON e.facility_id = f.facility_id
WHERE f.facility_id IS NULL;
--   👀 Two rows → FAC8888. No such facility.

/*  ★ WHY THIS IS DANGEROUS, and it's subtle:

    If you write your audit with an INNER JOIN, these orphans are silently
    dropped. Your query "works". Your totals are quietly short.

    An INNER JOIN is an ASSERTION: "I am certain every row has a match."
    Snowflake will not warn you when that assertion is false. It will just
    hand you a smaller number and let you present it.

    ➤ Use LEFT JOIN when you are INVESTIGATING.
    ➤ Use INNER JOIN only once you have PROVEN the relationship holds.
*/


-- ── 1.7 Duplicates — the double-billing check ───────────────────────────────
/*  A subsidy claim should be ONE per facility per month.
    That's the grain. Anything else is a double-claim.
*/
SELECT
    facility_id,
    claim_month,
    COUNT(*)                        AS claim_count,
    LISTAGG(claim_id, ', ')         AS claim_ids
FROM raw_subsidy_claims
GROUP BY facility_id, claim_month
HAVING COUNT(*) > 1;

--   👀 One facility/month has TWO claims. That is public money claimed twice.
--      Note the two claim_ids — they are DIFFERENT ids, same facility, same
--      month. This is not a copy-paste error in the data; it's a duplicate
--      SUBMISSION, and that's exactly what an auditor is looking for.

-- Look at them side by side:
SELECT *
FROM raw_subsidy_claims
WHERE (facility_id, claim_month) IN (
    SELECT facility_id, claim_month
    FROM raw_subsidy_claims
    GROUP BY facility_id, claim_month
    HAVING COUNT(*) > 1
)
ORDER BY facility_id, claim_month, claim_id;


-- ── 1.8 The anomaly nobody looks for: UNDER-claiming ────────────────────────
/*  Everyone hunts for over-claiming. Almost nobody checks the other direction.

    A facility with enrolled, subsidy-eligible children but ZERO claims is
    also a problem — the operator is leaving money on the table, or their
    records are broken. Either way, the Ministry should know.
*/
SELECT
    f.facility_id,
    f.facility_name,
    o.operator_name,
    COUNT(DISTINCT e.enrollment_month)          AS months_with_enrollment,
    SUM(TRY_TO_NUMBER(e.subsidized_count))      AS total_subsidized_children
FROM raw_facilities f
JOIN raw_enrollment e ON f.facility_id = e.facility_id
LEFT JOIN raw_operators o ON f.operator_id = o.operator_id
WHERE f.facility_id NOT IN (SELECT DISTINCT facility_id FROM raw_subsidy_claims)
GROUP BY f.facility_id, f.facility_name, o.operator_name;

--   👀 A facility with subsidy-eligible children, enrolled all year,
--      and not one claim submitted. Why? Nobody was looking.
--
--   ★ Finding an anomaly nobody asked you to look for is how you get noticed.


/* ═══════════════════════════════════════════════════════════════════════════
   PART 2 — 🛑 PUT THE KEYBOARD DOWN. FRAME THE QUESTION. 🛑
   ═══════════════════════════════════════════════════════════════════════════

   INSTRUCTOR: stop typing. Ask the room. Do not move on until they answer.

   The auditor said: "operators claiming beyond capacity."

   Turn that into arithmetic. Every one of these is a real decision:

   Q1. WHAT GRAIN?
       Claims are per FACILITY. Licences are per OPERATOR.
       An operator can run 3 facilities.
       → Do we compare per facility, or roll all facilities up to the operator?
       → THE LICENCE IS THE CONSTRAINT. Roll up to OPERATOR. ★

   Q2. WHAT TIME WINDOW?
       One month? A whole year? The average?
       → Monthly. A licence is a limit at a point in time, not an annual budget.

   Q3. WHICH NUMBER?
       claimed_children (what they asked for)?
       Or enrolled_count (who actually attends)?
       → CLAIMED. The auditor is asking about the CLAIM, not attendance.
         Attendance is a different — and also interesting — question.

   Q4. WHAT COUNTS AS A BREACH?
       claimed > capacity, strictly?
       Or allow a tolerance (say 5%) for legitimate timing/rounding?
       → Start strict. See what falls out. Then decide.

   Q5. ★ THE ONE THAT SEPARATES ANALYSTS FROM QUERY-WRITERS ★
       Is a ONE-MONTH breach the same as a NINE-MONTH breach?
       → Absolutely not. And this is what we're about to see.

   ═══════════════════════════════════════════════════════════════════════════ */


/* ═══════════════════════════════════════════════════════════════════════════
   PART 3 — THE AUDIT QUERY
   ═══════════════════════════════════════════════════════════════════════════ */

-- ── 3.1 First attempt: claims → facility → operator, monthly ────────────────
SELECT
    o.operator_id,
    TRIM(o.operator_name)                        AS operator_name,
    UPPER(TRIM(o.region))                        AS region,
    c.claim_month,
    TRY_TO_NUMBER(o.licensed_capacity)           AS licensed_capacity,
    SUM(TRY_TO_NUMBER(c.claimed_children))       AS children_claimed
FROM raw_subsidy_claims c
LEFT JOIN raw_facilities f ON c.facility_id = f.facility_id
LEFT JOIN raw_operators  o ON f.operator_id = o.operator_id
WHERE o.operator_id IS NOT NULL
GROUP BY 1, 2, 3, 4, 5
ORDER BY o.operator_id, c.claim_month
LIMIT 30;

/*  ★ NOTE WHAT WE ALREADY HAD TO DO, and none of it is "SQL skill":
      TRIM(operator_name)       — because the source has whitespace
      UPPER(TRIM(region))       — because the source has 10 spellings of 5 regions
      TRY_TO_NUMBER(capacity)   — because the source stored a number as text
      LEFT JOIN, not INNER      — because we know there's an orphan facility

    Every single one of those is a patch over a data quality defect.
    You are not writing a query. You are negotiating with reality.
*/


-- ── 3.2 ★★★ THE FINDING ★★★ ────────────────────────────────────────────────
WITH monthly_claims AS (
    SELECT
        o.operator_id,
        TRIM(o.operator_name)                    AS operator_name,
        o.operator_type,
        UPPER(TRIM(o.region))                    AS region,
        o.license_status,
        c.claim_month,
        TRY_TO_NUMBER(o.licensed_capacity)       AS licensed_capacity,
        SUM(TRY_TO_NUMBER(c.claimed_children))   AS children_claimed
    FROM raw_subsidy_claims c
    LEFT JOIN raw_facilities f ON c.facility_id = f.facility_id
    LEFT JOIN raw_operators  o ON f.operator_id = o.operator_id
    WHERE o.operator_id        IS NOT NULL     -- exclude the orphan facility
      AND o.licensed_capacity  IS NOT NULL     -- ⚠️ excludes 2 operators. REPORT THIS.
    GROUP BY 1, 2, 3, 4, 5, 6, 7
),
breaches AS (
    SELECT
        *,
        children_claimed - licensed_capacity                        AS excess_children,
        ROUND(children_claimed / NULLIF(licensed_capacity, 0), 2)   AS capacity_ratio
        --                       ^^^^^^ NULLIF guards divide-by-zero. Always.
    FROM monthly_claims
    WHERE children_claimed > licensed_capacity
)
SELECT
    operator_id,
    operator_name,
    operator_type,
    region,
    license_status,
    licensed_capacity,
    COUNT(*)                     AS months_in_breach,   -- ★ THE KEY COLUMN
    MAX(children_claimed)        AS peak_claimed,
    MAX(excess_children)         AS peak_excess,
    ROUND(AVG(capacity_ratio),2) AS avg_capacity_ratio,
    LISTAGG(claim_month, ', ') WITHIN GROUP (ORDER BY claim_month) AS breach_months
FROM breaches
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY months_in_breach DESC, peak_excess DESC;


/*  ═══════════════════════════════════════════════════════════════════════
    🛑 THE MOST IMPORTANT MOMENT IN THIS WORKSHOP. 🛑
    ═══════════════════════════════════════════════════════════════════════

    LOOK AT months_in_breach. The results split into TWO CLEAR GROUPS:

    ┌─ GROUP 1: PERSISTENT ────────────────────────────────────────────────┐
    │                                                                      │
    │   OP0004  Chinook House        cap 50   9 months   peaked at 121     │
    │   OP0017  Maple Place          cap 50   9 months   peaked at  86     │
    │   OP0029  Harmony Beginnings   cap 50   7 months   peaked at 100     │
    │                                                                      │
    │   → 121 children claimed against a 50-child licence.                 │
    │   → For NINE MONTHS. That is not an accident.                        │
    │   → THIS IS A FINDING. Escalate it.                                  │
    └──────────────────────────────────────────────────────────────────────┘

    ┌─ GROUP 2: INCIDENTAL ────────────────────────────────────────────────┐
    │                                                                      │
    │   OP0026  Willow Steps    cap  80   2 months   over by 8             │
    │   OP0025  Riverbend Nest  cap 150   1 month    over by 21            │
    │   OP0003  Aspen Learners  cap 150   1 month    over by 16            │
    │   OP0018  Lakeside        cap 150   1 month    over by 5             │
    │   OP0032  Meadow Care     cap 100   1 month    over by 4             │
    │                                                                      │
    │   → One month. A handful of children over. Then back to normal.      │
    │   → Is this fraud? Almost certainly not.                             │
    │   → Enrolment timing? A child counted twice during a transfer?       │
    │      A data entry slip? Seasonal intake?                             │
    │   → THIS IS A QUESTION, NOT A FINDING.                               │
    └──────────────────────────────────────────────────────────────────────┘

    ★ NOW LOOK AT THE DISTRIBUTION OF months_in_breach:

           1 month  →  4 operators   ┐
           2 months →  1 operator    ├─ noise
           3 months →  0             │
           4 months →  0             │  ★ NOTHING HERE. A CLEAN GAP.
           5 months →  0             │
           6 months →  0             ┘
           7 months →  1 operator    ┐
           8 months →  0             ├─ signal
           9 months →  2 operators   ┘

    ★★ THE DATA SEPARATES ITSELF. There is a hole between 2 and 7. ★★

    That is not a coincidence and it is not something you assumed — it is
    something you FOUND. When someone challenges your threshold, you do not
    say "three felt right." You say:

      "The distribution is bimodal. Operators either breach once or twice —
       consistent with timing and data-entry noise — or they breach seven to
       nine times out of twelve. Nothing sits in between. I drew the line in
       the empty space the data gave me."

    ➤ THAT is a defensible threshold. Run the distribution query yourself
      before you defend a cutoff. Always.

    ★★ IF YOU REPORT ALL EIGHT AS "FRAUD", YOU ARE WRONG. ★★

    You will have accused five legitimate childcare operators — small
    businesses, non-profits, people who look after children — of defrauding
    the Government of Alberta, because you did not think about your own output.

    That is not a technical error. That is a professional failure.

    THE QUERY GAVE YOU EIGHT ROWS.
    THE ANALYSIS IS DECIDING THAT THREE OF THEM MATTER.

    A machine can produce the eight. Only you can produce the three.
    ★ THAT IS WHY YOU HAVE A JOB. ★

    ═══════════════════════════════════════════════════════════════════════ */


-- ── 3.2b ★ DERIVE THE THRESHOLD. DO NOT ASSUME IT. ★ ───────────────────────
/*  Before you draw a line, LOOK AT WHERE THE DATA ALREADY DREW ONE.

    Run this. It is the evidence behind the judgment call.
*/
WITH monthly_claims AS (
    SELECT
        o.operator_id,
        c.claim_month,
        TRY_TO_NUMBER(o.licensed_capacity)     AS capacity,
        SUM(TRY_TO_NUMBER(c.claimed_children)) AS claimed
    FROM raw_subsidy_claims c
    LEFT JOIN raw_facilities f ON c.facility_id = f.facility_id
    LEFT JOIN raw_operators  o ON f.operator_id = o.operator_id
    WHERE o.operator_id       IS NOT NULL
      AND o.licensed_capacity IS NOT NULL
    GROUP BY 1, 2, 3
),
per_operator AS (
    SELECT operator_id, COUNT(*) AS months_in_breach
    FROM monthly_claims
    WHERE claimed > capacity
    GROUP BY 1
)
SELECT
    months_in_breach,
    COUNT(*)                            AS num_operators,
    REPEAT('█', COUNT(*))               AS histogram
FROM per_operator
GROUP BY 1
ORDER BY months_in_breach;

/*  👀 THE OUTPUT IS THE ARGUMENT:

        1  ████     4 operators
        2  █        1 operator
        7  █        1 operator
        9  ██       2 operators

    ★ Nothing at 3, 4, 5, or 6. The distribution is BIMODAL.

    You did not choose "3 months" because it felt reasonable.
    You chose it because the data has a HOLE there, and you put the line in
    the hole. That is a threshold you can defend in a room full of lawyers.

    ➤ Whenever you set a cutoff — a threshold, a tolerance, an outlier rule —
      PLOT THE DISTRIBUTION FIRST. If there's a natural gap, use it. If there
      ISN'T one, then you are making a genuine policy judgment, and you must
      SAY SO out loud rather than hiding it in a HAVING clause.
*/


-- ── 3.3 CORROBORATE: does an independent source agree? ──────────────────────
/*  One source is a hypothesis. Two independent sources agreeing is a finding.

    We found the breach in the CLAIMS data.
    Do the INSPECTIONS — collected by different people, for a different
    purpose, at a different time — say the same thing?
*/
SELECT
    TRIM(o.operator_name)      AS operator_name,
    o.operator_id,
    i.inspection_date,
    i.result,
    i.finding_summary,
    i.follow_up_required
FROM raw_inspections i
JOIN raw_operators o ON i.operator_id = o.operator_id
WHERE o.operator_id IN ('OP0004', 'OP0017', 'OP0029')    -- our three
ORDER BY o.operator_id, i.inspection_date;

/*  👀 READ THIS CAREFULLY — and notice the evidence is UNEVEN:

    ┌──────────┬──────────────────────┬─────────────┬─────────────────────┐
    │ OP0029   │ Harmony Beginnings   │ Fail  ×2    │ "Capacity exceeded" │ ✓✓ STRONG
    │          │                      │ Jan + Mar   │  TWICE.             │
    ├──────────┼──────────────────────┼─────────────┼─────────────────────┤
    │ OP0004   │ Chinook House        │ Conditional │ "Capacity exceeded" │ ✓  GOOD
    ├──────────┼──────────────────────┼─────────────┼─────────────────────┤
    │ OP0017   │ Maple Place          │ Pass        │ "No findings"       │ ✗  NONE
    └──────────┴──────────────────────┴─────────────┴─────────────────────┘

    ★ TWO of our three are independently corroborated. A different person —
      an inspector, on a site visit, for a different purpose, at a different
      time — physically wrote down "Capacity exceeded."

      OP0029 failed inspection for it TWICE. Claims data and inspection data,
      collected independently, tell the same story. That is powerful.

    ★ But OP0017 is NOT corroborated. Their April inspection came back clean:
      Pass, no findings. And yet the claims data says they breached in NINE
      of twelve months, peaking at 86 children against a 50-child licence.

    🛑 SIT WITH THAT CONTRADICTION. Don't resolve it too fast.

    Does the clean inspection mean OP0017 is innocent?
      → Not necessarily. Perhaps the inspection landed in a compliant month.
        Perhaps the inspector counted children present that day, not children
        CLAIMED that month. Those are different numbers.

    Does it mean your case against OP0017 is weaker?
      → YES. Unambiguously. And you must SAY SO.

    ➤ Report the confidence you ACTUALLY HAVE, not the confidence you WISH
      you had:

        "Three operators show persistent breaches. Two are independently
         corroborated by inspection findings of 'Capacity exceeded' — OP0029
         on two separate visits. The third, OP0017, rests on claims data
         alone; its most recent inspection recorded no findings. That
         discrepancy is itself worth investigating, and I would recommend a
         site visit before any enforcement action."

    ★ That paragraph is why a Deputy Minister will trust the NEXT thing you
      tell them. Analysts who overclaim get believed once.
*/


-- ── 3.4 What is this actually worth? Put a dollar figure on it ─────────────
/*  ★ A finding without a number is an opinion.
    "Some operators over-claimed" gets nodded at.
    "$347,000 in excess claims across 25 breach-months" gets ACTED ON.
*/
WITH monthly AS (
    SELECT
        o.operator_id,
        TRIM(o.operator_name)                                     AS operator_name,
        c.claim_month,
        TRY_TO_NUMBER(o.licensed_capacity)                        AS capacity,
        SUM(TRY_TO_NUMBER(c.claimed_children))                    AS claimed,
        -- clean the currency: strip $ and commas, THEN cast
        SUM(TRY_TO_NUMBER(REPLACE(REPLACE(c.claim_amount,'$',''),',',''))) AS amount
    FROM raw_subsidy_claims c
    LEFT JOIN raw_facilities f ON c.facility_id = f.facility_id
    LEFT JOIN raw_operators  o ON f.operator_id = o.operator_id
    WHERE o.operator_id       IS NOT NULL
      AND o.licensed_capacity IS NOT NULL
    GROUP BY 1, 2, 3, 4
)
SELECT
    operator_id,
    operator_name,
    capacity,
    COUNT(*)                                                  AS months_in_breach,
    SUM(claimed - capacity)                                   AS total_excess_children,
    -- attribute the claim value proportionally to the excess
    ROUND(SUM(amount * (claimed - capacity) / NULLIF(claimed,0)), 2)
                                                              AS est_excess_claim_value
FROM monthly
WHERE claimed > capacity
GROUP BY 1, 2, 3
HAVING COUNT(*) >= 3          -- ★ PERSISTENT breaches only. This is the judgment
                              --   call from 3.2, encoded in the query.
ORDER BY est_excess_claim_value DESC;

/*  ★ Notice HAVING COUNT(*) >= 3.

    That single line is your analytical judgment, written into SQL.
    It says: "I have decided that a one-off month is noise, and a sustained
    pattern is a finding."

    ➤ You must be able to DEFEND that threshold. If someone asks "why 3?",
      "it felt right" is not an answer. "Because the data shows a clean
      separation between operators breaching 1-2 months and operators
      breaching 7-9 months, with nothing in between" — THAT is an answer.

    ➤ And you must DISCLOSE it. Burying a threshold inside a query and
      presenting the output as objective truth is how analysts mislead
      people without ever technically lying.
*/


/* ═══════════════════════════════════════════════════════════════════════════
   PART 4 — THE HONEST SUMMARY (what actually goes to the auditor)
   ═══════════════════════════════════════════════════════════════════════════ */

SELECT  'CONFIRMED'   AS severity,
        'Persistent capacity breach (7-9 of 12 months). Est. $444K excess claims. '
     || '2 of 3 corroborated by inspection.'                       AS finding,
        3             AS num_operators,
        'ESCALATE — recommend formal investigation'                AS recommendation

UNION ALL SELECT 'QUESTION',
        'Single-month breach, small excess. Consistent with enrolment timing or '
     || 'data entry. No pattern.',
        5, 'DO NOT ESCALATE — note only. Accusation would be unjust.'

UNION ALL SELECT 'BLOCKED',
        'Cannot assess: licensed_capacity is NULL in source system.',
        2, 'The GAP IS THE FINDING — Ministry cannot audit what it did not record.'

UNION ALL SELECT 'INTEGRITY',
        'Facility FAC0053 references operator OP9999, which does not exist.',
        1, 'Source system referential integrity failure — remediate.'

UNION ALL SELECT 'INTEGRITY',
        'Duplicate claim: FAC0003, 2025-07 (CLM000031 + CLM000613). Same '
     || 'facility, same month, two claims.',
        1, 'Potential double-billing of public funds — recover if paid twice.'

UNION ALL SELECT 'INTEGRITY',
        'Enrollment rows reference facility FAC8888, which does not exist.',
        1, 'Source system referential integrity failure — remediate.'

UNION ALL SELECT 'UNDER-CLAIMING',
        'FAC0013 (Lakeside Site 6): 485 subsidy-eligible children enrolled '
     || 'across the year, ZERO claims filed.',
        1, 'Operator may be owed money. Nobody was looking for this.'

ORDER BY severity;

/*  ★ NOTE THE LAST ROW. Nobody asked you to look for under-claiming.
    The auditor asked about operators taking TOO MUCH.

    You found an operator who enrolled 485 subsidy-eligible children and
    claimed for NONE of them. They may be owed money they never asked for.

    Finding the thing nobody asked you to look for is how you stop being
    "the person who runs the queries" and start being "the analyst."
*/

/*  ★ THE SHAPE OF THIS TABLE IS THE LESSON.

    A junior analyst hands over: "I found 8 operators over capacity."

    A professional hands over:
        - what is CONFIRMED (and how confident, and why)
        - what is a QUESTION (and explicitly says DON'T act on it yet)
        - what could NOT BE ASSESSED (and why — the gap is itself a finding)
        - what else turned up along the way

    The second person gets promoted. The first person gets a correction
    from someone more senior, in front of the room.
*/


/* ═══════════════════════════════════════════════════════════════════════════
   TAKEAWAYS

   ✔ Profile BEFORE you analyse. Always. The region column alone proves why.
   ✔ NULL in your denominator SILENTLY DROPS ROWS. What you can't see can
     hurt you — and the gap is itself a finding worth reporting.
   ✔ TRY_TO_NUMBER / TRY_TO_DATE let you profile dirt without dying.
   ✔ LEFT JOIN to investigate. INNER JOIN only once you've PROVEN the match.
   ✔ ★ The query returns 8 rows. The ANALYSIS decides that 3 of them matter.
       A machine can do the first. Only you can do the second.
   ✔ Corroborate with an independent source — and report the confidence you
     ACTUALLY have, including where it's weak.
   ✔ Put a dollar value on it. A finding without a number is an opinion.
   ✔ Disclose your thresholds. A hidden HAVING clause is how analysts mislead
     people without ever technically lying.

   NEXT: 05_snowflake_deep_dive.sql — caching, Time Travel, cloning, and the
         query profile. The "how does this platform actually work" hour.
   ═══════════════════════════════════════════════════════════════════════════ */