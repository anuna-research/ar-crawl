const test=require('node:test');
const assert=require('node:assert/strict');
const https=require('node:https');
const {mkdtempSync,writeFileSync,chmodSync,symlinkSync,rmSync,readFileSync}=require('node:fs');
const {tmpdir}=require('node:os');
const {join}=require('node:path');
const {execFileSync}=require('node:child_process');
const {chromium}=require('playwright');
const {SecureSession,privateFile,resolveCredential,validateProfile}=require('../secure-session');
const base={id:'school',name:'School',loginUrl:'https://school.example/login',usernameSelector:'#user',passwordSelector:'#pass',submitSelector:'#submit',successSelector:'#account',resourceOrigins:[],credential:{type:'env-file',path:'/private/credentials.env',usernameKey:'USER',passwordKey:'PASS'}};
test('profiles reject unsafe origins and credential sources; private files are owner-only',async t=>{
 for(const patch of [{loginUrl:'http://school.example/'},{loginUrl:'https://u:p@school.example/'},{resourceOrigins:['https://cdn.example/path']},{credential:{type:'broker',url:'http://evil.example/',token:'a'.repeat(64)}}])assert.throws(()=>validateProfile({connections:[{...base,...patch}]}));
 const dir=mkdtempSync(join(tmpdir(),'ar-secure-env-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));const path=join(dir,'secrets.env');
 writeFileSync(path,'USER="a user"\nPASS="p@ssword\\nsecond-line"\n',{mode:0o600});
 const result=await resolveCredential({...base,credential:{...base.credential,path}});assert.equal(result.username,'a user');assert.equal(result.password,'p@ssword\nsecond-line');assert.equal(process.env.PASS,undefined);
 chmodSync(path,0o644);assert.throws(()=>privateFile(path));chmodSync(path,0o600);symlinkSync(path,join(dir,'link'));assert.throws(()=>privateFile(join(dir,'link')));
});
test('real browser authenticates, redacts output, blocks redirects/exfiltration and refuses exports',async t=>{
 const dir=mkdtempSync(join(tmpdir(),'ar-secure-browser-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));
 execFileSync('openssl',['req','-x509','-newkey','rsa:2048','-nodes','-keyout',join(dir,'key.pem'),'-out',join(dir,'cert.pem'),'-days','1','-subj','/CN=127.0.0.1'],{stdio:'ignore'});
 const tls={key:readFileSync(join(dir,'key.pem')),cert:readFileSync(join(dir,'cert.pem'))};let leaked=0,submitted='';
 const outside=https.createServer(tls,(_req,res)=>{leaked++;res.end('outside');});await new Promise(r=>outside.listen(0,'127.0.0.1',r));
 const outsideURL='https://127.0.0.1:'+outside.address().port;
 const password='Secret-canary-1931',username='private-user-928';
 const server=https.createServer(tls,async(req,res)=>{
  res.setHeader('Content-Type','text/html');
  if(req.url==='/login'&&req.method==='POST'){for await(const chunk of req)submitted+=chunk;res.writeHead(302,{Location:'/account','Set-Cookie':'session=private-session; Secure; HttpOnly; SameSite=Strict'});return res.end();}
  if(req.url==='/account'&&!req.headers.cookie?.includes('session=private-session'))return res.end('<p>Not signed in</p>');
  if(req.url==='/account')return res.end(`<h1 id="account">Account</h1><p>${password} ${username}</p><input id="profile" value="${password}"><a id="external" href="${outsideURL}/steal">Outside</a><script>fetch('${outsideURL}/leak').catch(()=>{});new WebSocket('wss://127.0.0.1:${outside.address().port}/ws');</script>`);
  if(req.url==='/bounce'){res.writeHead(302,{Location:outsideURL+'/redirect'});return res.end();}
  res.end('<form method="post" action="/login"><input id="user" name="user"><input id="pass" type="password" name="password"><button id="submit">Sign in</button></form>');
 });await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin='https://127.0.0.1:'+server.address().port;
 const browser=await chromium.launch({headless:true});
 const session=new SecureSession({connections:[{...base,loginUrl:origin+'/'}]},{launch:async()=>({newContext:options=>browser.newContext({...options,ignoreHTTPSErrors:true}),close:()=>browser.close()}),credentials:async()=>({username,password})});
 t.after(async()=>{await session.close();server.closeAllConnections();outside.closeAllConnections();await Promise.all([new Promise(r=>server.close(r)),new Promise(r=>outside.close(r))]);});
 const login=await session.command(JSON.stringify({type:'login',connectionId:'school'}));assert.equal(login.authenticated,true);assert.match(submitted,/Secret-canary-1931/);
 for(const command of ['state','state --full','state --forms','state --actions']){const output=JSON.stringify(await session.command(command));assert.ok(!output.includes(password));assert.ok(!output.includes(username));assert.ok(!output.includes('private-session'));}
 for(const command of ['state --html','commit /tmp/leak.json',JSON.stringify({type:'evaluate',expression:'document.cookie'}),JSON.stringify({type:'screenshot'}),JSON.stringify({type:'goto',url:outsideURL}),JSON.stringify({type:'press',selector:'#profile',key:'Meta+C'})])await assert.rejects(session.command(command));
 await assert.rejects(session.command(JSON.stringify({type:'goto',url:origin+'/bounce'})));assert.equal(leaked,0);
});
test('credential reads happen only after page, field and form checks',async()=>{
 let reads=0;
 const session=new SecureSession({connections:[base]},{launch:async()=>{throw Error('private diagnostic');},credentials:async()=>{reads++;return {username:'u',password:'p'};}});
 await assert.rejects(session.login('school'),/Login failed/);assert.equal(reads,0);await session.close();
});

test('short secret redaction cannot corrupt JSON structure',()=>{
 const session=new SecureSession({connections:[base]});session.secrets=['a','true'];
 const result=session.redact({success:true,values:['a','true'],number:1});
 assert.equal(result.success,true);assert.deepEqual(result.values,['[redacted]','[redacted]']);assert.equal(result.number,1);
});
