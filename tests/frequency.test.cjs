const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync('cloud.js','utf8');
const context={};vm.createContext(context);
vm.runInContext(source.match(/function paymentFrequency\(d\)\{[^\n]+/)[0],context);
vm.runInContext(source.match(/function monthsHTML\(d,amount,cumulative=true\)\{[^\n]+/)[0],context);
test('once-off and as-agreed collections have no monthly coverage, even with stale amounts',()=>{
 for(const paymentFrequency of ['Once-off','As agreed'])assert.equal(context.monthsHTML({paymentFrequency,monthlyAmount:100},200),'');
});
test('unclassified existing collections remain unspecified; explicit historical monthly amounts are preserved',()=>{
 assert.equal(context.paymentFrequency({monthlyAmount:0}),'Not specified');
 assert.equal(context.paymentFrequency({monthlyAmount:100}),'Monthly');
 assert.equal(context.paymentFrequency({paymentFrequency:'Once-off',monthlyAmount:100}),'Once-off');
});
test('monthly coverage uses agreed rate and recognises partial payments',()=>{
 context.money=n=>'MK '+n;
 const html=context.monthsHTML({paymentFrequency:'Monthly',monthlyAmount:100,start:'2026-01-01'},250);
 assert.match(html,/2 full months/);assert.match(html,/MK 50 towards next month/);
 assert.equal(context.monthsHTML({paymentFrequency:'Monthly',monthlyAmount:0},200),'');
});
