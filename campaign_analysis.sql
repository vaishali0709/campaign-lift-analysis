-- ===========================================================================
--  DID THE MARKETING CAMPAIGNS WORK?
--  MySQL 8.0
--
--  A grocery retailer ran 30 campaigns over two years. 1,584 households got
--  at least one. 916 never got any. Marketing wants to know what the spend
--  bought them.
--
--  The easy answer is to compare the two groups. That answer is wrong, and
--  most of this file is about showing why, and what to say instead.
--
--  Data: 2,500 households, 164,128 shopping trips, days 1 to 446.
--        The first campaign starts on day 224, so days 1-223 are a clean
--        "before" period where nobody had been contacted yet.
--
--  Sections:
--     0   Build the tables
--     1   Check the data is sound
--     2   How big is the business?
--     3   The easy answer (and why it's wrong)
--     4   Were the two groups alike before any campaign ran?
--     5   The proper method: difference-in-differences
--     6   Does the method's assumption actually hold?
--     7   What we CAN measure: coupon redemption
--     8   Does sending more campaigns help?
--     9   Who redeems?
--     10  Summary
-- ===========================================================================

CREATE DATABASE IF NOT EXISTS campaign_lift;
USE campaign_lift;


-- ===========================================================================
-- SECTION 0 - Build the tables
--
-- Five tables. Time is stored as a day number (1 to 446) rather than a date,
-- which is how the retailer anonymised it. Campaign start and end days use
-- the same numbering, so they line up.
-- ===========================================================================

DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS campaigns_sent;
DROP TABLE IF EXISTS campaign_periods;
DROP TABLE IF EXISTS coupon_redemptions;
DROP TABLE IF EXISTS households;

CREATE TABLE households (
    age_desc            VARCHAR(20),
    marital_status_code VARCHAR(5),
    income_desc         VARCHAR(20),
    homeowner_desc      VARCHAR(30),
    hh_comp_desc        VARCHAR(40),
    household_size_desc VARCHAR(10),
    kid_category_desc   VARCHAR(20),
    household_key       INT PRIMARY KEY
);

CREATE TABLE transactions (
    household_key     INT NOT NULL,
    day               INT NOT NULL,
    week_no           INT,
    basket_id         BIGINT,
    store_id          INT,
    items             INT,
    sales_value       DECIMAL(10,2),   -- money, so DECIMAL not FLOAT
    coupon_disc       DECIMAL(10,2),
    coupon_match_disc DECIMAL(10,2)
);

CREATE TABLE campaigns_sent (
    description   VARCHAR(10),         -- TypeA, TypeB or TypeC
    household_key INT NOT NULL,
    campaign      INT NOT NULL
);

CREATE TABLE campaign_periods (
    description VARCHAR(10),
    campaign    INT PRIMARY KEY,
    start_day   INT,
    end_day     INT
);

CREATE TABLE coupon_redemptions (
    household_key INT NOT NULL,
    day           INT,
    coupon_upc    BIGINT,
    campaign      INT
);

CREATE INDEX idx_tx_household ON transactions(household_key);
CREATE INDEX idx_tx_day       ON transactions(day);
CREATE INDEX idx_sent_hh      ON campaigns_sent(household_key);
CREATE INDEX idx_redeem_hh    ON coupon_redemptions(household_key);

-- Import the five CSVs now. All columns are populated, so the wizard handles
-- these without the blank-cell trouble that catches out date columns.


-- ===========================================================================
-- SECTION 1 - Is the data sound?
-- ===========================================================================

SELECT 'transactions'       AS t, COUNT(*) AS rows_loaded FROM transactions
UNION ALL SELECT 'campaigns_sent',     COUNT(*) FROM campaigns_sent
UNION ALL SELECT 'campaign_periods',   COUNT(*) FROM campaign_periods
UNION ALL SELECT 'coupon_redemptions', COUNT(*) FROM coupon_redemptions
UNION ALL SELECT 'households',         COUNT(*) FROM households;
-- Expect 164128, 7208, 30, 2318, 801.


-- Q: When does everything happen? The gap before day 224 is what makes this
--    analysis possible at all.
SELECT
    MIN(t.day)                              AS first_shopping_day,
    MAX(t.day)                              AS last_shopping_day,
    (SELECT MIN(start_day) FROM campaign_periods) AS first_campaign_day,
    (SELECT MAX(end_day)   FROM campaign_periods) AS last_campaign_day
FROM transactions t;


-- Q: Any redemption against a campaign that was never sent to that household?
--    Expect 0. If not, the two tables disagree and neither can be trusted.
SELECT COUNT(*) AS redemptions_without_a_matching_send
FROM coupon_redemptions r
LEFT JOIN campaigns_sent s
       ON s.household_key = r.household_key
      AND s.campaign      = r.campaign
WHERE s.household_key IS NULL;


-- Q: Anything impossible in the numbers?
SELECT
    SUM(sales_value < 0) AS negative_sales,
    SUM(items <= 0)      AS non_positive_items,
    SUM(day < 1)         AS bad_day_number
FROM transactions;


-- Q: How much demographic coverage is there? Only some households gave it.
SELECT
    (SELECT COUNT(DISTINCT household_key) FROM transactions) AS households_total,
    (SELECT COUNT(*) FROM households)                        AS households_with_demographics;
-- 801 of 2,500. Anything cut by income or family size describes a third of
-- the base, not all of it.


-- ===========================================================================
-- SECTION 2 - How big is the business?
-- ===========================================================================

SELECT
    COUNT(DISTINCT household_key)              AS households,
    COUNT(DISTINCT basket_id)                  AS shopping_trips,
    ROUND(SUM(sales_value), 0)                 AS total_sales,
    ROUND(AVG(sales_value), 2)                 AS avg_basket_value,
    ROUND(SUM(ABS(coupon_disc)), 0)            AS total_coupon_discount
FROM transactions;


-- ===========================================================================
-- SECTION 3 - The easy answer, and why nobody should use it
--
-- The obvious thing to do: compare what campaigned households spend against
-- what everyone else spends. It takes one query and it produces a big number.
-- ===========================================================================

WITH treated AS (
    SELECT DISTINCT household_key FROM campaigns_sent
)
SELECT
    CASE WHEN tr.household_key IS NULL THEN 'Never campaigned'
         ELSE 'Got a campaign' END                          AS grp,
    COUNT(DISTINCT t.household_key)                         AS households,
    ROUND(SUM(t.sales_value) / COUNT(DISTINCT t.household_key), 0) AS avg_spend_per_household
FROM transactions t
LEFT JOIN treated tr ON tr.household_key = t.household_key
WHERE t.day > 223                                            -- the campaign era
GROUP BY grp;

-- That comes out at roughly $1,590 against $279 - campaigned households look
-- about 4.7x better. If this went in a slide deck, marketing would double the
-- budget tomorrow.
--
-- Section 4 is why it shouldn't.


-- ===========================================================================
-- SECTION 4 - Were the two groups alike to begin with?
--
-- The comparison above only means something if the two groups were similar
-- before anyone was contacted. Days 1 to 223 are before the first campaign,
-- so we can check.
-- ===========================================================================

WITH treated AS (
    SELECT DISTINCT household_key FROM campaigns_sent
)
SELECT
    CASE WHEN tr.household_key IS NULL THEN 'Never campaigned'
         ELSE 'Got a campaign' END                              AS grp,
    COUNT(DISTINCT t.household_key)                             AS households,
    ROUND(SUM(t.sales_value)/COUNT(DISTINCT t.household_key),0) AS avg_spend_before,
    ROUND(COUNT(DISTINCT t.basket_id)/COUNT(DISTINCT t.household_key),1) AS avg_trips_before
FROM transactions t
LEFT JOIN treated tr ON tr.household_key = t.household_key
WHERE t.day <= 223                                              -- BEFORE any campaign
GROUP BY grp;

-- $1,049 against $265. Campaigned households were already spending nearly
-- four times as much before a single campaign went out.
--
-- So the retailer picked its best customers and sent them the campaigns.
-- That's a sensible thing to do. It also means the gap in section 3 mostly
-- existed already, and attributing it to the campaigns is wrong.
--
-- This is called selection bias, and it's the most expensive mistake in
-- marketing measurement.


-- ===========================================================================
-- SECTION 5 - The proper method
--
-- If both groups started in different places, compare how much each group
-- CHANGED rather than where each ended up.
--
--   treated:  spend after  -  spend before
--   control:  spend after  -  spend before
--   answer:   the difference between those two changes
--
-- This is difference-in-differences. Both windows are 223 days so they're
-- the same length.
-- ===========================================================================

WITH treated AS (
    SELECT DISTINCT household_key FROM campaigns_sent
),
per_household AS (
    SELECT
        t.household_key,
        (tr.household_key IS NOT NULL)                             AS is_treated,
        SUM(CASE WHEN t.day <= 223 THEN t.sales_value ELSE 0 END)  AS spend_before,
        SUM(CASE WHEN t.day >  223 THEN t.sales_value ELSE 0 END)  AS spend_after
    FROM transactions t
    LEFT JOIN treated tr ON tr.household_key = t.household_key
    GROUP BY t.household_key, is_treated
)
SELECT
    CASE WHEN is_treated THEN 'Got a campaign' ELSE 'Never campaigned' END AS grp,
    COUNT(*)                                    AS households,
    ROUND(AVG(spend_before), 0)                 AS avg_before,
    ROUND(AVG(spend_after), 0)                  AS avg_after,
    ROUND(AVG(spend_after - spend_before), 0)   AS spend_change
FROM per_household
GROUP BY is_treated;

-- Named spend_change, not change - CHANGE is a reserved word in MySQL
-- (ALTER TABLE ... CHANGE COLUMN) so it can't be used as a column alias.
--
-- Treated households went up about $541. Untreated went up about $14.
-- The difference between those changes is roughly $527 per household.
--
-- That's 40% of what the naive comparison suggested. Which sounds like a
-- reasonable, defensible answer.
--
-- Section 6 is why it isn't one either.


-- ===========================================================================
-- SECTION 6 - Does the method's assumption hold?
--
-- Difference-in-differences rests on one thing: that without the campaigns,
-- both groups would have carried on moving in step. You can't prove that,
-- but you can check whether they were moving in step BEFORE the campaigns.
--
-- If the gap between them was already growing, the method is measuring that
-- growth and calling it a campaign effect.
-- ===========================================================================

WITH treated AS (
    SELECT DISTINCT household_key FROM campaigns_sent
),
monthly AS (
    SELECT
        FLOOR((t.day - 1) / 30) + 1                                        AS month_no,
        SUM(CASE WHEN tr.household_key IS NOT NULL THEN t.sales_value END) AS treated_spend,
        SUM(CASE WHEN tr.household_key IS     NULL THEN t.sales_value END) AS control_spend
    FROM transactions t
    LEFT JOIN treated tr ON tr.household_key = t.household_key
    GROUP BY month_no
)
SELECT
    month_no,
    CASE WHEN month_no < 8 THEN 'before campaigns' ELSE 'campaign era' END AS period,
    ROUND(treated_spend / 1584, 1)                    AS treated_per_household,
    ROUND(control_spend /  916, 1)                    AS control_per_household,
    ROUND((treated_spend / 1584) / (control_spend / 916), 2) AS ratio
FROM monthly
WHERE month_no <= 16
ORDER BY month_no;

-- Read the ratio column down the first seven rows, all of them before any
-- campaign existed:
--
--     3.05, 3.19, 3.20, 3.34, 4.13, 4.67, 4.68
--
-- The two groups were already pulling apart. Control spending was falling
-- while treated spending climbed. There is no shared trend to compare
-- against, so the $527 figure can't be trusted either.
--
-- Being able to say that is the useful part. A number nobody has checked is
-- worse than no number.


-- ===========================================================================
-- SECTION 7 - What CAN be measured
--
-- Campaign lift can't be recovered from this data. Redemption can, because
-- it only involves households who were actually sent something - no
-- comparison group needed.
-- ===========================================================================

-- Q: Of the households that got a campaign, how many used a coupon?
SELECT
    COUNT(DISTINCT s.household_key)                                  AS households_sent_to,
    COUNT(DISTINCT r.household_key)                                  AS households_that_redeemed,
    ROUND(100.0 * COUNT(DISTINCT r.household_key)
                / COUNT(DISTINCT s.household_key), 1)                AS redemption_rate_pct
FROM campaigns_sent s
LEFT JOIN coupon_redemptions r ON r.household_key = s.household_key;


-- Q: Which campaign type gets used? Each row is one campaign sent to one
--    household, so this is per send, not per household.
SELECT
    s.description                                     AS campaign_type,
    COUNT(*)                                          AS times_sent,
    SUM(r.household_key IS NOT NULL)                  AS times_redeemed,
    ROUND(100.0 * SUM(r.household_key IS NOT NULL) / COUNT(*), 1) AS redemption_rate_pct
FROM campaigns_sent s
LEFT JOIN (
    SELECT DISTINCT household_key, campaign FROM coupon_redemptions
) r ON r.household_key = s.household_key AND r.campaign = s.campaign
GROUP BY s.description
ORDER BY redemption_rate_pct DESC;

-- TypeA is redeemed about twice as often as TypeB or TypeC. That's a real,
-- usable finding - it needs no comparison group and no assumptions.


-- ===========================================================================
-- SECTION 8 - Does sending more campaigns help?
--
-- Households received between 1 and 17 campaigns. Worth knowing whether the
-- extra ones do anything.
-- ===========================================================================

WITH per_household AS (
    SELECT
        s.household_key,
        COUNT(DISTINCT s.campaign)          AS campaigns_received,
        COUNT(DISTINCT r.campaign)          AS campaigns_redeemed
    FROM campaigns_sent s
    LEFT JOIN coupon_redemptions r ON r.household_key = s.household_key
    GROUP BY s.household_key
)
SELECT
    CASE
        WHEN campaigns_received <=  2 THEN '1-2'
        WHEN campaigns_received <=  4 THEN '3-4'
        WHEN campaigns_received <=  6 THEN '5-6'
        WHEN campaigns_received <= 10 THEN '7-10'
        ELSE                               '11+'
    END                                                          AS campaigns_band,
    COUNT(*)                                                     AS households,
    ROUND(100.0 * AVG(campaigns_redeemed > 0), 1)                AS pct_redeemed_anything,
    ROUND(AVG(campaigns_redeemed), 2)                            AS avg_campaigns_redeemed
FROM per_household
GROUP BY campaigns_band
ORDER BY FIELD(campaigns_band, '1-2','3-4','5-6','7-10','11+');

-- Redemption climbs steadily with volume, from 9% to 59%.
--
-- Careful with this one. It does not prove that sending more works. The
-- retailer sent more campaigns to households it already liked, so the same
-- selection problem from section 4 applies here too.


-- ===========================================================================
-- SECTION 9 - Who redeems?
--
-- Only 801 households gave demographics, so this covers about a third of the
-- base. Small groups are excluded.
-- ===========================================================================

WITH per_household AS (
    SELECT
        s.household_key,
        MAX(r.household_key IS NOT NULL) AS redeemed
    FROM campaigns_sent s
    LEFT JOIN coupon_redemptions r ON r.household_key = s.household_key
    GROUP BY s.household_key
)
SELECT
    h.income_desc                          AS income_band,
    COUNT(*)                               AS households,
    ROUND(100.0 * AVG(p.redeemed), 1)      AS pct_redeemed
FROM per_household p
JOIN households h ON h.household_key = p.household_key
GROUP BY h.income_desc
HAVING COUNT(*) >= 25
ORDER BY pct_redeemed DESC;


-- Same question by family size.
WITH per_household AS (
    SELECT
        s.household_key,
        MAX(r.household_key IS NOT NULL) AS redeemed
    FROM campaigns_sent s
    LEFT JOIN coupon_redemptions r ON r.household_key = s.household_key
    GROUP BY s.household_key
)
SELECT
    h.kid_category_desc                    AS children,
    COUNT(*)                               AS households,
    ROUND(100.0 * AVG(p.redeemed), 1)      AS pct_redeemed
FROM per_household p
JOIN households h ON h.household_key = p.household_key
GROUP BY h.kid_category_desc
HAVING COUNT(*) >= 25
ORDER BY pct_redeemed DESC;


-- ===========================================================================
-- SECTION 10 - Summary
--
-- Three numbers, and how much weight each can carry.
-- ===========================================================================

WITH treated AS (
    SELECT DISTINCT household_key FROM campaigns_sent
),
per_household AS (
    SELECT
        t.household_key,
        (tr.household_key IS NOT NULL)                            AS is_treated,
        SUM(CASE WHEN t.day <= 223 THEN t.sales_value ELSE 0 END) AS spend_before,
        SUM(CASE WHEN t.day >  223 THEN t.sales_value ELSE 0 END) AS spend_after
    FROM transactions t
    LEFT JOIN treated tr ON tr.household_key = t.household_key
    GROUP BY t.household_key, is_treated
),
figures AS (
    SELECT
        AVG(CASE WHEN is_treated     THEN spend_after END)                 AS treated_after,
        AVG(CASE WHEN NOT is_treated THEN spend_after END)                 AS control_after,
        AVG(CASE WHEN is_treated     THEN spend_after - spend_before END)  AS treated_change,
        AVG(CASE WHEN NOT is_treated THEN spend_after - spend_before END)  AS control_change
    FROM per_household
)
SELECT 'Simple group comparison' AS method,
       ROUND(treated_after - control_after, 0) AS estimated_lift_per_household,
       'Not usable - the groups were different before any campaign ran' AS verdict
FROM figures
UNION ALL
SELECT 'Difference-in-differences',
       ROUND(treated_change - control_change, 0),
       'Not usable either - the two groups were already drifting apart'
FROM figures
UNION ALL
SELECT 'Honest answer',
       NULL,
       'This data cannot measure campaign lift. Hold back a random group next time.'
FROM figures;
