-- Public income/outflow rows: preserve existing token and visibility checks.
BEGIN;
DO $$ BEGIN
 IF to_regprocedure('public.sungira_v19_action(uuid,text,text,jsonb)') IS NULL THEN ALTER FUNCTION public.sungira_action(uuid,text,text,jsonb) RENAME TO sungira_v19_action; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.sungira_action(actor_id uuid,actor_email text,action_name text,payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE result jsonb; d jsonb;
BEGIN
 result=public.sungira_v19_action(actor_id,actor_email,action_name,payload);
 IF action_name<>'public' OR result IS NULL THEN RETURN result;END IF;
 SELECT data INTO d FROM public.sungira_collections WHERE id=(payload->>'id')::uuid;
 -- No names, payees, private notes, references, proof files, or account details.
 RETURN result||jsonb_build_object('start',d->>'start','accountEntries',coalesce((SELECT jsonb_agg(jsonb_build_object('date',e->>'date','kind',e->>'kind','category',e->>'category','amount',e->'amount') ORDER BY e->>'date' DESC) FROM jsonb_array_elements(coalesce(d->'ledger','[]'::jsonb)) e WHERE e->>'status'='Confirmed' AND e->>'kind' IN ('Contribution','Group income','Loan repayment','Investment proceeds','Expense','Mkhonde payout','Investment placement','Loan disbursement','Savings withdrawal')),'[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.sungira_v19_action(uuid,text,text,jsonb) FROM public,anon,authenticated;
REVOKE ALL ON FUNCTION public.sungira_action(uuid,text,text,jsonb) FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.sungira_action(uuid,text,text,jsonb) TO service_role;
COMMIT;
