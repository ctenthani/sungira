-- Run after upgrade-v5.sql. Rerunnable. No record deletion.
do $$ begin
 if to_regprocedure('public.sungira_v5_action(uuid,text,text,jsonb)') is null then alter function public.sungira_action(uuid,text,text,jsonb) rename to sungira_v5_action;end if;
end $$;
create or replace function public.sungira_name_key(n text) returns text language sql immutable as $$select lower(trim(regexp_replace(n,'^(Bambo ndi May[io]|Bambo|Mayi|Mai|Pa)\s+','','i')))$$;
revoke all on function public.sungira_name_key(text) from public,anon,authenticated;
create or replace function public.sungira_action(actor_id uuid,actor_email text,action_name text,payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare c public.sungira_collections%rowtype;d jsonb;r jsonb;item jsonb;person jsonb;x jsonb;people jsonb;items jsonb;nm text;pid text;role_name text;quantity numeric;logtext text;seed jsonb;
begin
 if action_name='create' then
  r=public.sungira_v5_action(actor_id,actor_email,action_name,payload);
  if payload->>'seed'='charles' and payload?'churchSeed' then perform public.sungira_action(actor_id,actor_email,'church_import',jsonb_build_object('id',r->>'id','churchSeed',payload->'churchSeed'));end if;
  return r;
 end if;
 if action_name not in ('entry','names_bulk','church_import','in_kind','in_kind_receive') then return public.sungira_v5_action(actor_id,actor_email,action_name,payload);end if;
 if actor_id is null then raise exception using errcode='42501',message='Officer sign-in is required.';end if;
 select * into c from public.sungira_collections where id=(payload->>'id')::uuid for update;
 if c.id is null then raise exception 'Collection not found.';end if;
 if c.owner_id=actor_id then role_name='Owner';else select role into role_name from public.sungira_access where collection_id=c.id and email=lower(actor_email);end if;
 if role_name is null or role_name not in ('Owner','Treasurer') then raise exception using errcode='42501',message='Only responsible officers can edit names or record received payments.';end if;
 d=c.data;if d->>'status'='Closed' then raise exception 'Reopen before changing records.';end if;
 if action_name='entry' then
  r=public.sungira_v5_action(actor_id,actor_email,action_name,payload);
  if payload->>'kind'='Contribution' then
   select data into d from public.sungira_collections where id=c.id;
   select e into item from jsonb_array_elements(d->'ledger') e where e->>'id'=payload->>'requestId';
   if item->>'status'='Pending' then
    return public.sungira_v5_action(actor_id,actor_email,'review',jsonb_build_object('id',c.id,'entry',payload->>'requestId','decision','Confirmed','reason','Received payment recorded directly by responsible officer'));
   end if;
  end if;return r;
 elsif action_name='names_bulk' then
  if payload->>'updated' is distinct from d->>'updated' then raise exception 'Records changed while this editor was open. Reload the names and try again.';end if;
  if jsonb_typeof(payload->'names')<>'array' or jsonb_array_length(payload->'names')>1000 then raise exception 'Use at most 1000 names.';end if;
  if exists(select 1 from jsonb_array_elements(payload->'names') n where length(trim(coalesce(n->>'name','')))<1 or length(n->>'name')>120) then raise exception 'Every line needs a name of at most 120 characters.';end if;
  if exists(select 1 from jsonb_array_elements(payload->'names') n group by public.sungira_name_key(n->>'name') having count(*)>1) then raise exception 'Duplicate names found. Give different people distinct names.';end if;
  if exists(select 1 from jsonb_array_elements(payload->'names') n where nullif(n->>'id','') is not null and not exists(select 1 from jsonb_array_elements(d->'members') m where m->>'id'=n->>'id')) or exists(select 1 from jsonb_array_elements(payload->'names') n where nullif(n->>'id','') is not null group by n->>'id' having count(*)>1) then raise exception 'Keep each existing bracket ID exactly once.';end if;
  if exists(select 1 from jsonb_array_elements(d->'members') m where not exists(select 1 from jsonb_array_elements(payload->'names') n where n->>'id'=m->>'id')) then raise exception 'Keep every existing bracket ID. Rename lines rather than removing contributors with ledger history.';end if;
  people='[]'::jsonb;
  for x in select value from jsonb_array_elements(payload->'names') loop
   select m into person from jsonb_array_elements(d->'members') m where m->>'id'=x->>'id';
   if person is null then person=jsonb_build_object('id',gen_random_uuid()::text,'phone','','pledge',0,'publicConsent',false);end if;
   people=people||jsonb_build_array(person||jsonb_build_object('name',trim(x->>'name')));
  end loop;
  d=jsonb_set(d,'{members}',people);logtext='Names updated using notepad editor; contributor IDs and payments retained';
 elsif action_name='church_import' then
  seed=payload->'churchSeed';if seed is null then raise exception 'Prepared church list is unavailable.';end if;
  if coalesce((d->>'churchV6Imported')::boolean,false) then return jsonb_build_object('ok',true,'duplicate',true);end if;
  people=d->'members';
  for x in select value from jsonb_array_elements(seed->'names') loop
   nm=x#>>'{}';
   if not exists(select 1 from jsonb_array_elements(people) m where public.sungira_name_key(m->>'name')=public.sungira_name_key(nm)) then
    people=people||jsonb_build_array(jsonb_build_object('id',gen_random_uuid()::text,'name',nm,'phone','','pledge',0,'publicConsent',false));
   end if;
  end loop;
  for x in select value from jsonb_array_elements(seed->'cash') loop
   people=(select jsonb_agg(case when public.sungira_name_key(m->>'name')=public.sungira_name_key(x->>'name') then m||jsonb_build_object('pledge',greatest(coalesce((m->>'pledge')::numeric,0),(x->>'amount')::numeric)) else m end) from jsonb_array_elements(people) m);
  end loop;
  items=coalesce(d->'inKind','[]'::jsonb);
  for x in select value from jsonb_array_elements(seed->'items') loop
   select m->>'id' into pid from jsonb_array_elements(people) m where public.sungira_name_key(m->>'name')=public.sungira_name_key(x->>'donor') limit 1;
   item=jsonb_build_object('id',gen_random_uuid()::text,'member',pid,'description',x->>'description','quantity',x->'quantity','unit',x->>'unit','quantityNote',x->>'quantityNote','received',0,'publish',false,'sourceChecked',x->'sourceChecked','sourceDonor',x->>'donor','deliveries','[]'::jsonb);
   items=items||jsonb_build_array(item);
  end loop;
  d=d||jsonb_build_object('members',people,'inKind',items,'churchV6Imported',true,'groupName',coalesce(nullif(d->>'groupName',''),'Charles Lwangwa Mpakati'));logtext='Merged church schedules and item requirements imported; source ticks are not delivery acknowledgements';
 elsif action_name='in_kind' then
  pid=nullif(payload->>'member','');quantity=nullif(payload->>'quantity','')::numeric;
  if pid is not null and not exists(select 1 from jsonb_array_elements(d->'members') m where m->>'id'=pid) then raise exception 'Choose a contributor or leave unassigned.';end if;
  if quantity is not null and (quantity<=0 or quantity>100000000000 or quantity<>round(quantity,3)) or length(trim(coalesce(payload->>'description','')))<1 or length(trim(coalesce(payload->>'unit','')))<1 then raise exception 'Check item, quantity and unit.';end if;
  select k into item from jsonb_array_elements(coalesce(d->'inKind','[]'::jsonb)) k where k->>'id'=payload->>'pledgeId';
  if coalesce((item->>'received')::numeric,0)>0 and (quantity is null or quantity<(item->>'received')::numeric or item->>'member' is distinct from pid or item->>'description' is distinct from trim(payload->>'description') or item->>'unit' is distinct from trim(payload->>'unit')) then raise exception 'Reverse received deliveries before changing their contributor, unit or item.';end if;
  item=coalesce(item,jsonb_build_object('id',gen_random_uuid()::text,'received',0,'deliveries','[]'::jsonb))||jsonb_build_object('member',pid,'description',trim(payload->>'description'),'quantity',quantity,'unit',trim(payload->>'unit'),'quantityNote',coalesce(payload->>'quantityNote',''),'due',nullif(payload->>'due','')::date,'publish',coalesce((payload->>'publish')::boolean,false));
  d=jsonb_set(d,'{inKind}',coalesce((select jsonb_agg(k) from jsonb_array_elements(coalesce(d->'inKind','[]'::jsonb)) k where k->>'id'<>item->>'id'),'[]'::jsonb)||jsonb_build_array(item));logtext='Goods/service requirement or pledge saved';
 elsif action_name='in_kind_receive' then
  select k into item from jsonb_array_elements(coalesce(d->'inKind','[]'::jsonb)) k where k->>'id'=payload->>'pledgeId';
  if item->>'quantity' is null or item->>'member' is null then raise exception 'Set the agreed quantity and contributor before acknowledging delivery.';end if;
  return public.sungira_v5_action(actor_id,actor_email,action_name,payload);
 end if;
 d=jsonb_set(d,'{members}',coalesce((select jsonb_agg(m order by public.sungira_name_key(m->>'name'),m->>'name') from jsonb_array_elements(d->'members') m),'[]'::jsonb));
 d=jsonb_set(d,'{audit}',jsonb_build_array(jsonb_build_object('at',now(),'actor',actor_email,'text',logtext))||(d->'audit'));d=jsonb_set(d,'{updated}',to_jsonb(now()));
 update public.sungira_collections set data=d where id=c.id;return jsonb_build_object('ok',true);
end $$;
revoke all on function public.sungira_v5_action(uuid,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.sungira_action(uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.sungira_action(uuid,text,text,jsonb) to service_role;
