const fs=require('node:fs');
fs.mkdirSync('public',{recursive:true});
for(const file of ['index.html','cloud.js','mobile.js','reports.js','qrcode.js','style.css','local.html','app.js','404.html','bank-core.js','bank-ui.js','receipt-pdf.js'])fs.copyFileSync(file,'public/'+file);
console.log('Sungira static assets ready. Private setup files are excluded.');

fs.mkdirSync('public/downloads',{recursive:true});
fs.copyFileSync('downloads/sungira-preview.apk','public/downloads/sungira-preview.apk');

fs.mkdirSync('public/vendor',{recursive:true});fs.copyFileSync('node_modules/jspdf/dist/jspdf.umd.min.js','public/vendor/jspdf.umd.min.js');fs.copyFileSync('node_modules/jspdf/LICENSE','public/vendor/JSPDF-LICENSE.txt');fs.copyFileSync('fonts/OFL.txt','public/vendor/NOTO-OFL.txt');fs.writeFileSync('public/vendor/receipt-font.js','window.SungiraReceiptFont='+JSON.stringify(fs.readFileSync('fonts/NotoSans-Regular.ttf').toString('base64'))+';');
