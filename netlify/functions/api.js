'use strict';
const headers={'Content-Type':'application/json','Cache-Control':'no-store'};
const reply=(status,body)=>({statusCode:status,headers,body:JSON.stringify(body)});
exports.handler=async event=>{
 if(event.httpMethod!=='POST')return reply(405,{error:'Use POST'});
 const url=process.env.SUPABASE_URL,key=process.env.SUPABASE_SERVICE_ROLE_KEY;
 if(!url||!key)return reply(503,{error:'Shared accounts are not connected yet. The organiser must complete the setup guide.'});
 try{
  if(Buffer.byteLength(event.body||'')>350000)return reply(413,{error:'This attachment is too large. Use a smaller picture (up to 200 KB).'});
  const body=JSON.parse(event.body||'{}'),action=body.action;
  let actor=null,email=null;
  const bearer=event.headers.authorization||event.headers.Authorization;
  if(bearer){const userResponse=await fetch(url+'/auth/v1/user',{headers:{apikey:key,Authorization:bearer}});if(!userResponse.ok)return reply(401,{error:'Please sign in again.'});const user=await userResponse.json();if(!user.email_confirmed_at)return reply(403,{error:'Please confirm your email before using shared groups.'});actor=user.id;email=user.email;}
  if(action!=='public'&&!actor)return reply(401,{error:'Please sign in to continue.'});
  const seedAllowed=!!email&&!!process.env.SEED_OWNER_EMAIL&&email.toLowerCase()===process.env.SEED_OWNER_EMAIL.trim().toLowerCase();
  if(action==='seed_status')return reply(200,{allowed:seedAllowed});
  if((action==='church_import'||action==='create'&&body.data?.seed)&&!seedAllowed)return reply(403,{error:'This prepared church list is reserved for the designated organiser.'});
  if(action==='church_import'||action==='create'&&body.data?.seed)body.data={...body.data,churchSeed:require('../../database/church-v6.json')};
  const response=await fetch(url+'/rest/v1/rpc/sungira_action',{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify({actor_id:actor,actor_email:email,action_name:action,payload:body.data||{}})});
  const result=await response.json();if(!response.ok){const message=result.message||'The request could not be completed.';return reply(result.code==='42501'?403:400,{error:message})}
  return reply(200,result);
 }catch(error){console.error('Sungira request failed:',error.name);return reply(500,{error:'Unable to connect. Please try again. Do not submit the same payment twice.'})}
};
