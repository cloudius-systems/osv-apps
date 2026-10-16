-- Copyright (C) 2026 Greg Burd. BSD-3-Clause.
-- Collation demo for OSv: sort the same text under the libc provider (a real
-- locale, en_US.UTF-8) and under the ICU provider, showing the two orders.
-- Run by pg_runsql against the `demo` database (default locale en_US.UTF-8
-- libc) with `postgres --single -j` (one query per blank-line-separated chunk).

-- A libc collation object for en_US.UTF-8 (initdb imports ICU collations but
-- not per-locale libc ones unless the host enumerated them; create it so the
-- spec query can name it). The ICU collations (en-US-x-icu, sv-SE-x-icu) are
-- imported by initdb from the --with-icu build.
CREATE COLLATION IF NOT EXISTS "en_US.UTF-8" (provider = libc, locale = 'en_US.UTF-8');

-- 1. libc provider, en_US.UTF-8 (the exact spec query).
SELECT x FROM (VALUES ('a'),('A'),('ä'),('z'),('Z')) v(x) ORDER BY x COLLATE "en_US.UTF-8";

-- 2. ICU provider, en-US: the same values under the ICU collation.
SELECT x FROM (VALUES ('a'),('A'),('ä'),('z'),('Z')) v(x) ORDER BY x COLLATE "en-US-x-icu";

-- 3. The baked words table (ASCII + Swedish letters) under libc en_US.UTF-8.
SELECT w FROM words ORDER BY w COLLATE "en_US.UTF-8";

-- 4. The same words under ICU sv-SE (Swedish sorts z before the accented
--    vowels, which come at the end of the alphabet).
SELECT w FROM words ORDER BY w COLLATE "sv-SE-x-icu";

-- 5. Prove the two demo databases exist and carry the right provider/collation
--    (the datcollate round-trip that #1477 fixed, opened on OSv at runtime).
SELECT datname, datlocprovider, datcollate FROM pg_database WHERE datname LIKE 'demo%' ORDER BY datname;
