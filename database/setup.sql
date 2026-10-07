-- Run once in a new Supabase project's SQL editor. All mutations go through
-- the server-only RPC below; no browser receives the service-role key.
create extension if not exists pgcrypto;
create table if not exists public.sungira_collections (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 data jsonb not null, created_at timestamptz not null default now()
);
create table if not exists public.sungira_access (
 collection_id uuid not null references public.sungira_collections(id) on delete cascade,
 email text not null, role text not null check(role in ('Treasurer','Member','Viewer')),
 primary key(collection_id,email)
);
alter table public.sungira_collections enable row level security;
alter table public.sungira_access enable row level security;
revoke all on public.sungira_collections,public.sungira_access from anon,authenticated;

create or replace function public.sungira_action(actor_id uuid,actor_email text,action_name text,payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
 c public.sungira_collections%rowtype;
 role_name text; d jsonb; item jsonb; person jsonb; ledger jsonb; people jsonb; rec jsonb;
 result jsonb; entry_id text; amount numeric; balance numeric; created_id uuid;
 members_json jsonb; contribution_total numeric; expense_total numeric; note text;
begin
 if action_name='public' then
  select * into c from public.sungira_collections where id=(payload->>'id')::uuid;
  if c.id is null or coalesce((c.data->>'isPublic')::boolean,false)=false then raise exception 'This collection is private or unavailable.'; end if;
  d=c.data;
  select coalesce(sum((e->>'amount')::numeric) filter(where e->>'kind'='Contribution' and e->>'status'='Confirmed'),0),
         coalesce(sum((e->>'amount')::numeric) filter(where e->>'kind'<>'Contribution' and e->>'status'='Confirmed'),0)
    into contribution_total,expense_total from jsonb_array_elements(d->'ledger') e;
  select coalesce(jsonb_agg(jsonb_build_object('name',m->>'name','paid',coalesce((select sum((e->>'amount')::numeric) from jsonb_array_elements(d->'ledger') e where e->>'member'=m->>'id' and e->>'kind'='Contribution' and e->>'status'='Confirmed'),0))), '[]'::jsonb)
    into members_json from jsonb_array_elements(d->'members') m where coalesce((m->>'publicConsent')::boolean,false)=true;
  return jsonb_build_object('id',c.id,'name',d->>'name','type',d->>'type','start',d->>'start','due',d->>'due','status',d->>'status','target',coalesce(nullif((d->>'target')::numeric,0),(select sum((m->>'pledge')::numeric) from jsonb_array_elements(d->'members') m),0),'note',d->>'publicNote','collected',contribution_total,'spent',expense_total,'balance',contribution_total-expense_total,'members',members_json,'headcount',jsonb_array_length(d->'members'),'expenses',coalesce((select jsonb_agg(jsonb_build_object('date',e->>'date','category',e->>'category','amount',e->'amount')) from jsonb_array_elements(d->'ledger') e where e->>'kind'<>'Contribution' and e->>'status'='Confirmed'),'[]'::jsonb),'updated',d->>'updated');
 end if;
 if actor_id is null or actor_email is null then raise exception using errcode='42501',message='Please sign in.'; end if;
 if action_name='list' then
  return coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'data',g.data||jsonb_build_object('ledger',coalesce((select jsonb_agg((e-'attachment')||jsonb_build_object('hasAttachment',length(coalesce(e->>'attachment',''))>0)) from jsonb_array_elements(g.data->'ledger') e),'[]'::jsonb)),'role',case when g.owner_id=actor_id then 'Owner' else a.role end) order by g.created_at desc) from public.sungira_collections g left join public.sungira_access a on a.collection_id=g.id and a.email=lower(actor_email) where g.owner_id=actor_id or a.email is not null),'[]'::jsonb);
 end if;
 if action_name='create' then
  if payload->>'name' is null or payload->>'due' is null or payload->>'start' is null or length(trim(payload->>'name'))<1 or length(payload->>'name')>120 or (payload->>'due')::date<(payload->>'start')::date or coalesce((payload->>'target')::numeric,0)<0 or coalesce((payload->>'each')::numeric,0)<0 then raise exception 'Check the name, dates and amounts.'; end if;
  created_id=gen_random_uuid();
  d=jsonb_build_object('id',created_id,'name',trim(payload->>'name'),'type',coalesce(payload->>'type','Other'),'start',payload->>'start','due',payload->>'due','target',coalesce((payload->>'target')::numeric,0),'each',coalesce((payload->>'each')::numeric,0),'note',coalesce(payload->>'note',''),'publicNote',coalesce(payload->>'publicNote',''),'isPublic',false,'status','Open','members','[]'::jsonb,'ledger','[]'::jsonb,'audit',jsonb_build_array(jsonb_build_object('at',now(),'actor',actor_email,'text','Collection created')),'turn',0,'cycle',coalesce(payload->>'cycle','Not applicable'),'updated',now());
  -- Seed names are contributor names only, never accounts or received payments.
  if payload->>'seed'='charles' then
   for person in select value from jsonb_array_elements('["Bambo ndi Mayi Raphael","Mayi Cathreen Zambezi","Mayi Phekani","Mayi Esther Sumani","Bambo ndi Mayi Nkhata","Bambo ndi Mayi Kanike","Bambo ndi Mayi Makoka","Bambo ndi Mayi Mwinjiro","Bambo ndi Mayi Mofolo","Mayi Phales Paul","Bambo ndi Mayi Haward","Bambo Mbewe","Bambo ndi Mayi Chimombo","Bambo ndi Mayi Rhodricks","Bambo ndi Mayi R Kanagwa","Bambo ndi Mayi Njobvuyalema","Mayi Mphonde","Bambo ndi Mayi Mwale","Mayi Kantwela","Bambo ndi Mayo Sochera","Bambo ndi Mayi Alafuledi","Bambo ndi Mayi Chavula","Mayi Mbingwani","Mayi Immaculate Maleka","Mayi Moto","Bambo ndi Mayi Tenthani","Bambo ndi Mayi Malata","Mayi Chabwera","Bambo ndi Mayi D Kanagwa"]'::jsonb) loop
    d=jsonb_set(d,'{members}',(d->'members')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'name',person#>>'{}','phone','','pledge',0,'publicConsent',false)));
   end loop;
  end if;
  insert into public.sungira_collections(id,owner_id,data) values(created_id,actor_id,d);
  return jsonb_build_object('id',created_id);
 end if;
 select * into c from public.sungira_collections where id=(payload->>'id')::uuid for update;
 if c.id is null then raise exception 'Collection not found.'; end if;
 if c.owner_id=actor_id then role_name='Owner';else select role into role_name from public.sungira_access where collection_id=c.id and email=lower(actor_email);end if;
 if role_name is null then raise exception using errcode='42501',message='You do not have access to this collection.';end if;
 d=c.data;
 if action_name='proof' then
  select e into rec from jsonb_array_elements(d->'ledger') e where e->>'id'=payload->>'entry';
  if rec is null then raise exception 'Entry not found.';end if;
  return jsonb_build_object('attachment',coalesce(rec->>'attachment',''));
 end if;
 if action_name='access_list' then
  if role_name<>'Owner' then raise exception using errcode='42501',message='Only the owner can manage account access.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('email',email,'role',role)) from public.sungira_access where collection_id=c.id),'[]'::jsonb);
 end if;
 if action_name='grant' or action_name='revoke' then
  if role_name<>'Owner' then raise exception using errcode='42501',message='Only the owner can manage account access.'; end if;
  if payload->>'email' !~ '^[^ @]+@[^ @]+\.[^ @]+$' then raise exception 'Enter a valid email address.';end if;
  if action_name='grant' then
   if payload->>'role' is null or payload->>'role' not in ('Treasurer','Member','Viewer') then raise exception 'Choose a valid role.';end if;
   insert into public.sungira_access values(c.id,lower(trim(payload->>'email')),payload->>'role') on conflict(collection_id,email) do update set role=excluded.role;
   note='Access granted to '||lower(payload->>'email')||' as '||(payload->>'role');
  else
   delete from public.sungira_access where collection_id=c.id and email=lower(trim(payload->>'email'));
   note='Access removed for '||lower(payload->>'email');
  end if;
 elsif action_name='settings' then
  if role_name<>'Owner' then raise exception using errcode='42501',message='Only the owner can change publishing and settings.';end if;
  if payload->>'name' is null or payload->>'due' is null or payload->>'target' is null or length(trim(payload->>'name'))<1 or length(payload->>'name')>120 or (payload->>'due')::date<(payload->>'start')::date or (payload->>'target')::numeric<0 then raise exception 'Check collection settings.';end if;
  d=d||jsonb_build_object('name',trim(payload->>'name'),'due',payload->>'due','target',(payload->>'target')::numeric,'note',payload->>'note','publicNote',payload->>'publicNote','isPublic',coalesce((payload->>'isPublic')::boolean,false));note='Collection settings updated';
 elsif action_name='close' then
  if role_name not in ('Owner','Treasurer') then raise exception using errcode='42501',message='Only a treasurer can close or reopen collections.';end if;
  d=jsonb_set(d,'{status}',to_jsonb(case when d->>'status'='Closed' then 'Open' else 'Closed' end));note='Collection '||(d->>'status');
 elsif action_name='turn' then
  if role_name not in ('Owner','Treasurer') or d->>'status'='Closed' then raise exception 'You cannot change the turn.';end if;
  d=jsonb_set(d,'{turn}',to_jsonb(coalesce((d->>'turn')::int,0)+1));note='Rotation moved to next recipient';
 elsif action_name='person' then
  if role_name not in ('Owner','Treasurer') or d->>'status'='Closed' then raise exception using errcode='42501',message='Only a treasurer can change contributors in an open collection.';end if;
  if payload->>'name' is null or payload->>'pledge' is null or length(trim(payload->>'name'))<1 or length(payload->>'name')>120 or (payload->>'pledge')::numeric<0 then raise exception 'Check name and pledge.';end if;
  entry_id=coalesce(nullif(payload->>'member',''),gen_random_uuid()::text);
  if entry_id !~ '^[0-9a-f-]{36}$' then raise exception 'Invalid contributor identifier.';end if;
  person=jsonb_build_object('id',entry_id,'name',trim(payload->>'name'),'phone',coalesce(payload->>'phone',''),'pledge',(payload->>'pledge')::numeric,'publicConsent',coalesce((payload->>'publicConsent')::boolean,false));
  if exists(select 1 from jsonb_array_elements(d->'members') m where m->>'id'=entry_id) then
   select jsonb_agg(case when m->>'id'=entry_id then person else m end) into people from jsonb_array_elements(d->'members') m;d=jsonb_set(d,'{members}',people);
  else d=jsonb_set(d,'{members}',(d->'members')||jsonb_build_array(person));end if;note='Contributor saved: '||(person->>'name');
 elsif action_name='entry' then
  if role_name not in ('Owner','Treasurer','Member') or d->>'status'='Closed' then raise exception using errcode='42501',message='You cannot record payments in this collection.';end if;
  if payload->>'kind' is null or payload->>'kind' not in ('Contribution','Expense','Mkhonde payout') then raise exception 'Choose a valid entry type.';end if;
  if role_name='Member' and payload->>'kind'<>'Contribution' then raise exception using errcode='42501',message='Only the treasurer can record expenses.';end if;
  amount=(payload->>'amount')::numeric;
  if amount is null or payload->>'date' is null or amount<=0 or amount>100000000000 or amount<>round(amount,2) then raise exception 'Enter a positive amount with at most two decimal places.';end if;
  if (payload->>'date')::date>(now() at time zone 'Africa/Blantyre')::date or (payload->>'date')::date<(d->>'start')::date then raise exception 'Date must be within the collection start and today.';end if;
  if payload->>'kind'='Contribution' and not exists(select 1 from jsonb_array_elements(d->'members') m where m->>'id'=payload->>'member') then raise exception 'Choose a contributor.';end if;
  if payload->>'kind'<>'Contribution' and (length(trim(payload->>'payee'))<1 or length(trim(payload->>'note'))<1) then raise exception 'Enter the recipient and expenditure purpose.';end if;
  if payload->>'method' is null or payload->>'method' not in ('Cash','Airtel Money','TNM Mpamba','Bank transfer','Other') then raise exception 'Choose a valid payment method.';end if;
  if payload->>'method'<>'Cash' and length(trim(coalesce(payload->>'ref','')))<1 then raise exception 'A transaction reference is required for non-cash payments.';end if;
  if length(coalesce(payload->>'ref',''))>0 and exists(select 1 from jsonb_array_elements(d->'ledger') e where e->>'ref'=payload->>'ref' and e->>'method'=payload->>'method' and e->>'status' not in ('Rejected','Voided')) then raise exception 'This transaction reference has already been recorded.';end if;
  entry_id=payload->>'requestId';
  if entry_id is null or entry_id !~ '^[0-9a-f-]{36}$' then raise exception 'Missing request identifier. Please reload.';end if;
  if exists(select 1 from jsonb_array_elements(d->'ledger') e where e->>'id'=entry_id) then return jsonb_build_object('ok',true,'duplicate',true);end if;
  if length(coalesce(payload->>'attachment',''))>280000 or (payload->>'attachment' is not null and payload->>'attachment'<>'' and payload->>'attachment' !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$') then raise exception 'Use a PNG, JPEG or WebP picture smaller than 200 KB.';end if;
  rec=jsonb_build_object('id',entry_id,'kind',payload->>'kind','member',payload->>'member','payee',payload->>'payee','category',payload->>'category','amount',amount,'date',payload->>'date','method',payload->>'method','ref',coalesce(payload->>'ref',''),'note',coalesce(payload->>'note',''),'attachment',coalesce(payload->>'attachment',''),'status','Pending','reportedBy',actor_email,'recordedAt',now());
  if payload->>'kind'<>'Contribution' then
   select coalesce(sum(case when e->>'kind'='Contribution' then (e->>'amount')::numeric else -(e->>'amount')::numeric end),0) into balance from jsonb_array_elements(d->'ledger') e where e->>'status'='Confirmed';
   if amount>balance then raise exception 'Expenditure exceeds the confirmed available balance.';end if;
   rec=rec||jsonb_build_object('status','Confirmed','verification','Treasurer recorded','reviewedBy',actor_email,'reviewedAt',now());
  end if;
  d=jsonb_set(d,'{ledger}',jsonb_build_array(rec)||(d->'ledger'));note='Recorded '||(rec->>'kind')||' '||amount||' MK';
 elsif action_name='review' or action_name='void' then
  if role_name not in ('Owner','Treasurer') or d->>'status'='Closed' then raise exception using errcode='42501',message='Only a treasurer can review entries in an open collection.';end if;
  select e into rec from jsonb_array_elements(d->'ledger') e where e->>'id'=payload->>'entry';
  if rec is null then raise exception 'Entry not found.';end if;
  if length(trim(coalesce(payload->>'reason','')))<3 then raise exception 'Enter a review note with at least three characters.';end if;
  if action_name='review' then
   if coalesce((rec->>'providerPending')::boolean,false) then raise exception 'Use provider verification for this checkout, not manual review.';end if;
   if rec->>'status'<>'Pending' or payload->>'decision' is null or payload->>'decision' not in ('Confirmed','Rejected') then raise exception 'Only pending contributions can be reviewed.';end if;
   rec=rec||jsonb_build_object('status',payload->>'decision','verification',case when payload->>'decision'='Confirmed' then 'Treasurer confirmed' else 'Treasurer rejected' end,'reviewedBy',actor_email,'reviewedAt',now(),'reviewNote',payload->>'reason');
  else
   if rec->>'status'<>'Confirmed' then raise exception 'Only confirmed entries can be voided.';end if;
   select coalesce(sum(case when e->>'kind'='Contribution' then (e->>'amount')::numeric else -(e->>'amount')::numeric end),0) into balance from jsonb_array_elements(d->'ledger') e where e->>'status'='Confirmed';
   if rec->>'kind'='Contribution' and balance-(rec->>'amount')::numeric<0 then raise exception 'Correct the related expense first to avoid a negative balance.';end if;
   rec=rec||jsonb_build_object('status','Voided','voidReason',payload->>'reason','voidedBy',actor_email,'voidedAt',now());
  end if;
  select jsonb_agg(case when e->>'id'=payload->>'entry' then rec else e end) into ledger from jsonb_array_elements(d->'ledger') e;d=jsonb_set(d,'{ledger}',ledger);note=action_name||' '||(rec->>'id')||': '||(payload->>'reason');
 else raise exception 'Unknown action.';
 end if;
 d=jsonb_set(d,'{audit}',jsonb_build_array(jsonb_build_object('at',now(),'actor',actor_email,'text',note))||(d->'audit'));
 d=jsonb_set(d,'{updated}',to_jsonb(now()));
 update public.sungira_collections set data=d where id=c.id;
 return jsonb_build_object('ok',true);
end;
$$;
revoke all on function public.sungira_action(uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.sungira_action(uuid,text,text,jsonb) to service_role;
