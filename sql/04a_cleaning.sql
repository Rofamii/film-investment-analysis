/* =====================================================================
   04a_cleaning.sql
   Film Investment Analysis: Step 4a, cleaning (functions, lookup table, views)

   Purpose
   - Turn the raw staging data into clean, typed data, using SQL only.
   - Cleaning happens in VIEWS: a view is a saved query that shows the
     cleaned version of a staging table without changing the raw data.
     Step 4b loads these views into the final tables.

   Cleaning rules (decided from the data quality report, Step 2)
    1. Repair broken characters from the scraping ("La vallÃ©e" -> "La vallée");
       titles that can't be repaired are rebuilt from the film's URL
    2. Dutch numbers ("1058457,00") -> numeric; "n/a", "None", "" -> NULL; budget 0 -> NULL
    3. Odd release dates ("2002 (Wide) by") -> NULL date, the year is kept
    4. Missing titles (e.g. "(500) Days of Summer") are recovered from the URL
    5. Duplicate title + year combinations are kept, but never matched (Step 4b)
    6. Age rating: remove the "| " prefix ("| PG-13" -> "PG-13")
    7. Duplicate reviews: keep only the first copy
    8. Empty review rows (no valid score AND no real text) are removed
    9. Reviewer names, dates and texts: strip stray quotes; "None" -> NULL
   10. Studio names: variants of the same studio are merged (lookup table)

   Contents
   1. Cleaning functions
   2. Lookup table: studio name variants
   3. Cleaning views
   4. Checks

   Safe to run more than once: CREATE OR REPLACE / IF NOT EXISTS / ON CONFLICT.
   Requires 02_data_quality_checks.sql (functions is_missing and to_num).
   ===================================================================== */

-- =====================================================================
-- 1. Cleaning functions
-- =====================================================================

-- Removes accents (é -> e) so titles from both websites can be compared
CREATE EXTENSION IF NOT EXISTS unaccent;

