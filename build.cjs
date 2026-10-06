const fs=require('node:fs');
fs.mkdirSync('public',{recursive:true});
for(const file of ['index.html','cloud.js','mobile.js','qrcode.js','style.css','local.html','app.js','404.html'])fs.copyFileSync(file,'public/'+file);
console.log('Sungira static assets ready. Private setup files are excluded.');

fs.mkdirSync('public/downloads',{recursive:true});
fs.copyFileSync('downloads/sungira-preview.apk','public/downloads/sungira-preview.apk');
