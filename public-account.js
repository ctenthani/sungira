/* Public report consumes only the server's token-checked, allowlisted projection. */
function publicAccountHTML(d){
 const incoming=['Contribution','Group income','Loan repayment','Investment proceeds'];
 const outgoing=['Expense','Mkhonde payout','Investment placement','Loan disbursement','Savings withdrawal'];
 const entries=Array.isArray(d.accountEntries)?d.accountEntries:null;
 const income=entries?entries.filter(e=>incoming.includes(e.kind)):[];
 const spending=entries?entries.filter(e=>outgoing.includes(e.kind)):(d.expenses||[]).map(e=>({...e,kind:'Expense'}));
 const total=rows=>rows.reduce((n,e)=>n+Math.round(Number(e.amount||0)*100),0)/100;
 const table=(rows,empty)=>`<div class="table"><table><thead><tr><th>Date</th><th>What it was for</th><th>Amount (MK)</th></tr></thead><tbody>${rows.slice().sort((a,b)=>String(b.date).localeCompare(String(a.date))).map(e=>`<tr><td>${esc(e.date||'—')}</td><td>${esc(e.kind)}${e.category&&e.category!==e.kind?' · '+esc(e.category):''}</td><td>${money(e.amount)}</td></tr>`).join('')||`<tr><td colspan="3">${empty}</td></tr>`}</tbody></table></div>`;
 return `<section class="card" id="public-account" style="margin:20px 0"><h2>Our money</h2><p>Payments checked by the group officer.</p><div class="stats">${stat('Money received',entries?total(income):d.collected)}${stat('Money spent',total(spending))}${stat('Money left',d.balance)}</div><details class="public-fold"><summary>Money received · see payments</summary>${entries?table(income,'No confirmed income yet.'):`<p>Confirmed contributions: <strong>${money(d.collected)}</strong></p><p class="muted">Detailed income rows are not available yet.</p>`}</details><details class="public-fold"><summary>Money spent · see spending</summary>${table(spending,'No confirmed expenditure yet.')}</details><button id="publicPrint">Print / save PDF</button></section>`;
}
