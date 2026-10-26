/* =====================================================================
   05_validation.sql
   Film Investment Analysis: Step 5, validation after loading

   Purpose
   - Prove that the loaded data can be trusted before analysing it.
   - Nothing is changed here; every query only checks.

   Contents
   1. Relationships: does every link point to something real?      (expected: all 0)
   2. Business rules: do the numbers follow real-world logic?       (expected: all 0)
   3. Outliers: what do box office multiples look like?
      3a. Distribution of the multiple
      3b. The extremes, side by side
      3c. Sensitivity: how would each outlier rule change the results?
   4. Spot check: famous films compared with the source website

   (Row counts per table are checked at the end of 04b_matching_and_load.sql.)
   ===================================================================== */

-- =====================================================================
-- 1. Relationships (expected: all 0)
-- =====================================================================
SELECT
    (SELECT COUNT(*) FROM review AS r
      WHERE NOT EXISTS (SELECT 1 FROM movie AS m WHERE m.movie_id = r.movie_id))        AS reviews_without_film,
    (SELECT COUNT(*) FROM box_office AS b
      WHERE NOT EXISTS (SELECT 1 FROM movie AS m WHERE m.movie_id = b.movie_id))        AS box_office_without_film,
    (SELECT COUNT(*) FROM movie_genre AS mg
      WHERE NOT EXISTS (SELECT 1 FROM movie AS m WHERE m.movie_id = mg.movie_id)
         OR NOT EXISTS (SELECT 1 FROM genre AS g WHERE g.genre_id = mg.genre_id))       AS broken_genre_links,
    (SELECT COUNT(*) FROM movie AS m
      WHERE m.studio_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM studio AS s WHERE s.studio_id = m.studio_id))     AS films_with_unknown_studio,
    (SELECT COUNT(*) FROM movie
      WHERE numbers_url IS NULL AND metacritic_url IS NULL)                             AS films_without_source,
    (SELECT COUNT(*) FROM movie AS m
      WHERE m.metacritic_url IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM review AS r
                        WHERE r.movie_id = m.movie_id AND r.reviewer_type = 'critic'))  AS metacritic_films_without_critic_review;

-- =====================================================================
-- 2. Business rules (expected: 0 rows breaking each rule)
-- =====================================================================
SELECT 'worldwide = domestic + international' AS rule,
       COUNT(*) AS rows_breaking_rule
FROM box_office
WHERE worldwide_gross <> domestic_gross + international_gross
UNION ALL
SELECT 'worldwide >= domestic',
       COUNT(*)
FROM box_office
WHERE worldwide_gross < domestic_gross
UNION ALL
SELECT 'opening weekend <= total domestic',
       COUNT(*)
FROM box_office
WHERE opening_weekend > domestic_gross
UNION ALL
SELECT 'helpful votes <= total votes',
       COUNT(*)
FROM review
WHERE thumbs_up > thumbs_total
UNION ALL
SELECT 'The-Numbers films released 2000-2021',
       COUNT(*)
FROM movie
WHERE numbers_url IS NOT NULL
  AND release_year NOT BETWEEN 2000 AND 2021
UNION ALL
SELECT 'matched films at most 1 year apart',
       COUNT(*)
FROM staging.film_match AS fm
JOIN staging.clean_sales      AS s ON s.numbers_url    = fm.numbers_url
JOIN staging.clean_metacritic AS m ON m.metacritic_url = fm.metacritic_url
WHERE ABS(s.release_year - m.release_year) > 1
UNION ALL
SELECT 'release date falls in release year',
       COUNT(*)
FROM movie
WHERE EXTRACT(YEAR FROM release_date) <> release_year;

-- =====================================================================
-- 3. Outliers
-- =====================================================================

-- 3a. Distribution of the multiple (worldwide gross / budget), films with budget + worldwide gross
-- Result (full data): 3,900 films | p25 0.86 | median 2.04 | p75 3.93 | p99 30.5 |
--                     highest 431.5 (Paranormal Activity) | average 3.94 | 23 films over 50x |
--                     14 budgets under $100k | 127 under $1M
-- -> The average is pulled up by a few huge hits, so groups are compared with MEDIANS.
WITH films AS (
    SELECT production_budget,
           worldwide_gross,
           worldwide_gross::numeric / production_budget AS multiple
    FROM box_office
    WHERE production_budget IS NOT NULL
      AND worldwide_gross IS NOT NULL
)
SELECT COUNT(*)                                                                  AS films,
       ROUND(MIN(multiple), 3)                                                   AS lowest,
       ROUND((PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY multiple))::numeric, 2) AS p25,
       ROUND((PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY multiple))::numeric, 2) AS median,
       ROUND((PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY multiple))::numeric, 2) AS p75,
       ROUND((PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY multiple))::numeric, 2) AS p99,
       ROUND(MAX(multiple), 1)                                                   AS highest,
       ROUND(AVG(multiple), 2)                                                   AS average,
       COUNT(*) FILTER (WHERE multiple > 50)                                     AS multiple_over_50,
       COUNT(*) FILTER (WHERE production_budget < 100000)                        AS budget_under_100k,
       COUNT(*) FILTER (WHERE production_budget < 1000000)                       AS budget_under_1m
