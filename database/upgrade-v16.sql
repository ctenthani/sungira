-- Run after upgrade-v15.sql. Payment nature and editable activity names.
BEGIN;
DO $$ BEGIN
 IF to_regprocedure('public.sungira_v15_action(uuid,text,text,jsonb)') IS NULL THEN ALTER FUNCTION public.sungira_action(uuid,text,text,jsonb) RENAME TO sungira_v15_action;END IF;
END $$;
CREATE OR REPLACE FUNCTION public.sungira_action(actor_id uuid,actor_email text,action_name text,payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE c public.sungira_collections%rowtype;role_name text;nature text;r jsonb;p jsonb;
BEGIN
 IF action_name='create' THEN
  nature=coalesce(payload->>'incomeNature','Individual');
  IF nature NOT IN ('Individual','Group') THEN RAISE EXCEPTION 'Choose Individual or Group payment nature.';END IF;
  p=payload;
  IF nature='Group' THEN
   IF payload?'seed' THEN RAISE EXCEPTION 'Prepared member lists are for individual activities.';END IF;
   IF nullif(payload->>'parentId','') IS NOT NULL THEN
    SELECT * INTO c FROM public.sungira_collections WHERE id=(payload->>'parentId')::uuid;
    IF c.owner_id=actor_id THEN role_name='Owner';ELSE SELECT role INTO role_name FROM public.sungira_access WHERE collection_id=c.id AND email=lower(actor_email);END IF;
    IF actor_id IS NULL OR role_name IS NULL OR role_name NOT IN ('Owner','Treasurer') THEN RAISE EXCEPTION USING errcode='42501',message='Only responsible group officers can create activities.';END IF;
    p=(p-'parentId')||jsonb_build_object('groupName',coalesce(nullif(trim(c.data->>'groupName'),''),c.data->>'name'));
   END IF;
  END IF;
  r=public.sungira_v15_action(actor_id,actor_email,action_name,p);
  UPDATE public.sungira_collections SET data=data||jsonb_build_object('incomeNature',nature) WHERE id=(r->>'id')::uuid;
  RETURN r;
 END IF;
 IF action_name IN ('activity_settings','group_members','entry','group_income','church_import','person','names_bulk') THEN
  SELECT * INTO c FROM public.sungira_collections WHERE id=(payload->>'id')::uuid FOR UPDATE;
  IF action_name='activity_settings' THEN
   IF c.owner_id=actor_id THEN role_name='Owner';ELSE SELECT role INTO role_name FROM public.sungira_access WHERE collection_id=c.id AND email=lower(actor_email);END IF;
   IF actor_id IS NULL OR role_name IS NULL OR role_name NOT IN ('Owner','Treasurer') THEN RAISE EXCEPTION USING errcode='42501',message='Only responsible officers can edit an activity.';END IF;
   nature=coalesce(payload->>'incomeNature',c.data->>'incomeNature','Mixed');
   IF nature NOT IN ('Individual','Group','Mixed') OR length(trim(coalesce(payload->>'name','')))=0 OR length(payload->>'name')>120 THEN RAISE EXCEPTION 'Enter an activity name and valid payment nature.';END IF;
   IF nature='Group' AND EXISTS(SELECT 1 FROM jsonb_array_elements(c.data->'ledger') e WHERE e->>'kind'='Contribution') OR nature='Individual' AND EXISTS(SELECT 1 FROM jsonb_array_elements(c.data->'ledger') e WHERE e->>'kind'='Group income') THEN RAISE EXCEPTION 'Recorded payments use another nature. Keep Mixed to preserve their history.';END IF;
   UPDATE public.sungira_collections SET data=data||jsonb_build_object('name',trim(payload->>'name'),'activity',trim(payload->>'name'),'incomeNature',nature,'updated',now(),'audit',jsonb_build_array(jsonb_build_object('at',now(),'actor',actor_email,'text','Activity name/payment nature updated'))||(data->'audit')) WHERE id=c.id;
   RETURN jsonb_build_object('ok',true);
  END IF;
  IF c.data->>'incomeNature'='Group' AND (action_name IN ('group_members','person','names_bulk','church_import') OR action_name='entry' AND payload->>'kind'='Contribution') THEN RAISE EXCEPTION 'This activity records group income without individual members.';END IF;
  IF c.data->>'incomeNature'='Individual' AND action_name='group_income' THEN RAISE EXCEPTION 'This activity records individual contributions. Create a Group activity for collective income.';END IF;
 END IF;
 RETURN public.sungira_v15_action(actor_id,actor_email,action_name,payload);
END $$;
REVOKE ALL ON FUNCTION public.sungira_v15_action(uuid,text,text,jsonb) FROM public,anon,authenticated;
REVOKE ALL ON FUNCTION public.sungira_action(uuid,text,text,jsonb) FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.sungira_action(uuid,text,text,jsonb) TO service_role;
COMMIT;
