-- Explicit activity contribution frequency; does not alter historical receipts.
BEGIN;
DO $$ BEGIN
 IF to_regprocedure('public.sungira_v18_action(uuid,text,text,jsonb)') IS NULL THEN ALTER FUNCTION public.sungira_action(uuid,text,text,jsonb) RENAME TO sungira_v18_action; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.sungira_action(actor_id uuid,actor_email text,action_name text,payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE c public.sungira_collections%rowtype; r jsonb; p jsonb:=payload; frequency text; monthly numeric; cid uuid;
BEGIN
 IF action_name='public' THEN
  r=public.sungira_v18_action(actor_id,actor_email,action_name,payload);
  IF r IS NULL THEN RETURN r; END IF;
  SELECT * INTO c FROM public.sungira_collections WHERE id=(payload->>'id')::uuid;
  frequency=coalesce(c.data->>'paymentFrequency',CASE WHEN coalesce((r->>'monthlyAmount')::numeric,0)>0 THEN 'Monthly' ELSE 'Not specified' END);
  RETURN r||jsonb_build_object('paymentFrequency',frequency);
 END IF;
 IF action_name NOT IN ('create','settings','activity_settings') THEN RETURN public.sungira_v18_action(actor_id,actor_email,action_name,payload); END IF;
 IF NOT EXISTS(SELECT 1 FROM auth.users WHERE id=actor_id AND lower(email)=lower(actor_email) AND email_confirmed_at IS NOT NULL) THEN RAISE EXCEPTION USING errcode='42501',message='A verified matching officer account is required.'; END IF;
 IF action_name<>'create' THEN
  SELECT * INTO c FROM public.sungira_collections WHERE id=(payload->>'id')::uuid FOR UPDATE;
  IF c.id IS NULL THEN RAISE EXCEPTION 'Activity not found.'; END IF;
 END IF;
 -- Legacy clients retain their previous configuration rather than being assumed monthly.
 monthly=coalesce(nullif(payload->>'monthlyAmount','')::numeric,(c.data->>'monthlyAmount')::numeric,0);
 frequency=coalesce(nullif(payload->>'paymentFrequency',''),c.data->>'paymentFrequency',CASE WHEN monthly>0 THEN 'Monthly' ELSE 'Not specified' END);
 IF frequency NOT IN ('Once-off','Monthly','As agreed','Not specified') OR (payload?'paymentFrequency' AND frequency='Not specified') THEN RAISE EXCEPTION 'Choose Once-off, Monthly or As agreed payment frequency.'; END IF;
 IF frequency='Monthly' THEN
  IF monthly<=0 OR monthly>100000000000 OR monthly<>round(monthly,2) THEN RAISE EXCEPTION 'Enter a positive agreed monthly contribution with at most two decimal places.'; END IF;
 ELSE monthly=0;
 END IF;
 p=p||jsonb_build_object('monthlyAmount',monthly);
 r=public.sungira_v18_action(actor_id,actor_email,action_name,p);
 cid=CASE WHEN action_name='create' THEN (r->>'id')::uuid ELSE c.id END;
 UPDATE public.sungira_collections SET data=data||jsonb_build_object('paymentFrequency',frequency,'monthlyAmount',monthly,'updated',now(),'audit',jsonb_build_array(jsonb_build_object('at',now(),'actor',actor_email,'text','Payment frequency: '||frequency))||coalesce(data->'audit','[]'::jsonb)) WHERE id=cid;
 RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.sungira_v18_action(uuid,text,text,jsonb) FROM public,anon,authenticated;
REVOKE ALL ON FUNCTION public.sungira_action(uuid,text,text,jsonb) FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.sungira_action(uuid,text,text,jsonb) TO service_role;
COMMIT;
