-- Sungira v4: run AFTER existing setup.sql and payments.sql. Preserves records.
-- Safe to rerun. Existing member links must be re-shared after token creation.
SET search_path = public, extensions, pg_temp;
do $$ begin
 if to_regprocedure('public.sungira_v3_action(uuid,text,text,jsonb)') is null then
  alter function public.sungira_action(uuid,text,text,jsonb) rename to sungira_v3_action;
 end if;
end $$;
-- Teach legacy expense/void checks about principal and investment cash receipts.
do $$ declare definition text;begin
 definition=pg_get_functiondef('public.sungira_v3_action(uuid,text,text,jsonb)'::regprocedure);
 definition=replace(definition,'case when e->>''kind''=''Contribution'' then','case when e->>''kind'' in (''Contribution'',''Loan repayment'',''Investment proceeds'') then');
 execute definition;
end $$;
update public.sungira_collections set data=data||jsonb_build_object('publicToken',encode(gen_random_bytes(24),'hex')) where not(data?'publicToken');

create or replace function public.sungira_financial_summary(d jsonb) returns jsonb
language plpgsql immutable set search_path=public,extensions,pg_temp as $$
declare ledger_entry jsonb;cash numeric=0;collected numeric=0;expenses numeric=0;pending numeric=0;invested numeric=0;loans numeric=0;interest_expected numeric=0;interest_received numeric=0;gain numeric=0;writeoffs numeric=0;l jsonb;principal_paid numeric;interest_paid numeric;waived numeric;
begin
 for ledger_entry in select value from jsonb_array_elements(coalesce(d->'ledger','[]'::jsonb)) loop
  if ledger_entry->>'status'='Pending' then pending=pending+coalesce((ledger_entry->>'amount')::numeric,0);end if;
  if ledger_entry->>'status'<>'Confirmed' then continue;end if;
  if ledger_entry->>'kind' in ('Contribution','Loan repayment','Investment proceeds') then cash=cash+(ledger_entry->>'amount')::numeric;
  elsif ledger_entry->>'kind' in ('Expense','Mkhonde payout','Investment placement','Loan disbursement') then cash=cash-(ledger_entry->>'amount')::numeric;end if;
  if ledger_entry->>'kind'='Contribution' then collected=collected+(ledger_entry->>'amount')::numeric;
  elsif ledger_entry->>'kind' in ('Expense','Mkhonde payout') then expenses=expenses+(ledger_entry->>'amount')::numeric;
  elsif ledger_entry->>'kind'='Investment placement' then invested=invested+(ledger_entry->>'amount')::numeric;
  elsif ledger_entry->>'kind'='Investment proceeds' then invested=invested-coalesce((ledger_entry->>'basisReleased')::numeric,0);gain=gain+(ledger_entry->>'amount')::numeric-coalesce((ledger_entry->>'basisReleased')::numeric,0);
  elsif ledger_entry->>'kind'='Loan disbursement' then loans=loans+(ledger_entry->>'amount')::numeric;
  elsif ledger_entry->>'kind'='Loan repayment' then loans=loans-(ledger_entry->>'principalPaid')::numeric;interest_received=interest_received+(ledger_entry->>'interestPaid')::numeric;
  elsif ledger_entry->>'kind'='Loan adjustment' then loans=loans-(ledger_entry->>'principalWrittenOff')::numeric;writeoffs=writeoffs+(ledger_entry->>'principalWrittenOff')::numeric;end if;
 end loop;
 for l in select value from jsonb_array_elements(coalesce(d->'loans','[]'::jsonb)) loop
  if not exists(select 1 from jsonb_array_elements(d->'ledger') e where e->>'entityId'=l->>'id' and e->>'kind'='Loan disbursement' and e->>'status'='Confirmed') then continue;end if;
  select coalesce(sum((e->>'interestPaid')::numeric),0),coalesce(sum((e->>'interestWaived')::numeric),0) into interest_paid,waived from jsonb_array_elements(d->'ledger') e where e->>'entityId'=l->>'id' and e->>'status'='Confirmed';
  interest_expected=interest_expected+greatest(0,(l->>'agreedInterest')::numeric-interest_paid-waived);
 end loop;
 return jsonb_build_object('collected',collected,'expenses',expenses,'cash',cash,'pending',pending,'investmentBook',invested,'loanPrincipal',loans,'assets',cash+invested+loans,'scheduledInterestOutstanding',interest_expected,'interestReceived',interest_received,'investmentGain',gain,'loanWriteoffs',writeoffs);
