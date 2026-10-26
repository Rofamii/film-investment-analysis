/* =====================================================================
   06_analysis.sql
   Film Investment Analysis: Step 6, analysis

   Main question
   What kind of film should a studio invest in, and how should it launch it,
   to get the highest box office multiple at the lowest risk?

   Metrics
   - Box office multiple = worldwide gross / production budget
   - Hit rate            = % of films that earned back their budget (multiple >= 1)
   - Reached 2.5x        = stricter break-even (cinemas keep part of ticket sales,
                           marketing costs are not in the data)
   - Profit ($)          = worldwide gross - production budget
   - Groups are compared with MEDIANS, not averages (a few huge hits distort averages)
   - Low-budget angle: every question shows low-budget films (budget under $10M)
     next to all films
   - Groups that are too small are hidden (HAVING / CASE WHEN COUNT >= ...)
   - Wording: results are "linked to", never "cause"

   Contents
   0. Analysis base view (one definition of the films and metrics for every question)
   Q1 Market context: international share of box office
   Q2 Studios
   Q3 Genres
   Q4 Budget size
   Q5 Release month
   Q6 Critic scores
   Q7 Critics vs audiences
   ===================================================================== */

-- =====================================================================
-- 0. Analysis base view
--    Rules: films with a budget AND worldwide gross; rule C: worldwide gross
--    >= $100,000 (removes incomplete records, see 05_validation.sql);
--    low budget = under $10M. Result: 3,819 films.
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS analysis;

CREATE OR REPLACE VIEW analysis.analysis_films AS
SELECT
    m.movie_id,
    m.title,
    m.release_year,
    m.release_date,
    EXTRACT(MONTH FROM m.release_date)::integer               AS release_month,
    m.main_genre,
    m.creative_type,
    m.age_rating,
    m.runtime_min,
    st.studio_name,
    m.metascore,
    m.userscore,
    b.production_budget,
    b.domestic_gross,
    b.international_gross,
    b.worldwide_gross,
    b.opening_weekend,
    b.theatre_count,
    b.worldwide_gross::numeric / b.production_budget          AS multiple,            -- box office multiple
    b.worldwide_gross - b.production_budget                   AS profit,              -- box office profit ($)
    (b.worldwide_gross >= b.production_budget)                AS earned_back_budget,  -- hit (>= 1x)
    (b.worldwide_gross >= 2.5 * b.production_budget)          AS reached_2_5x,        -- stricter break-even
    CASE WHEN b.production_budget <   1000000 THEN '1. Under $1M'
         WHEN b.production_budget <  10000000 THEN '2. $1M-$10M'
         WHEN b.production_budget <  50000000 THEN '3. $10M-$50M'
         WHEN b.production_budget < 100000000 THEN '4. $50M-$100M'
         ELSE '5. $100M+'
    END                                                       AS budget_group,
    (b.production_budget < 10000000)                          AS is_low_budget
FROM movie AS m
JOIN box_office AS b  ON b.movie_id   = m.movie_id
LEFT JOIN studio AS st ON st.studio_id = m.studio_id
WHERE b.production_budget IS NOT NULL
  AND b.worldwide_gross   IS NOT NULL
  AND b.worldwide_gross   >= 100000;                          -- rule C

-- Check: films per budget group
-- Result: under $1M 105 | $1M-$10M 809 | $10M-$50M 1,835 | $50M-$100M 646 | $100M+ 424 = 3,819
SELECT budget_group, COUNT(*) AS films
FROM analysis.analysis_films
GROUP BY budget_group
ORDER BY budget_group;


/* =====================================================================
   Q1 MARKET CONTEXT
   How has the international share of box office changed, and which genres
   earn the most abroad?
   Findings
   - International share rose from 45% (2000) to 60%+ from 2011 (65.6% in 2020,
     when US cinemas closed): a studio must plan for global distribution.
   - Low-budget films rely less on abroad (~53% vs ~61%, 2010-2019).
   - Action (61.5%) and adventure (59.5%) travel best; comedy (33%) the least.
   - Among low-budget films, thrillers travel best (67%, 97 films);
     low-budget comedies depend mainly on the US market.
   ===================================================================== */

