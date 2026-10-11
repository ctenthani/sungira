'use strict';
// Bound both response headers and body parsing. Never retry financial writes here.
async function requestJson(url, options={}, timeoutMs=12000) {
 const controller=new AbortController();
 const timer=setTimeout(()=>controller.abort(),timeoutMs);
 try {
  const response=await fetch(url,{...options,signal:controller.signal});
  return {ok:response.ok,status:response.status,body:await response.json()};
 } catch(error) {
  if(controller.signal.aborted)throw Object.assign(Error('The connection timed out. Check the latest records before trying again.'),{name:'TimeoutError'});
  throw error;
 } finally {clearTimeout(timer)}
}
module.exports={requestJson};
