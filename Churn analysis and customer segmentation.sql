--README 
--Goal: Identify early risk signals driving churn and support load prior to public launch.
--Approach: Exploratory analysis across usage, support, and subscription lifecycle data.
--Outcome: Found that churn is driven by early operational friction, not raw usage or feature adoption.

--FINAL ANALYSIS TABLE (CLEAN) 
CREATE OR REPLACE VIEW churn_eda_base AS
SELECT
  a.account_id,
  a.churn_flag,
  a.is_trial,
  a.seats,

  -- lifecycle
  AGE(s.end_date, s.start_date) AS tenure,

  -- first 30 days usage
  AVG(f.usage_count) FILTER (
    WHERE f.usage_date <= s.start_date + INTERVAL '30 days'
  ) AS usage_30d,

  AVG(f.error_count) FILTER (
    WHERE f.usage_date <= s.start_date + INTERVAL '30 days'
  ) AS errors_30d,

  -- support in first 30 days
  COUNT(st.ticket_id) FILTER (
    WHERE st.submitted_at <= s.start_date + INTERVAL '30 days'
  ) AS tickets_30d,

  AVG(st.resolution_time_hours) FILTER (
    WHERE st.submitted_at <= s.start_date + INTERVAL '30 days'
  ) AS resolution_30d

FROM accounts a
JOIN subscriptions s ON a.account_id = s.account_id
LEFT JOIN feature_usage_stage f ON s.subscription_id = f.subscription_id
LEFT JOIN support_tickets st ON a.account_id = st.account_id
GROUP BY a.account_id, a.churn_flag, a.is_trial, a.seats, tenure;

SELECT column_name
FROM information_schema.columns
WHERE table_name = 'churn_eda_base';

--remove nulls (except tenure as could be new/fresh accounts) and round decimals in churn_eda_base table 

SELECT
  account_id,
  churn_flag,
  is_trial,
  seats,
  tenure,

  ROUND(COALESCE(usage_30d, 0), 2)       AS usage_30d,
  ROUND(COALESCE(errors_30d, 0), 2)      AS errors_30d,
  COALESCE(tickets_30d, 0)               AS tickets_30d,
  ROUND(COALESCE(resolution_30d, 0), 2) AS resolution_30d
  

FROM churn_eda_base;

--CORE ANALYSIS AND QUERYING 
--(Revenue vs usage correlation, looks like revenue is not usage driven)

SELECT
  CORR(usage_count, mrr_amount) AS usage_mrr_corr
FROM feature_usage_analytics
WHERE mrr_amount IS NOT NULL;

--feature level usage impact on churn(indicates that avg feature usage converges around 10 for churned and non churned users)
SELECT
  feature_name,
  churn_flag,
  AVG(usage_count) AS avg_usage
FROM feature_usage_analytics
GROUP BY feature_name, churn_flag;

--Support tickets vs churn (avg resolution time and avg satisfaction shows no meaningful difference, the escalation rate is slightly higher for churned users)
SELECT 
   a.churn_flag, 
   AVG(st.resolution_time_hours) AS avg_resolution_time, 
   AVG(st.satisfaction_score) AS avg_satisfaction_score, 
   AVG(st.escalation_flag::int) as escalation_rate
FROM support_tickets AS st 
JOIN accounts AS a
 ON st.account_id = a.account_id
GROUP BY a.churn_flag; 

--Churn by lifecycle stage(only early and mid groups contain churned subscriptions, those with active subscriptions belong to groups who have had subscriptions for a long time)
SELECT
  CASE 
  WHEN AGE(COALESCE(end_date, CURRENT_DATE), start_date) < INTERVAL '3 months' THEN 'EARLY'
  WHEN AGE(COALESCE(end_date, CURRENT_DATE), start_date) < INTERVAL '12 months' THEN 'MID'
  ELSE 'LATE'
  END AS lifecycle_stage, 
  ROUND(AVG(churn_flag::int), 2) as churn_rate
FROM subscriptions 
GROUP BY lifecycle_stage; 

-- Churn by plan tier, by trial vs paid, and by account size (no meaningful differences between plan tier. Those in trial churn slightly more than the paid, not highly significant. Small accounts churn more than medium and large accounts.)
SELECT
  plan_tier,
  AVG(churn_flag::int) AS churn_rate
FROM subscriptions
GROUP BY plan_tier;

SELECT
  is_trial,
  AVG(churn_flag::int) AS churn_rate
FROM subscriptions
GROUP BY is_trial;


SELECT
  CASE
    WHEN seats < 10 THEN 'Small'
    WHEN seats < 50 THEN 'Medium'
    ELSE 'Large'
  END AS account_size,
  AVG(churn_flag::int) AS churn_rate
FROM subscriptions
GROUP BY account_size;

-- Usage change before churn (usage drop is not a strong diffrentiator between churned and non churned users)
WITH max_dates AS (
  SELECT MAX(usage_date) AS max_date
  FROM feature_usage_analytics
)
SELECT
  churn_flag,
  AVG(usage_count) FILTER (
    WHERE usage_date >= max_date - INTERVAL '30 days'
  )
  -
  AVG(usage_count) FILTER (
    WHERE usage_date < max_date - INTERVAL '30 days'
  ) AS usage_delta
FROM feature_usage_analytics, max_dates
GROUP BY churn_flag;

