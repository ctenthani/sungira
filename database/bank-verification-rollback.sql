-- Synthetic village-bank fixtures. Run inside a transaction and ROLLBACK.
DO $$
DECLARE owner_id uuid=gen_random_uuid();officer_id uuid=gen_random_uuid();viewer_id uuid=gen_random_uuid();owner_email text=owner_id||'@example.invalid';officer_email text=officer_id||'@example.invalid';viewer_email text=viewer_id||'@example.invalid';c uuid;member text=gen_random_uuid()::text;other_member text=gen_random_uuid()::text;loan_req text=gen_random_uuid()::text;repay_req text=gen_random_uuid()::text;withdraw_req text=gen_random_uuid()::text;r jsonb;d jsonb;p jsonb;loan_id text;
BEGIN
 INSERT INTO auth.users(id,email,email_confirmed_at) VALUES(owner_id,owner_email,now()),(officer_id,officer_email,now()),(viewer_id,viewer_email,now());
 r=public.sungira_action(owner_id,owner_email,'create',jsonb_build_object('name','TEST bank rollback','start','2026-01-01','due','2027-12-31','incomeNature','Individual'));c=(r->>'id')::uuid;
 PERFORM public.sungira_action(owner_id,owner_email,'person',jsonb_build_object('id',c,'member',member,'name','TEST member A','pledge',1000));
 PERFORM public.sungira_action(owner_id,owner_email,'person',jsonb_build_object('id',c,'member',other_member,'name','TEST member B','pledge',1000));
 INSERT INTO public.sungira_access VALUES(c,officer_email,'Treasurer'),(c,viewer_email,'Viewer');
 p=jsonb_build_object('id',c,'multiple',3,'rate',10,'basis','Flat for whole term','classificationConfirmed',true,'approval','TEST meeting');
 BEGIN PERFORM public.sungira_action(officer_id,officer_email,'bank_setup',p);RAISE EXCEPTION 'Treasurer changed policy';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 PERFORM public.sungira_action(owner_id,owner_email,'bank_setup',p);
 PERFORM public.sungira_action(owner_id,owner_email,'entry',jsonb_build_object('id',c,'kind','Contribution','member',member,'amount',300,'date','2026-10-18','method','Cash','requestId',gen_random_uuid()));
 PERFORM public.sungira_action(owner_id,owner_email,'entry',jsonb_build_object('id',c,'kind','Contribution','member',other_member,'amount',700,'date','2026-10-18','method','Cash','requestId',gen_random_uuid()));
 p=jsonb_build_object('id',c,'member',member,'amount',600,'rate',10,'basis','Flat for whole term','months',1,'firstDue','2026-11-18','date','2026-10-18','method','Cash','note','TEST approved loan','requestId',loan_req);
 BEGIN PERFORM public.sungira_action(viewer_id,viewer_email,'loan',p);RAISE EXCEPTION 'Viewer recorded loan';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 PERFORM public.sungira_action(officer_id,officer_email,'loan',p);
 r=public.sungira_action(officer_id,officer_email,'loan',p);IF NOT (r->>'duplicate')::boolean THEN RAISE EXCEPTION 'Loan retry duplicated';END IF;
 BEGIN PERFORM public.sungira_action(officer_id,officer_email,'loan',p||jsonb_build_object('amount',650));RAISE EXCEPTION 'Changed retry accepted';EXCEPTION WHEN OTHERS THEN IF SQLERRM='Changed retry accepted' THEN RAISE;END IF;END;
 BEGIN PERFORM public.sungira_action(officer_id,officer_email,'loan',p||jsonb_build_object('requestId',gen_random_uuid(),'amount',400));RAISE EXCEPTION 'Savings limit bypassed';EXCEPTION WHEN OTHERS THEN IF SQLERRM='Savings limit bypassed' THEN RAISE;END IF;END;
 SELECT data INTO d FROM public.sungira_collections WHERE id=c;SELECT l->>'id' INTO loan_id FROM jsonb_array_elements(d->'loans') l LIMIT 1;
 p=jsonb_build_object('id',c,'entity',loan_id,'principal',200,'interest',20,'date','2026-10-18','method','Cash','requestId',repay_req);
 PERFORM public.sungira_action(officer_id,officer_email,'repayment',p);
 r=public.sungira_action(officer_id,officer_email,'finance_receipt',jsonb_build_object('id',c,'entry',repay_req));IF (r->>'principalPaid')::numeric<>200 OR (r->>'interestPaid')::numeric<>20 THEN RAISE EXCEPTION 'Repayment receipt allocation failed';END IF;
 p=jsonb_build_object('id',c,'member',member,'amount',150,'date','2026-10-18','method','Cash','requestId',withdraw_req);
 PERFORM public.sungira_action(officer_id,officer_email,'bank_withdraw',p);
 BEGIN PERFORM public.sungira_action(officer_id,officer_email,'bank_withdraw',p||jsonb_build_object('amount',17,'requestId',gen_random_uuid()));RAISE EXCEPTION 'Loan security bypassed';EXCEPTION WHEN OTHERS THEN IF SQLERRM='Loan security bypassed' THEN RAISE;END IF;END;
 SELECT data INTO d FROM public.sungira_collections WHERE id=c;r=public.sungira_financial_summary(d);
 IF (r->>'cash')::numeric<>470 OR (r->>'loanPrincipal')::numeric<>400 OR (r->>'assets')::numeric<>870 OR (r->>'interestReceived')::numeric<>20 THEN RAISE EXCEPTION 'Bank balances do not reconcile: %',r;END IF;
 r=public.sungira_bank_member(d,member);IF (r->>'savings')::numeric<>150 OR (r->>'capacity')::numeric<>50 THEN RAISE EXCEPTION 'Member balances wrong: %',r;END IF;
 r=public.sungira_action(owner_id,owner_email,'finance_receipt',jsonb_build_object('id',c,'entry',withdraw_req));IF (r->>'amount')::numeric<>150 OR r->>'kind'<>'Savings withdrawal' THEN RAISE EXCEPTION 'Withdrawal receipt failed';END IF;
 PERFORM public.sungira_action(officer_id,officer_email,'finance_reverse',jsonb_build_object('id',c,'entry',withdraw_req,'reason','TEST reversal'));
 SELECT data INTO d FROM public.sungira_collections WHERE id=c;IF (public.sungira_financial_summary(d)->>'cash')::numeric<>620 THEN RAISE EXCEPTION 'Reversal did not restore cash';END IF;
 BEGIN PERFORM public.sungira_action(owner_id,owner_email,'finance_receipt',jsonb_build_object('id',c,'entry',withdraw_req));RAISE EXCEPTION 'Voided receipt issued';EXCEPTION WHEN OTHERS THEN IF SQLERRM='Voided receipt issued' THEN RAISE;END IF;END;
END $$;
SELECT 'PASS: bank rules, role separation, savings-backed limits, idempotent loans, changed retries, repayment allocation, withdrawal security, reconciliation, receipts and reversals. Synthetic changes rolled back.' AS result;
