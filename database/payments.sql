-- Run AFTER setup.sql. Optional PayChangu checkout with server verification.
create table if not exists public.sungira_payment_intents (
 tx_ref text primary key,collection_id uuid not null references public.sungira_collections(id),
 actor_id uuid not null references auth.users(id),member_id text not null,amount numeric(16,2) not null check(amount>0),
 confirmed boolean not null default false,created_at timestamptz not null default now()
);
alter table public.sungira_payment_intents enable row level security;
revoke all on public.sungira_payment_intents from anon,authenticated;
create or replace function public.sungira_reserve_payment(actor_id uuid,actor_email text,collection_id uuid,member_id text,amount numeric,tx_ref text)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare c public.sungira_collections%rowtype;d jsonb;role_name text;entry jsonb;
begin
 select * into c from public.sungira_collections where id=collection_id for update;
 if c.id is null then raise exception 'Collection not found.';end if;
 if c.owner_id=actor_id then role_name='Owner';else select a.role into role_name from public.sungira_access a where a.collection_id=c.id and a.email=lower(actor_email);end if;
 if role_name is null or role_name not in ('Owner','Treasurer') then raise exception using errcode='42501',message='You cannot make payments for this group.';end if;
 if c.data->>'status'='Closed' then raise exception 'This collection is closed.';end if;
 if amount is null or amount<=0 or amount>100000000000 or amount<>round(amount,2) then raise exception 'Check the payment amount.';end if;
 if not exists(select 1 from jsonb_array_elements(c.data->'members') m where m->>'id'=member_id) then raise exception 'Choose a contributor.';end if;
 insert into public.sungira_payment_intents values(tx_ref,c.id,actor_id,member_id,amount,false,now());
 entry=jsonb_build_object('id',gen_random_uuid(),'kind','Contribution','member',member_id,'amount',amount,'date',(now() at time zone 'Africa/Blantyre')::date,'method','PayChangu checkout','ref',tx_ref,'note','Awaiting provider confirmation','status','Pending','reportedBy',actor_email,'recordedAt',now(),'providerPending',true);
 d=jsonb_set(c.data,'{ledger}',jsonb_build_array(entry)||(c.data->'ledger'));
 d=jsonb_set(d,'{audit}',jsonb_build_array(jsonb_build_object('at',now(),'actor',actor_email,'text','PayChangu checkout reserved: '||tx_ref))||(d->'audit'));
 d=jsonb_set(d,'{updated}',to_jsonb(now()));update public.sungira_collections set data=d where id=c.id;
 return jsonb_build_object('tx_ref',tx_ref,'name',d->>'name');
end;$$;
create or replace function public.sungira_settle_payment(transaction_ref text,verified_amount numeric,verified_currency text,verified_mode text,provider_fee numeric)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare intent public.sungira_payment_intents%rowtype;c public.sungira_collections%rowtype;d jsonb;ledger jsonb;rec jsonb;
begin
 select * into intent from public.sungira_payment_intents where tx_ref=transaction_ref for update;
 if intent.tx_ref is null then raise exception 'Unknown transaction.';end if;
 if intent.confirmed then return jsonb_build_object('ok',true,'alreadyConfirmed',true);end if;
 if verified_amount is null or verified_amount<>intent.amount or verified_currency is distinct from 'MWK' or verified_mode is distinct from 'live' or provider_fee is null or provider_fee<0 or provider_fee>verified_amount then raise exception 'Provider amount, currency, mode or charges do not match.';end if;
 select * into c from public.sungira_collections where id=intent.collection_id for update;
 -- A payment started while open may finish after closing. The receipt must be
 -- recorded; automatically reopen for reconciliation rather than lose funds.
 d=c.data;
 select jsonb_agg(case when e->>'ref'=transaction_ref and coalesce((e->>'providerPending')::boolean,false) then e||jsonb_build_object('status','Confirmed','verification','Provider verified (PayChangu)','providerPending',false,'reviewedBy','PayChangu server verification','reviewedAt',now(),'note','Provider confirmed gross payment; charges recorded separately') else e end) into ledger from jsonb_array_elements(d->'ledger') e;
 if provider_fee>0 then
  rec=jsonb_build_object('id',gen_random_uuid(),'kind','Expense','payee','PayChangu','category','Payment provider fees','amount',provider_fee,'date',(now() at time zone 'Africa/Blantyre')::date,'method','PayChangu checkout','ref',transaction_ref||'-fee','note','Provider-reported transaction charges','status','Confirmed','verification','Provider verified (PayChangu)','reportedBy','PayChangu server verification','recordedAt',now());ledger=jsonb_build_array(rec)||ledger;
 end if;
 d=jsonb_set(d,'{ledger}',ledger);d=jsonb_set(d,'{status}','"Open"'::jsonb);
 d=jsonb_set(d,'{audit}',jsonb_build_array(jsonb_build_object('at',now(),'actor','PayChangu server verification','text','Provider verified '||transaction_ref||'; gross '||verified_amount||' MK; charges '||provider_fee||' MK; collection open for reconciliation'))||(d->'audit'));
 d=jsonb_set(d,'{updated}',to_jsonb(now()));update public.sungira_collections set data=d where id=c.id;
 update public.sungira_payment_intents set confirmed=true where tx_ref=transaction_ref;
 return jsonb_build_object('ok',true);
end;$$;
revoke all on function public.sungira_reserve_payment(uuid,text,uuid,text,numeric,text) from public,anon,authenticated;
revoke all on function public.sungira_settle_payment(text,numeric,text,text,numeric) from public,anon,authenticated;
grant execute on function public.sungira_reserve_payment(uuid,text,uuid,text,numeric,text) to service_role;
grant execute on function public.sungira_settle_payment(text,numeric,text,text,numeric) to service_role;
grant select on public.sungira_payment_intents to service_role;