--early engagement failures (identical accross two groups)

SELECT churn_flag, 
  COUNT(DISTINCT feature_name) AS features_used
FROM feature_usage_analytics
GROUP BY churn_flag; 

--support pain assessment and churn (identical across two groups)

SELECT
  a.churn_flag,
  PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY st.resolution_time_hours) AS p90_resolution_time
FROM support_tickets AS st JOIN accounts AS a ON st.account_id = a.account_id
GROUP BY churn_flag; 

--impact of auto-renewal on churn (not a significant driver)

SELECT 
   auto_renew_flag, 
   AVG(churn_flag::int) AS churn_rate 
FROM subscriptions 
GROUP BY auto_renew_flag; 

--downgrade flag assessment (downgrades are an indicator of churn)

SELECT 
   downgrade_flag, 
   AVG(churn_flag::int) AS churn_rate 
FROM subscriptions 
GROUP BY downgrade_flag; 

--assessing feature_error_count (no significant difference)

WITH account_errors AS (
  SELECT 
    s.account_id, 
    AVG(f.error_count) AS avg_error_count
  FROM feature_usage_stage AS f
  JOIN subscriptions AS s 
    ON f.subscription_id = s.subscription_id
  GROUP BY s.account_id
)
SELECT 
  a.churn_flag, 
  AVG(e.avg_error_count) AS avg_error_count
FROM account_errors AS e
JOIN accounts AS a 
  ON e.account_id = a.account_id
GROUP BY a.churn_flag;

--satisfaction score as a driver (not a key driver)

SELECT
  CASE
    WHEN satisfaction_score >= 4 THEN 'High (4–5)'
    WHEN satisfaction_score >= 3 THEN 'Medium (3–4)'
    ELSE 'Low (<3)'
  END AS satisfaction_bucket,
  AVG(a.churn_flag::int) AS churn_rate,
  COUNT(*) AS tickets
FROM support_tickets st
JOIN accounts a
  ON st.account_id = a.account_id
GROUP BY satisfaction_bucket
ORDER BY churn_rate DESC;


--error count and churn (in churned users, errors increased in the last 30 days before leaving, which could be an indicator of churn)
WITH max_date AS (
  SELECT MAX(usage_date) AS max_usage_date
  FROM feature_usage_analytics
)
SELECT
  churn_flag,

  ROUND(
    AVG(error_count) FILTER (
      WHERE usage_date >= (SELECT max_usage_date FROM max_date) - INTERVAL '30 days'
    ),
    2
  )
  -
  ROUND(
    AVG(error_count) FILTER (
      WHERE usage_date < (SELECT max_usage_date FROM max_date) - INTERVAL '30 days'
    ),
    2
  ) AS error_delta

FROM feature_usage_analytics
GROUP BY churn_flag;


-- assessing high priority support tickets (high-severity tickets do not explain churn, and ticket volume is almost the same between churned and non churned)
WITH account_support_metrics AS (
  SELECT
    a.account_id,

    COUNT(st.ticket_id) AS total_tickets,

    AVG(
      CASE
        WHEN LOWER(st.priority) IN ('high', 'urgent', 'p1', 'critical') THEN 1
        ELSE 0
      END
    ) AS severe_ticket_rate

  FROM accounts a
  LEFT JOIN support_tickets st
    ON a.account_id = st.account_id
  GROUP BY a.account_id
)

SELECT
  a.churn_flag,
  AVG(asm.severe_ticket_rate) AS avg_severe_rate,
  AVG(asm.total_tickets) AS avg_tickets,
  COUNT(*) AS accounts
FROM account_support_metrics asm
JOIN accounts a
  ON asm.account_id = a.account_id
GROUP BY a.churn_flag;

--first month experience vs churn (early product experience and error counts are not drivers of churn, however, average resolution time is higher in churned users,which could be an indicator)


SELECT
  a.churn_flag,

  -- product experience
  ROUND(AVG(f.usage_count) FILTER (
    WHERE f.usage_date BETWEEN a.signup_date AND a.signup_date + INTERVAL '30 days'
  ),2) AS avg_usage_30d,

  ROUND(AVG(f.error_count) FILTER (
    WHERE f.usage_date BETWEEN a.signup_date AND a.signup_date + INTERVAL '30 days'
  ),2) AS avg_errors_30d,

  -- support experience
  COUNT(st.ticket_id) FILTER (
    WHERE st.submitted_at BETWEEN a.signup_date AND a.signup_date + INTERVAL '30 days'
  ) AS tickets_30d,

  ROUND(AVG(st.resolution_time_hours) FILTER (
    WHERE st.submitted_at BETWEEN a.signup_date AND a.signup_date + INTERVAL '30 days'
  ),2) AS avg_resolution_30d,

  AVG(
    CASE
      WHEN st.priority IN ('High','Urgent')
       AND st.submitted_at BETWEEN a.signup_date AND a.signup_date + INTERVAL '30 days'
      THEN 1 ELSE 0
    END
  ) AS severe_ticket_rate_30d,

  COUNT(DISTINCT a.account_id) AS accounts

FROM accounts a
LEFT JOIN subscriptions s ON a.account_id = s.account_id
LEFT JOIN feature_usage_stage f ON s.subscription_id = f.subscription_id
LEFT JOIN support_tickets st ON a.account_id = st.account_id
GROUP BY a.churn_flag;

