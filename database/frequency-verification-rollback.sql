BEGIN;
DO $$
DECLARE uid uuid:=gen_random_uuid(); email_address text:=uid||'@example.invalid'; cid uuid; r jsonb; d jsonb; before_ledger jsonb;
BEGIN
 INSERT INTO auth.users(id,email,email_confirmed_at) VALUES(uid,email_address,now());
 r=public.sungira_action(uid,email_address,'create',jsonb_build_object('name','TEST cadence rollback','start','2026-01-01','due','2026-12-31','incomeNature','Individual','paymentFrequency','Once-off','monthlyAmount',500));cid=(r->>'id')::uuid;
 SELECT data INTO d FROM public.sungira_collections WHERE id=cid;
 IF d->>'paymentFrequency'<>'Once-off' OR (d->>'monthlyAmount')::numeric<>0 THEN RAISE EXCEPTION 'Once-off must not accrue monthly dues';END IF;
 BEGIN
  PERFORM public.sungira_action(uid,email_address,'activity_settings',jsonb_build_object('id',cid,'name','TEST cadence rollback','incomeNature','Individual','paymentFrequency','Monthly','monthlyAmount',0));
  RAISE EXCEPTION 'Missing monthly amount accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM='Missing monthly amount accepted' THEN RAISE;END IF;END;
 PERFORM public.sungira_action(uid,email_address,'activity_settings',jsonb_build_object('id',cid,'name','TEST cadence rollback','incomeNature','Individual','paymentFrequency','Monthly','monthlyAmount',500));
 SELECT data INTO d FROM public.sungira_collections WHERE id=cid;
 IF d->>'paymentFrequency'<>'Monthly' OR (d->>'monthlyAmount')::numeric<>500 THEN RAISE EXCEPTION 'Monthly configuration failed';END IF;
 -- Synthetic issued receipt proves cadence edits leave payment history unchanged.
 UPDATE public.sungira_collections SET data=jsonb_set(data,'{ledger}','[{"id":"synthetic","kind":"Contribution","status":"Confirmed","amount":500,"receipt":{"monthlyAmount":500,"monthsCovered":1,"number":"TEST-HISTORICAL"}}]'::jsonb) WHERE id=cid;
 SELECT data->'ledger' INTO before_ledger FROM public.sungira_collections WHERE id=cid;
 PERFORM public.sungira_action(uid,email_address,'activity_settings',jsonb_build_object('id',cid,'name','TEST cadence rollback','incomeNature','Individual','paymentFrequency','As agreed'));
 SELECT data INTO d FROM public.sungira_collections WHERE id=cid;
 IF d->>'paymentFrequency'<>'As agreed' OR (d->>'monthlyAmount')::numeric<>0 OR d->'ledger' IS DISTINCT FROM before_ledger THEN RAISE EXCEPTION 'Frequency edit changed ledger or retained dues';END IF;
END $$;
SELECT 'Frequency tests passed; all fixtures rolled back' AS result;
ROLLBACK;
