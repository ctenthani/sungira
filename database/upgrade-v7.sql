-- After upgrade-v6.sql. Share the requested church checklist; names still require consent.
do $$ begin
 if to_regprocedure('public.sungira_v6_action(uuid,text,text,jsonb)') is null then alter function public.sungira_action(uuid,text,text,jsonb) rename to sungira_v6_action;end if;
end $$;
update public.sungira_collections set data=data||jsonb_build_object('publicItems',true,'inKind',coalesce((select jsonb_agg(k||jsonb_build_object('publish',true)) from jsonb_array_elements(coalesce(data->'inKind','[]'::jsonb)) k),'[]'::jsonb)) where coalesce((data->>'churchV6Imported')::boolean,false) and not(data?'publicItems');
create or replace function public.sungira_action(actor_id uuid,actor_email text,action_name text,payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r jsonb;d jsonb;c public.sungira_collections%rowtype;role_name text;
begin
 if action_name='public' then
  r=public.sungira_v6_action(actor_id,actor_email,action_name,payload);
  select data into d from public.sungira_collections where id=(payload->>'id')::uuid;
  return r||jsonb_build_object('inKind',coalesce((select jsonb_agg(jsonb_build_object('id',k->>'id','name',case when coalesce((m->>'publicConsent')::boolean,false) then m->>'name' else null end,'assigned',nullif(k->>'member','') is not null,'description',k->>'description','unit',k->>'unit','quantity',k->'quantity','received',k->'received','quantityNote',coalesce(k->>'quantityNote',''),'due',k->>'due')) from jsonb_array_elements(coalesce(d->'inKind','[]'::jsonb)) k left join lateral jsonb_array_elements(d->'members') m on m->>'id'=k->>'member' where coalesce((k->>'publish')::boolean,false) and coalesce((d->>'publicItems')::boolean,true)),'[]'::jsonb));
 end if;
 if action_name='items_visibility' then
  select * into c from public.sungira_collections where id=(payload->>'id')::uuid for update;
  if actor_id is null or c.id is null then raise exception using errcode='42501',message='Officer sign-in required.';end if;
  if c.owner_id=actor_id then role_name='Owner';else select role into role_name from public.sungira_access where collection_id=c.id and email=lower(actor_email);end if;
  if role_name is null or role_name not in ('Owner','Treasurer') then raise exception using errcode='42501',message='Only responsible officers can share the checklist.';end if;
  d=c.data||jsonb_build_object('publicItems',coalesce((payload->>'visible')::boolean,false));
  if coalesce((payload->>'visible')::boolean,false) then d=jsonb_set(d,'{inKind}',coalesce((select jsonb_agg(k||jsonb_build_object('publish',true)) from jsonb_array_elements(coalesce(d->'inKind','[]'::jsonb)) k),'[]'::jsonb));end if;
  d=jsonb_set(d,'{updated}',to_jsonb(now()));d=jsonb_set(d,'{audit}',jsonb_build_array(jsonb_build_object('at',now(),'actor',actor_email,'text',case when (payload->>'visible')::boolean then 'All checklist items shared; names retain consent controls' else 'Public checklist hidden' end))||(d->'audit'));
  update public.sungira_collections set data=d where id=c.id;return jsonb_build_object('ok',true);
 end if;
 r=public.sungira_v6_action(actor_id,actor_email,action_name,payload);
 if action_name='church_import' or action_name='create' and payload->>'seed'='charles' then
  update public.sungira_collections set data=data||jsonb_build_object('publicItems',true,'inKind',coalesce((select jsonb_agg(k||jsonb_build_object('publish',true)) from jsonb_array_elements(coalesce(data->'inKind','[]'::jsonb)) k),'[]'::jsonb)) where id=(case when action_name='create' then r->>'id' else payload->>'id' end)::uuid and not(data?'publicItems');
 end if;
 return r;
end $$;
revoke all on function public.sungira_v6_action(uuid,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.sungira_action(uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.sungira_action(uuid,text,text,jsonb) to service_role;
