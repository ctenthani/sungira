'use strict';
const {randomUUID}=require('node:crypto');
const headers={'Content-Type':'application/json','Cache-Control':'no-store'};
const reply=(status,body)=>({statusCode:status,headers,body:JSON.stringify(body)});
const providerReady=()=>!!(process.env.PAYCHANGU_SECRET_KEY&&process.env.PAYCHANGU_COLLECTION_ID&&process.env.PAYCHANGU_MERCHANT_NAME&&process.env.URL);
async function db(path,data,method='POST'){
 const response=await fetch(process.env.SUPABASE_URL+'/rest/v1/'+path,{method,headers:{apikey:process.env.SUPABASE_SERVICE_ROLE_KEY,Authorization:'Bearer '+process.env.SUPABASE_SERVICE_ROLE_KEY,'Content-Type':'application/json'},...(method==='GET'?{}:{body:JSON.stringify(data)})});const out=await response.json();if(!response.ok)throw Error(out.message||'Payment record could not be saved.');return out;
}
async function verify(tx,actor){
 if(!/^SG-[a-f0-9-]{36}$/.test(tx))throw Error('Invalid transaction reference.');
 const intents=await db('sungira_payment_intents?tx_ref=eq.'+encodeURIComponent(tx)+'&select=*',null,'GET'),intent=intents[0];
 if(!intent||(actor&&intent.actor_id!==actor.id))throw Error('This payment does not belong to your account.');
 if(intent.collection_id!==process.env.PAYCHANGU_COLLECTION_ID)throw Error('This merchant account is not connected to this collection.');
 if(intent.confirmed)return{ok:true,alreadyConfirmed:true};
 const r=await fetch('https://api.paychangu.com/verify-payment/'+encodeURIComponent(tx),{headers:{Authorization:'Bearer '+process.env.PAYCHANGU_SECRET_KEY,Accept:'application/json'}});
 const out=await r.json(),data=out.data;
 if(!r.ok||out.status!=='success'||!data||data.status!=='success')return{ok:false,pending:true,message:'Payment is not confirmed by the provider yet. Please try Check payment again shortly.'};
 if(data.tx_ref!==tx||data.currency!=='MWK'||Number(data.amount)!==Number(intent.amount)||data.mode!=='live')throw Error('Provider verification did not match the expected reference, amount, currency or live mode. Contact your treasurer.');
 const fee=Number(data.charges);if(!Number.isFinite(fee)||fee<0||fee>Number(data.amount))throw Error('Provider charges could not be reconciled.');
 return await db('rpc/sungira_settle_payment',{transaction_ref:tx,verified_amount:Number(data.amount),verified_currency:data.currency,verified_mode:data.mode,provider_fee:fee});
}
exports.handler=async event=>{
 if(event.httpMethod!=='POST')return reply(405,{error:'Use POST'});
 if(!providerReady()||!process.env.SUPABASE_SERVICE_ROLE_KEY||!process.env.SUPABASE_URL)return reply(503,{error:'Online payment is not connected. Use the group payment instructions and submit your reference instead.'});
 try{
 const bearer=event.headers.authorization||event.headers.Authorization;if(!bearer)return reply(401,{error:'Please sign in.'});
 const ur=await fetch(process.env.SUPABASE_URL+'/auth/v1/user',{headers:{apikey:process.env.SUPABASE_SERVICE_ROLE_KEY,Authorization:bearer}});if(!ur.ok)return reply(401,{error:'Please sign in again.'});const user=await ur.json();if(!user.email_confirmed_at)return reply(403,{error:'Confirm your email first.'});
 const body=JSON.parse(event.body||'{}');if(body.action==='verify')return reply(200,await verify(body.tx_ref,user));
 if(body.action!=='checkout')return reply(400,{error:'Unknown payment action.'});
 if(body.id!==process.env.PAYCHANGU_COLLECTION_ID)return reply(403,{error:'This collection is not connected to the online merchant account.'});
 const amount=Number(body.amount);if(!Number.isFinite(amount)||amount<=0||amount>100000000000||Math.abs(amount*100-Math.round(amount*100))>0.0001)return reply(400,{error:'Enter a valid positive amount.'});
 const tx='SG-'+randomUUID();const reserved=await db('rpc/sungira_reserve_payment',{actor_id:user.id,actor_email:user.email,collection_id:body.id,member_id:body.member,amount,tx_ref:tx});
 const base=process.env.URL.replace(/\/$/,'');
 const r=await fetch('https://api.paychangu.com/payment',{method:'POST',headers:{Authorization:'Bearer '+process.env.PAYCHANGU_SECRET_KEY,'Content-Type':'application/json',Accept:'application/json'},body:JSON.stringify({amount:String(amount),currency:'MWK',tx_ref:tx,callback_url:base+'/?payment='+encodeURIComponent(tx),return_url:base+'/?payment='+encodeURIComponent(tx),email:user.email,first_name:user.user_metadata?.name||'Contributor',customization:{title:reserved.name,description:'Contribution to '+reserved.name},meta:JSON.stringify({collection_id:body.id,member_id:body.member})})});
 const out=await r.json(),link=out.data?.checkout_url;
 if(!r.ok||out.status!=='success'||typeof link!=='string')throw Error('Provider checkout could not be opened. A pending reference was saved; no money has been confirmed.');
 const checkout=new URL(link);if(checkout.protocol!=='https:'||!(checkout.hostname==='paychangu.com'||checkout.hostname.endsWith('.paychangu.com')))throw Error('The provider returned an unexpected checkout address.');
 return reply(200,{checkout_url:link,tx_ref:tx});
 }catch(err){return reply(400,{error:err.message||'The payment could not be processed.'})}
};
exports.verify=verify;