-- Q1a: share of box office earned outside the US, per year
SELECT release_year,
       COUNT(*)                                                                  AS films,
       ROUND(100.0 * SUM(international_gross) / SUM(worldwide_gross), 1)        AS intl_share_all_pct,
       COUNT(*) FILTER (WHERE is_low_budget)                                     AS low_budget_films,
       ROUND(100.0 * SUM(international_gross) FILTER (WHERE is_low_budget)
                   / SUM(worldwide_gross)     FILTER (WHERE is_low_budget), 1)   AS intl_share_low_budget_pct
FROM analysis.analysis_films
WHERE international_gross IS NOT NULL
GROUP BY release_year
ORDER BY release_year;

-- Q1b: which genres earn the biggest share of their box office abroad? (typical film)
SELECT main_genre,
       COUNT(*)                                                                   AS films,
       ROUND(100 * (PERCENTILE_CONT(0.5) WITHIN GROUP
             (ORDER BY international_gross::numeric / worldwide_gross))::numeric, 1)  AS median_intl_share_pct,
       COUNT(*) FILTER (WHERE is_low_budget)                                      AS low_budget_films,
       ROUND(100 * (PERCENTILE_CONT(0.5) WITHIN GROUP
             (ORDER BY international_gross::numeric / worldwide_gross)
             FILTER (WHERE is_low_budget))::numeric, 1)                           AS median_intl_share_low_budget_pct
FROM analysis.analysis_films
WHERE main_genre IS NOT NULL
  AND international_gross IS NOT NULL
GROUP BY main_genre
HAVING COUNT(*) >= 20
ORDER BY median_intl_share_pct DESC;


/* =====================================================================
   Q2 STUDIOS
   Which studios achieve the best multiples, and how is their film mix different?
   (Studio names come from Metacritic; name variants were merged in 04a.)
   Findings
   - Best balance: mid-budget horror labels (Dimension, Screen Gems: ~$20M,
     2.9-3.0x, 85-88% hit rate).
   - Specialty labels with cheap dramas (A24, Paramount Vantage: $4-7M) reach a
     similar multiple (2.8x) with more risk (71-73% hit rate).
   - Big studios (Universal, Disney, Columbia, Fox) are reliable (84-88% hit rate,
     2.5-2.7x) but need $40-70M per film.
   - Low budget alone is not enough: distributors that release mainly on
     video-on-demand (IFC, Magnolia) earn under 1x from cinemas.
   - Best low-budget records: big studios releasing horror
     (Paramount 26.0x, Warner Bros. 13.7x, Universal 12.2x with a 96% hit rate).
   ===================================================================== */

-- Q2a: studios with at least 20 films: typical result and film mix
SELECT studio_name,
       COUNT(*)                                                                    AS films,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY multiple))::numeric, 2)  AS median_multiple,
       ROUND(100.0 * AVG(earned_back_budget::int), 1)                              AS hit_rate_pct,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY production_budget))::numeric / 1000000, 1)
                                                                                   AS median_budget_musd,
       ROUND(100.0 * AVG(is_low_budget::int), 1)                                   AS low_budget_share_pct,
       MODE() WITHIN GROUP (ORDER BY main_genre)                                   AS most_common_genre
FROM analysis.analysis_films
WHERE studio_name IS NOT NULL
GROUP BY studio_name
HAVING COUNT(*) >= 20
ORDER BY median_multiple DESC;

