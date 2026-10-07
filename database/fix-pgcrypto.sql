-- Sungira: fix "function gen_random_bytes(integer) does not exist".
-- Run once in the Supabase SQL Editor as the project administrator.
-- Safe to rerun. Does not modify collections, contributions or existing links.
BEGIN;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
DO $fix$
DECLARE crypto_schema text; fn record; token text; patched integer := 0;
BEGIN
 SELECT n.nspname INTO crypto_schema
 FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace
 WHERE e.extname='pgcrypto';
 IF crypto_schema IS NULL THEN
  RAISE EXCEPTION 'pgcrypto is unavailable. Enable the pgcrypto extension in Supabase and run this script again.';
 END IF;
 -- Verify the schema-qualified crypto function before changing any function.
 EXECUTE format('SELECT encode(%I.gen_random_bytes(24), ''hex'')',crypto_schema) INTO token;
 IF length(token)<>48 THEN RAISE EXCEPTION 'Token generation check failed.'; END IF;
 -- All versioned RPC layers need the path: the top-level RPC delegates to them.
 FOR fn IN
  SELECT p.oid::regprocedure AS signature
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname ~ '^sungira_(v[0-9]+_)?action$'
 LOOP
  EXECUTE format('ALTER FUNCTION %s SET search_path = public, %I, pg_temp',fn.signature,crypto_schema);
  patched := patched+1;
 END LOOP;
 IF patched=0 THEN RAISE EXCEPTION 'Sungira database functions were not found. Run the database setup first.'; END IF;
 RAISE NOTICE 'Token generation verified. Updated % Sungira RPC function search paths.',patched;
END $fix$;
COMMIT;
