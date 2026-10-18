(function(root){
'use strict';
function receiptPdf(r,jsPDF,font){
 const doc=new jsPDF({unit:'mm',format:'a4',compress:true,putOnlyUsedFonts:true});
 if(font){doc.addFileToVFS('NotoSans.ttf',font);doc.addFont('NotoSans.ttf','NotoSans','normal');doc.setFont('NotoSans');}
 doc.setProperties({title:'Sungira receipt '+r.number,subject:r.kind||'Confirmed contribution',author:r.groupName||'Sungira'});
 const cash=n=>'MK '+Number(n||0).toLocaleString('en-MW',{minimumFractionDigits:2,maximumFractionDigits:2});
 let y=25;const left=22,width=166,green=[23,63,53];
 function line(text,size=10,gap=5){doc.setFontSize(size);const lines=doc.splitTextToSize(String(text??''),width);for(const textLine of lines){if(y+gap>265){doc.addPage();y=25;}doc.text(textLine,left,y);y+=gap;}return y;}
 function rule(){doc.setDrawColor(...green);doc.line(left,y,left+width,y);y+=8;}
 doc.setTextColor(...green);line('SUNGIRA | OFFICIAL RECEIPT',11,6);y+=4;line(r.groupName||'Group',21,9);line(r.activity||'',11,6);y+=3;rule();
 const withdrawal=r.kind==='Savings withdrawal',repayment=r.kind==='Loan repayment';
 doc.setTextColor(35,45,55);line(withdrawal?'SAVINGS RETURNED TO MEMBER':repayment?'LOAN REPAYMENT RECEIVED':'CONTRIBUTION RECEIVED',12,7);y+=3;
 line((withdrawal?'Paid to: ':'Received from: ')+(r.contributor||'Member'),12,6);y+=3;
 for(const [label,value] of [['Receipt number',r.number],['Transaction date',r.date],['Method',r.method],['Reference',r.reference||'Cash / no external reference']]){line(label.toUpperCase(),8,4);line(value,11,6);y+=2;}
 y+=2;line(cash(r.amount),23,12);y+=4;
 if(repayment){line('Principal received: '+cash(r.principalPaid));line('Interest received by group: '+cash(r.interestPaid));y+=4;}
 if(Number(r.monthlyAmount)>0){line('Monthly contribution: '+cash(r.monthlyAmount));line('Total paid at issue: '+cash(r.totalPaidAtIssue));line('Full months covered at issue: '+r.monthsCovered);line('Partial next month: '+cash(r.partialMonth));y+=4;}
 rule();line('Acknowledged by: '+r.acknowledgedBy,10,5);
 const acknowledged=new Date(r.acknowledgedAt);line('Acknowledged: '+(Number.isFinite(acknowledged.getTime())?acknowledged.toLocaleString('en-GB',{timeZone:'Africa/Blantyre'})+' (Malawi time)':String(r.acknowledgedAt||'')),9,5);
 y+=5;line(withdrawal?'This acknowledges the savings paid back to the member.':repayment?'Principal restores group capital. Interest belongs to the group.':'Thank you for your contribution.',10,5);line('A later reversal or void invalidates this receipt. Keep the full receipt number for verification.',9,5);
 const pages=doc.getNumberOfPages();for(let page=1;page<=pages;page++){doc.setPage(page);doc.setFontSize(8);doc.setTextColor(95,110,110);doc.text('Sungira | Page '+page+' of '+pages,22,282);}
 return new Uint8Array(doc.output('arraybuffer'));
}
if(typeof module==='object'&&module.exports){module.exports={receiptPdf};return;}
root.SungiraReceiptPdf={receiptPdf};
function safeFilename(number){return String(number||'receipt').replace(/[^A-Za-z0-9._-]/g,'_').slice(0,105)+'.pdf';}
function browserDownload(bytes,name){const url=URL.createObjectURL(new Blob([bytes],{type:'application/pdf'})),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),30000);}
function nativePdf(bytes,name,share,text){if(!root.SungiraAndroid)return false;if(!SungiraAndroid.supportsPdf||!SungiraAndroid.supportsPdf()){toast('Update the Sungira Android preview from the site footer for PDF attachments, or open Sungira in your browser.');return true;}let binary='';for(const byte of bytes)binary+=String.fromCharCode(byte);SungiraAndroid.exportFile(btoa(binary),name,'application/pdf',share,text);return true;}
root.attachPdfReceipt=function(r){
 const target=document.querySelector('#receiptWhatsApp');if(!target)return;
 const bytes=receiptPdf(r,root.jspdf.jsPDF,root.SungiraReceiptFont),name=safeFilename(r.number),text='Sungira receipt '+r.number+' · '+r.groupName;
 target.textContent='Share PDF · choose WhatsApp';
 const downloadButton=document.querySelector('#receiptDownload');downloadButton.textContent='Download PDF receipt';downloadButton.onclick=()=>{if(!nativePdf(bytes,name,false,''))browserDownload(bytes,name);};
 const hint=document.createElement('p');hint.className='muted';hint.setAttribute('role','status');hint.textContent='Choose WhatsApp and the recipient in your device share sheet. If file sharing is unavailable, download the PDF and attach it as a document in WhatsApp.';target.parentElement.after(hint);
 target.onclick=async()=>{try{if(nativePdf(bytes,name,true,text))return;const file=new File([bytes],name,{type:'application/pdf'});if(navigator.canShare?.({files:[file]})&&navigator.share){await navigator.share({files:[file],title:'Sungira receipt',text});hint.textContent='The receipt was handed to the share sheet. Check WhatsApp to confirm sending.';}else{browserDownload(bytes,name);hint.textContent='PDF downloaded. In WhatsApp, choose Attach → Document and select '+name+'. No message was sent automatically.';}}catch(error){if(error.name==='AbortError'){hint.textContent='Sharing cancelled. No automatic resend.';return;}hint.textContent='File sharing could not open. Use Download PDF receipt and attach it in WhatsApp.';}};
};
})(typeof globalThis==='object'?globalThis:this);
