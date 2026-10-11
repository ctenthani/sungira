-- Apply after v16. Preserves all collection and payment data.
BEGIN;
DO $$ BEGIN
 IF to_regprocedure('public.sungira_v16_action(uuid,text,text,jsonb)') IS NULL THEN
  ALTER FUNCTION public.sungira_action(uuid,text,text,jsonb) RENAME TO sungira_v16_action;
 END IF;
END $$;
CREATE OR REPLACE FUNCTION public.sungira_action(actor_id uuid,actor_email text,action_name text,payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE c public.sungira_collections%rowtype; role_name text; rec jsonb; k text;
BEGIN
 IF action_name<>'public' AND NOT EXISTS(SELECT 1 FROM auth.users u WHERE u.id=actor_id AND lower(u.email)=lower(actor_email) AND u.email_confirmed_at IS NOT NULL) THEN
  RAISE EXCEPTION USING errcode='42501',message='A verified account matching this identity is required.';
 END IF;
 IF action_name IN ('entry','group_income','void') THEN
  SELECT * INTO c FROM public.sungira_collections WHERE id=(payload->>'id')::uuid FOR UPDATE;
  IF c.owner_id=actor_id THEN role_name='Owner';ELSE SELECT a.role INTO role_name FROM public.sungira_access a WHERE a.collection_id=c.id AND a.email=lower(actor_email);END IF;
  IF role_name IS NULL OR role_name NOT IN ('Owner','Treasurer') THEN RAISE EXCEPTION USING errcode='42501',message='Only responsible officers can change payment records.';END IF;
  IF action_name='void' THEN
   SELECT e INTO rec FROM jsonb_array_elements(c.data->'ledger') e WHERE e->>'id'=payload->>'entry';
   IF rec->>'verification'='Provider verified (PayChangu)' THEN RAISE EXCEPTION 'Provider payments need a reconciled refund. Their receipts cannot be voided manually.';END IF;
  ELSE
   SELECT e INTO rec FROM jsonb_array_elements(c.data->'ledger') e WHERE e->>'id'=payload->>'requestId';
   IF rec IS NOT NULL THEN
    IF rec->>'kind' IS DISTINCT FROM (CASE WHEN action_name='group_income' THEN 'Group income' ELSE payload->>'kind' END)
       OR (rec->>'amount')::numeric IS DISTINCT FROM (payload->>'amount')::numeric THEN RAISE EXCEPTION 'This request identifier belongs to a different payment.';END IF;
    FOREACH k IN ARRAY ARRAY['date','method','ref','note','member','payee','category','attachment'] LOOP
     IF coalesce(rec->>k,'') IS DISTINCT FROM coalesce(payload->>k,'') THEN RAISE EXCEPTION 'This request identifier belongs to different payment details.';END IF;
    END LOOP;
    RETURN jsonb_build_object('ok',true,'duplicate',true,'id',rec->>'id');
   END IF;
   IF action_name='group_income' AND length(trim(coalesce(payload->>'ref','')))>0 AND EXISTS(SELECT 1 FROM jsonb_array_elements(c.data->'ledger') e WHERE e->>'ref'=payload->>'ref' AND e->>'method'=payload->>'method' AND e->>'status' NOT IN ('Rejected','Voided')) THEN RAISE EXCEPTION 'This transaction reference has already been recorded.';END IF;
  END IF;
 END IF;
 RETURN public.sungira_v16_action(actor_id,actor_email,action_name,payload);
END $$;
REVOKE ALL ON FUNCTION public.sungira_v16_action(uuid,text,text,jsonb) FROM public,anon,authenticated;
REVOKE ALL ON FUNCTION public.sungira_action(uuid,text,text,jsonb) FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.sungira_action(uuid,text,text,jsonb) TO service_role;
-- Require one matching reservation before settlement can acknowledge funds.
DO $$ DECLARE definition text; BEGIN
 definition=pg_get_functiondef('public.sungira_settle_payment(text,numeric,text,text,numeric)'::regprocedure);
 IF position('Reservation ledger does not match' in definition)=0 THEN
  definition=replace(definition,'d=c.data;', E'd=c.data;\n IF (SELECT count(*) FROM jsonb_array_elements(d->''ledger'') e WHERE e->>''ref''=transaction_ref AND coalesce((e->>''providerPending'')::boolean,false) AND e->>''status''=''Pending'' AND e->>''kind''=''Contribution'' AND e->>''member''=intent.member_id AND (e->>''amount'')::numeric=intent.amount)<>1 THEN RAISE EXCEPTION ''Reservation ledger does not match the payment intent. Reconcile before settlement.'';END IF;\n IF provider_fee<>round(provider_fee,2) THEN RAISE EXCEPTION ''Provider charges require at most two decimal places.'';END IF;');
  EXECUTE definition;
 END IF;
END $$;
COMMIT;
