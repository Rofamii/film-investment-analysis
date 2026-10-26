/* =====================================================================
   03_final_tables.sql
   Film Investment Analysis: Step 3, final tables from the ERD (clean layer)

   Purpose
   - Create the 6 tables of the data model in schema "public". They will
     hold the CLEAN data (loaded in Step 4).
   - Unlike staging, every column has its real type (integer, bigint, date,
     numeric), and the database itself protects data quality:
       PRIMARY KEY / FOREIGN KEY       every row is unique, every link is real
       GENERATED ALWAYS AS IDENTITY    IDs are numbered automatically (1, 2, 3 ...)
       NOT NULL / UNIQUE               required values can't be empty or duplicated
       CHECK                           impossible values (e.g. a score of 150) are refused
   - Tables are created in order: a table must exist before another can point to it.
   - Money columns are BIGINT: the biggest films exceed the INTEGER limit (~2.1 billion).

   Safe to run more than once: CREATE ... IF NOT EXISTS.
   ===================================================================== */

-- 1. Lookup tables (nothing points out of them)
CREATE TABLE IF NOT EXISTS studio (
    studio_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    studio_name  text NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS genre (
    genre_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    genre_name  text NOT NULL UNIQUE
);

-- 2. Core table: one row per film, matched across The-Numbers and Metacritic
CREATE TABLE IF NOT EXISTS movie (
    movie_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title           text    NOT NULL,
    release_date    date,
    release_year    integer NOT NULL,
    runtime_min     integer CHECK (runtime_min > 0),
    age_rating      text,                    -- US age rating (G, PG, PG-13, R ...) from Metacritic
    main_genre      text,                    -- single genre from The-Numbers
    creative_type   text,
    studio_id       integer REFERENCES studio (studio_id),
    metascore       integer CHECK (metascore BETWEEN 0 AND 100),
    userscore       numeric CHECK (userscore BETWEEN 0 AND 10),
    numbers_url     text UNIQUE,
    metacritic_url  text UNIQUE,
    CHECK (numbers_url IS NOT NULL OR metacritic_url IS NOT NULL)   -- every film comes from at least one website
);

-- 3. Tables that point to movie
CREATE TABLE IF NOT EXISTS box_office (
    movie_id             integer PRIMARY KEY REFERENCES movie (movie_id),   -- 1 row per film
    production_budget    bigint CHECK (production_budget > 0),
    domestic_gross       bigint CHECK (domestic_gross >= 0),
    international_gross  bigint CHECK (international_gross >= 0),
    worldwide_gross      bigint CHECK (worldwide_gross >= 0),
    opening_weekend      bigint CHECK (opening_weekend >= 0),
    theatre_count        integer CHECK (theatre_count >= 0),
    avg_run_weeks        numeric CHECK (avg_run_weeks >= 0)
);

CREATE TABLE IF NOT EXISTS movie_genre (
    movie_id  integer NOT NULL REFERENCES movie (movie_id),
    genre_id  integer NOT NULL REFERENCES genre (genre_id),
    PRIMARY KEY (movie_id, genre_id)          -- composite key: a film can't get the same genre twice
);

CREATE TABLE IF NOT EXISTS review (
    review_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    movie_id          integer NOT NULL REFERENCES movie (movie_id),
    reviewer_type     text    NOT NULL CHECK (reviewer_type IN ('critic', 'user')),
    reviewer_name     text,
    review_date       date,
    score_raw         numeric,                -- critic 0-100, user 0-10 (as on the website)
    score_100         numeric CHECK (score_100 BETWEEN 0 AND 100),   -- both on one 0-100 scale
    thumbs_up         integer,                -- users only
    thumbs_total      integer,                -- users only
    word_count        integer,                -- LIWC text-analysis columns: 4 of 93 kept
    tone              numeric,
    positive_emotion  numeric,
    negative_emotion  numeric,
    review_text       text
);

-- 4. Index: PostgreSQL does not index foreign keys automatically;
--    reviews are joined to films by movie_id all the time, so this keeps those joins fast
CREATE INDEX IF NOT EXISTS idx_review_movie_id ON review (movie_id);

-- 5. Table descriptions (stored inside the database as documentation)
COMMENT ON TABLE movie       IS 'One row per film, matched across The-Numbers and Metacritic';
COMMENT ON TABLE box_office  IS 'The-Numbers financials, 1 row per film';
COMMENT ON TABLE review      IS 'Critics + users, one row per review';
COMMENT ON TABLE studio      IS 'Distributor / studio';
COMMENT ON TABLE genre       IS 'Metacritic genres';
COMMENT ON TABLE movie_genre IS 'Bridge: film to genre (many-to-many)';

/* ---------------------------------------------------------------------
   Check: number of columns per table
   Expected: box_office 8 | genre 2 | movie 13 | movie_genre 2 | review 14 | studio 2
   --------------------------------------------------------------------- */
SELECT table_name, COUNT(*) AS columns
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('movie', 'box_office', 'review', 'studio', 'genre', 'movie_genre')
GROUP BY table_name
ORDER BY table_name;