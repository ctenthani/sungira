-- Synthetic public-account fixture; never sends emails or retains records.
BEGIN;
DO $$
DECLARE uid uuid:=gen_random_uuid(); cid uuid; email_address text:=uid||'@example.invalid'; r jsonb; d jsonb; pub jsonb;
BEGIN
 INSERT INTO auth.users(id,email,email_confirmed_at) VALUES(uid,email_address,now());
 r=public.sungira_action(uid,email_address,'create',jsonb_build_object('name','TEST public account rollback','start','2026-01-01','due','2026-12-31','incomeNature','Individual','paymentFrequency','Once-off','isPublic',true));cid=(r->>'id')::uuid;
 UPDATE public.sungira_collections SET data=jsonb_set(data,'{ledger}','[{"id":"test-income","kind":"Contribution","status":"Confirmed","date":"2026-10-21","amount":100,"note":"PRIVATE-NOTE","ref":"SECRET-REF"},{"id":"test-expense","kind":"Expense","category":"Travel","status":"Confirmed","date":"2026-10-21","amount":30,"payee":"PRIVATE-PAYEE"},{"id":"test-pending","kind":"Contribution","status":"Pending","date":"2026-10-21","amount":500},{"id":"test-void","kind":"Expense","status":"Voided","date":"2026-10-21","amount":999}]'::jsonb) WHERE id=cid;
 SELECT data INTO d FROM public.sungira_collections WHERE id=cid;
 pub=public.sungira_action(null,null,'public',jsonb_build_object('id',cid,'token',d->>'publicToken'));
 IF jsonb_array_length(pub->'accountEntries')<>2 OR (pub->'accountEntries')::text LIKE '%PRIVATE%' OR (pub->'accountEntries')::text LIKE '%SECRET%' THEN RAISE EXCEPTION 'Public projection included private or unconfirmed data';END IF;
 BEGIN
  PERFORM public.sungira_action(null,null,'public',jsonb_build_object('id',cid,'token','wrong'));
  RAISE EXCEPTION 'Invalid token accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM='Invalid token accepted' THEN RAISE;END IF;END;
END $$;
SELECT 'Public income/expense projection, privacy and link checks passed' AS verification;
ROLLBACK;
