-- Run AFTER upgrade-v4.sql. Rerunnable, preserves accounts and records.
do $$ begin
 if to_regprocedure('public.sungira_v4_action(uuid,text,text,jsonb)') is null then
  alter function public.sungira_action(uuid,text,text,jsonb) rename to sungira_v4_action;
 end if;
end $$;
create or replace function public.sungira_action(actor_id uuid,actor_email text,action_name text,payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare c public.sungira_collections%rowtype;d jsonb;r jsonb;item jsonb;old jsonb;rec jsonb;role_name text;eid text;n numeric;received numeric;monthly numeric;total numeric;logtext text;
begin
 if action_name='public' then
  r=public.sungira_v4_action(actor_id,actor_email,action_name,payload);
  select data into d from public.sungira_collections where id=(payload->>'id')::uuid;
  monthly=coalesce((d->>'monthlyAmount')::numeric,0);
  return r||jsonb_build_object('groupName',coalesce(d->>'groupName',''),'activity',coalesce(d->>'activity',d->>'name'),'monthlyAmount',monthly,'members',coalesce((select jsonb_agg(jsonb_build_object('name',m->>'name','pledge',m->'pledge','paid',coalesce((select sum((e->>'amount')::numeric) from jsonb_array_elements(d->'ledger') e where e->>'member'=m->>'id' and e->>'kind'='Contribution' and e->>'status'='Confirmed'),0))) from jsonb_array_elements(d->'members') m where coalesce((m->>'publicConsent')::boolean,false)),'[]'::jsonb),'inKind',coalesce((select jsonb_agg(jsonb_build_object('name',m->>'name','description',k->>'description','unit',k->>'unit','quantity',k->'quantity','received',k->'received')) from jsonb_array_elements(coalesce(d->'inKind','[]'::jsonb)) k join lateral jsonb_array_elements(d->'members') m on m->>'id'=k->>'member' where coalesce((m->>'publicConsent')::boolean,false) and coalesce((k->>'publish')::boolean,false)),'[]'::jsonb));
 end if;
 if action_name in ('create','settings') then
  monthly=coalesce(nullif(payload->>'monthlyAmount','')::numeric,0);
  if monthly<0 or monthly<>round(monthly,2) or monthly>100000000000 or length(coalesce(payload->>'groupName',''))>120 or length(coalesce(payload->>'activity',''))>120 then raise exception 'Check group, activity and monthly contribution.';end if;
  r=public.sungira_v4_action(actor_id,actor_email,action_name,payload);
  eid=case when action_name='create' then r->>'id' else payload->>'id' end;
  update public.sungira_collections set data=data||jsonb_build_object('groupName',trim(coalesce(payload->>'groupName','')),'activity',trim(coalesce(nullif(payload->>'activity',''),payload->>'name')),'monthlyAmount',monthly) where id=eid::uuid;
  return r;
 end if;
 if action_name not in ('visibility_all','in_kind','in_kind_receive','in_kind_reverse','receipt','review') then return public.sungira_v4_action(actor_id,actor_email,action_name,payload);end if;
 if actor_id is null then raise exception using errcode='42501',message='Officer sign-in is required.';end if;
 select * into c from public.sungira_collections where id=(payload->>'id')::uuid for update;
 if c.id is null then raise exception 'Collection not found.';end if;
 if c.owner_id=actor_id then role_name='Owner';else select role into role_name from public.sungira_access where collection_id=c.id and email=lower(actor_email);end if;
 if role_name is null or role_name not in ('Owner','Treasurer') then raise exception using errcode='42501',message='Only responsible officers can acknowledge payments or change visibility.';end if;
 d=c.data;
 if action_name='review' then
  r=public.sungira_v4_action(actor_id,actor_email,action_name,payload);
  select data into d from public.sungira_collections where id=c.id;
  if payload->>'decision'<>'Confirmed' then return r;end if;
 end if;
 if action_name in ('receipt','review') then
  select e into rec from jsonb_array_elements(d->'ledger') e where e->>'id'=payload->>'entry';
  if rec is null or rec->>'kind'<>'Contribution' or rec->>'status'<>'Confirmed' then raise exception 'Receipts are issued only for acknowledged, confirmed contributions.';end if;
  if rec?'receipt' then return rec->'receipt';end if;
  select m into item from jsonb_array_elements(d->'members') m where m->>'id'=rec->>'member';
  monthly=coalesce((d->>'monthlyAmount')::numeric,0);
  select coalesce(sum((e->>'amount')::numeric),0) into total from jsonb_array_elements(d->'ledger') e where e->>'member'=rec->>'member' and e->>'kind'='Contribution' and e->>'status'='Confirmed';
  r=jsonb_build_object('number','SG-'||replace(rec->>'id','-',''),'groupName',coalesce(nullif(d->>'groupName',''),d->>'name'),'activity',coalesce(d->>'activity',d->>'name'),'contributor',item->>'name','amount',rec->'amount','date',rec->>'date','method',rec->>'method','reference',rec->>'ref','acknowledgedBy',coalesce(rec->>'reviewedBy',actor_email),'acknowledgedAt',coalesce(rec->>'reviewedAt',now()::text),'issuedAt',now(),'monthlyAmount',monthly,'totalPaidAtIssue',total,'monthsCovered',case when monthly>0 then floor(total/monthly) else null end,'partialMonth',case when monthly>0 then mod(total,monthly) else null end);
  d=jsonb_set(d,'{ledger}',(select jsonb_agg(case when e->>'id'=rec->>'id' then e||jsonb_build_object('receipt',r) else e end) from jsonb_array_elements(d->'ledger') e));logtext='Contribution receipt issued: '||(r->>'number');
 elsif action_name='visibility_all' then
  if coalesce((payload->>'visible')::boolean,false) and not coalesce((payload->>'consentConfirmed')::boolean,false) then raise exception 'Confirm that all contributors agreed before showing their names.';end if;
  d=jsonb_set(d,'{members}',coalesce((select jsonb_agg(m||jsonb_build_object('publicConsent',coalesce((payload->>'visible')::boolean,false))) from jsonb_array_elements(d->'members') m),'[]'::jsonb));
  logtext=case when coalesce((payload->>'visible')::boolean,false) then 'All contributor names shown; officer confirmed consent' else 'All contributor names hidden' end;
 elsif action_name='in_kind' then
  if d->>'status'='Closed' then raise exception 'Reopen before changing pledges.';end if;
  eid=coalesce(nullif(payload->>'pledgeId',''),gen_random_uuid()::text);n=(payload->>'quantity')::numeric;
  if eid !~ '^[0-9a-f-]{36}$' or n is null or n<=0 or n>100000000000 or n<>round(n,3) or length(trim(coalesce(payload->>'description','')))<1 or length(trim(coalesce(payload->>'unit','')))<1 then raise exception 'Enter the item/service, quantity and unit.';end if;
  if not exists(select 1 from jsonb_array_elements(d->'members') m where m->>'id'=payload->>'member') then raise exception 'Choose a contributor.';end if;
  select k into old from jsonb_array_elements(coalesce(d->'inKind','[]'::jsonb)) k where k->>'id'=eid;
  received=coalesce((old->>'received')::numeric,0);
  if n<received or (received>0 and (old->>'member' is distinct from payload->>'member' or old->>'description' is distinct from trim(payload->>'description') or old->>'unit' is distinct from trim(payload->>'unit'))) then raise exception 'Received items cannot be relabelled or reduced. Reverse the receipt first.';end if;
  item=jsonb_build_object('id',eid,'member',payload->>'member','description',trim(payload->>'description'),'unit',trim(payload->>'unit'),'quantity',n,'received',received,'due',nullif(payload->>'due','')::date,'publish',coalesce((payload->>'publish')::boolean,false),'deliveries',coalesce(old->'deliveries','[]'::jsonb));
  d=jsonb_set(d,'{inKind}',coalesce((select jsonb_agg(k) from jsonb_array_elements(coalesce(d->'inKind','[]'::jsonb)) k where k->>'id'<>eid),'[]'::jsonb)||jsonb_build_array(item));logtext='In-kind pledge saved';
 elsif action_name in ('in_kind_receive','in_kind_reverse') then
  if d->>'status'='Closed' then raise exception 'Reopen before recording goods or services.';end if;
  select k into item from jsonb_array_elements(coalesce(d->'inKind','[]'::jsonb)) k where k->>'id'=payload->>'pledgeId';
  if item is null then raise exception 'Pledge not found.';end if;
  if action_name='in_kind_receive' then
   eid=payload->>'requestId';n=(payload->>'quantity')::numeric;
   if eid is null or eid !~ '^[0-9a-f-]{36}$' then raise exception 'Missing request identifier.';end if;
   if exists(select 1 from jsonb_array_elements(item->'deliveries') x where x->>'id'=eid) then return jsonb_build_object('ok',true,'duplicate',true);end if;
   if n is null or n<=0 or n<>round(n,3) or n+(item->>'received')::numeric>(item->>'quantity')::numeric or length(trim(coalesce(payload->>'note','')))<3 or (payload->>'date') is null or (payload->>'date')::date<(d->>'start')::date or (payload->>'date')::date>(now() at time zone 'Africa/Blantyre')::date then raise exception 'Check received quantity, date and acknowledgement note.';end if;
   rec=jsonb_build_object('id',eid,'quantity',n,'date',(payload->>'date')::date,'note',payload->>'note','acknowledgedBy',actor_email,'at',now(),'status','Received');
   item=item||jsonb_build_object('received',(item->>'received')::numeric+n,'deliveries',(item->'deliveries')||jsonb_build_array(rec));logtext='In-kind delivery acknowledged';
  else
   select x into rec from jsonb_array_elements(item->'deliveries') x where x->>'id'=payload->>'delivery' and x->>'status'='Received';
   if rec is null or length(trim(coalesce(payload->>'reason','')))<3 then raise exception 'Choose a received delivery and provide a correction reason.';end if;
   item=item||jsonb_build_object('received',(item->>'received')::numeric-(rec->>'quantity')::numeric,'deliveries',(select jsonb_agg(case when x->>'id'=rec->>'id' then x||jsonb_build_object('status','Voided','reason',payload->>'reason','voidedBy',actor_email) else x end) from jsonb_array_elements(item->'deliveries') x));logtext='In-kind delivery reversed';
  end if;
  d=jsonb_set(d,'{inKind}',(select jsonb_agg(case when k->>'id'=item->>'id' then item else k end) from jsonb_array_elements(d->'inKind') k));
 end if;
 d=jsonb_set(d,'{audit}',jsonb_build_array(jsonb_build_object('at',now(),'actor',actor_email,'text',logtext))||(d->'audit'));d=jsonb_set(d,'{updated}',to_jsonb(now()));
 update public.sungira_collections set data=d where id=c.id;return coalesce(r,jsonb_build_object('ok',true));
end $$;
revoke all on function public.sungira_v4_action(uuid,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.sungira_action(uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.sungira_action(uuid,text,text,jsonb) to service_role;