-- Repairs broken characters from the scraping, e.g. "La vallÃ©e" -> "La vallée".
-- The scraper read UTF-8 text as Windows text. To undo that, every broken character is
-- turned back into its original byte and the bytes are read again as UTF-8.
-- Windows has 27 special characters (€ ‚ ƒ „ … ™ ...) in positions 128-159; TRANSLATE puts
-- them back on those positions, so LATIN1 can turn every character into exactly one byte.
-- Extra: "à" was broken into "Ã" + an invisible space that got lost ("Cet amour-lÃ");
-- after a lowercase letter, a word-final "Ã" can only be "à".
-- Characters shown as "�" were truly lost in the scraping and cannot be rebuilt.
CREATE OR REPLACE FUNCTION staging.fix_text(val text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    fixed text := REGEXP_REPLACE(val, '([a-z-])Ã( |$)', '\1Ã' || chr(160) || '\2', 'g');   -- put the lost space of "à" back
BEGIN
    FOR i IN 1..3 LOOP                                                    -- some text was broken 2-3 times
        EXIT WHEN fixed IS NULL OR fixed !~ '[ÃÂâÄÅ]';                  -- nothing (left) to repair
        BEGIN
            fixed := convert_from(
                         convert_to(
                             TRANSLATE(fixed,
                                 '€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ',
                                 chr(128)||chr(130)||chr(131)||chr(132)||chr(133)||chr(134)||chr(135)||chr(136)||chr(137)||
                                 chr(138)||chr(139)||chr(140)||chr(142)||chr(145)||chr(146)||chr(147)||chr(148)||chr(149)||
                                 chr(150)||chr(151)||chr(152)||chr(153)||chr(154)||chr(155)||chr(156)||chr(158)||chr(159)),
                             'LATIN1'),
                         'UTF8');
        EXCEPTION WHEN others THEN
            EXIT;                                                         -- not repairable: stop
        END;
    END LOOP;
    IF fixed ~ '(Ã|Â|â€|Ä|Å)' AND fixed <> val THEN
        fixed := val;                                                     -- half-repaired: return the original unchanged
    END IF;
    RETURN NULLIF(TRIM(REGEXP_REPLACE(fixed, ' {2,}', ' ', 'g')), '');
END;
$$;

-- Turns text into a date using a format; returns NULL instead of an error if it doesn't fit
CREATE OR REPLACE FUNCTION staging.try_date(val text, fmt text)
RETURNS date
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    RETURN to_date(TRIM(val), fmt);
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

-- Rebuilds a title from a The-Numbers link:
-- ".../movie/Walk-to-Remember-A" -> "A Walk to Remember", ".../movie/(T)ERROR-(2015)" -> "(T)ERROR"
CREATE OR REPLACE FUNCTION staging.title_from_url(url text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
    SELECT NULLIF(REGEXP_REPLACE(
               TRIM(REPLACE(
                   REGEXP_REPLACE(SPLIT_PART(url, '/movie/', 2), '(-?\([^)]*\))+$', ''),  -- drop "(Russia)", "(2015)" at the end
                   '-', ' ')),                                                         -- dashes -> spaces
               '^(.*) (The|A|An)$', '\2 \1'),                                          -- "... The" -> "The ..."
           '');
$$;

-- Matching key: one simple version of a title, so both websites can be compared (used in Step 4b).
-- "(500) Days of Summer" and "500 Days of Summer" -> "500 days of summer"
-- "Angry Monk: Reflections on Tibet, The" and "The Angry Monk..." -> "angry monk reflections on tibet"
CREATE OR REPLACE FUNCTION staging.title_key(title text)
RETURNS text
LANGUAGE sql STABLE
AS $$
    SELECT NULLIF(TRIM(REGEXP_REPLACE(
               REGEXP_REPLACE(
                   REGEXP_REPLACE(LOWER(unaccent(title)), ',\s*(the|a|an)$', ''),  -- drop ", The" at the end
                   '[^a-z0-9]+', ' ', 'g'),                                       -- punctuation -> space
               '^(the|a|an) ', '')),                                              -- drop "The " at the start
           '');
$$;

-- =====================================================================
-- 2. Lookup table: studio name variants (rule 10)
--    Metacritic lists the same studio under several names (renames over
--    time, distribution arms, spelling). Rule: merge names of the same main
--    label; keep separate labels (e.g. Fox Searchlight, Screen Gems, IFC
--    Midnight), home-video/TV arms and unrelated companies apart.
-- =====================================================================
CREATE TABLE IF NOT EXISTS staging.studio_rename (
    old_name text PRIMARY KEY,
    new_name text NOT NULL
);

INSERT INTO staging.studio_rename (old_name, new_name) VALUES
    -- Disney (Buena Vista was Disney's distributor name until 2007)
    ('Buena Vista Pictures',                                  'Walt Disney Studios Motion Pictures'),
    ('Buena Vista Pictures Distribution',                     'Walt Disney Studios Motion Pictures'),
    ('Buena Vista International',                             'Walt Disney Studios Motion Pictures'),
    ('Walt Disney Pictures',                                  'Walt Disney Studios Motion Pictures'),
    ('Walt Disney Studios',                                   'Walt Disney Studios Motion Pictures'),
    ('Walt Disney Company, The',                              'Walt Disney Studios Motion Pictures'),
    -- Warner
    ('Warner Bros.',                                          'Warner Bros. Pictures'),
    ('Warner Bros. Entertainment',                            'Warner Bros. Pictures'),
    -- Universal
    ('Universal Studios',                                     'Universal Pictures'),
    ('MCA/Universal Pictures',                                'Universal Pictures'),
    ('Universal Pictures International (UPI)',                'Universal Pictures'),
    ('Universal Pictures International Entertainment (UPIE)', 'Universal Pictures'),
    ('Universal Focus',                                       'Focus Features'),
    -- Fox
    ('Twentieth Century Fox',                                 'Twentieth Century Fox Film Corporation'),
    ('20th Century Fox',                                      'Twentieth Century Fox Film Corporation'),
    ('20th Century Fox Studios',                              'Twentieth Century Fox Film Corporation'),
    ('20th Century Fox Argentina',                            'Twentieth Century Fox Film Corporation'),
    ('Searchlight Pictures',                                  'Fox Searchlight Pictures'),
    -- Paramount (Paramount Classics became Paramount Vantage in 2006)
    ('Paramount Classics',                                    'Paramount Vantage'),
    -- Sony (label not known, so grouped under the parent company)
    ('Sony Pictures',                                         'Sony Pictures Entertainment (SPE)'),
    ('Sony Pictures Entertainment',                           'Sony Pictures Entertainment (SPE)'),
    ('Sony Pictures Releasing',                               'Sony Pictures Entertainment (SPE)'),
    ('Sony Pictures Releasing International',                 'Sony Pictures Entertainment (SPE)'),
    ('Columbia TriStar',                                      'Sony Pictures Entertainment (SPE)'),
    ('Columbia Pictures Corporation',                         'Columbia Pictures'),
    -- Lionsgate
    ('Lions Gate Films',                                      'Lionsgate'),
    -- MGM
    ('Metro-Goldwyn-Mayer',                                   'Metro-Goldwyn-Mayer (MGM)'),
    ('Metro-Goldwyn-Mayer Distributing Corporation (MGM)',    'Metro-Goldwyn-Mayer (MGM)'),
    ('MGM Distribution',                                      'Metro-Goldwyn-Mayer (MGM)'),
    -- Miramax / Weinstein / Dimension
    ('Miramax',                                               'Miramax Films'),
    ('The Weinstein Company',                                 'Weinstein Company, The'),
    ('TWC-Dimension',                                         'Dimension Films'),
    -- Smaller studios
    ('STX Films',                                             'STX Entertainment'),
    ('STXfilms',                                              'STX Entertainment'),
    ('Summit Distribution',                                   'Summit Entertainment'),
    ('Open Road Films (II)',                                  'Open Road Films'),
    ('DreamWorks SKG',                                        'DreamWorks Distribution'),
    -- Independent distributors
    ('Bleecker Street Media',                                 'Bleecker Street'),
    ('Annapurna Distribution',                                'Annapurna Pictures'),
    ('IFC',                                                   'IFC Films'),
    ('IFC Releasing',                                         'IFC Films'),
    ('Magnolia Films',                                        'Magnolia Pictures')
ON CONFLICT (old_name) DO NOTHING;

-- =====================================================================
-- 3. Cleaning views
-- =====================================================================

-- 3.1 The-Numbers: one clean row per film (rules 1, 2, 3, 4)
CREATE OR REPLACE VIEW staging.clean_sales AS
WITH titled AS (
    SELECT *,
           CASE WHEN staging.fix_text(title) IS NULL                 -- title missing (rule 4)
                  OR staging.fix_text(title) ~ '(Ã|Â|â€)'            -- or still broken after repair (rule 1)
                THEN staging.title_from_url(url)                     -- -> rebuild it from the URL
                ELSE staging.fix_text(title)
           END AS clean_title
    FROM staging.stg_sales
)
SELECT
    TRIM(url)                                                         AS numbers_url,
    REGEXP_REPLACE(clean_title, '^(.*), (The|A|An)$', '\2 \1')        AS title,          -- "Angry Monk, The" -> "The Angry Monk"
    staging.to_num(year)::integer                                     AS release_year,
    CASE WHEN TRIM(release_date) ~ '^[A-Z][a-z]+ \d{1,2}(st|nd|rd|th)$'                  -- rule 3
         THEN staging.try_date(REGEXP_REPLACE(TRIM(release_date), '(st|nd|rd|th)$', '')
                               || ' ' || TRIM(year), 'FMMonth DD YYYY')
    END                                                               AS release_date,
    CASE WHEN NOT staging.is_missing(genre)         THEN TRIM(genre)         END AS main_genre,
    CASE WHEN NOT staging.is_missing(creative_type) THEN TRIM(creative_type) END AS creative_type,
    NULLIF(staging.to_num(runtime)::integer, 0)                       AS runtime_min,
    NULLIF(ROUND(staging.to_num(production_budget))::bigint, 0)       AS production_budget,   -- rule 2
    ROUND(staging.to_num(domestic_box_office))::bigint                AS domestic_gross,
    ROUND(staging.to_num(international_box_office))::bigint           AS international_gross,
    ROUND(staging.to_num(worldwide_box_office))::bigint               AS worldwide_gross,
    ROUND(staging.to_num(opening_weekend))::bigint                    AS opening_weekend,
    staging.to_num(theatre_count)::integer                            AS theatre_count,
    staging.to_num(avg_run_per_theatre)                               AS avg_run_weeks
FROM titled
WHERE clean_title IS NOT NULL;                                        -- drops "(Untitled)", which has no data

-- 3.2 Metacritic: one clean row per film (rules 1, 2, 6, 10)
CREATE OR REPLACE VIEW staging.clean_metacritic AS
SELECT
    TRIM(m.url)                                                       AS metacritic_url,
    staging.fix_text(m.title)                                         AS title,
    staging.try_date(m.rel_date, 'DD-MM-YYYY')                        AS release_date,
    EXTRACT(YEAR FROM staging.try_date(m.rel_date, 'DD-MM-YYYY'))::integer AS release_year,
    CASE WHEN NOT staging.is_missing(m.studio)
         THEN COALESCE(r.new_name, staging.fix_text(m.studio)) END    AS studio,          -- rule 10: merged name
    NULLIF(TRIM(REGEXP_REPLACE(m.rating, '^\s*\|\s*', '')), '')       AS age_rating,      -- rule 6
    NULLIF(staging.to_num(m.runtime)::integer, 0)                     AS runtime_min,
    CASE WHEN NOT staging.is_missing(m.genre) THEN m.genre END        AS genre_list,      -- split in clean_movie_genres
    staging.to_num(m.metascore)::integer                              AS metascore,
    staging.to_num(m.userscore)                                       AS userscore
FROM staging.stg_metacritic AS m
LEFT JOIN staging.studio_rename AS r
       ON r.old_name = staging.fix_text(m.studio);

-- 3.3 Metacritic genres: "Action,Sci-Fi,Drama" -> one row per film per genre
CREATE OR REPLACE VIEW staging.clean_movie_genres AS
SELECT DISTINCT
    TRIM(m.url)    AS metacritic_url,
    TRIM(g.genre)  AS genre_name
FROM staging.stg_metacritic AS m
CROSS JOIN LATERAL unnest(string_to_array(m.genre, ',')) AS g(genre)
WHERE NOT staging.is_missing(m.genre)
  AND TRIM(g.genre) <> '';

-- 3.4 Reviews: critics + users in one list (rules 7, 8, 9)
CREATE OR REPLACE VIEW staging.clean_reviews AS
WITH all_reviews AS (
    SELECT 'critic' AS reviewer_type, url, idvscore, reviewer, date_p, rev,
           NULL::text AS thumbs_up, NULL::text AS thumbs_tot, wc, tone, posemo, negemo
    FROM staging.stg_expert_reviews
    UNION ALL
    SELECT 'user', url, idvscore, reviewer, date_p, rev,
           thumbs_up, thumbs_tot, wc, tone, posemo, negemo
    FROM staging.stg_user_reviews
),
numbered AS (                                   -- rule 7: number identical reviews 1, 2, 3 ...
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY reviewer_type, url, reviewer, rev
                              ORDER BY idvscore) AS copy_nr
    FROM all_reviews
    WHERE NOT (staging.to_num(idvscore) IS NULL                          -- rule 8: drop rows with no valid score
               AND staging.is_missing(TRIM(BOTH ' ''"' FROM rev)))       --         and no real text (quotes only = empty)
)
SELECT
    reviewer_type,
    TRIM(url)                                                         AS metacritic_url,
    CASE WHEN NOT staging.is_missing(TRIM(BOTH ' ''"' FROM reviewer))                     -- rule 9
         THEN staging.fix_text(TRIM(BOTH ' ''"' FROM reviewer)) END   AS reviewer_name,
    COALESCE(staging.try_date(TRIM(BOTH ' ''"' FROM date_p), 'Mon DD, YYYY'),
             staging.try_date(TRIM(BOTH ' ''"' FROM date_p), 'FMMonth DD, YYYY'))   AS review_date,
    staging.to_num(idvscore)                                          AS score_raw,
    CASE reviewer_type WHEN 'critic' THEN staging.to_num(idvscore)
                       ELSE staging.to_num(idvscore) * 10 END         AS score_100,       -- users 0-10 -> 0-100
    staging.to_num(thumbs_up)::integer                                AS thumbs_up,
    staging.to_num(thumbs_tot)::integer                               AS thumbs_total,
    staging.to_num(wc)::integer                                       AS word_count,
    staging.to_num(tone)                                              AS tone,
    staging.to_num(posemo)                                            AS positive_emotion,
    staging.to_num(negemo)                                            AS negative_emotion,
    CASE WHEN NOT staging.is_missing(TRIM(BOTH ' ''"' FROM rev))
         THEN staging.fix_text(TRIM(BOTH ' ''"' FROM rev)) END        AS review_text
FROM numbered
WHERE copy_nr = 1;                              -- rule 7: keep only the first copy

-- =====================================================================
-- 4. Checks
-- =====================================================================

-- Check 1: rows before and after cleaning
-- Expected: sales 30,612 -> 30,611 | metacritic 11,364 -> 11,364 |
--           reviews 558,635 -> 554,903 | film-genre pairs 27,051
SELECT 'sales' AS source,
       (SELECT COUNT(*) FROM staging.stg_sales)         AS raw_rows,
       (SELECT COUNT(*) FROM staging.clean_sales)       AS clean_rows
UNION ALL
SELECT 'metacritic',
       (SELECT COUNT(*) FROM staging.stg_metacritic),
       (SELECT COUNT(*) FROM staging.clean_metacritic)
UNION ALL
SELECT 'reviews (critic + user)',
       (SELECT COUNT(*) FROM staging.stg_expert_reviews) + (SELECT COUNT(*) FROM staging.stg_user_reviews),
       (SELECT COUNT(*) FROM staging.clean_reviews)
UNION ALL
SELECT 'movie genres (film-genre pairs)',
       NULL,
       (SELECT COUNT(*) FROM staging.clean_movie_genres);

-- Check 2: did the cleaning rules work?
-- Expected: 0 | 0 | 3,900 | 46 | 0 | 0 | 0 | 1,076
SELECT
    (SELECT COUNT(*) FROM staging.clean_sales WHERE title ~ '(Ã|Â|â€)')                  AS titles_still_broken,
    (SELECT COUNT(*) FROM staging.clean_sales WHERE title IS NULL)                       AS films_without_title,
    (SELECT COUNT(*) FROM staging.clean_sales
      WHERE production_budget IS NOT NULL AND worldwide_gross IS NOT NULL)               AS films_with_budget_and_worldwide,
    (SELECT COUNT(*) FROM staging.clean_sales WHERE release_date IS NULL)                AS films_without_date,
    (SELECT COUNT(*) FROM staging.clean_metacritic WHERE age_rating LIKE '|%')           AS ratings_with_pipe,
    (SELECT COUNT(*) FROM staging.clean_reviews
      WHERE score_raw IS NULL AND review_text IS NULL)                                   AS empty_reviews_left,
    (SELECT COUNT(*) FROM staging.clean_reviews WHERE reviewer_name = 'None')            AS reviewer_none_left,
    (SELECT COUNT(DISTINCT studio) FROM staging.clean_metacritic)                        AS studios_after_merge;