-- Q2b: which studios are best at LOW-BUDGET films? (at least 10 low-budget films)
SELECT studio_name,
       COUNT(*)                                                                    AS low_budget_films,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY multiple))::numeric, 2)  AS median_multiple,
       ROUND(100.0 * AVG(earned_back_budget::int), 1)                              AS hit_rate_pct,
       ROUND(100.0 * AVG(reached_2_5x::int), 1)                                    AS pct_at_least_2_5x,
       MODE() WITHIN GROUP (ORDER BY main_genre)                                   AS most_common_genre
FROM analysis.analysis_films
WHERE studio_name IS NOT NULL
  AND is_low_budget
GROUP BY studio_name
HAVING COUNT(*) >= 10
ORDER BY median_multiple DESC;

-- Q2c: which small films are behind Paramount's and Universal's results?
-- Paramount: mostly the Paranormal Activity series (431x, 59x, 41x, 29x, 18x);
-- Universal: almost all small films are horror/thriller (Unfriended 64x, Get Out 50x, Split 31x).
-- Sequels keep making money, but each earns a smaller multiple.
SELECT studio_name, title, release_year, main_genre,
       ROUND(production_budget / 1000000.0, 2) AS budget_musd,
       ROUND(worldwide_gross   / 1000000.0, 1) AS worldwide_musd,
       ROUND(multiple, 1)                      AS multiple
FROM analysis.analysis_films
WHERE is_low_budget
  AND studio_name IN ('Paramount Pictures', 'Universal Pictures')
ORDER BY studio_name, multiple DESC;


/* =====================================================================
   Q3 GENRES
   Which genres have the highest median multiple and hit rate?
   Findings
   - Horror is best on return AND risk: 3.36x, and even its weakest quarter
     earns 1.56x; 82% hit rate at a $12.5M median budget.
   - Adventure: highest hit rate (83.5%) and largest dollar profit ($87M), but $75M budgets.
   - Drama, the most common genre (1,014 films), is among the weakest (1.61x, 64% hit).
   - Low budget helps story-driven genres (horror 5.59x, drama 2.37x) and hurts
     spectacle genres (adventure 1.80x, musical 0.82x).
   - Horror is strong at every type of studio (3.24x outside Paramount,
     Universal and Warner Bros.).
   ===================================================================== */

-- Q3a: return and risk per genre (all films + low-budget films side by side)
SELECT main_genre,
       COUNT(*)                                                                         AS films,
       ROUND((PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY multiple))::numeric, 2)      AS median_multiple,
       ROUND((PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY multiple))::numeric, 2)      AS p25_multiple,
       ROUND(100.0 * AVG(earned_back_budget::int), 1)                                   AS hit_rate_pct,
       ROUND(100.0 * AVG(reached_2_5x::int), 1)                                         AS pct_at_least_2_5x,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY production_budget))::numeric / 1000000, 1) AS median_budget_musd,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY profit))::numeric / 1000000, 1)            AS median_profit_musd,
       COUNT(*) FILTER (WHERE is_low_budget)                                            AS low_budget_films,
       CASE WHEN COUNT(*) FILTER (WHERE is_low_budget) >= 10 THEN
            ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY multiple) FILTER (WHERE is_low_budget))::numeric, 2)
       END                                                                              AS lb_median_multiple,
       CASE WHEN COUNT(*) FILTER (WHERE is_low_budget) >= 10 THEN
            ROUND(100.0 * AVG(earned_back_budget::int) FILTER (WHERE is_low_budget), 1)
       END                                                                              AS lb_hit_rate_pct,
       CASE WHEN COUNT(*) FILTER (WHERE is_low_budget) >= 10 THEN
            ROUND(100.0 * AVG(reached_2_5x::int) FILTER (WHERE is_low_budget), 1)
       END                                                                              AS lb_pct_at_least_2_5x
FROM analysis.analysis_films
WHERE main_genre IS NOT NULL
GROUP BY main_genre
HAVING COUNT(*) >= 20
ORDER BY median_multiple DESC;

