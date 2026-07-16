/* ═══════════════════════════════════════════════════════════════════════════
   APPLIED DATA ANALYTICS — WORKSHOP 2
   SCRIPT 01 — COST CONTROL & SAFETY SETUP

   ⚠️  RUN THIS FIRST. BEFORE ANYTHING ELSE. NO EXCEPTIONS.

   ---------------------------------------------------------------------------
   READ THIS BEFORE YOU RUN A SINGLE LINE
   ---------------------------------------------------------------------------

   1. NEVER ADD A CREDIT CARD TO YOUR SNOWFLAKE TRIAL ACCOUNT.

      This is the single most important rule in this entire workshop series.
      A Snowflake trial has NO payment method attached. When the free credits
      are used up, the account simply STOPS. It does not bill you. It cannot
      bill you. There is nothing to charge.

      The moment you add a card, that protection is gone.

      Do not add a card. Not for this workshop. Not "just to be safe."
      Not because a prompt asks nicely.

   2. Your real risk is not money. It is RUNNING OUT OF TRIAL CREDITS
      before Workshops 3, 4, and 5.

      The classic way students do this: they leave a warehouse running
      overnight. Compute in Snowflake is billed per second while a warehouse
      is RUNNING — even if you are asleep and nobody is querying.

      Everything below exists to make that impossible.

   ---------------------------------------------------------------------------
   WHAT THIS SCRIPT DOES — the four layers of protection
   ---------------------------------------------------------------------------

     LAYER 1 : X-SMALL warehouse        -> lowest possible burn rate (1 credit/hr)
     LAYER 2 : AUTO_SUSPEND = 60s       -> idle warehouse shuts itself off
     LAYER 3 : AUTO_RESUME = TRUE       -> it wakes up when you query. No babysitting.
     LAYER 4 : RESOURCE MONITOR         -> hard cap. Suspends compute at the limit.

   The resource monitor is the safety net. It is the thing that saves you when
   layers 1-3 fail because you did something clever at 2am.

   ---------------------------------------------------------------------------
   A NOTE ON "SET IT TO ZERO"
   ---------------------------------------------------------------------------

   You cannot set a resource monitor quota to 0. Snowflake requires a positive
   integer, and a zero quota would not mean "spend nothing" anyway.

   $0 is guaranteed by the TRIAL + NO CREDIT CARD. That is the real protection.
   The monitor's job is to protect your CREDITS so they last all five workshops.

   We set a 5-credit cap. That is generous for this workshop and will hard-stop
   you long before the trial is exhausted.

   ═══════════════════════════════════════════════════════════════════════════ */


/* ───────────────────────────────────────────────────────────────────────────
   STEP 0 — Confirm who you are
   ───────────────────────────────────────────────────────────────────────────
   Resource monitors require ACCOUNTADMIN.
   On a trial account, YOU are the account admin. This will work.
   If it errors here, stop and flag it — do not skip ahead.
*/

USE ROLE ACCOUNTADMIN;

-- Sanity check. Look at the output before you continue.
SELECT
    CURRENT_ACCOUNT()   AS account,
    CURRENT_USER()      AS username,
    CURRENT_ROLE()      AS active_role,
    CURRENT_REGION()    AS region;


/* ───────────────────────────────────────────────────────────────────────────
   STEP 1 — THE RESOURCE MONITOR  (Layer 4: the hard cap)
   ───────────────────────────────────────────────────────────────────────────

   CREDIT_QUOTA        = 5      -> the ceiling, in credits, for this interval
   FREQUENCY           = MONTHLY-> the quota resets each month
   START_TIMESTAMP     = NOW    -> begins tracking immediately

   TRIGGERS — read these carefully, they are the whole point:

     50% -> NOTIFY            : an email. Just a heads-up.
     75% -> NOTIFY            : pay attention now.
     90% -> NOTIFY            : you are close.
    100% -> SUSPEND           : stop accepting NEW queries. Running ones finish.
    100% -> SUSPEND_IMMEDIATE : kill everything NOW, including running queries.

   SUSPEND vs SUSPEND_IMMEDIATE:
     SUSPEND is polite — it lets in-flight work complete.
     SUSPEND_IMMEDIATE is the emergency brake — it kills queries mid-execution.

   We use BOTH. Belt and braces. If a runaway query is the thing burning your
   credits, "let it finish politely" is not what you want.
*/

