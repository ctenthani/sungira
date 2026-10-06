const fs=require('node:fs');
fs.mkdirSync('public',{recursive:true});
for(const file of ['index.html','cloud.js','style.css','local.html','app.js','404.html'])fs.copyFileSync(file,'public/'+file);
console.log('Sungira static assets ready. Private setup files are excluded.');