-- Q3b: is horror strong everywhere, or only at Paramount / Universal / Warner Bros.?
SELECT CASE
           WHEN studio_name IN ('Paramount Pictures', 'Universal Pictures', 'Warner Bros. Pictures')
                THEN '1. Paramount, Universal, Warner Bros.'
           WHEN studio_name IS NOT NULL THEN '2. All other studios'
           ELSE '3. Studio unknown'
       END                                                                              AS studio_group,
       COUNT(*)                                                                         AS horror_films,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY multiple))::numeric, 2)       AS median_multiple,
       ROUND(100.0 * AVG(earned_back_budget::int), 1)                                   AS hit_rate_pct,
       COUNT(*) FILTER (WHERE is_low_budget)                                            AS low_budget_films,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY multiple) FILTER (WHERE is_low_budget))::numeric, 2) AS lb_median_multiple,
       ROUND(100.0 * AVG(earned_back_budget::int) FILTER (WHERE is_low_budget), 1)      AS lb_hit_rate_pct
FROM analysis.analysis_films
WHERE main_genre = 'Horror'
GROUP BY studio_group
ORDER BY studio_group;


/* =====================================================================
   Q4 BUDGET SIZE
   Which budget size gives the best multiple for the risk?
   Findings
   - U-shape: under $1M (5.83x) and $100M+ (2.73x) do best; $10-50M is the
     squeezed middle (1.81x).
   - $100M+ is the safest: 89% hit rate, 2% big losses, narrowest range.
   - $1-10M is the riskiest: 1 in 5 films loses half its budget or more.
   - Under $1M is affected by survivorship bias (failed micro films rarely
     reach cinemas or publish a budget).
   - The right budget depends on the genre: horror, drama and documentaries
     earn most when cheap (horror $1-10M: 5.20x, 81% hit, 107 films); action,
     adventure and thrillers only perform reliably at $100M+.
   - Worst common choice: drama at $10-50M (547 films, 1.38x, 59% hit).
   ===================================================================== */

-- Q4a: return and risk per budget size
SELECT budget_group,
       COUNT(*)                                                                         AS films,
       ROUND((PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY multiple))::numeric, 2)      AS p25_multiple,
       ROUND((PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY multiple))::numeric, 2)      AS median_multiple,
       ROUND((PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY multiple))::numeric, 2)      AS p75_multiple,
       ROUND(100.0 * AVG(earned_back_budget::int), 1)                                   AS hit_rate_pct,
       ROUND(100.0 * AVG(reached_2_5x::int), 1)                                         AS pct_at_least_2_5x,
       ROUND(100.0 * AVG((multiple < 0.5)::int), 1)                                     AS pct_lost_half_or_more,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY profit))::numeric / 1000000, 1) AS median_profit_musd
FROM analysis.analysis_films
GROUP BY budget_group
ORDER BY budget_group;

-- Q4b: which budget size works best for each genre? (genre x budget, at least 10 films)
SELECT main_genre,
       budget_group,
       COUNT(*)                                                                         AS films,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY multiple))::numeric, 2)       AS median_multiple,
       ROUND(100.0 * AVG(earned_back_budget::int), 1)                                   AS hit_rate_pct,
       ROUND(100.0 * AVG(reached_2_5x::int), 1)                                         AS pct_at_least_2_5x
FROM analysis.analysis_films
WHERE main_genre IS NOT NULL
GROUP BY main_genre, budget_group
HAVING COUNT(*) >= 10
ORDER BY main_genre, budget_group;


/* =====================================================================
   Q5 RELEASE MONTH
   Which release months give the strongest opening weekends and multiples?
   (Opening weekend = US cinemas only.)
   Findings
   - Summer (May-Jul) is for blockbusters: biggest budgets and openings, good multiples.
   - Low-budget films do best in January-February (4.3x) and worst in May
     (1.86x, 63% hit rate).
   - Jan-Feb are the quietest months (fewest films and fewest $100M+ films);
     May has the most blockbusters (25% of releases) -> competition is the
     likely explanation (partly supported).
   - Horror: January best (4.92x, 90% hit rate); June-July works as
     counter-programming; October gives the biggest opening but not the best return.
   - December's small median opening ($2.4M) reflects limited awards-season
     releases, not failure (2.15x).
   ===================================================================== */