CREATE OR REPLACE RESOURCE MONITOR mdp_workshop_monitor
  WITH
    CREDIT_QUOTA    = 5
    FREQUENCY       = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
      ON 50  PERCENT DO NOTIFY
      ON 75  PERCENT DO NOTIFY
      ON 90  PERCENT DO SUSPEND_IMMEDIATE;


/* ───────────────────────────────────────────────────────────────────────────
   STEP 2 — THE WAREHOUSE  (Layers 1, 2, 3)
   ───────────────────────────────────────────────────────────────────────────

   WAREHOUSE_SIZE = XSMALL
       The smallest compute available: 1 credit/hour while RUNNING.
       Every size up DOUBLES the credit rate:
           X-Small =  1 credit/hr
           Small   =  2
           Medium  =  4
           Large   =  8
           X-Large = 16   ... and so on.
       You do not need more than X-Small for this dataset. Resist the urge.

   AUTO_SUSPEND = 60
       Seconds of idle time before the warehouse shuts itself off.
       THIS IS THE LINE THAT SAVES YOU. Without it, a warehouse you forgot
       about runs all night and bills every second of it.

   AUTO_RESUME = TRUE
       It turns itself back on the moment you run a query.
       So suspending costs you nothing but a second or two of wake-up.

   INITIALLY_SUSPENDED = TRUE
       Do not start burning credits the instant this script runs.

   NOTE: Billing has a 60-SECOND MINIMUM each time a warehouse resumes.
   So: don't suspend/resume in a tight loop. Just work normally.
*/

CREATE OR REPLACE WAREHOUSE mdp_wh
  WITH
    WAREHOUSE_SIZE      = 'XSMALL'
    WAREHOUSE_TYPE      = 'STANDARD'
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE
    MIN_CLUSTER_COUNT   = 1
    MAX_CLUSTER_COUNT   = 1     -- no multi-cluster scale-out. We do not need it.
    COMMENT             = 'MDP Workshop Series - X-Small, cost-capped';


/* ───────────────────────────────────────────────────────────────────────────
   STEP 3 — ATTACH THE MONITOR TO THE WAREHOUSE
   ───────────────────────────────────────────────────────────────────────────
   A resource monitor that is not attached to anything protects nothing.
   This is the step people forget.
*/

ALTER WAREHOUSE mdp_wh
  SET RESOURCE_MONITOR = mdp_workshop_monitor;


/* ───────────────────────────────────────────────────────────────────────────
   STEP 4 — ACCOUNT-LEVEL MONITOR  (the second safety net)
   ───────────────────────────────────────────────────────────────────────────

   The monitor above guards ONE warehouse (mdp_wh).

   But Snowflake trials ship with a default warehouse called COMPUTE_WH, and
   it is very easy to accidentally run something on it. An account-level
   monitor catches EVERYTHING, including warehouses you forgot existed.

   This is the "I did something stupid at 2am" insurance policy.
*/

CREATE OR REPLACE RESOURCE MONITOR mdp_account_guard
  WITH
    CREDIT_QUOTA    = 10
    FREQUENCY       = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
      ON 60  PERCENT DO NOTIFY
      ON 85  PERCENT DO NOTIFY
      ON 100 PERCENT DO SUSPEND
      ON 105 PERCENT DO SUSPEND_IMMEDIATE;

-- Apply it across the whole account.
ALTER ACCOUNT SET RESOURCE_MONITOR = mdp_account_guard;


