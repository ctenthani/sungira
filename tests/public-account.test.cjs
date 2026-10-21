const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const ctx=vm.createContext({esc:s=>String(s??'').replaceAll('<','&lt;'),money:n=>'MK '+Number(n).toFixed(2),stat:(label,n)=>label+':'+Number(n).toFixed(2)});vm.runInContext(fs.readFileSync('public-account.js','utf8'),ctx);
test('public account shows income and outflow types, including principal, without private fields',()=>{
 const html=ctx.publicAccountHTML({balance:70,accountEntries:[{date:'2026-10-21',kind:'Contribution',amount:100,note:'PRIVATE',ref:'SECRET'},{date:'2026-10-21',kind:'Loan disbursement',amount:30}]});
 assert.match(html,/Cash received:100.00/);assert.match(html,/Cash paid out:30.00/);assert.match(html,/Loan disbursement/);assert.ok(!html.includes('PRIVATE'));assert.ok(!html.includes('SECRET'));
});
test('public report handles an empty ledger and safely escapes categories',()=>{
 const html=ctx.publicAccountHTML({balance:0,accountEntries:[]});assert.match(html,/No confirmed income/);assert.match(html,/No confirmed expenditure/);
 assert.ok(!ctx.publicAccountHTML({balance:0,accountEntries:[{kind:'Expense',amount:1,category:'<script>'}]}).includes('<script>'));
});
