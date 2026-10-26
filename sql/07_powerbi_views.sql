/* =====================================================================
   07_powerbi_views.sql
   Film Investment Analysis: Step 7, views for the Power BI dashboard

   Purpose
   - The "gold" reporting layer: staging (raw) -> public (clean) -> analysis (reporting).
   - Power BI gets ONE ROW PER FILM with ready-made labels and calculates medians
     and hit rates live, for whatever filters the viewer clicks.
   - Rank correlations are hard to calculate in Power BI, so they are
     pre-calculated here.

   Views
   1. analysis.pbi_films               one row per film (built on analysis.analysis_films)
   2. analysis.pbi_score_correlations  critic / audience score vs multiple,
                                       all years and since 2010 (robustness check)

   Requires 06_analysis.sql (view analysis.analysis_films).
   Safe to run more than once: CREATE OR REPLACE.
   ===================================================================== */

-- =====================================================================
-- 1. One row per film, with labels for slicers and chart axes
--    - true/false flags become 1/0, so their AVERAGE in Power BI is the rate
--    - "1. 2. 3." in front of labels keeps them in the right order
--    - missing genre / studio shown as 'Unknown' (easy to filter out)
-- =====================================================================
CREATE OR REPLACE VIEW analysis.pbi_films AS
SELECT movie_id,
       title,
       release_year,
       release_date,
       release_month,
       TO_CHAR(release_date, 'Mon')                                   AS month_name,
       COALESCE(main_genre, 'Unknown')                                AS main_genre,
       creative_type,
       age_rating,
       runtime_min,
       COALESCE(studio_name, 'Unknown')                               AS studio_name,
       metascore,
       userscore * 10                                                 AS audience_score,
       metascore - userscore * 10                                     AS score_gap,
       CASE WHEN metascore IS NULL THEN NULL
            WHEN metascore >= 81  THEN '4. Universal acclaim (81-100)'
            WHEN metascore >= 61  THEN '3. Generally favorable (61-80)'
            WHEN metascore >= 40  THEN '2. Mixed (40-60)'
            ELSE                       '1. Unfavorable (0-39)'
       END                                                            AS critic_band,
       CASE WHEN metascore IS NULL OR userscore IS NULL      THEN NULL
            WHEN metascore - userscore * 10 >= 20            THEN '1. Critics liked it much more'
            WHEN metascore - userscore * 10 <= -20           THEN '3. Audiences liked it much more'
            ELSE                                                  '2. Roughly agree'
       END                                                            AS disagreement,
       production_budget,
       domestic_gross,
       international_gross,
       worldwide_gross,
       opening_weekend,
       theatre_count,
       international_gross::numeric / NULLIF(worldwide_gross, 0)      AS international_share,
       multiple,
       profit,
       earned_back_budget::int                                        AS earned_back_budget,
       reached_2_5x::int                                              AS reached_2_5x,
       (multiple < 0.5)::int                                          AS lost_half_or_more,
       budget_group,
       CASE WHEN is_low_budget THEN 'Low budget (under $10M)'
            ELSE                    '$10M and over'
       END                                                            AS budget_class
FROM analysis.analysis_films;

-- =====================================================================
-- 2. Rank correlations (Spearman): critics / audiences vs multiple
--    Combines Q7a (all years) and Q7e (since 2010) in one table: each film
--    is joined to every period it belongs to, then ranked within its period
--    and group. In Power BI, a "period" slicer switches between the two.
-- =====================================================================
CREATE OR REPLACE VIEW analysis.pbi_score_correlations AS
WITH periods AS (
    SELECT * FROM (VALUES ('All years', 0), ('Since 2010', 2010)) AS p(period, from_year)
),
films AS (
    SELECT p.period, f.main_genre, f.is_low_budget, f.metascore, f.userscore, f.multiple
    FROM analysis.analysis_films AS f
    JOIN periods AS p ON f.release_year >= p.from_year
    WHERE f.metascore IS NOT NULL
      AND f.userscore IS NOT NULL
),
base AS (
    SELECT period, 'All films' AS film_group, metascore, userscore, multiple FROM films
    UNION ALL
    SELECT period, 'Low budget', metascore, userscore, multiple FROM films WHERE is_low_budget
    UNION ALL
    SELECT period, 'Genre: ' || main_genre, metascore, userscore, multiple FROM films WHERE main_genre IS NOT NULL
),
ranked AS (
    SELECT period, film_group,
           RANK() OVER (PARTITION BY period, film_group ORDER BY metascore)
               + (COUNT(*) OVER (PARTITION BY period, film_group, metascore) - 1) / 2.0  AS critic_rank,
           RANK() OVER (PARTITION BY period, film_group ORDER BY userscore)
               + (COUNT(*) OVER (PARTITION BY period, film_group, userscore) - 1) / 2.0  AS audience_rank,
           RANK() OVER (PARTITION BY period, film_group ORDER BY multiple)
               + (COUNT(*) OVER (PARTITION BY period, film_group, multiple) - 1) / 2.0   AS multiple_rank
    FROM base
)
SELECT period,
       film_group,
       COUNT(*)                                                AS films,
       ROUND(CORR(critic_rank,   multiple_rank)::numeric, 2)   AS critic_correlation,
       ROUND(CORR(audience_rank, multiple_rank)::numeric, 2)   AS audience_correlation,
       ROUND(CORR(critic_rank,   audience_rank)::numeric, 2)   AS critics_vs_audiences
FROM ranked
GROUP BY period, film_group
HAVING COUNT(*) >= 50;

-- =====================================================================
-- Checks
-- =====================================================================

-- Expected: 3,819 films
SELECT COUNT(*) AS films FROM analysis.pbi_films;

-- Expected: All years 3,363 films 0.21 / 0.12 / 0.54 | Since 2010 1,768 films 0.17 / 0.14 / 0.66
-- (the same numbers as Q7a and Q7e in 06_analysis.sql)
SELECT *
FROM analysis.pbi_score_correlations
WHERE film_group = 'All films';