/* ───────────────────────────────────────────────────────────────────────────
   STEP 5 — TAME THE DEFAULT WAREHOUSE
   ───────────────────────────────────────────────────────────────────────────
   COMPUTE_WH ships with the trial and often has a long auto-suspend.
   We are not going to use it, but if it exists, it should be safe.

   If this errors because COMPUTE_WH doesn't exist on your account: fine.
   Ignore it and move on.
*/

ALTER WAREHOUSE IF EXISTS COMPUTE_WH SET
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND   = 60
    AUTO_RESUME    = TRUE;


/* ═══════════════════════════════════════════════════════════════════════════
   VERIFICATION — DO NOT SKIP THIS
   Run each block. Read the output. Confirm it says what it should.
   ═══════════════════════════════════════════════════════════════════════════ */

-- 1. Do the monitors exist, and what are their quotas?
SHOW RESOURCE MONITORS;
--    EXPECT: mdp_workshop_monitor (quota 5), mdp_account_guard (quota 10)


-- 2. Is the warehouse X-Small, suspended, with a 60s auto-suspend?
SHOW WAREHOUSES LIKE 'mdp_wh';
--    EXPECT: size = X-Small
--            state = SUSPENDED
--            auto_suspend = 60
--            resource_monitor = MDP_WORKSHOP_MONITOR   <-- must NOT be "null"


-- 3. How many credits have we actually used? (Should be ~0.)
SELECT
    WAREHOUSE_NAME,
    ROUND(SUM(CREDITS_USED), 4)          AS credits_used,
    ROUND(SUM(CREDITS_USED) * 4.00, 2)   AS approx_cad_equivalent  -- illustrative only
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD(day, -7, CURRENT_TIMESTAMP())
GROUP BY WAREHOUSE_NAME
ORDER BY credits_used DESC;
--    NOTE: ACCOUNT_USAGE views have a latency of up to ~45 minutes.
--          A brand-new account may return zero rows. That is normal, not an error.
--          The CAD column is ILLUSTRATIVE — you are on trial credits, not being billed.


/* ═══════════════════════════════════════════════════════════════════════════
   YOUR HABITS FOR THE REST OF THE SERIES
   ═══════════════════════════════════════════════════════════════════════════

   ✔  NEVER add a credit card. Say it with me.
   ✔  Stay on X-Small. You do not need more. This dataset is tiny.
   ✔  When you finish a session, run:   ALTER WAREHOUSE mdp_wh SUSPEND;
        (Auto-suspend will do it in 60s anyway — but build the habit.)
   ✔  If you ever see a warehouse RUNNING and you are not querying: suspend it.
   ✔  Check your credit burn now and then with the query in Verification #3.

   THE PANIC BUTTON — if anything ever looks wrong, run this:

       ALTER WAREHOUSE mdp_wh SUSPEND;
       ALTER WAREHOUSE IF EXISTS COMPUTE_WH SUSPEND;

   Suspending a warehouse loses you NOTHING. Your data is untouched. Storage
   is separate from compute — that is the whole architectural point of
   Snowflake, and we will talk about exactly why in a few minutes.

   ═══════════════════════════════════════════════════════════════════════════

   WHY THIS IS ACTUALLY AN INTERVIEW STORY, NOT JUST HOUSEKEEPING
   ═══════════════════════════════════════════════════════════════════════════

   What you just did has a name in industry: COST GOVERNANCE. Sometimes FinOps.

   In a cloud data warehouse, compute is metered by the second. Someone has to
   own the question "what is this costing us, and who is burning it?" On a lot
   of teams, nobody does — until finance asks.

   Almost no junior candidate can talk about this. Most have never heard of a
   resource monitor. You now have:

     - Configured a warehouse for the workload instead of defaulting to big
     - Set auto-suspend to eliminate idle burn
     - Built a hard cap with staged notify + suspend triggers
     - Understood scale-up vs. the credit doubling that comes with it

   That is a genuine, specific, technical thing to say in an interview.
   Most people cannot.

   ═══════════════════════════════════════════════════════════════════════════ */