-- Q5a: opening weekend and multiple per release month (all films + low-budget)
SELECT release_month,
       TO_CHAR(MAKE_DATE(2000, release_month, 1), 'Mon')                                AS month_name,
       COUNT(*)                                                                         AS films,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY production_budget))::numeric / 1000000, 1) AS median_budget_musd,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY opening_weekend))::numeric / 1000000, 1)   AS median_opening_musd,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY multiple))::numeric, 2)       AS median_multiple,
       ROUND(100.0 * AVG(earned_back_budget::int), 1)                                   AS hit_rate_pct,
       COUNT(*) FILTER (WHERE is_low_budget)                                            AS low_budget_films,
       CASE WHEN COUNT(*) FILTER (WHERE is_low_budget) >= 10 THEN
            ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY multiple) FILTER (WHERE is_low_budget))::numeric, 2)
       END                                                                              AS lb_median_multiple,
       CASE WHEN COUNT(*) FILTER (WHERE is_low_budget) >= 10 THEN
            ROUND(100.0 * AVG(earned_back_budget::int) FILTER (WHERE is_low_budget), 1)
       END                                                                              AS lb_hit_rate_pct
FROM analysis.analysis_films
WHERE release_month IS NOT NULL
GROUP BY release_month
ORDER BY release_month;

-- Q5b: horror films per release month
SELECT release_month,
       TO_CHAR(MAKE_DATE(2000, release_month, 1), 'Mon')                                AS month_name,
       COUNT(*)                                                                         AS horror_films,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY opening_weekend))::numeric / 1000000, 1)   AS median_opening_musd,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY multiple))::numeric, 2)       AS median_multiple,
       ROUND(100.0 * AVG(earned_back_budget::int), 1)                                   AS hit_rate_pct
FROM analysis.analysis_films
WHERE main_genre = 'Horror'
  AND release_month IS NOT NULL
GROUP BY release_month
ORDER BY release_month;

-- Q5c: how crowded is each month with blockbusters? (checks the competition explanation)
SELECT release_month,
       TO_CHAR(MAKE_DATE(2000, release_month, 1), 'Mon')                                AS month_name,
       COUNT(*)                                                                         AS films,
       COUNT(*) FILTER (WHERE production_budget >= 100000000)                           AS blockbusters_100m_plus,
       ROUND(100.0 * AVG((production_budget >= 100000000)::int), 1)                     AS blockbuster_share_pct
FROM analysis.analysis_films
WHERE release_month IS NOT NULL
GROUP BY release_month
ORDER BY release_month;


/* =====================================================================
   Q6 CRITIC SCORES
   Are better critic scores linked to higher multiples?
   Findings
   - All films: a clear staircase from unfavorable (1.58x) to universal acclaim
     (4.01x, 89% hit rate).
   - Low-budget films: U-shaped; mixed reviews are the worst outcome
     (1.38x, 58% hit rate), acclaimed small films the best (3.97x).
   - Rank correlation 0.21 overall, but stronger inside every genre
     (0.22-0.49): the genre mix weakens the overall number. Strongest for action.
   ===================================================================== */

