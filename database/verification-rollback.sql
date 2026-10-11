-- Synthetic fixtures only; every change is rolled back.
BEGIN;
DO $$
DECLARE owner_id uuid:=gen_random_uuid(); other_id uuid:=gen_random_uuid(); officer_id uuid:=gen_random_uuid(); viewer_id uuid:=gen_random_uuid();
 owner_email text:=owner_id||'@example.invalid'; other_email text:=other_id||'@example.invalid'; officer_email text:=officer_id||'@example.invalid'; viewer_email text:=viewer_id||'@example.invalid';
 c uuid; g uuid; member text:=gen_random_uuid()::text; eid text:=gen_random_uuid()::text; second_id text:=gen_random_uuid()::text; tx text:='SG-'||gen_random_uuid(); r jsonb; d jsonb; p jsonb;
BEGIN
 INSERT INTO auth.users(id,email,email_confirmed_at) VALUES(owner_id,owner_email,now()),(other_id,other_email,now()),(officer_id,officer_email,now()),(viewer_id,viewer_email,now());
 r=public.sungira_action(owner_id,owner_email,'create',jsonb_build_object('name','TEST rollback individual','start','2026-01-01','due','2026-12-31','incomeNature','Individual'));
 c=(r->>'id')::uuid;
 PERFORM public.sungira_action(owner_id,owner_email,'person',jsonb_build_object('id',c,'member',member,'name','TEST private contributor','pledge',1000,'anonymous',true));
 INSERT INTO public.sungira_access VALUES(c,officer_email,'Treasurer'),(c,viewer_email,'Viewer');
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.sungira_action(officer_id,officer_email,'list','{}')) x WHERE x->>'id'=c::text AND x->>'role'='Treasurer') THEN RAISE EXCEPTION 'Treasurer list failed';END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(public.sungira_action(other_id,other_email,'list','{}')) x WHERE x->>'id'=c::text) THEN RAISE EXCEPTION 'Foreign group leaked';END IF;
 BEGIN PERFORM public.sungira_action(viewer_id,viewer_email,'activity_settings',jsonb_build_object('id',c,'name','Bad','incomeNature','Individual'));RAISE EXCEPTION 'Viewer edited group';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.sungira_action(officer_id,officer_email,'grant',jsonb_build_object('id',c,'email',other_email,'role','Treasurer'));RAISE EXCEPTION 'Treasurer granted access';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.sungira_action(other_id,owner_email,'list','{}');RAISE EXCEPTION 'Forged email accepted';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 p=jsonb_build_object('id',c,'kind','Contribution','member',member,'amount',1000,'date','2026-10-11','method','Bank transfer','ref','TEST-bank-1','note','','requestId',eid,'attachment','data:image/png;base64,AAAA');
 PERFORM public.sungira_action(officer_id,officer_email,'entry',p);
 r=public.sungira_action(officer_id,officer_email,'entry',p);
 IF NOT coalesce((r->>'duplicate')::boolean,false) THEN RAISE EXCEPTION 'Retry was not idempotent';END IF;
 BEGIN PERFORM public.sungira_action(officer_id,officer_email,'entry',p||jsonb_build_object('amount',999));RAISE EXCEPTION 'Changed retry accepted';EXCEPTION WHEN OTHERS THEN IF SQLERRM='Changed retry accepted' THEN RAISE;END IF;END;
 SELECT data INTO d FROM public.sungira_collections WHERE id=c;
 IF jsonb_array_length(d->'ledger')<>1 OR d->'ledger'->0->>'status'<>'Confirmed' THEN RAISE EXCEPTION 'Payment acknowledgement duplicated or missing';END IF;
 r=public.sungira_action(viewer_id,viewer_email,'list','{}');
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(r) x CROSS JOIN LATERAL jsonb_array_elements(x->'data'->'ledger') e WHERE e?'attachment') THEN RAISE EXCEPTION 'Proof leaked in list';END IF;
 -- Public projection must retain explicit anonymity and hide raw attachments.
 UPDATE public.sungira_collections SET data=data||jsonb_build_object('isPublic',true,'publicToken','TEST-private-token') WHERE id=c;
 r=public.sungira_action(NULL,NULL,'public',jsonb_build_object('id',c,'token','TEST-private-token'));
 IF r::text LIKE '%TEST private contributor%' OR r::text LIKE '%data:image%' OR r?'ledger' THEN RAISE EXCEPTION 'Public projection exposed private data';END IF;
 -- Reserve and settle provider payment twice; gross and fee appear once.
 PERFORM public.sungira_reserve_payment(owner_id,owner_email,c,member,100,tx);
 BEGIN PERFORM public.sungira_settle_payment(tx,101,'MWK','live',2);RAISE EXCEPTION 'Wrong settlement amount accepted';EXCEPTION WHEN OTHERS THEN IF SQLERRM='Wrong settlement amount accepted' THEN RAISE;END IF;END;
 PERFORM public.sungira_settle_payment(tx,100,'MWK','live',2);
 r=public.sungira_settle_payment(tx,100,'MWK','live',2);
 IF NOT (r->>'alreadyConfirmed')::boolean THEN RAISE EXCEPTION 'Settlement retry failed';END IF;
 SELECT data INTO d FROM public.sungira_collections WHERE id=c;
 IF (SELECT count(*) FROM jsonb_array_elements(d->'ledger') e WHERE e->>'ref'=tx)<>1 OR (SELECT count(*) FROM jsonb_array_elements(d->'ledger') e WHERE e->>'ref'=tx||'-fee')<>1 THEN RAISE EXCEPTION 'Provider receipt/fee duplicated';END IF;
 -- Group receipts reject the same bank reference under a fresh request ID.
 r=public.sungira_action(owner_id,owner_email,'create',jsonb_build_object('name','TEST rollback group','start','2026-01-01','due','2026-12-31','incomeNature','Group'));g=(r->>'id')::uuid;
 p=jsonb_build_object('id',g,'amount',250,'date','2026-10-11','category','Donation','payee','TEST source','method','Bank transfer','ref','TEST-group-1','requestId',second_id);
 PERFORM public.sungira_action(owner_id,owner_email,'group_income',p);
 PERFORM public.sungira_action(owner_id,owner_email,'group_income',p);
 BEGIN PERFORM public.sungira_action(owner_id,owner_email,'group_income',p||jsonb_build_object('requestId',gen_random_uuid()));RAISE EXCEPTION 'Duplicate group bank reference accepted';EXCEPTION WHEN OTHERS THEN IF SQLERRM='Duplicate group bank reference accepted' THEN RAISE;END IF;END;
END $$;
SELECT 'PASS: account isolation, owner/treasurer/viewer controls, identity binding, payment retry, private projection, provider mismatch and settlement retry, duplicate group references. All fixtures rolled back.' AS result;
ROLLBACK;
