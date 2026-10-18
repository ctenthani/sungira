-- v18: explicit village-bank accounts. Existing activities are not converted automatically.
BEGIN;
DO $$ BEGIN
 IF to_regprocedure('public.sungira_v17_action(uuid,text,text,jsonb)') IS NULL THEN ALTER FUNCTION public.sungira_action(uuid,text,text,jsonb) RENAME TO sungira_v17_action; END IF;
END $$;
-- Preserve the summary function's identity so existing callers see withdrawals immediately.
DO $patch$ DECLARE definition text;BEGIN
 definition=pg_get_functiondef('public.sungira_financial_summary(jsonb)'::regprocedure);
 IF position('Savings withdrawal' IN definition)=0 THEN
  definition=replace(definition,$from$'Expense','Mkhonde payout','Investment placement','Loan disbursement'$from$,$to$'Expense','Mkhonde payout','Investment placement','Loan disbursement','Savings withdrawal'$to$);
  IF position('Savings withdrawal' IN definition)=0 THEN RAISE EXCEPTION 'Accounting function does not match the expected installed version.';END IF;
  EXECUTE definition;
 END IF;
END $patch$;
CREATE OR REPLACE FUNCTION public.sungira_bank_member(d jsonb,member_id text) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path=public,extensions,pg_temp AS $$
DECLARE savings numeric;principal numeric;multiple numeric;
BEGIN
 SELECT coalesce(sum(CASE WHEN e->>'kind'='Contribution' THEN (e->>'amount')::numeric WHEN e->>'kind'='Savings withdrawal' THEN -(e->>'amount')::numeric ELSE 0 END),0),
 coalesce(sum(CASE WHEN e->>'kind'='Loan disbursement' THEN (e->>'amount')::numeric ELSE -coalesce((e->>'principalPaid')::numeric,0)-coalesce((e->>'principalWrittenOff')::numeric,0) END),0)
 INTO savings,principal FROM jsonb_array_elements(coalesce(d->'ledger','[]')) e WHERE e->>'status'='Confirmed' AND e->>'member'=member_id;
 multiple=coalesce((d->'bank'->>'multiple')::numeric,1);
 RETURN jsonb_build_object('savings',savings,'principal',principal,'capacity',greatest(0,trunc(savings*multiple,2)-principal),'withdrawable',greatest(0,savings-ceil(principal/multiple*100)/100));