-- Q6a: multiple per critic score band (Metacritic's own bands)
SELECT CASE WHEN metascore >= 81 THEN '4. Universal acclaim (81-100)'
            WHEN metascore >= 61 THEN '3. Generally favorable (61-80)'
            WHEN metascore >= 40 THEN '2. Mixed (40-60)'
            ELSE                      '1. Unfavorable (0-39)'
       END                                                                              AS critic_band,
       COUNT(*)                                                                         AS films,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY production_budget))::numeric / 1000000, 1) AS median_budget_musd,
       MODE() WITHIN GROUP (ORDER BY main_genre)                                        AS most_common_genre,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY multiple))::numeric, 2)       AS median_multiple,
       ROUND(100.0 * AVG(earned_back_budget::int), 1)                                   AS hit_rate_pct,
       ROUND(100.0 * AVG(reached_2_5x::int), 1)                                         AS pct_at_least_2_5x,
       COUNT(*) FILTER (WHERE is_low_budget)                                            AS low_budget_films,
       CASE WHEN COUNT(*) FILTER (WHERE is_low_budget) >= 10 THEN
            ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY multiple) FILTER (WHERE is_low_budget))::numeric, 2)
       END                                                                              AS lb_median_multiple,
       CASE WHEN COUNT(*) FILTER (WHERE is_low_budget) >= 10 THEN
            ROUND(100.0 * AVG(earned_back_budget::int) FILTER (WHERE is_low_budget), 1)
       END                                                                              AS lb_hit_rate_pct
FROM analysis.analysis_films
WHERE metascore IS NOT NULL
GROUP BY critic_band
ORDER BY critic_band;

-- Q6b: rank correlation (Spearman) between critic score and multiple
-- Ranks instead of raw values, because multiples are extremely skewed (one film at 431x).
-- Tied values get the average of their positions (standard Spearman rule).
WITH base AS (
    SELECT 'All films' AS film_group, metascore, multiple
    FROM analysis.analysis_films
    WHERE metascore IS NOT NULL
    UNION ALL
    SELECT 'Low budget', metascore, multiple
    FROM analysis.analysis_films
    WHERE metascore IS NOT NULL AND is_low_budget
    UNION ALL
    SELECT 'Genre: ' || main_genre, metascore, multiple
    FROM analysis.analysis_films
    WHERE metascore IS NOT NULL AND main_genre IS NOT NULL
),
ranked AS (
    SELECT film_group,
           RANK() OVER (PARTITION BY film_group ORDER BY metascore)
               + (COUNT(*) OVER (PARTITION BY film_group, metascore) - 1) / 2.0  AS score_rank,
           RANK() OVER (PARTITION BY film_group ORDER BY multiple)
               + (COUNT(*) OVER (PARTITION BY film_group, multiple) - 1) / 2.0   AS multiple_rank
    FROM base
)
SELECT film_group,
       COUNT(*)                                            AS films,
       ROUND(CORR(score_rank, multiple_rank)::numeric, 2)  AS rank_correlation
FROM ranked
GROUP BY film_group
HAVING COUNT(*) >= 50
ORDER BY CASE film_group WHEN 'All films' THEN 1 WHEN 'Low budget' THEN 2 ELSE 3 END,
         rank_correlation DESC;


/* =====================================================================
   Q7 CRITICS VS AUDIENCES
   Where do critics and audiences disagree, and which score lines up better
   with box office? (Only films with both scores; user score x 10.)
   Findings
   - All years: the critic score lines up better in every genre (0.21 vs 0.12).
   - Robustness check (Q7e, films since 2010): most of that advantage disappears;
     both scores are about equally linked, except comedy and romance where
     critics still lead. Older films' user scores are inflated (Q7d: gap shrinks
     from about -18 in 2000-2005 to -6 in 2017-2021).
   - When critics and audiences disagree, films earn less (1.72-1.80x vs 2.25x).
   - Small films backed by critics did much better (3.93x) than small films
     only audiences liked (2.09x).
   - Limitation: Metacritic user scores are self-selected and vulnerable to
     organised campaigns (e.g. Captain Marvel: users 29/100, yet 6.5x).
   ===================================================================== */

