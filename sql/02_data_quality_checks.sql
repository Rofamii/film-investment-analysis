/* =====================================================================
   02_data_quality_checks.sql
   Film Investment Analysis: Step 2, data quality report on the raw data

   Purpose
   - Measure the problems in the staging tables BEFORE cleaning anything.
     Nothing is changed here; the results decide the cleaning rules in Step 4.
   - Output: one row per check (52 checks), in long format:
     table_name | check_name | result

   Contents
   1. Two helper functions used here and in the cleaning step
   2. An index that makes the review checks fast
   3. The report

   Safe to run more than once.
   ===================================================================== */

-- ---------------------------------------------------------------------
-- 1. Helper functions
-- ---------------------------------------------------------------------

-- Is this raw value "missing"? (NULL, empty, n/a, None, nan, tbd ...)
CREATE OR REPLACE FUNCTION staging.is_missing(val text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
    SELECT val IS NULL OR TRIM(val) IN ('', 'n/a', 'N/A', 'None', 'none', 'nan', 'NaN', 'tbd');
$$;

-- Turn a Dutch-format number ("1058457,00", "7,30", "86") into a real number;
-- returns NULL if the value is missing or not a valid number
CREATE OR REPLACE FUNCTION staging.to_num(val text)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE WHEN TRIM(val) ~ '^-?\d+(,\d+)?$'
                THEN REPLACE(TRIM(val), ',', '.')::numeric
           END;
$$;

-- ---------------------------------------------------------------------
-- 2. Index: each of the ~560k reviews is checked against the Metacritic
--    table; without an index that means scanning the whole table every
--    time (minutes). With it, the full report runs in seconds.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_stg_metacritic_url ON staging.stg_metacritic (url);

-- ---------------------------------------------------------------------
-- 3. Data quality report
--    Each CTE measures one table in a single pass (COUNT ... FILTER);
--    CROSS JOIN LATERAL (VALUES ...) turns the wide result into one row per check.
-- ---------------------------------------------------------------------
WITH
sales AS (
    SELECT
        COUNT(*)                                                                 AS total_rows,
        COUNT(*) - COUNT(DISTINCT url)                                           AS duplicate_urls,
        COUNT(*) - COUNT(DISTINCT (LOWER(TRIM(title)), year))                    AS duplicate_title_year,
        COUNT(*) FILTER (WHERE staging.is_missing(title))                        AS missing_title,
        COUNT(*) FILTER (WHERE staging.is_missing(genre))                        AS missing_genre,
        COUNT(*) FILTER (WHERE staging.is_missing(production_budget))            AS missing_budget,
        COUNT(*) FILTER (WHERE staging.is_missing(worldwide_box_office))         AS missing_worldwide,
        COUNT(*) FILTER (WHERE staging.is_missing(domestic_box_office))          AS missing_domestic,
        COUNT(*) FILTER (WHERE staging.is_missing(international_box_office))     AS missing_international,
        COUNT(*) FILTER (WHERE NOT staging.is_missing(production_budget)
                           AND NOT staging.is_missing(worldwide_box_office))     AS has_budget_and_worldwide,
        COUNT(*) FILTER (WHERE
              (NOT staging.is_missing(production_budget)        AND staging.to_num(production_budget)        IS NULL)
           OR (NOT staging.is_missing(worldwide_box_office)     AND staging.to_num(worldwide_box_office)     IS NULL)
           OR (NOT staging.is_missing(domestic_box_office)      AND staging.to_num(domestic_box_office)      IS NULL)
           OR (NOT staging.is_missing(international_box_office) AND staging.to_num(international_box_office) IS NULL)
           OR (NOT staging.is_missing(opening_weekend)          AND staging.to_num(opening_weekend)          IS NULL))
                                                                                 AS money_not_a_number,
        COUNT(*) FILTER (WHERE staging.to_num(worldwide_box_office)
                            <> staging.to_num(domestic_box_office) + staging.to_num(international_box_office))
                                                                                 AS worldwide_not_dom_plus_intl,
        COUNT(*) FILTER (WHERE NOT staging.is_missing(release_date)
                           AND TRIM(release_date) !~ '^[A-Z][a-z]+ \d{1,2}(st|nd|rd|th)$')
                                                                                 AS release_date_odd_format,
        MIN(staging.to_num(year))                                                AS first_year,
        MAX(staging.to_num(year))                                                AS last_year,
        COUNT(*) FILTER (WHERE NOT staging.is_missing(empty_col))                AS empty_col_not_empty,
        COUNT(*) FILTER (WHERE title ~ '(Ã|Â|â€)')                               AS broken_characters_title
    FROM staging.stg_sales
),
meta AS (
    SELECT
        COUNT(*)                                                                 AS total_rows,
        COUNT(*) - COUNT(DISTINCT url)                                           AS duplicate_urls,
        COUNT(*) FILTER (WHERE url NOT LIKE 'https://www.metacritic.com/%')      AS rows_without_url,
        COUNT(*) FILTER (WHERE staging.is_missing(title))                        AS missing_title,
        COUNT(*) FILTER (WHERE staging.is_missing(studio))                       AS missing_studio,
        COUNT(*) FILTER (WHERE staging.is_missing(rating))                       AS missing_rating,
        COUNT(*) FILTER (WHERE staging.is_missing(genre))                        AS missing_genre,
        COUNT(*) FILTER (WHERE staging.is_missing(metascore))                    AS missing_metascore,
        COUNT(*) FILTER (WHERE staging.is_missing(userscore))                    AS missing_userscore,
        COUNT(*) FILTER (WHERE NOT staging.is_missing(metascore)
                           AND NOT staging.to_num(metascore) BETWEEN 0 AND 100)  AS metascore_invalid,
        COUNT(*) FILTER (WHERE NOT staging.is_missing(userscore)
                           AND NOT staging.to_num(userscore) BETWEEN 0 AND 10)   AS userscore_invalid,
        COUNT(*) FILTER (WHERE TRIM(userscore) = 'tbd')                          AS userscore_tbd,
        COUNT(*) FILTER (WHERE staging.is_missing(rel_date))                     AS missing_rel_date,
        COUNT(*) FILTER (WHERE NOT staging.is_missing(rel_date)
                           AND TRIM(rel_date) !~ '^\d{1,2}-\d{1,2}-\d{4}$')      AS rel_date_odd_format,
        COUNT(*) FILTER (WHERE rating LIKE '|%')                                 AS rating_with_pipe,
        COUNT(*) FILTER (WHERE title ~ '(Ã|Â|â€)')                               AS broken_characters_title
    FROM staging.stg_metacritic
),
critic AS (
    SELECT
        COUNT(*)                                                                 AS total_rows,
        COUNT(DISTINCT url)                                                      AS films_reviewed,
        COUNT(*) - COUNT(DISTINCT (url, reviewer, rev))                          AS duplicate_reviews,
        COUNT(*) FILTER (WHERE staging.is_missing(idvscore))                     AS missing_score,
        COUNT(*) FILTER (WHERE NOT staging.is_missing(idvscore)
                           AND NOT staging.to_num(idvscore) BETWEEN 0 AND 100)   AS score_invalid,
        COUNT(*) FILTER (WHERE staging.is_missing(reviewer))                     AS missing_reviewer,
        COUNT(*) FILTER (WHERE staging.is_missing(date_p))                       AS missing_date,
        COUNT(*) FILTER (WHERE staging.is_missing(rev))                          AS missing_text,
        COUNT(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM staging.stg_metacritic m
                                           WHERE m.url = c.url))                 AS film_not_in_metacritic
    FROM staging.stg_expert_reviews c
),
usr AS (
    SELECT
        COUNT(*)                                                                 AS total_rows,
        COUNT(DISTINCT url)                                                      AS films_reviewed,
        COUNT(*) - COUNT(DISTINCT (url, reviewer, rev))                          AS duplicate_reviews,
        COUNT(*) FILTER (WHERE staging.is_missing(idvscore))                     AS missing_score,
        COUNT(*) FILTER (WHERE NOT staging.is_missing(idvscore)
                           AND NOT staging.to_num(idvscore) BETWEEN 0 AND 10)    AS score_invalid,
        COUNT(*) FILTER (WHERE staging.is_missing(reviewer))                     AS missing_reviewer,
        COUNT(*) FILTER (WHERE staging.is_missing(date_p))                       AS missing_date,
        COUNT(*) FILTER (WHERE staging.is_missing(rev))                          AS missing_text,
        COUNT(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM staging.stg_metacritic m
                                           WHERE m.url = u.url))                 AS film_not_in_metacritic
    FROM staging.stg_user_reviews u
),
title_match AS (   -- how many sales films have the exact same title + year on Metacritic?
    SELECT COUNT(DISTINCT s.url) AS sales_films_exact_match
    FROM staging.stg_sales s
    JOIN staging.stg_metacritic m
      ON LOWER(TRIM(s.title)) = LOWER(TRIM(m.title))
     AND TRIM(s.year) = RIGHT(TRIM(m.rel_date), 4)
)
SELECT 'stg_sales' AS table_name, c.check_name, c.result
FROM sales CROSS JOIN LATERAL (VALUES
    ('total_rows', total_rows), ('duplicate_urls', duplicate_urls), ('duplicate_title_year', duplicate_title_year),
    ('missing_title', missing_title), ('missing_genre', missing_genre), ('missing_budget', missing_budget),
    ('missing_worldwide', missing_worldwide), ('missing_domestic', missing_domestic),
    ('missing_international', missing_international), ('has_budget_and_worldwide', has_budget_and_worldwide),
    ('money_not_a_number', money_not_a_number), ('worldwide_not_dom_plus_intl', worldwide_not_dom_plus_intl),
    ('release_date_odd_format', release_date_odd_format), ('first_year', first_year), ('last_year', last_year),
    ('empty_col_not_empty', empty_col_not_empty), ('broken_characters_title', broken_characters_title)
) AS c(check_name, result)
UNION ALL
SELECT 'stg_metacritic', c.check_name, c.result
FROM meta CROSS JOIN LATERAL (VALUES
    ('total_rows', total_rows), ('duplicate_urls', duplicate_urls), ('rows_without_url', rows_without_url),
    ('missing_title', missing_title), ('missing_studio', missing_studio), ('missing_rating', missing_rating),
    ('missing_genre', missing_genre), ('missing_metascore', missing_metascore), ('missing_userscore', missing_userscore),
    ('metascore_invalid', metascore_invalid), ('userscore_invalid', userscore_invalid), ('userscore_tbd', userscore_tbd),
    ('missing_rel_date', missing_rel_date), ('rel_date_odd_format', rel_date_odd_format),
    ('rating_with_pipe', rating_with_pipe), ('broken_characters_title', broken_characters_title)
) AS c(check_name, result)
UNION ALL
SELECT 'stg_expert_reviews', c.check_name, c.result
FROM critic CROSS JOIN LATERAL (VALUES
    ('total_rows', total_rows), ('films_reviewed', films_reviewed), ('duplicate_reviews', duplicate_reviews),
    ('missing_score', missing_score), ('score_invalid', score_invalid), ('missing_reviewer', missing_reviewer),
    ('missing_date', missing_date), ('missing_text', missing_text), ('film_not_in_metacritic', film_not_in_metacritic)
) AS c(check_name, result)
UNION ALL
SELECT 'stg_user_reviews', c.check_name, c.result
FROM usr CROSS JOIN LATERAL (VALUES
    ('total_rows', total_rows), ('films_reviewed', films_reviewed), ('duplicate_reviews', duplicate_reviews),
    ('missing_score', missing_score), ('score_invalid', score_invalid), ('missing_reviewer', missing_reviewer),
    ('missing_date', missing_date), ('missing_text', missing_text), ('film_not_in_metacritic', film_not_in_metacritic)
) AS c(check_name, result)
UNION ALL
SELECT 'sales_vs_metacritic', 'sales_films_exact_title_year_match', sales_films_exact_match
FROM title_match;

/* ---------------------------------------------------------------------
   Main findings (full data)
   - stg_sales: 30,612 films (2000-2021); only 3,900 have both a budget and
     worldwide box office (the base for the multiple); 2,324 titles with broken
     characters; 8 missing titles; 1,704 missing genre; 32 duplicate title+year;
     46 odd release dates; money values all valid; worldwide = domestic +
     international in every complete row
   - stg_metacritic: 11,364 films; 10,297 age ratings start with "| ";
     user score missing for 2,105 (18.5%); studio missing for 350
   - reviews: 0 orphan reviews; duplicates 72 critic + 1,051 user;
     ~3,400 empty user-review rows; 44% of critic reviews without a date
   - 8,019 sales films already match Metacritic on exact title + year
   --------------------------------------------------------------------- */