// Run: node tests/comments.test.js
// Guards against a block comment that is never closed: it silently swallows every function below it (this once switched off
// "publish a post" on the live site). A comment that starts a line must close before the next top-level declaration.
const fs=require('fs'), path=require('path');
const lines=fs.readFileSync(path.join(__dirname,'..','index.html'),'utf8').split('\n');
let bad=0, open=null;
lines.forEach((ln,i)=>{
  if(open===null){
    if(/^\s*\/\*/.test(ln)&&!/\*\//.test(ln.slice(ln.indexOf('/*')+2))) open=i+1;       // comment opened and not closed on the same line
  } else if(/\*\//.test(ln)){ open=null; }
  else if(/^(async function |function |let |const |class )/.test(ln)){ console.error('FAIL: the comment opened on line '+open+' is still open at line '+(i+1)+': '+ln.slice(0,70)); bad++; open=null; }
});
if(open!==null){ console.error('FAIL: the comment opened on line '+open+' is never closed'); bad++; }
if(bad) process.exit(1); console.log('ok: no unclosed block comments swallow code');