-- Q7a: critics vs audiences: rank correlation with the multiple (same films)
WITH base AS (
    SELECT 'All films' AS film_group, metascore, userscore, multiple
    FROM analysis.analysis_films
    WHERE metascore IS NOT NULL AND userscore IS NOT NULL
    UNION ALL
    SELECT 'Low budget', metascore, userscore, multiple
    FROM analysis.analysis_films
    WHERE metascore IS NOT NULL AND userscore IS NOT NULL AND is_low_budget
    UNION ALL
    SELECT 'Genre: ' || main_genre, metascore, userscore, multiple
    FROM analysis.analysis_films
    WHERE metascore IS NOT NULL AND userscore IS NOT NULL AND main_genre IS NOT NULL
),
ranked AS (
    SELECT film_group,
           RANK() OVER (PARTITION BY film_group ORDER BY metascore)
               + (COUNT(*) OVER (PARTITION BY film_group, metascore) - 1) / 2.0  AS critic_rank,
           RANK() OVER (PARTITION BY film_group ORDER BY userscore)
               + (COUNT(*) OVER (PARTITION BY film_group, userscore) - 1) / 2.0  AS audience_rank,
           RANK() OVER (PARTITION BY film_group ORDER BY multiple)
               + (COUNT(*) OVER (PARTITION BY film_group, multiple) - 1) / 2.0   AS multiple_rank
    FROM base
)
SELECT film_group,
       COUNT(*)                                                AS films,
       ROUND(CORR(critic_rank,   multiple_rank)::numeric, 2)   AS critic_correlation,
       ROUND(CORR(audience_rank, multiple_rank)::numeric, 2)   AS audience_correlation,
       ROUND(CORR(critic_rank,   audience_rank)::numeric, 2)   AS critics_vs_audiences
FROM ranked
GROUP BY film_group
HAVING COUNT(*) >= 50
ORDER BY CASE film_group WHEN 'All films' THEN 1 WHEN 'Low budget' THEN 2 ELSE 3 END,
         film_group;

-- Q7b: when critics and audiences disagree (gap of 20+ points), which side does the box office follow?
SELECT CASE WHEN metascore - userscore * 10 >= 20  THEN '1. Critics liked it much more'
            WHEN metascore - userscore * 10 <= -20 THEN '3. Audiences liked it much more'
            ELSE                                        '2. Roughly agree'
       END                                                                              AS disagreement,
       COUNT(*)                                                                         AS films,
       MODE() WITHIN GROUP (ORDER BY main_genre)                                        AS most_common_genre,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY metascore))::numeric)         AS median_critic_score,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY userscore * 10))::numeric)    AS median_audience_score,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY multiple))::numeric, 2)       AS median_multiple,
       ROUND(100.0 * AVG(earned_back_budget::int), 1)                                   AS hit_rate_pct,
       ROUND(100.0 * AVG(reached_2_5x::int), 1)                                         AS pct_at_least_2_5x,
       COUNT(*) FILTER (WHERE is_low_budget)                                            AS low_budget_films,
       CASE WHEN COUNT(*) FILTER (WHERE is_low_budget) >= 10 THEN
            ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY multiple) FILTER (WHERE is_low_budget))::numeric, 2)
       END                                                                              AS lb_median_multiple,
       CASE WHEN COUNT(*) FILTER (WHERE is_low_budget) >= 10 THEN
            ROUND(100.0 * AVG(earned_back_budget::int) FILTER (WHERE is_low_budget), 1)
       END                                                                              AS lb_hit_rate_pct
FROM analysis.analysis_films
WHERE metascore IS NOT NULL
  AND userscore IS NOT NULL
GROUP BY disagreement
ORDER BY disagreement;

-- Q7c: the 10 biggest disagreements each way, among well-known films (worldwide >= $50M)
(SELECT 'Critics liked it much more'      AS side, title, release_year, main_genre,
        metascore                          AS critic_score,
        ROUND(userscore * 10)              AS audience_score,
        metascore - ROUND(userscore * 10)  AS gap,
        ROUND(multiple, 1)                 AS multiple
 FROM analysis.analysis_films
 WHERE metascore IS NOT NULL AND userscore IS NOT NULL AND worldwide_gross >= 50000000
 ORDER BY metascore - userscore * 10 DESC
 LIMIT 10)
