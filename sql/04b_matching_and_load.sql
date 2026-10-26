/* =====================================================================
   04b_matching_and_load.sql
   Film Investment Analysis: Step 4b, match films across the two websites
   and load the clean data into the 6 final tables

   Part 1: Matching
   - A film matches only if its title AND year fit at the same time.
     Titles are compared with staging.title_key(): no punctuation, accents or "The".
   - Round 1: same title + same year.
   - Round 2: same title + year differs by 1 (festival year vs cinema year),
     only for films still unmatched, and only if there is exactly one
     possible partner on both sides.
   - No guessing: a title + year that appears twice on one website is never matched.
   - Result: staging.film_match, one row per matched pair.

   Part 2: Load
   - Order matters: lookup tables first, then movie, then the tables that point to movie.
   - Matched films become ONE row in movie, with both URLs. Films found on only
     one website are kept too (the other URL stays empty).
   - Matched films use the Metacritic title (no broken characters) and the
     The-Numbers release date (cinema release); the Metacritic date is only used
     if it falls in the same year (3 UK films had a later US date on Metacritic).
   - TRUNCATE empties the final tables first, so the whole load can be run again
     from scratch. The raw data in staging is never touched.

   Requires 04a_cleaning.sql (views and title_key).
   ===================================================================== */

-- =====================================================================
-- Part 1: Matching
-- =====================================================================
CREATE TABLE IF NOT EXISTS staging.film_match (
    numbers_url     text PRIMARY KEY,
    metacritic_url  text NOT NULL UNIQUE,
    match_method    text NOT NULL            -- 'exact year' or 'year +/- 1'
);

TRUNCATE staging.film_match;                 -- start empty, so the script can be run again

-- Round 1: same title + same year
WITH s AS (
    SELECT numbers_url,
           staging.title_key(title) AS tkey,
           release_year,
           COUNT(*) OVER (PARTITION BY staging.title_key(title), release_year) AS same_key_count
    FROM staging.clean_sales
),
m AS (
    SELECT metacritic_url,
           staging.title_key(title) AS tkey,
           release_year,
           COUNT(*) OVER (PARTITION BY staging.title_key(title), release_year) AS same_key_count
    FROM staging.clean_metacritic
)
INSERT INTO staging.film_match (numbers_url, metacritic_url, match_method)
SELECT s.numbers_url, m.metacritic_url, 'exact year'
FROM s
JOIN m ON m.tkey = s.tkey
      AND m.release_year = s.release_year
WHERE s.tkey IS NOT NULL
  AND s.same_key_count = 1                   -- title + year is unique on The-Numbers
  AND m.same_key_count = 1;                  -- ... and unique on Metacritic

-- Round 2: same title + year differs by exactly 1, only for films not matched yet
WITH s AS (
    SELECT numbers_url, staging.title_key(title) AS tkey, release_year
    FROM staging.clean_sales
    WHERE numbers_url NOT IN (SELECT numbers_url FROM staging.film_match)
),
m AS (
    SELECT metacritic_url, staging.title_key(title) AS tkey, release_year
    FROM staging.clean_metacritic
    WHERE metacritic_url NOT IN (SELECT metacritic_url FROM staging.film_match)
),
candidates AS (
    SELECT s.numbers_url, m.metacritic_url,
           COUNT(*) OVER (PARTITION BY s.numbers_url)    AS partners_for_numbers_film,
           COUNT(*) OVER (PARTITION BY m.metacritic_url) AS partners_for_metacritic_film
    FROM s
    JOIN m ON m.tkey = s.tkey
          AND ABS(m.release_year - s.release_year) = 1
    WHERE s.tkey IS NOT NULL
)
INSERT INTO staging.film_match (numbers_url, metacritic_url, match_method)
SELECT numbers_url, metacritic_url, 'year +/- 1'
FROM candidates
WHERE partners_for_numbers_film = 1          -- exactly one possible partner on both sides
  AND partners_for_metacritic_film = 1;

-- Check A: how many films matched, and how?
-- Expected: exact year 8,358 | year +/- 1 464 | only The-Numbers 21,789 | only Metacritic 2,542
SELECT match_method, COUNT(*) AS films
FROM staging.film_match
GROUP BY match_method
UNION ALL
SELECT 'not matched: only on The-Numbers',
       (SELECT COUNT(*) FROM staging.clean_sales
        WHERE numbers_url NOT IN (SELECT numbers_url FROM staging.film_match))
UNION ALL
SELECT 'not matched: only on Metacritic',
       (SELECT COUNT(*) FROM staging.clean_metacritic
        WHERE metacritic_url NOT IN (SELECT metacritic_url FROM staging.film_match));

-- =====================================================================
-- Part 2: Load the 6 final tables
-- =====================================================================
TRUNCATE review, movie_genre, box_office, movie, genre, studio RESTART IDENTITY;   -- IDs start again at 1

-- 1. Studios: each name once
INSERT INTO studio (studio_name)
SELECT DISTINCT studio
FROM staging.clean_metacritic
WHERE studio IS NOT NULL
ORDER BY studio;

-- 2. Genres: each Metacritic genre once
INSERT INTO genre (genre_name)
SELECT DISTINCT genre_name
FROM staging.clean_movie_genres
ORDER BY genre_name;