FROM films;

-- 3b. The extremes: highest and lowest multiples, smallest budgets
-- The lowest multiples are incomplete records (e.g. a worldwide gross of $17),
-- not real flops.
(SELECT 'highest multiple' AS list, m.title, m.release_year,
        b.production_budget, b.worldwide_gross,
        ROUND(b.worldwide_gross::numeric / b.production_budget, 2) AS multiple
 FROM box_office AS b JOIN movie AS m USING (movie_id)
 WHERE b.production_budget IS NOT NULL AND b.worldwide_gross IS NOT NULL
 ORDER BY multiple DESC
 LIMIT 10)
UNION ALL
(SELECT 'lowest multiple', m.title, m.release_year,
        b.production_budget, b.worldwide_gross,
        ROUND(b.worldwide_gross::numeric / b.production_budget, 4)
 FROM box_office AS b JOIN movie AS m USING (movie_id)
 WHERE b.production_budget IS NOT NULL AND b.worldwide_gross IS NOT NULL
 ORDER BY 6 ASC
 LIMIT 10)
UNION ALL
(SELECT 'smallest budget', m.title, m.release_year,
        b.production_budget, b.worldwide_gross,
        ROUND(b.worldwide_gross::numeric / b.production_budget, 2)
 FROM box_office AS b JOIN movie AS m USING (movie_id)
 WHERE b.production_budget IS NOT NULL AND b.worldwide_gross IS NOT NULL
 ORDER BY b.production_budget ASC
 LIMIT 10);

-- 3c. Sensitivity: how would each possible outlier rule change the results?
-- Result (full data): the median stays between 2.02x and 2.08x and the hit rate
-- between 71.6% and 73.0% under every rule, so the conclusions don't depend on the rule.
-- Chosen: rule C (worldwide gross >= $100k, 3,819 films). It removes incomplete
-- records but keeps micro-budget hits, which form their own "under $1M" group.
WITH films AS (
    SELECT production_budget,
           worldwide_gross,
           worldwide_gross::numeric / production_budget AS multiple
    FROM box_office
    WHERE production_budget IS NOT NULL
      AND worldwide_gross IS NOT NULL
),
rules AS (
    SELECT 'A: all films'                      AS rule, * FROM films
    UNION ALL
    SELECT 'B: budget >= $1M',                         * FROM films
     WHERE production_budget >= 1000000
    UNION ALL
    SELECT 'C: worldwide >= $100k',                    * FROM films
     WHERE worldwide_gross >= 100000
    UNION ALL
    SELECT 'D: budget >= $1M and worldwide >= $100k',  * FROM films
     WHERE production_budget >= 1000000 AND worldwide_gross >= 100000
)
SELECT rule,
       COUNT(*)                                                                    AS films,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY multiple))::numeric, 2)  AS median_multiple,
       ROUND(AVG(multiple), 2)                                                     AS average_multiple,
       ROUND(100.0 * COUNT(*) FILTER (WHERE multiple >= 1)   / COUNT(*), 1)        AS hit_rate_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE multiple >= 2.5) / COUNT(*), 1)        AS pct_at_least_2_5x
FROM rules
GROUP BY rule
ORDER BY rule;

-- =====================================================================
-- 4. Spot check: compare these rows with the films' pages on the-numbers.com
--    (open numbers_url). Result: budgets and worldwide gross match the source.
-- =====================================================================
SELECT m.title,
       m.release_year,
       b.production_budget,
       b.worldwide_gross,
       ROUND(b.worldwide_gross::numeric / b.production_budget, 2) AS multiple,
       m.numbers_url
FROM movie AS m
JOIN box_office AS b USING (movie_id)
WHERE (m.title, m.release_year) IN (('The Dark Knight', 2008), ('Avatar', 2009), ('Inception', 2010),
                                    ('Frozen', 2013), ('Joker', 2019))
ORDER BY m.release_year;