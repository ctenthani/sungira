-- Run after upgrade-v7.sql. Names are public by default; explicit anonymity survives bulk sharing.
do $$ begin
 if to_regprocedure('public.sungira_v7_action(uuid,text,text,jsonb)') is null then alter function public.sungira_action(uuid,text,text,jsonb) rename to sungira_v7_action;end if;
end $$;
update public.sungira_collections set data=jsonb_set(data,'{members}',coalesce((select jsonb_agg(m||jsonb_build_object('anonymous',coalesce((m->>'anonymous')::boolean,false),'publicConsent',not coalesce((m->>'anonymous')::boolean,false))) from jsonb_array_elements(data->'members') m),'[]'::jsonb)) where not coalesce((data->>'namesV8')::boolean,false);
update public.sungira_collections set data=data||jsonb_build_object('namesV8',true) where not coalesce((data->>'namesV8')::boolean,false);
create or replace function public.sungira_action(actor_id uuid,actor_email text,action_name text,payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare c public.sungira_collections%rowtype;d jsonb;r jsonb;role_name text;visible boolean;anon boolean;member_id text;old_ids jsonb;
begin
 if action_name='visibility_all' then
  select * into c from public.sungira_collections where id=(payload->>'id')::uuid for update;
  if actor_id is null or c.id is null then raise exception using errcode='42501',message='Officer sign-in required.';end if;
  if c.owner_id=actor_id then role_name='Owner';else select role into role_name from public.sungira_access where collection_id=c.id and email=lower(actor_email);end if;
  if role_name is null or role_name not in ('Owner','Treasurer') then raise exception using errcode='42501',message='Only responsible officers can change visibility.';end if;
  visible=coalesce((payload->>'visible')::boolean,false);d=c.data;
  d=jsonb_set(d,'{members}',coalesce((select jsonb_agg(m||jsonb_build_object('publicConsent',visible and not coalesce((m->>'anonymous')::boolean,false))) from jsonb_array_elements(d->'members') m),'[]'::jsonb));
  if visible then d=d||jsonb_build_object('publicItems',true,'inKind',coalesce((select jsonb_agg(k||jsonb_build_object('publish',true)) from jsonb_array_elements(coalesce(d->'inKind','[]'::jsonb)) k),'[]'::jsonb));end if;
  d=jsonb_set(d,'{updated}',to_jsonb(now()));d=jsonb_set(d,'{audit}',jsonb_build_array(jsonb_build_object('at',now(),'actor',actor_email,'text',case when visible then 'Names and in-kind pledges shared; explicit anonymous contributors protected' else 'All public names hidden; anonymous preferences preserved' end))||(d->'audit'));
  update public.sungira_collections set data=d where id=c.id;return jsonb_build_object('ok',true);
 end if;
 if action_name='person' then
  -- Protect the selected member identity and remember existing IDs for an added name.
  select data into d from public.sungira_collections where id=(payload->>'id')::uuid for update;
  old_ids=coalesce((select jsonb_agg(m->>'id') from jsonb_array_elements(d->'members') m),'[]'::jsonb);
  anon=coalesce((payload->>'anonymous')::boolean,false);
  r=public.sungira_v7_action(actor_id,actor_email,action_name,payload||jsonb_build_object('publicConsent',not anon));
  select data into d from public.sungira_collections where id=(payload->>'id')::uuid;
  member_id=nullif(payload->>'member','');
  if member_id is null then select m->>'id' into member_id from jsonb_array_elements(d->'members') m where not(old_ids ? (m->>'id'));end if;
  d=jsonb_set(d,'{members}',(select jsonb_agg(case when m->>'id'=member_id then m||jsonb_build_object('anonymous',anon,'publicConsent',not anon) else m end) from jsonb_array_elements(d->'members') m));
  update public.sungira_collections set data=d where id=(payload->>'id')::uuid;return r;
 end if;
 r=public.sungira_v7_action(actor_id,actor_email,action_name,payload);
 if action_name in ('create','church_import','names_bulk') then
  member_id=case when action_name='create' then r->>'id' else payload->>'id' end;
  update public.sungira_collections set data=jsonb_set(data,'{members}',coalesce((select jsonb_agg(case when m?'anonymous' then m else m||jsonb_build_object('anonymous',false,'publicConsent',true) end) from jsonb_array_elements(data->'members') m),'[]'::jsonb))||jsonb_build_object('namesV8',true) where id=member_id::uuid;
 end if;
 return r;
end $$;
revoke all on function public.sungira_v7_action(uuid,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.sungira_action(uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.sungira_action(uuid,text,text,jsonb) to service_role;
