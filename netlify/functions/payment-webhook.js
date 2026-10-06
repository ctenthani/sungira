'use strict';
const {createHmac,timingSafeEqual}=require('node:crypto');
const {verify}=require('./payment');
exports.handler=async event=>{
 if(event.httpMethod!=='POST')return{statusCode:405,body:'Use POST'};
 const secret=process.env.PAYCHANGU_WEBHOOK_SECRET;
 if(!secret)return{statusCode:503,body:'Webhook not configured'};
 const raw=event.isBase64Encoded?Buffer.from(event.body||'','base64'):Buffer.from(event.body||'');
 if(raw.length>100000)return{statusCode:413,body:'Payload too large'};
 const sig=event.headers.signature||event.headers.Signature||'';
 if(!/^[a-f0-9]{64}$/i.test(sig))return{statusCode:401,body:'Invalid signature'};
 const expected=createHmac('sha256',secret).update(raw).digest();
 if(!timingSafeEqual(expected,Buffer.from(sig,'hex')))return{statusCode:401,body:'Invalid signature'};
 try{
  const payload=JSON.parse(raw.toString('utf8')),tx=payload.tx_ref||payload.data?.tx_ref;
  if(typeof tx!=='string'||!/^SG-[a-f0-9-]{36}$/.test(tx))return{statusCode:200,body:'Event ignored'};
  if((payload.status||payload.data?.status)!=='success')return{statusCode:200,body:'No successful payment to confirm'};
  const out=await verify(tx,null);
  return{statusCode:out.ok?200:503,body:out.ok?'Verified':'Awaiting verification'};
 }catch(err){console.error('Payment webhook verification failed:',err.name);return{statusCode:503,body:'Verification temporarily unavailable'}}
};