end $$;
revoke all on function public.sungira_financial_summary(jsonb) from public,anon,authenticated;

create or replace function public.sungira_action(actor_id uuid,actor_email text,action_name text,payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare c public.sungira_collections%rowtype;d jsonb;role_name text;result jsonb;rec jsonb;entity jsonb;item jsonb;
 amount numeric;pnum numeric;inum numeric;remaining numeric;outstanding_interest numeric;summary jsonb;
 entity_id text;entry_id text;note text;new_token text;rate numeric;months integer;agreed numeric;schedule jsonb;principal_part numeric;interest_part numeric;due_date date;is_finance boolean;
begin
 if action_name='public' then
  select * into c from public.sungira_collections where id=(payload->>'id')::uuid;
  if c.id is null or not coalesce((c.data->>'isPublic')::boolean,false) or c.data->>'publicToken' is distinct from payload->>'token' then raise exception 'This member link is unavailable or has been replaced. Ask the officer for the latest link.';end if;
  d=c.data;result=public.sungira_v3_action(null,null,'public',payload);summary=public.sungira_financial_summary(d);
  result=result||jsonb_build_object('finance',summary,'collected',summary->'collected','spent',summary->'expenses','balance',summary->'cash','paymentInfo',coalesce(d->>'publicPaymentInfo',''),'officerContact',coalesce(d->>'publicContact',''),'plans',coalesce((select jsonb_agg(jsonb_build_object('title',pl->>'publicTitle','kind',pl->>'kind','budget',pl->'budget','status',pl->>'status','due',pl->>'due')) from jsonb_array_elements(coalesce(d->'plans','[]'::jsonb)) pl where length(coalesce(pl->>'publicTitle',''))>0),'[]'::jsonb));
  -- Expenses includes only operating spending, not invested/lent principal.
  result=jsonb_set(result,'{expenses}',coalesce((select jsonb_agg(jsonb_build_object('date',e->>'date','category',e->>'category','amount',e->'amount')) from jsonb_array_elements(d->'ledger') e where e->>'kind' in ('Expense','Mkhonde payout') and e->>'status'='Confirmed'),'[]'::jsonb));
  return result;
 end if;
 if action_name in ('list','proof','access_list') then return public.sungira_v3_action(actor_id,actor_email,action_name,payload);end if;
 if action_name='create' then
  result=public.sungira_v3_action(actor_id,actor_email,action_name,payload);
  update public.sungira_collections set data=data||jsonb_build_object('publicToken',encode(gen_random_bytes(24),'hex'),'isPublic',coalesce((payload->>'isPublic')::boolean,false),'publicPaymentInfo',coalesce(payload->>'publicPaymentInfo',''),'publicContact',coalesce(payload->>'publicContact',''),'plans','[]'::jsonb,'investments','[]'::jsonb,'loans','[]'::jsonb) where id=(result->>'id')::uuid;
  return result;
 end if;
 if actor_id is null or actor_email is null then raise exception using errcode='42501',message='Officer sign-in is required.';end if;
 select * into c from public.sungira_collections where id=(payload->>'id')::uuid for update;
 if c.id is null then raise exception 'Collection not found.';end if;
 if c.owner_id=actor_id then role_name='Owner';else select role into role_name from public.sungira_access where collection_id=c.id and email=lower(actor_email);end if;
 if role_name not in ('Owner','Treasurer') or role_name is null then raise exception using errcode='42501',message='Only the responsible officers can change financial records. Members use their viewing link.';end if;
 d=c.data;
 if action_name in ('grant','revoke','settings','close','turn','person','entry','review','void') then
  if action_name='grant' and payload->>'role' not in ('Treasurer','Viewer') then raise exception 'Give account access only to an officer or read-only reviewer. Members use the viewing link.';end if;
  if action_name='entry' and nullif(payload->>'plan','') is not null then
   select pl into entity from jsonb_array_elements(coalesce(d->'plans','[]'::jsonb)) pl where pl->>'id'=payload->>'plan';
   if entity is null or entity->>'status'<>'Planned' or payload->>'kind'<>'Expense' then raise exception 'Choose an open planned item for this expense.';end if;
   select coalesce(sum((e->>'amount')::numeric),0) into amount from jsonb_array_elements(d->'ledger') e where e->>'plan'=entity->>'id' and e->>'status'='Confirmed';
   if amount+(payload->>'amount')::numeric>(entity->>'budget')::numeric then raise exception 'This expense exceeds the remaining item budget. Update the plan first if the group approved a higher budget.';end if;
  end if;
  if action_name='void' then
   select e into rec from jsonb_array_elements(d->'ledger') e where e->>'id'=payload->>'entry';
   if rec->>'kind' in ('Loan disbursement','Loan repayment','Loan adjustment','Investment placement','Investment proceeds') then raise exception 'Use Reverse in the savings ledger for this financial entry.';end if;
  end if;
  result=public.sungira_v3_action(actor_id,actor_email,action_name,payload);
  if action_name='settings' then
   update public.sungira_collections set data=data||jsonb_build_object('publicPaymentInfo',coalesce(payload->>'publicPaymentInfo',''),'publicContact',coalesce(payload->>'publicContact','')) where id=c.id;
  elsif action_name='entry' and nullif(payload->>'plan','') is not null then
   update public.sungira_collections set data=jsonb_set(data,'{ledger}',(select jsonb_agg(case when e->>'id'=payload->>'requestId' then e||jsonb_build_object('plan',payload->>'plan') else e end) from jsonb_array_elements(data->'ledger') e)) where id=c.id;
  end if;
  return result;
 end if;
 if action_name='rotate_link' then
  if role_name<>'Owner' then raise exception 'Only the owner can replace member links.';end if;
  d=d||jsonb_build_object('publicToken',encode(gen_random_bytes(24),'hex'));note='Member viewing link replaced; old links revoked';
 elsif action_name in ('plan','plan_status') then
  if d->>'status'='Closed' then raise exception 'Reopen the collection before changing plans.';end if;
  if action_name='plan' then
   entity_id=coalesce(nullif(payload->>'plan',''),gen_random_uuid()::text);
   if entity_id !~ '^[0-9a-f-]{36}$' or length(trim(coalesce(payload->>'title','')))<1 or payload->>'kind' not in ('Welfare case','School fee','Project milestone','Purchase order','Event booking') then raise exception 'Check the planned item.';end if;
   amount=(payload->>'budget')::numeric;if amount is null or amount<0 or amount<>round(amount,2) then raise exception 'Enter a valid planned cost.';end if;
   if payload->>'due' is null then raise exception 'Enter a due date.';end if;due_date=(payload->>'due')::date;
   if payload->>'kind' in ('Purchase order','Event booking') then
    pnum=(payload->>'quantity')::numeric;inum=(payload->>'unitCost')::numeric;
    if pnum is null or pnum<=0 or pnum<>trunc(pnum) or inum is null or inum<0 or round(pnum*inum,2)<>amount then raise exception 'Quantity × unit cost must match the planned cost.';end if;
   end if;
   select coalesce(sum((e->>'amount')::numeric),0) into remaining from jsonb_array_elements(d->'ledger') e where e->>'plan'=entity_id and e->>'status'='Confirmed';
   if amount<remaining then raise exception 'Budget cannot be lower than spending already recorded.';end if;
   select pl into entity from jsonb_array_elements(coalesce(d->'plans','[]'::jsonb)) pl where pl->>'id'=entity_id;
   item=jsonb_build_object('id',entity_id,'kind',payload->>'kind','title',trim(payload->>'title'),'publicTitle',coalesce(payload->>'publicTitle',''),'budget',amount,'due',due_date,'quantity',payload->'quantity','unitCost',payload->'unitCost','member',payload->>'member','note',coalesce(payload->>'note',''),'status',coalesce(entity->>'status','Planned'));
   if exists(select 1 from jsonb_array_elements(coalesce(d->'plans','[]'::jsonb)) pl where pl->>'id'=entity_id) then
    d=jsonb_set(d,'{plans}',(select jsonb_agg(case when pl->>'id'=entity_id then item else pl end) from jsonb_array_elements(d->'plans') pl));
   else d=jsonb_set(d,'{plans}',coalesce(d->'plans','[]'::jsonb)||jsonb_build_array(item));end if;
   note='Planned '||(item->>'kind')||': '||(item->>'title');
  else
   if payload->>'status' not in ('Completed','Cancelled','Planned') then raise exception 'Choose a valid plan status.';end if;
   select pl into entity from jsonb_array_elements(coalesce(d->'plans','[]'::jsonb)) pl where pl->>'id'=payload->>'plan';if entity is null then raise exception 'Item not found.';end if;
   if payload->>'status'='Cancelled' and exists(select 1 from jsonb_array_elements(d->'ledger') e where e->>'plan'=entity->>'id' and e->>'status'='Confirmed') then raise exception 'An item with recorded spending cannot be cancelled. Correct its spending or mark the outcome completed.';end if;
   d=jsonb_set(d,'{plans}',(select jsonb_agg(case when pl->>'id'=entity->>'id' then pl||jsonb_build_object('status',payload->>'status') else pl end) from jsonb_array_elements(d->'plans') pl));note='Planned item marked '||(payload->>'status');
  end if;
 elsif action_name in ('investment','investment_return','loan','repayment','loan_adjustment','finance_reverse') then
  if d->>'status'='Closed' then raise exception 'Reopen the collection before recording savings activity.';end if;
  summary=public.sungira_financial_summary(d);
  if action_name='finance_reverse' then
   select e into rec from jsonb_array_elements(d->'ledger') e where e->>'id'=payload->>'entry';
   if rec is null or rec->>'status'<>'Confirmed' or rec->>'kind' not in ('Loan disbursement','Loan repayment','Loan adjustment','Investment placement','Investment proceeds') then raise exception 'Choose a confirmed savings entry.';end if;
   if length(trim(coalesce(payload->>'reason','')))<3 then raise exception 'Enter a reason for reversal.';end if;
   if rec->>'kind' in ('Loan disbursement','Investment placement') and exists(select 1 from jsonb_array_elements(d->'ledger') e where e->>'entityId'=rec->>'entityId' and e->>'status'='Confirmed' and e->>'id'<>rec->>'id') then raise exception 'Reverse the related receipts or adjustments before reversing principal placement.';end if;
   item=rec||jsonb_build_object('status','Voided','voidReason',payload->>'reason','voidedBy',actor_email,'voidedAt',now());
   d=jsonb_set(d,'{ledger}',(select jsonb_agg(case when e->>'id'=rec->>'id' then item else e end) from jsonb_array_elements(d->'ledger') e));
   if (public.sungira_financial_summary(d)->>'cash')::numeric<0 or (public.sungira_financial_summary(d)->>'investmentBook')::numeric<0 or (public.sungira_financial_summary(d)->>'loanPrincipal')::numeric<0 then raise exception 'This reversal would create a negative balance. Correct later related entries first.';end if;
   note='Savings entry reversed: '||(rec->>'id')||' — '||(payload->>'reason');
  else
   entry_id=payload->>'requestId';if entry_id is null or entry_id !~ '^[0-9a-f-]{36}$' then raise exception 'Missing request identifier.';end if;
   if exists(select 1 from jsonb_array_elements(d->'ledger') e where e->>'id'=entry_id) then return jsonb_build_object('ok',true,'duplicate',true);end if;
   if payload->>'date' is null then raise exception 'Enter the transaction date.';end if;due_date=(payload->>'date')::date;
   if due_date<(d->>'start')::date or due_date>(now() at time zone 'Africa/Blantyre')::date then raise exception 'Date must be between collection start and today.';end if;
   if payload->>'method' is null or payload->>'method' not in ('Cash','Airtel Money','TNM Mpamba','Bank transfer','Other') then raise exception 'Select a payment method.';end if;
   if payload->>'method'<>'Cash' and length(trim(coalesce(payload->>'ref','')))<1 then raise exception 'Enter the transaction reference.';end if;
   if length(coalesce(payload->>'ref',''))>0 and exists(select 1 from jsonb_array_elements(d->'ledger') e where e->>'ref'=payload->>'ref' and e->>'method'=payload->>'method' and e->>'status' in ('Pending','Confirmed')) then raise exception 'This reference is already recorded.';end if;
   rec=jsonb_build_object('id',entry_id,'date',due_date,'method',payload->>'method','ref',coalesce(payload->>'ref',''),'note',coalesce(payload->>'note',''),'status','Confirmed','verification','Officer reconciled','reportedBy',actor_email,'reviewedBy',actor_email,'recordedAt',now());
   if action_name='investment' then
    amount=(payload->>'amount')::numeric;
    if amount is null or amount<=0 or amount<>round(amount,2) or amount>(summary->>'cash')::numeric or length(trim(coalesce(payload->>'title','')))<1 then raise exception 'Check the investment name, amount and available cash.';end if;
    if payload->>'maturity' is null or (payload->>'maturity')::date<due_date then raise exception 'Review date must be on or after the placement date.';end if;
    entity_id=gen_random_uuid()::text;entity=jsonb_build_object('id',entity_id,'title',trim(payload->>'title'),'amount',amount,'date',due_date,'maturity',payload->>'maturity','note',payload->>'note');
    d=jsonb_set(d,'{investments}',coalesce(d->'investments','[]'::jsonb)||jsonb_build_array(entity));rec=rec||jsonb_build_object('kind','Investment placement','entityId',entity_id,'amount',amount,'payee',entity->>'title');
   elsif action_name='investment_return' then
    select iv into entity from jsonb_array_elements(coalesce(d->'investments','[]'::jsonb)) iv where iv->>'id'=payload->>'entity';
    if entity is null or not exists(select 1 from jsonb_array_elements(d->'ledger') e where e->>'entityId'=entity->>'id' and e->>'kind'='Investment placement' and e->>'status'='Confirmed') then raise exception 'Choose an active investment.';end if;
    select (entity->>'amount')::numeric-coalesce(sum((e->>'basisReleased')::numeric),0) into remaining from jsonb_array_elements(d->'ledger') e where e->>'entityId'=entity->>'id' and e->>'kind'='Investment proceeds' and e->>'status'='Confirmed';
    amount=(payload->>'amount')::numeric;pnum=(payload->>'basisReleased')::numeric;
    if remaining<0 or due_date<(entity->>'date')::date or amount is null or amount<0 or pnum is null or pnum<0 or pnum>remaining or amount+pnum<=0 or amount<>round(amount,2) or pnum<>round(pnum,2) then raise exception 'Check the cash received and original capital released. Capital released cannot exceed capital still invested.';end if;
    rec=rec||jsonb_build_object('kind','Investment proceeds','entityId',entity->>'id','amount',amount,'basisReleased',pnum,'payee',entity->>'title');
   elsif action_name='loan' then
    amount=(payload->>'amount')::numeric;rate=(payload->>'rate')::numeric;months=(payload->>'months')::integer;
    if amount is null or amount<=0 or amount<>round(amount,2) or amount>(summary->>'cash')::numeric or rate is null or rate<0 or rate>100 or months is null or months<1 or months>60 or payload->>'basis' not in ('Flat for whole term','Simple per month') then raise exception 'Check principal, agreed rate, interest basis, term and available cash.';end if;
    if not exists(select 1 from jsonb_array_elements(d->'members') m where m->>'id'=payload->>'member') then raise exception 'Choose a borrower from the contributor list.';end if;
    if payload->>'firstDue' is null or (payload->>'firstDue')::date<due_date then raise exception 'First repayment date cannot precede disbursement.';end if;
    agreed=round(amount*rate/100*case when payload->>'basis'='Simple per month' then months else 1 end,2);
    schedule='[]'::jsonb;
    for i in 1..months loop
     principal_part=case when i=months then amount-trunc(amount/months,2)*(months-1) else trunc(amount/months,2) end;
     interest_part=case when i=months then agreed-trunc(agreed/months,2)*(months-1) else trunc(agreed/months,2) end;
     schedule=schedule||jsonb_build_array(jsonb_build_object('due',((payload->>'firstDue')::date+make_interval(months=>i-1))::date,'principal',principal_part,'interest',interest_part));
    end loop;
    entity_id=gen_random_uuid()::text;entity=jsonb_build_object('id',entity_id,'member',payload->>'member','principal',amount,'rate',rate,'basis',payload->>'basis','months',months,'agreedInterest',agreed,'date',due_date,'schedule',schedule,'note',coalesce(payload->>'note',''));
    d=jsonb_set(d,'{loans}',coalesce(d->'loans','[]'::jsonb)||jsonb_build_array(entity));rec=rec||jsonb_build_object('kind','Loan disbursement','entityId',entity_id,'member',payload->>'member','amount',amount);
   else
    select l into entity from jsonb_array_elements(coalesce(d->'loans','[]'::jsonb)) l where l->>'id'=payload->>'entity';
    if entity is null or not exists(select 1 from jsonb_array_elements(d->'ledger') e where e->>'entityId'=entity->>'id' and e->>'kind'='Loan disbursement' and e->>'status'='Confirmed') then raise exception 'Choose an active loan.';end if;
    select (entity->>'principal')::numeric-coalesce(sum((e->>'principalPaid')::numeric),0)-coalesce(sum((e->>'principalWrittenOff')::numeric),0),(entity->>'agreedInterest')::numeric-coalesce(sum((e->>'interestPaid')::numeric),0)-coalesce(sum((e->>'interestWaived')::numeric),0)
     into remaining,outstanding_interest from jsonb_array_elements(d->'ledger') e where e->>'entityId'=entity->>'id' and e->>'status'='Confirmed';
    pnum=(payload->>'principal')::numeric;inum=(payload->>'interest')::numeric;
    if due_date<(entity->>'date')::date or pnum is null or inum is null or pnum<0 or inum<0 or pnum+inum<=0 or pnum>remaining or inum>outstanding_interest or pnum<>round(pnum,2) or inum<>round(inum,2) then raise exception 'Check principal and interest amounts; neither may exceed its outstanding balance.';end if;
    if action_name='repayment' then rec=rec||jsonb_build_object('kind','Loan repayment','entityId',entity->>'id','member',entity->>'member','amount',pnum+inum,'principalPaid',pnum,'interestPaid',inum);
    else
     if length(trim(coalesce(payload->>'note','')))<3 then raise exception 'Record the group-approved reason for the write-off or interest waiver.';end if;
     rec=rec||jsonb_build_object('kind','Loan adjustment','entityId',entity->>'id','member',entity->>'member','amount',0,'principalWrittenOff',pnum,'interestWaived',inum);
    end if;
   end if;
   d=jsonb_set(d,'{ledger}',jsonb_build_array(rec)||(d->'ledger'));note=(rec->>'kind')||' recorded: '||(rec->>'amount')||' MK';
  end if;
 else raise exception 'Unknown action.';end if;
 d=jsonb_set(d,'{audit}',jsonb_build_array(jsonb_build_object('at',now(),'actor',actor_email,'text',note))||(d->'audit'));d=jsonb_set(d,'{updated}',to_jsonb(now()));
 update public.sungira_collections set data=d where id=c.id;return jsonb_build_object('ok',true);
end $$;
revoke all on function public.sungira_action(uuid,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.sungira_v3_action(uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.sungira_action(uuid,text,text,jsonb) to service_role;