UNION ALL
(SELECT 'Audiences liked it much more', title, release_year, main_genre,
        metascore,
        ROUND(userscore * 10),
        metascore - ROUND(userscore * 10),
        ROUND(multiple, 1)
 FROM analysis.analysis_films
 WHERE metascore IS NOT NULL AND userscore IS NOT NULL AND worldwide_gross >= 50000000
 ORDER BY metascore - userscore * 10 ASC
 LIMIT 10);

-- Q7d: critic vs audience score per release year (are older films' user scores inflated?)
SELECT release_year,
       COUNT(*)                                                                                  AS films,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY metascore))::numeric)                  AS median_critic_score,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY userscore * 10))::numeric)             AS median_audience_score,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY metascore - userscore * 10))::numeric) AS median_gap
FROM analysis.analysis_films
WHERE metascore IS NOT NULL
  AND userscore IS NOT NULL
GROUP BY release_year
ORDER BY release_year;

-- Q7e: robustness check: Q7a again, only films from 2010 onwards
WITH base AS (
    SELECT 'All films' AS film_group, metascore, userscore, multiple
    FROM analysis.analysis_films
    WHERE metascore IS NOT NULL AND userscore IS NOT NULL AND release_year >= 2010
    UNION ALL
    SELECT 'Low budget', metascore, userscore, multiple
    FROM analysis.analysis_films
    WHERE metascore IS NOT NULL AND userscore IS NOT NULL AND release_year >= 2010 AND is_low_budget
    UNION ALL
    SELECT 'Genre: ' || main_genre, metascore, userscore, multiple
    FROM analysis.analysis_films
    WHERE metascore IS NOT NULL AND userscore IS NOT NULL AND release_year >= 2010 AND main_genre IS NOT NULL
),
ranked AS (
    SELECT film_group,
           RANK() OVER (PARTITION BY film_group ORDER BY metascore)
               + (COUNT(*) OVER (PARTITION BY film_group, metascore) - 1) / 2.0  AS critic_rank,
           RANK() OVER (PARTITION BY film_group ORDER BY userscore)
               + (COUNT(*) OVER (PARTITION BY film_group, userscore) - 1) / 2.0  AS audience_rank,
           RANK() OVER (PARTITION BY film_group ORDER BY multiple)
               + (COUNT(*) OVER (PARTITION BY film_group, multiple) - 1) / 2.0   AS multiple_rank
    FROM base
)
SELECT film_group,
       COUNT(*)                                                AS films,
       ROUND(CORR(critic_rank,   multiple_rank)::numeric, 2)   AS critic_correlation,
       ROUND(CORR(audience_rank, multiple_rank)::numeric, 2)   AS audience_correlation,
       ROUND(CORR(critic_rank,   audience_rank)::numeric, 2)   AS critics_vs_audiences
FROM ranked
GROUP BY film_group
HAVING COUNT(*) >= 50
ORDER BY CASE film_group WHEN 'All films' THEN 1 WHEN 'Low budget' THEN 2 ELSE 3 END,
         film_group;


/* =====================================================================
   RECOMMENDATIONS (full explanation in README.md)
   1. What to make: horror at $1-50M (best low-budget bet: horror at $1-10M,
      5.2x, 81% hit rate); avoid drama at $10-50M, cheap spectacle and westerns.
   2. How to launch: small films in January-February, avoid May, September and
      November; partner with a wide-release distributor; plan internationally
      for big films.
   3. Invest in quality where it pays: reviews matter most for expensive action;
      for small films, genre, budget, month and distributor matter more than reviews.
   ===================================================================== */