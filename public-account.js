/* Public report consumes only the server's token-checked, allowlisted projection. */
function publicAccountHTML(d){
 const incoming=['Contribution','Group income','Loan repayment','Investment proceeds'];
 const outgoing=['Expense','Mkhonde payout','Investment placement','Loan disbursement','Savings withdrawal'];
 const entries=Array.isArray(d.accountEntries)?d.accountEntries:null;
 const income=entries?entries.filter(e=>incoming.includes(e.kind)):[];
 const spending=entries?entries.filter(e=>outgoing.includes(e.kind)):(d.expenses||[]).map(e=>({...e,kind:'Expense'}));
 const total=rows=>rows.reduce((n,e)=>n+Math.round(Number(e.amount||0)*100),0)/100;
 const table=(rows,empty)=>`<div class="table"><table><thead><tr><th>Date</th><th>Type / category</th><th>Amount (MK)</th></tr></thead><tbody>${rows.slice().sort((a,b)=>String(b.date).localeCompare(String(a.date))).map(e=>`<tr><td>${esc(e.date||'—')}</td><td>${esc(e.kind)}${e.category&&e.category!==e.kind?' · '+esc(e.category):''}</td><td>${money(e.amount)}</td></tr>`).join('')||`<tr><td colspan="3">${empty}</td></tr>`}</tbody></table></div>`;
 return `<section class="card" id="public-account" style="margin:20px 0"><h2>Income &amp; expenditure</h2><p>Confirmed transactions for this activity · ${esc(d.start||'Start')} to date.</p><div class="stats">${stat('Cash received',entries?total(income):d.collected)}${stat('Cash paid out',total(spending))}${stat('Cash remaining',d.balance)}</div><h3>Income received</h3>${entries?table(income,'No confirmed income yet.'):`<p>Confirmed contributions: <strong>${money(d.collected)}</strong></p><p class="muted">Detailed income rows are not available yet.</p>`}<h3>Expenditure &amp; cash outflows</h3>${table(spending,'No confirmed expenditure yet.')}<p class="muted">Loan and investment principal movements are labelled separately from operating income and expenses. Pending and reversed transactions are excluded.</p><button id="publicPrint">Print / save PDF</button></section>`;
}
