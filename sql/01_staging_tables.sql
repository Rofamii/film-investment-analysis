/* =====================================================================
   01_staging_tables.sql
   Film Investment Analysis: Step 1, raw "landing" tables (staging layer)

   Purpose
   - Import the 4 source files exactly as they are, before any cleaning.
   - Every column is TEXT on purpose: the raw data contains values such as
     "n/a", "None", "1058457,00" (decimal comma) or "2002 (Wide) by" that
     would make a typed import fail. Types are fixed later, in SQL (Step 4).
   - The tables live in their own schema, "staging", so raw data stays
     separate from the clean tables in "public" (ELT: Extract, Load, Transform).

   Sources (scraped in a group university project; data not included in this repo)
   - sales            The-Numbers.com   box office and budget, one row per film
   - metacritic       Metacritic.com    film details and average scores, one row per film
   - expert_reviews   Metacritic.com    one row per critic review + LIWC text-analysis columns
   - user_reviews     Metacritic.com    one row per user review + LIWC text-analysis columns

   How to import (pgAdmin 4)
   - Right-click a table > Import/Export Data > Import
   - Format: csv | Header: on | Delimiter: ; | Encoding: UTF8
   - The CSV files were saved from Excel with Dutch settings (";" separator,
     decimal commas). Before import, the Metacritic file was re-saved as UTF-8
     (it contained cut-in-half characters) and rows split by line breaks in the
     summaries were glued back together.

   Safe to run more than once: CREATE ... IF NOT EXISTS.
   ===================================================================== */

CREATE SCHEMA IF NOT EXISTS staging;

-- The-Numbers: box office and budget (16 columns)
CREATE TABLE IF NOT EXISTS staging.stg_sales (
    year                      text,
    release_date              text,
    title                     text,
    genre                     text,
    international_box_office  text,
    domestic_box_office       text,
    worldwide_box_office      text,
    production_budget         text,
    empty_col                 text,   -- empty column in the source file
    opening_weekend           text,
    theatre_count             text,
    avg_run_per_theatre       text,
    runtime                   text,
    keywords                  text,
    creative_type             text,
    url                       text
);

-- Metacritic: film details and average scores (13 columns)
CREATE TABLE IF NOT EXISTS staging.stg_metacritic (
    url        text,
    title      text,
    studio     text,
    rating     text,
    runtime    text,
    "cast"     text,   -- CAST is an SQL keyword, so the name needs quotes
    director   text,
    genre      text,
    summary    text,
    awards     text,
    metascore  text,
    userscore  text,
    rel_date   text
);

-- Metacritic: critic reviews (5 review columns + 93 LIWC columns = 98)
-- LIWC = text-analysis scores per review; only wc, tone, posemo and negemo are used later.
CREATE TABLE IF NOT EXISTS staging.stg_expert_reviews (
    url text, idvscore text, reviewer text, date_p text, rev text,
    -- LIWC text-analysis columns
    wc text, analytic text, clout text, authentic text, tone text, wps text, sixltr text, dic text,
    function text, pronoun text, ppron text, i text, we text, you text, shehe text, they text,
    ipron text, article text, prep text, auxverb text, adverb text, conj text, negate text,
    verb text, adj text, compare text, interrog text, number text, quant text, affect text,
    posemo text, negemo text, anx text, anger text, sad text, social text, family text,
    friend text, female text, male text, cogproc text, insight text, cause text, discrep text,
    tentat text, certain text, differ text, percept text, see text, hear text, feel text,
    bio text, body text, health text, sexual text, ingest text, drives text, affiliation text,
    achieve text, power text, reward text, risk text, focuspast text, focuspresent text,
    focusfuture text, relativ text, motion text, space text, time text, work text, leisure text,
    home text, money text, relig text, death text, informal text, swear text, netspeak text,
    assent text, nonflu text, filler text, allpunc text, period text, comma text, colon text,
    semic text, qmark text, exclam text, dash text, quote text, apostro text, parenth text, otherp text
);

-- Metacritic: user reviews (7 review columns incl. thumbs up/total + 93 LIWC columns = 100)
CREATE TABLE IF NOT EXISTS staging.stg_user_reviews (
    url text, idvscore text, reviewer text, date_p text, rev text, thumbs_up text, thumbs_tot text,
    -- LIWC text-analysis columns
    wc text, analytic text, clout text, authentic text, tone text, wps text, sixltr text, dic text,
    function text, pronoun text, ppron text, i text, we text, you text, shehe text, they text,
    ipron text, article text, prep text, auxverb text, adverb text, conj text, negate text,
    verb text, adj text, compare text, interrog text, number text, quant text, affect text,
    posemo text, negemo text, anx text, anger text, sad text, social text, family text,
    friend text, female text, male text, cogproc text, insight text, cause text, discrep text,
    tentat text, certain text, differ text, percept text, see text, hear text, feel text,
    bio text, body text, health text, sexual text, ingest text, drives text, affiliation text,
    achieve text, power text, reward text, risk text, focuspast text, focuspresent text,
    focusfuture text, relativ text, motion text, space text, time text, work text, leisure text,
    home text, money text, relig text, death text, informal text, swear text, netspeak text,
    assent text, nonflu text, filler text, allpunc text, period text, comma text, colon text,
    semic text, qmark text, exclam text, dash text, quote text, apostro text, parenth text, otherp text
);

/* ---------------------------------------------------------------------
   Check after importing: every row arrived
   Expected: stg_sales 30,612 | stg_metacritic 11,364 |
             stg_expert_reviews 238,973 | stg_user_reviews 319,662
   --------------------------------------------------------------------- */
SELECT 'stg_sales'          AS table_name, COUNT(*) AS row_count FROM staging.stg_sales
UNION ALL
SELECT 'stg_metacritic',                   COUNT(*)              FROM staging.stg_metacritic
UNION ALL
SELECT 'stg_expert_reviews',               COUNT(*)              FROM staging.stg_expert_reviews
UNION ALL
SELECT 'stg_user_reviews',                 COUNT(*)              FROM staging.stg_user_reviews;
