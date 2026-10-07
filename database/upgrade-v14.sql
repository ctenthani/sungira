-- Run after upgrade-v8.sql and fix-pgcrypto.sql. Safe to rerun.
-- Copy group names into new activities without copying financial history.
BEGIN;
DO $$ BEGIN
 IF to_regprocedure('public.sungira_v8_action(uuid,text,text,jsonb)') IS NULL THEN
  ALTER FUNCTION public.sungira_action(uuid,text,text,jsonb) RENAME TO sungira_v8_action;
 END IF;
END $$;
CREATE OR REPLACE FUNCTION public.sungira_action(actor_id uuid,actor_email text,action_name text,payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE source public.sungira_collections%rowtype; target public.sungira_collections%rowtype;
 role_name text; group_name text; result jsonb; new_members jsonb; added integer;
BEGIN
 IF action_name='create' AND nullif(payload->>'parentId','') IS NOT NULL OR action_name='group_members' THEN
  IF actor_id IS NULL OR actor_email IS NULL THEN RAISE EXCEPTION USING errcode='42501',message='Officer sign-in required.';END IF;
  SELECT * INTO source FROM public.sungira_collections WHERE id=(CASE WHEN action_name='create' THEN payload->>'parentId' ELSE payload->>'id' END)::uuid;
  IF source.id IS NULL THEN RAISE EXCEPTION 'Group activity not found.';END IF;
  IF source.owner_id=actor_id THEN role_name='Owner';ELSE SELECT role INTO role_name FROM public.sungira_access WHERE collection_id=source.id AND email=lower(actor_email);END IF;
  IF role_name IS NULL OR role_name NOT IN ('Owner','Treasurer') THEN RAISE EXCEPTION USING errcode='42501',message='Only group officers can add names to an activity.';END IF;
  group_name=coalesce(nullif(trim(source.data->>'groupName'),''),source.data->>'name');
  IF action_name='create' THEN
   result=public.sungira_v8_action(actor_id,actor_email,action_name,payload||jsonb_build_object('groupName',group_name));
   SELECT * INTO target FROM public.sungira_collections WHERE id=(result->>'id')::uuid FOR UPDATE;
  ELSE
   SELECT * INTO target FROM public.sungira_collections WHERE id=source.id FOR UPDATE;
   IF target.data->>'status'='Closed' THEN RAISE EXCEPTION 'Reopen the activity before adding names.';END IF;
   result=jsonb_build_object('ok',true);
  END IF;
  WITH candidates AS (
   SELECT m,lower(trim(m->>'name')) AS name_key,g.id,g.data->>'updated' AS updated
   FROM public.sungira_collections g CROSS JOIN LATERAL jsonb_array_elements(coalesce(g.data->'members','[]'::jsonb)) m
   WHERE (g.id=source.id OR lower(trim(g.data->>'groupName'))=lower(trim(group_name)))
    AND (g.owner_id=actor_id OR EXISTS(SELECT 1 FROM public.sungira_access a WHERE a.collection_id=g.id AND a.email=lower(actor_email)))
    AND length(trim(coalesce(m->>'name','')))>0
  ), chosen AS (
   SELECT DISTINCT ON(name_key) name_key,m FROM candidates ORDER BY name_key,(id=source.id) DESC,updated DESC NULLS LAST,id
  ), privacy AS (
   SELECT name_key,bool_or(coalesce((m->>'anonymous')::boolean,false)) AS anonymous,
    bool_and(coalesce((m->>'publicConsent')::boolean,true)) AS consent FROM candidates GROUP BY name_key
  ) SELECT coalesce(jsonb_agg(jsonb_build_object('id',gen_random_uuid()::text,'name',trim(c.m->>'name'),'phone',coalesce(c.m->>'phone',''),'pledge',0,'anonymous',p.anonymous,'publicConsent',p.consent AND NOT p.anonymous) ORDER BY c.name_key),'[]'::jsonb)
   INTO new_members FROM chosen c JOIN privacy p USING(name_key)
   WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(coalesce(target.data->'members','[]'::jsonb)) existing WHERE lower(trim(existing->>'name'))=c.name_key);
  added=jsonb_array_length(new_members);
  IF added+jsonb_array_length(coalesce(target.data->'members','[]'::jsonb))>1000 THEN RAISE EXCEPTION 'An activity supports up to 1000 names.';END IF;
  UPDATE public.sungira_collections SET data=jsonb_set(data,'{members}',coalesce(data->'members','[]'::jsonb)||new_members)||jsonb_build_object('updated',now(),'audit',jsonb_build_array(jsonb_build_object('at',now(),'actor',actor_email,'text','Group names added: '||added))||coalesce(data->'audit','[]'::jsonb)) WHERE id=target.id;
  RETURN result||jsonb_build_object('namesAdded',added);
 END IF;
 RETURN public.sungira_v8_action(actor_id,actor_email,action_name,payload);
END $$;
REVOKE ALL ON FUNCTION public.sungira_v8_action(uuid,text,text,jsonb) FROM public,anon,authenticated;
REVOKE ALL ON FUNCTION public.sungira_action(uuid,text,text,jsonb) FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.sungira_action(uuid,text,text,jsonb) TO service_role;
COMMIT;