-- 3. Movies: matched films (1 row with both URLs) + films found on only one website
INSERT INTO movie (title, release_date, release_year, runtime_min, age_rating, main_genre,
                   creative_type, studio_id, metascore, userscore, numbers_url, metacritic_url)
SELECT
    COALESCE(m.title, s.title)                AS title,          -- Metacritic title preferred (no broken characters)
    COALESCE(s.release_date,                                      -- cinema release (The-Numbers) preferred;
             CASE WHEN EXTRACT(YEAR FROM m.release_date)          -- Metacritic date only if it falls in
                       = COALESCE(s.release_year, m.release_year) -- the same release year
                  THEN m.release_date END)  AS release_date,
    COALESCE(s.release_year, m.release_year)  AS release_year,
    COALESCE(s.runtime_min, m.runtime_min)    AS runtime_min,
    m.age_rating,
    s.main_genre,                                                 -- single genre from The-Numbers
    s.creative_type,
    st.studio_id,
    m.metascore,
    m.userscore,
    s.numbers_url,
    m.metacritic_url
FROM staging.clean_sales AS s
LEFT JOIN staging.film_match AS fm ON fm.numbers_url = s.numbers_url
FULL OUTER JOIN staging.clean_metacritic AS m ON m.metacritic_url = fm.metacritic_url   -- keeps Metacritic-only films too
LEFT JOIN studio AS st ON st.studio_name = m.studio;

-- 4. Box office: one row per film that has at least one financial number
INSERT INTO box_office (movie_id, production_budget, domestic_gross, international_gross,
                        worldwide_gross, opening_weekend, theatre_count, avg_run_weeks)
SELECT mv.movie_id, s.production_budget, s.domestic_gross, s.international_gross,
       s.worldwide_gross, s.opening_weekend, s.theatre_count, s.avg_run_weeks
FROM staging.clean_sales AS s
JOIN movie AS mv ON mv.numbers_url = s.numbers_url
WHERE num_nonnulls(s.production_budget, s.domestic_gross, s.international_gross,
                   s.worldwide_gross, s.opening_weekend, s.theatre_count, s.avg_run_weeks) > 0;

-- 5. Film-genre pairs
INSERT INTO movie_genre (movie_id, genre_id)
SELECT DISTINCT mv.movie_id, g.genre_id
FROM staging.clean_movie_genres AS cg
JOIN movie AS mv ON mv.metacritic_url = cg.metacritic_url
JOIN genre AS g  ON g.genre_name      = cg.genre_name;

-- 6. Reviews (critics + users)
INSERT INTO review (movie_id, reviewer_type, reviewer_name, review_date, score_raw, score_100,
                    thumbs_up, thumbs_total, word_count, tone, positive_emotion, negative_emotion, review_text)
SELECT mv.movie_id, r.reviewer_type, r.reviewer_name, r.review_date, r.score_raw, r.score_100,
       r.thumbs_up, r.thumbs_total, r.word_count, r.tone, r.positive_emotion, r.negative_emotion, r.review_text
FROM staging.clean_reviews AS r
JOIN movie AS mv ON mv.metacritic_url = r.metacritic_url;

-- Check B: rows in the final tables, compared with what we expect
-- Expected: movie 33,153 | studio 1,076 | genre 27 | movie_genre 27,051 |
--           review 554,903 | box_office 26,647
SELECT 'movie'       AS table_name, COUNT(*) AS rows_loaded,
       (SELECT COUNT(*) FROM staging.clean_sales) + (SELECT COUNT(*) FROM staging.clean_metacritic)
       - (SELECT COUNT(*) FROM staging.film_match)                    AS rows_expected FROM movie
UNION ALL SELECT 'studio',      COUNT(*), (SELECT COUNT(DISTINCT studio) FROM staging.clean_metacritic) FROM studio
UNION ALL SELECT 'genre',       COUNT(*), (SELECT COUNT(DISTINCT genre_name) FROM staging.clean_movie_genres) FROM genre
UNION ALL SELECT 'movie_genre', COUNT(*), (SELECT COUNT(*) FROM staging.clean_movie_genres) FROM movie_genre
UNION ALL SELECT 'review',      COUNT(*), (SELECT COUNT(*) FROM staging.clean_reviews) FROM review
UNION ALL SELECT 'box_office',  COUNT(*), NULL FROM box_office;

-- Check C: the numbers that matter for the analysis
-- Expected: 3,900 | 8,822 | 3,414 | 0
SELECT
    (SELECT COUNT(*) FROM box_office
      WHERE production_budget IS NOT NULL AND worldwide_gross IS NOT NULL)        AS films_with_budget_and_worldwide,
    (SELECT COUNT(*) FROM movie
      WHERE numbers_url IS NOT NULL AND metacritic_url IS NOT NULL)              AS films_on_both_websites,
    (SELECT COUNT(*) FROM movie m JOIN box_office b USING (movie_id)
      WHERE b.production_budget IS NOT NULL AND b.worldwide_gross IS NOT NULL
        AND m.metacritic_url IS NOT NULL)                                        AS films_with_money_and_reviews,
    (SELECT COUNT(*) FROM movie WHERE title ~ '(Ã|Â|â€)')                        AS broken_titles;