'use strict';
// Offline checks against the repository code. All accounts and amounts are synthetic.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
Object.assign(process.env, {SUPABASE_URL:'https://test.invalid', SUPABASE_SERVICE_ROLE_KEY:'synthetic', PAYCHANGU_SECRET_KEY:'synthetic', PAYCHANGU_COLLECTION_ID:'test-collection', PAYCHANGU_MERCHANT_NAME:'Test', URL:'https://test.invalid', PAYCHANGU_WEBHOOK_SECRET:'synthetic'});
const api = require(path.join(root,'netlify/functions/api.js'));
const payment = require(path.join(root,'netlify/functions/payment.js'));
const webhook = require(path.join(root,'netlify/functions/payment-webhook.js'));
let checks=0;
async function check(name,fn){await fn();checks++;console.log('PASS '+name)}
const response = body => ({ok:true,json:async()=>body});
const tx='SG-00000000-0000-0000-0000-000000000001';
let settlements, providerCalls, intent, provider;
function reset(){settlements=0;providerCalls=0;intent={actor_id:'owner',collection_id:'test-collection',amount:100,confirmed:false};provider={status:'success',data:{status:'success',tx_ref:tx,currency:'MWK',amount:100,mode:'live',charges:2}};global.fetch=async url=>{if(url.includes('sungira_payment_intents'))return response([intent]);if(url.includes('api.paychangu.com')){providerCalls++;return response(provider)}if(url.endsWith('rpc/sungira_settle_payment')){settlements++;return response({ok:true})}throw Error('Unexpected network path in offline test')}}
(async()=>{
 await check('Unauthenticated API rejects account listing',async()=>{global.fetch=async()=>{throw Error('Must not contact database')};assert.equal((await api.handler({httpMethod:'POST',headers:{},body:'{"action":"list"}'})).statusCode,401)});
 await check('API rejects oversized payload before database access',async()=>assert.equal((await api.handler({httpMethod:'POST',headers:{},body:'x'.repeat(350001)})).statusCode,413));
 await check('Webhook rejects incorrect signatures',async()=>assert.equal((await webhook.handler({httpMethod:'POST',headers:{signature:'0'.repeat(64)},body:'{}'})).statusCode,401));
 await check('Payment belongs to authenticated actor',async()=>{reset();await assert.rejects(payment.verify(tx,{id:'other'}),/does not belong/);assert.equal(providerCalls,0);assert.equal(settlements,0)});
 for(const [field,value] of [['amount',101],['currency','USD'],['mode','test'],['tx_ref','SG-00000000-0000-0000-0000-000000000002']])await check('Reject provider mismatch: '+field,async()=>{reset();provider.data[field]=value;await assert.rejects(payment.verify(tx,{id:'owner'}),/did not match/);assert.equal(settlements,0)});
 await check('Pending provider result cannot settle',async()=>{reset();provider.data.status='pending';assert.equal((await payment.verify(tx,{id:'owner'})).pending,true);assert.equal(settlements,0)});
 await check('Verified payment reaches settlement once',async()=>{reset();assert.equal((await payment.verify(tx,{id:'owner'})).ok,true);assert.equal(settlements,1)});
 await check('Already confirmed payment skips provider and settlement',async()=>{reset();intent.confirmed=true;assert.equal((await payment.verify(tx,{id:'owner'})).alreadyConfirmed,true);assert.equal(providerCalls,0);assert.equal(settlements,0)});
 const make=(id,groupName,ledger)=>({id,data:{groupName,activity:id,members:[],inKind:[],ledger}});
 const entry=(kind,amount,date,status='Confirmed')=>({kind,amount,date,status,id:kind+date,category:kind});
 const first=make('first','Group A',[entry('Group income',50,'2026-09-30'),entry('Contribution',100,'2026-10-01'),entry('Expense',25,'2026-10-03'),entry('Contribution',900,'2026-10-04','Pending'),entry('Contribution',800,'2026-10-04','Voided'),entry('Contribution',700,'2026-11-01')]);
 const second=make('second','Group A',[entry('Group income',20,'2026-10-02')]);
 const excluded=make('excluded','Group B',[entry('Group income',999,'2026-10-02')]);
 const context=vm.createContext({TextEncoder,window:{addEventListener:()=>{}},groups:[first,second,excluded],report:()=>{},sum:rows=>rows.reduce((s,e)=>s+Number(e.amount),0),today:()=>'2026-10-11',itemState:()=>''});
 vm.runInContext(fs.readFileSync(path.join(root,'reports.js'),'utf8'),context);
 context.first=first;
 const model=scope=>vm.runInContext(`reportModel(first,{scope:'${scope}',from:'2026-10-01',to:'2026-10-31',start:2026,end:2026})`,context);
 await check('Group report excludes other groups, pending, voided and out-of-period entries',async()=>{const m=model('group');assert.equal(m.opening,50);assert.equal(m.received,120);assert.equal(m.spent,25);assert.equal(m.closing,145);assert.equal(m.pending.length,1);assert.equal(m.sources.length,2)});
 await check('Activity report excludes sister activity',async()=>{const m=model('activity');assert.equal(m.received,100);assert.equal(m.closing,125)});
 await check('Savings withdrawals appear in cash reports without becoming a contribution',async()=>{first.data.ledger.push(entry('Savings withdrawal',10,'2026-10-05'));const m=model('activity');assert.equal(m.received,100);assert.equal(m.spent,35);assert.equal(m.closing,115);first.data.ledger.pop();});
 await check('Once-off reports omit quarterly and monthly schedules in screen and workbook model',async()=>{first.data.paymentFrequency='Once-off';const m=model('activity');assert.equal(m.simple,true);assert.equal(m.sheets[0].rows.find(r=>r[0]==='Activity / category').length,2);assert.ok(!m.sheets.some(s=>s.name==='Quarterly balances'||s.name.startsWith('Members ')));context.compactModel=m;const xlsx=vm.runInContext('reportXlsx(compactModel)',context);assert.ok(!new TextDecoder().decode(xlsx).includes('<f>'));});
 await check('Monthly and mixed accounts retain quarterly view; explicit simple layout remains available',async()=>{first.data.paymentFrequency='Monthly';assert.equal(model('activity').simple,false);assert.ok(model('group').sheets.some(s=>s.name==='Quarterly balances'));assert.equal(vm.runInContext("reportModel(first,{scope:'activity',from:'2026-10-01',to:'2026-10-31',start:2026,end:2026,layout:'simple'})",context).simple,true);first.data.paymentFrequency='Once-off';});
 first.data.ledger[0].payee='=HYPERLINK("https://example.invalid")';
 context.exportModel=model('group');
 assert.ok(vm.runInContext('reportXlsx(exportModel)',context).length>0);
 await check('Payment rejects oversized and encoded requests',async()=>{assert.equal((await payment.handler({httpMethod:'POST',headers:{},body:'x'.repeat(16001)})).statusCode,413);assert.equal((await payment.handler({httpMethod:'POST',headers:{},body:'e30=',isBase64Encoded:true})).statusCode,400)});
 await check('Timeout aborts without retrying an uncertain write',async()=>{const {requestJson}=require(path.join(root,'netlify/functions/request'));let calls=0;global.fetch=async(url,{signal})=>{calls++;return new Promise((resolve,reject)=>signal.addEventListener('abort',()=>reject(Error('aborted')),{once:true}))};await assert.rejects(requestJson('https://test.invalid',{},5),/timed out/);assert.equal(calls,1)});
 for(const file of ['app.js','cloud.js','reports.js'])await check('CSV injection protection: '+file,async()=>{const code=fs.readFileSync(path.join(root,file),'utf8').match(/function csvCell[^\n]+/)[0];const ctx=vm.createContext({});vm.runInContext(code,ctx);for(const input of ['=SUM(1,2)',' \t=1','\tfoo','\r=1','\ufeff+1','＝1','＠SUM(1,2)','\u0001-1'])assert.ok(ctx.csvCell(input).startsWith('"\''));assert.equal(ctx.csvCell('ordinary "name"'),'"ordinary ""name"""')});
 console.log(checks+' offline checks passed.');
})().catch(error=>{console.error(error);process.exitCode=1});
