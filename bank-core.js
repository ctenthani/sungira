(function(root){
'use strict';
const cents=n=>Math.round(Number(n||0)*100),amount=n=>n/100;
function bankModel(d,asOf){
 const rows=(d.ledger||[]).filter(e=>e.status==='Confirmed'),sum=(filter,field='amount')=>rows.filter(filter).reduce((s,e)=>s+cents(e[field]),0);
 const savings=sum(e=>e.kind==='Contribution'),withdrawals=sum(e=>e.kind==='Savings withdrawal'),interest=sum(e=>e.kind==='Loan repayment','interestPaid'),income=sum(e=>e.kind==='Group income'),expenses=sum(e=>['Expense','Mkhonde payout'].includes(e.kind)),loss=sum(e=>e.kind==='Loan adjustment','principalWrittenOff');
 const capital=sum(e=>e.kind==='Investment placement')-sum(e=>e.kind==='Investment proceeds','basisReleased'),gain=sum(e=>e.kind==='Investment proceeds')-sum(e=>e.kind==='Investment proceeds','basisReleased');
 const principal=sum(e=>e.kind==='Loan disbursement')-sum(e=>e.kind==='Loan repayment','principalPaid')-loss;
 const incoming=sum(e=>['Contribution','Group income','Loan repayment','Investment proceeds'].includes(e.kind)),outgoing=sum(e=>['Expense','Mkhonde payout','Loan disbursement','Investment placement','Savings withdrawal'].includes(e.kind));
 const cash=incoming-outgoing,surplus=income+interest+gain-expenses-loss,netSavings=savings-withdrawals,assets=cash+capital+principal;
 const multiple=Number(d.bank?.multiple||1);
 const members=(d.members||[]).map(m=>{
  const saved=sum(e=>e.kind==='Contribution'&&e.member===m.id)-sum(e=>e.kind==='Savings withdrawal'&&e.member===m.id);
  let outstanding=0,interestDue=0,overdue=0;
  for(const loan of d.loans||[]){if(loan.member!==m.id)continue;const entries=rows.filter(e=>e.entityId===loan.id);if(!entries.some(e=>e.kind==='Loan disbursement'))continue;const total=key=>entries.reduce((s,e)=>s+cents(e[key]),0),p=cents(loan.principal)-total('principalPaid')-total('principalWrittenOff'),i=cents(loan.agreedInterest)-total('interestPaid')-total('interestWaived');outstanding+=p;interestDue+=i;const due=(loan.schedule||[]).filter(e=>e.due<asOf);overdue+=Math.max(0,due.reduce((s,e)=>s+cents(e.principal),0)-total('principalPaid')-total('principalWrittenOff'))+Math.max(0,due.reduce((s,e)=>s+cents(e.interest),0)-total('interestPaid')-total('interestWaived'));}
  const ceiling=Math.floor(saved*multiple),capacity=Math.max(0,ceiling-outstanding),unencumbered=Math.max(0,saved-Math.ceil(outstanding/multiple));
  return {id:m.id,name:m.name,savings:amount(saved),principal:amount(outstanding),interest:amount(interestDue),overdue:amount(overdue),limit:amount(ceiling),capacity:amount(Math.max(0,Math.min(capacity,cash))),withdrawable:amount(Math.max(0,Math.min(cash,unencumbered)))};
 });
 return {savings:amount(netSavings),deposits:amount(savings),withdrawals:amount(withdrawals),cash:amount(cash),loanPrincipal:amount(principal),investmentCapital:amount(capital),interestReceived:amount(interest),surplus:amount(surplus),assets:amount(assets),difference:amount(assets-netSavings-surplus),unallocatedSavings:amount(netSavings-members.reduce((s,m)=>s+cents(m.savings),0)),members};
}
function scenario({capital,months,rate,basis,fees=0,loss=0}){
 for(const x of [capital,months,rate,fees,loss])if(!Number.isFinite(Number(x)))throw Error('Enter finite numbers in every scenario field.');
 capital=Number(capital);months=Number(months);rate=Number(rate);fees=Number(fees);loss=Number(loss);
 if(capital<=0||capital>1e11||!Number.isInteger(months)||months<1||months>120||rate<0||rate>100||fees<0||fees>capital||loss<0||loss>100||!['Annual simple','Monthly simple','Annual rate, monthly compounding','Whole-term return'].includes(basis))throw Error('Check capital, months (1–120), rate (0–100%), fees and principal loss (0–100%).');
 let gross=capital*(basis==='Annual simple'?rate/100*months/12:basis==='Monthly simple'?rate/100*months:basis==='Whole-term return'?rate/100:Math.pow(1+rate/1200,months)-1);
 const principalLoss=capital*loss/100,ending=capital+gross-fees-principalLoss,net=ending-capital;
 if(ending<0||!Number.isSafeInteger(cents(ending)))throw Error('Costs exceed the remaining value, or the result exceeds the calculator range. Model additional debt separately.');
 return {gross:amount(cents(gross)),fees:amount(cents(fees)),principalLoss:amount(cents(principalLoss)),ending:amount(cents(ending)),net:amount(cents(net)),returnPercent:net/capital*100,annualisedPercent:(Math.pow(ending/capital,12/months)-1)*100};
}
const api={bankModel,scenario};if(typeof module==='object'&&module.exports)module.exports=api;else root.SungiraBank=api;
})(typeof globalThis==='object'?globalThis:this);
