const test=require('node:test');
const assert=require('node:assert/strict');
const {spawn}=require('node:child_process');
const {mkdtempSync,writeFileSync,rmSync}=require('node:fs');
const {join,resolve}=require('node:path');
const {tmpdir}=require('node:os');
const {createInterface}=require('node:readline');
test('actual Racket CLI selects secure driver without starting legacy service',async t=>{
 const dir=mkdtempSync(join(tmpdir(),'ar-secure-cli-')),profile=join(dir,'profile.json');t.after(()=>rmSync(dir,{recursive:true,force:true}));
 writeFileSync(profile,JSON.stringify({connections:[{id:'school',name:'School',loginUrl:'https://school.example/',usernameSelector:'#user',passwordSelector:'#pass',submitSelector:'#submit',successSelector:'#account',credential:{type:'env-file',path:join(dir,'missing.env'),usernameKey:'USER',passwordKey:'PASS'}}]}),{mode:0o600});
 const root=resolve(__dirname,'../..');
 const child=spawn('racket',[join(root,'src/cli.rkt'),'session','--secure-profile',profile],{env:{...process.env,PLAYWRIGHT_SERVICE_DIR:join(root,'playwright-service')},stdio:['pipe','pipe','pipe']});
 t.after(()=>child.kill());let stderr='';child.stderr.on('data',s=>stderr+=s);const exited=new Promise(resolve=>child.once('exit',resolve));
 const lines=createInterface({input:child.stdout})[Symbol.asyncIterator]();const read=async()=>JSON.parse((await lines.next()).value);
 assert.equal((await read()).mode,'secure');child.stdin.write('help\n');assert.equal((await read()).recording,false);
 child.stdin.write('commit /tmp/forbidden.json\n');assert.equal((await read()).success,false);
 child.stdin.end('exit\n');assert.equal((await read()).closed,true);assert.equal(await exited,0);assert.equal(stderr,'');
});