END $$;
CREATE OR REPLACE FUNCTION public.sungira_action(actor_id uuid,actor_email text,action_name text,payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE c public.sungira_collections%rowtype;d jsonb;role_name text;rec jsonb;item jsonb;member_info jsonb;summary jsonb;result jsonb;r jsonb;note text;fingerprint text;amount numeric;multiple numeric;rate numeric;is_finance boolean;
BEGIN
 IF action_name='public' THEN RETURN public.sungira_v17_action(actor_id,actor_email,action_name,payload);END IF;
 IF NOT EXISTS(SELECT 1 FROM auth.users u WHERE u.id=actor_id AND lower(u.email)=lower(actor_email) AND u.email_confirmed_at IS NOT NULL) THEN RAISE EXCEPTION USING errcode='42501',message='A verified matching officer account is required.';END IF;
 is_finance=action_name IN ('loan','repayment','loan_adjustment','investment','investment_return','bank_withdraw');
 IF NOT is_finance AND action_name NOT IN ('bank_setup','finance_receipt','finance_reverse') THEN RETURN public.sungira_v17_action(actor_id,actor_email,action_name,payload);END IF;
 SELECT * INTO c FROM public.sungira_collections WHERE id=(payload->>'id')::uuid FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION 'Activity not found.';END IF;
 IF c.owner_id=actor_id THEN role_name='Owner';ELSE SELECT a.role INTO role_name FROM public.sungira_access a WHERE a.collection_id=c.id AND a.email=lower(actor_email);END IF;
 IF role_name IS NULL OR role_name NOT IN ('Owner','Treasurer') THEN RAISE EXCEPTION USING errcode='42501',message='Only responsible officers may change financial records.';END IF;
 d=c.data;
 IF action_name='finance_receipt' THEN
  SELECT e INTO rec FROM jsonb_array_elements(d->'ledger') e WHERE e->>'id'=payload->>'entry';
  IF rec IS NULL OR rec->>'status'<>'Confirmed' OR rec->>'kind' NOT IN ('Loan repayment','Savings withdrawal') THEN RAISE EXCEPTION 'Only a confirmed repayment or savings withdrawal can have this receipt.';END IF;
  IF rec?'receipt' THEN RETURN rec->'receipt';END IF;
  SELECT m INTO item FROM jsonb_array_elements(d->'members') m WHERE m->>'id'=rec->>'member';
  r=jsonb_build_object('number','SG-'||replace(rec->>'id','-',''),'groupName',coalesce(nullif(d->>'groupName',''),d->>'name'),'activity',coalesce(d->>'activity',d->>'name'),'contributor',item->>'name','amount',rec->'amount','date',rec->>'date','method',rec->>'method','reference',rec->>'ref','acknowledgedBy',coalesce(rec->>'reviewedBy',actor_email),'acknowledgedAt',coalesce(rec->>'recordedAt',now()::text),'issuedAt',now(),'kind',rec->>'kind','principalPaid',rec->'principalPaid','interestPaid',rec->'interestPaid');
  d=jsonb_set(d,'{ledger}',(SELECT jsonb_agg(CASE WHEN e->>'id'=rec->>'id' THEN e||jsonb_build_object('receipt',r) ELSE e END) FROM jsonb_array_elements(d->'ledger') e));note='Finance receipt issued: '||(r->>'number');
 ELSIF action_name='bank_setup' THEN
  IF role_name<>'Owner' THEN RAISE EXCEPTION USING errcode='42501',message='Only the owner can approve village-bank rules.';END IF;
  IF d->>'status'<>'Open' OR NOT coalesce((payload->>'classificationConfirmed')::boolean,false) THEN RAISE EXCEPTION 'Confirm that this activity holds member savings and is open.';END IF;
  multiple=(payload->>'multiple')::numeric;rate=(payload->>'rate')::numeric;
  IF multiple IS NULL OR multiple<0.1 OR multiple>10 OR multiple<>round(multiple,2) OR rate IS NULL OR rate<0 OR rate>100 OR rate<>round(rate,2) OR payload->>'basis' NOT IN ('Flat for whole term','Simple per month') OR length(trim(coalesce(payload->>'approval','')))<3 THEN RAISE EXCEPTION 'Enter approved savings multiple (0.1–10), rate, interest basis and approval reference.';END IF;
  d=jsonb_set(d,'{bank}',jsonb_build_object('enabled',true,'multiple',multiple,'rate',rate,'basis',payload->>'basis','approval',left(payload->>'approval',500),'approvedBy',actor_email,'approvedAt',now()));note='Village-bank rules approved; previous loan agreements unchanged.';
 ELSIF action_name='finance_reverse' THEN
  SELECT e INTO rec FROM jsonb_array_elements(d->'ledger') e WHERE e->>'id'=payload->>'entry';
  IF rec->>'kind' IS DISTINCT FROM 'Savings withdrawal' THEN RETURN public.sungira_v17_action(actor_id,actor_email,action_name,payload);END IF;
  IF d->>'status'<>'Open' OR rec->>'status'<>'Confirmed' OR length(trim(coalesce(payload->>'reason','')))<3 THEN RAISE EXCEPTION 'Choose a confirmed withdrawal in an open activity and give a reversal reason.';END IF;
  d=jsonb_set(d,'{ledger}',(SELECT jsonb_agg(CASE WHEN e->>'id'=rec->>'id' THEN e||jsonb_build_object('status','Voided','voidReason',payload->>'reason','voidedBy',actor_email,'voidedAt',now()) ELSE e END) FROM jsonb_array_elements(d->'ledger') e));note='Savings withdrawal reversed: '||(rec->>'id');
 ELSE
  fingerprint=encode(digest(jsonb_build_object('action',action_name,'payload',payload)::text,'sha256'),'hex');
  SELECT e INTO rec FROM jsonb_array_elements(d->'ledger') e WHERE e->>'id'=payload->>'requestId';
  IF rec IS NOT NULL THEN
   IF rec->>'requestFingerprint' IS DISTINCT FROM fingerprint THEN RAISE EXCEPTION 'This request identifier was already used. Refresh records before retrying.';END IF;
   RETURN jsonb_build_object('ok',true,'duplicate',true);
  END IF;
  IF d->>'status'<>'Open' THEN RAISE EXCEPTION 'Reopen the activity before recording a financial transaction.';END IF;
  IF action_name IN ('loan','bank_withdraw') AND coalesce((d->'bank'->>'enabled')::boolean,false) THEN
   member_info=public.sungira_bank_member(d,payload->>'member');summary=public.sungira_financial_summary(d);amount=(payload->>'amount')::numeric;
   IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(d->'members') m WHERE m->>'id'=payload->>'member') THEN RAISE EXCEPTION 'Choose a member.';END IF;
   IF amount IS NULL OR amount<=0 OR amount<>round(amount,2) OR amount>(summary->>'cash')::numeric THEN RAISE EXCEPTION 'Check the positive amount and available group cash.';END IF;
   IF action_name='loan' THEN
    IF length(trim(coalesce(payload->>'note','')))<3 THEN RAISE EXCEPTION 'Enter the member loan approval or agreement reference.';END IF;
    IF amount>(member_info->>'capacity')::numeric THEN RAISE EXCEPTION 'The loan exceeds remaining borrowing capacity based on this member''s savings and outstanding principal.';END IF;
    IF (payload->>'rate')::numeric IS DISTINCT FROM (d->'bank'->>'rate')::numeric OR payload->>'basis' IS DISTINCT FROM d->'bank'->>'basis' THEN RAISE EXCEPTION 'Use the currently approved group interest rate and basis.';END IF;
   ELSE
    IF amount>(member_info->>'withdrawable')::numeric THEN RAISE EXCEPTION 'This exceeds savings available after reserving loan security.';END IF;
   END IF;
  ELSIF action_name='bank_withdraw' THEN RAISE EXCEPTION 'The owner must first approve village-bank rules for this activity.';
  END IF;
  IF action_name='bank_withdraw' THEN
   IF coalesce(payload->>'requestId','')!~'^[0-9a-f-]{36}$' OR payload->>'date' IS NULL OR (payload->>'date')::date<(d->>'start')::date OR (payload->>'date')::date>(now() AT TIME ZONE 'Africa/Blantyre')::date OR payload->>'method' IS NULL OR payload->>'method' NOT IN ('Cash','Airtel Money','TNM Mpamba','Bank transfer','Other') OR (payload->>'method'<>'Cash' AND length(trim(coalesce(payload->>'ref','')))=0) THEN RAISE EXCEPTION 'Enter the request, transaction date, method and payment reference.';END IF;
   IF length(coalesce(payload->>'ref',''))>0 AND EXISTS(SELECT 1 FROM jsonb_array_elements(d->'ledger') e WHERE e->>'ref'=payload->>'ref' AND e->>'method'=payload->>'method' AND e->>'status' IN ('Confirmed','Pending')) THEN RAISE EXCEPTION 'This payment reference is already recorded.';END IF;
   rec=jsonb_build_object('id',payload->>'requestId','kind','Savings withdrawal','member',payload->>'member','amount',amount,'date',payload->>'date','method',payload->>'method','ref',coalesce(payload->>'ref',''),'note',left(coalesce(payload->>'note',''),500),'status','Confirmed','verification','Officer reconciled','reportedBy',actor_email,'reviewedBy',actor_email,'recordedAt',now(),'requestFingerprint',fingerprint);
   d=jsonb_set(d,'{ledger}',jsonb_build_array(rec)||(d->'ledger'));note='Member savings withdrawal recorded: '||amount;
  ELSE
   result=public.sungira_v17_action(actor_id,actor_email,action_name,payload);
   SELECT data INTO d FROM public.sungira_collections WHERE id=c.id;
   d=jsonb_set(d,'{ledger}',(SELECT jsonb_agg(CASE WHEN e->>'id'=payload->>'requestId' THEN e||jsonb_build_object('requestFingerprint',fingerprint) ELSE e END) FROM jsonb_array_elements(d->'ledger') e));
   UPDATE public.sungira_collections SET data=d WHERE id=c.id;RETURN result;
  END IF;
 END IF;
 d=jsonb_set(d,'{audit}',jsonb_build_array(jsonb_build_object('at',now(),'actor',actor_email,'text',note))||coalesce(d->'audit','[]'));d=jsonb_set(d,'{updated}',to_jsonb(now()));
 UPDATE public.sungira_collections SET data=d WHERE id=c.id;
 RETURN coalesce(r,jsonb_build_object('ok',true));
END $$;
REVOKE ALL ON FUNCTION public.sungira_bank_member(jsonb,text),public.sungira_financial_summary(jsonb) FROM public,anon,authenticated;
REVOKE ALL ON FUNCTION public.sungira_v17_action(uuid,text,text,jsonb),public.sungira_action(uuid,text,text,jsonb) FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.sungira_action(uuid,text,text,jsonb) TO service_role;
COMMIT;
