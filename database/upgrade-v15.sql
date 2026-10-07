-- Run after upgrade-v14.sql. Group-level income and context-sensitive church actions.
BEGIN;
DO $$ BEGIN
 IF to_regprocedure('public.sungira_v14_action(uuid,text,text,jsonb)') IS NULL THEN
  ALTER FUNCTION public.sungira_action(uuid,text,text,jsonb) RENAME TO sungira_v14_action;
 END IF;
END $$;
-- Extend the existing financial cash calculations, including expense/void guards.
DO $$ DECLARE definition text;fn regprocedure;BEGIN
 FOR fn IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN ('sungira_financial_summary','sungira_v3_action') LOOP
  definition=pg_get_functiondef(fn);
  definition=replace(definition,'''Contribution'',''Loan repayment'',''Investment proceeds''','''Contribution'',''Group income'',''Loan repayment'',''Investment proceeds''');
  definition=replace(definition,'ledger_entry->>''kind''=''Contribution''','ledger_entry->>''kind'' in (''Contribution'',''Group income'')');
  definition=replace(definition,'rec->>''kind''=''Contribution''','rec->>''kind'' in (''Contribution'',''Group income'')');
  EXECUTE definition;
 END LOOP;
END $$;
CREATE OR REPLACE FUNCTION public.sungira_action(actor_id uuid,actor_email text,action_name text,payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE c public.sungira_collections%rowtype;role_name text;amount numeric;eid text;entry jsonb;
BEGIN
 IF action_name IN ('group_income','church_import') THEN
  SELECT * INTO c FROM public.sungira_collections WHERE id=(payload->>'id')::uuid FOR UPDATE;
  IF actor_id IS NULL OR actor_email IS NULL OR c.id IS NULL THEN RAISE EXCEPTION USING errcode='42501',message='Officer sign-in and an existing activity are required.';END IF;
  IF c.owner_id=actor_id THEN role_name='Owner';ELSE SELECT role INTO role_name FROM public.sungira_access WHERE collection_id=c.id AND email=lower(actor_email);END IF;
  IF role_name IS NULL OR role_name NOT IN ('Owner','Treasurer') THEN RAISE EXCEPTION USING errcode='42501',message='Only responsible officers can record income.';END IF;
  IF action_name='church_import' THEN
   IF c.data->>'type'<>'Church' OR coalesce(c.data->>'groupName',c.data->>'name','') !~* 'charles.*(lwanga|luanga|lwangwa)' THEN RAISE EXCEPTION 'The prepared church list belongs to Charles Lwanga church activities only.';END IF;
   RETURN public.sungira_v14_action(actor_id,actor_email,action_name,payload);
  END IF;
  IF c.data->>'status'<>'Open' THEN RAISE EXCEPTION 'Reopen the activity before recording income.';END IF;
  eid=payload->>'requestId';amount=(payload->>'amount')::numeric;
  IF eid IS NULL OR eid !~ '^[0-9a-f-]{36}$' THEN RAISE EXCEPTION 'A valid request identifier is required.';END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(c.data->'ledger') e WHERE e->>'id'=eid) THEN RETURN jsonb_build_object('ok',true,'id',eid);END IF;
  IF amount IS NULL OR amount<=0 OR amount>100000000000 OR amount<>round(amount,2) OR length(trim(coalesce(payload->>'category','')))=0 OR length(payload->>'category')>120 OR length(trim(coalesce(payload->>'payee','')))=0 OR length(payload->>'payee')>120 THEN RAISE EXCEPTION 'Check income type, source and amount.';END IF;
  IF payload->>'date' IS NULL OR (payload->>'date')::date<(c.data->>'start')::date OR (payload->>'date')::date>(now() AT TIME ZONE 'Africa/Blantyre')::date THEN RAISE EXCEPTION 'Income date must be between the activity start and today.';END IF;
  IF payload->>'method' IS NULL OR payload->>'method' NOT IN ('Cash','Airtel Money','TNM Mpamba','Bank transfer','Other') OR (payload->>'method'<>'Cash' AND length(trim(coalesce(payload->>'ref','')))<3) OR length(coalesce(payload->>'note',''))>500 OR length(coalesce(payload->>'ref',''))>120 THEN RAISE EXCEPTION 'Choose a payment method and provide a reference for non-cash income.';END IF;
  entry=jsonb_build_object('id',eid,'kind','Group income','category',trim(payload->>'category'),'payee',trim(payload->>'payee'),'amount',amount,'date',payload->>'date','method',payload->>'method','ref',coalesce(payload->>'ref',''),'note',coalesce(payload->>'note',''),'status','Confirmed','verification','Treasurer acknowledged','reportedBy',actor_email,'reviewedBy',actor_email,'reviewedAt',now());
  UPDATE public.sungira_collections SET data=data||jsonb_build_object('ledger',(data->'ledger')||jsonb_build_array(entry),'updated',now(),'audit',jsonb_build_array(jsonb_build_object('at',now(),'actor',actor_email,'text','Group income recorded: '||(payload->>'category')))||(data->'audit')) WHERE id=c.id;
  RETURN jsonb_build_object('ok',true,'id',eid);
 END IF;
 RETURN public.sungira_v14_action(actor_id,actor_email,action_name,payload);
END $$;
REVOKE ALL ON FUNCTION public.sungira_v14_action(uuid,text,text,jsonb) FROM public,anon,authenticated;
REVOKE ALL ON FUNCTION public.sungira_action(uuid,text,text,jsonb) FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.sungira_action(uuid,text,text,jsonb) TO service_role;
COMMIT;
