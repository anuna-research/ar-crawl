const test=require('node:test');
const assert=require('node:assert/strict');
const https=require('node:https');
const {mkdtempSync,writeFileSync,chmodSync,symlinkSync,rmSync,readFileSync}=require('node:fs');
const {tmpdir}=require('node:os');
const {join}=require('node:path');
const {execFileSync}=require('node:child_process');
const {chromium}=require('playwright');
const {SecureSession,privateFile,resolveCredential,resolveSensitiveField,validateProfile}=require('../secure-session');
const base={id:'school',name:'School',loginUrl:'https://school.example/login',usernameSelector:'#user',passwordSelector:'#pass',submitSelector:'#submit',successSelector:'#account',resourceOrigins:[],credential:{type:'env-file',path:'/private/credentials.env',usernameKey:'USER',passwordKey:'PASS'}};
test('profiles reject unsafe origins and credential sources; private files are owner-only',async t=>{
 for(const patch of [{loginUrl:'http://school.example/'},{loginUrl:'https://u:p@school.example/'},{resourceOrigins:['https://cdn.example/path']},{credential:{type:'broker',url:'http://evil.example/',token:'a'.repeat(64)}}])assert.throws(()=>validateProfile({connections:[{...base,...patch}]}));
 const dir=mkdtempSync(join(tmpdir(),'ar-secure-env-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));const path=join(dir,'secrets.env');
 writeFileSync(path,'USER="a user"\nPASS="p@ssword\\nsecond-line"\n',{mode:0o600});
 const result=await resolveCredential({...base,credential:{...base.credential,path}});assert.equal(result.username,'a user');assert.equal(result.password,'p@ssword\nsecond-line');assert.equal(process.env.PASS,undefined);
 assert.equal(await resolveSensitiveField(base,{id:'private',source:{type:'env-file',path,key:'USER'}}),'a user');
 await assert.rejects(resolveSensitiveField(base,{id:'missing',source:{type:'env-file',path,key:'MISSING'}}));
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
  if(req.url==='/sensitive')return res.end('<form method=post><input id=card><input id=hidden type=hidden><input id=readonly readonly><button>Pay</button></form><p id=echo></p><script>document.querySelector("#card").oninput=e=>document.querySelector("#echo").textContent=e.target.value.split("").join(" " )</script>');
  if(req.url==='/bounce'){res.writeHead(302,{Location:outsideURL+'/redirect'});return res.end();}
  res.end('<form method="post" action="/login"><input id="user" name="user" autocomplete="username"><input id="pass" type="password" name="password" autocomplete="current-password"><button id="submit">Sign in</button></form>');
 });await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin='https://127.0.0.1:'+server.address().port;
 let sensitiveReads=0;
 const fields=['card','hidden','readonly'].map(id=>({id,url:origin+'/sensitive',selector:'#'+id,source:{type:'env-file',path:'/unused',key:'CARD'}}));
 const browser=await chromium.launch({headless:true});
 const session=new SecureSession({connections:[{...base,loginUrl:origin+'/',sensitiveFields:fields}]},{launch:async()=>({newContext:options=>browser.newContext({...options,ignoreHTTPSErrors:true}),close:()=>browser.close()}),credentials:async()=>({username,password}),sensitiveFields:async()=>{sensitiveReads++;return '4242424242424242';}});
 t.after(async()=>{await session.close();server.closeAllConnections();outside.closeAllConnections();await Promise.all([new Promise(r=>server.close(r)),new Promise(r=>outside.close(r))]);});
 const login=await session.command(JSON.stringify({type:'login',connectionId:'school'}));assert.equal(login.authenticated,true);assert.match(submitted,/Secret-canary-1931/);
 for(const command of ['state','state --full','state --forms','state --actions']){const output=JSON.stringify(await session.command(command));assert.ok(!output.includes(password));assert.ok(!output.includes(username));assert.ok(!output.includes('private-session'));}
 for(const command of ['state --html','commit /tmp/leak.json',JSON.stringify({type:'evaluate',expression:'document.cookie'}),JSON.stringify({type:'screenshot'}),JSON.stringify({type:'goto',url:outsideURL}),JSON.stringify({type:'press',selector:'#profile',key:'Meta+C'})])await assert.rejects(session.command(command));
 await assert.rejects(session.command(JSON.stringify({type:'goto',url:origin+'/bounce'})));assert.equal(leaked,0);
 await session.login('school');
 await session.command(JSON.stringify({type:'goto',url:origin+'/sensitive'}));
 await assert.rejects(session.command(JSON.stringify({type:'fillSecret',fieldId:'unknown'})));assert.equal(sensitiveReads,0);
 await assert.rejects(session.command(JSON.stringify({type:'fillSecret',fieldId:'card',selector:'#profile'})));assert.equal(sensitiveReads,0);
 const filled=await session.command(JSON.stringify({type:'fillSecret',fieldId:'card'}));assert.equal(filled.filled,true);assert.equal(filled.submissionAllowed,false);assert.equal(sensitiveReads,1);
 assert.equal(await session.page.locator('#card').inputValue(),'4242424242424242');
 assert.match(await session.page.locator('#echo').innerText(),/4 2 4 2/);
 for(const command of ['state','state --full','state --forms','state --actions'])assert.deepEqual(await session.command(command),await session.state());
 assert.ok(!JSON.stringify(await session.command('state --full')).includes('4 2'));
 for(const action of [{type:'click',selector:'button'},{type:'press',selector:'#card',key:'Enter'},{type:'goto',url:origin+'/'},{type:'fill',selector:'#card',value:'x'}])await assert.rejects(session.command(JSON.stringify(action)));
 await session.command(JSON.stringify({type:'fillSecret',fieldId:'card'}));assert.equal(sensitiveReads,2);
 for(const fieldId of ['hidden','readonly']){
  await session.login('school');await session.command(JSON.stringify({type:'goto',url:origin+'/sensitive'}));
  await assert.rejects(session.command(JSON.stringify({type:'fillSecret',fieldId})));assert.equal(sensitiveReads,2);assert.equal(session.page,null);
 }
 await session.login('school');
 await assert.rejects(session.command(JSON.stringify({type:'fillSecret',fieldId:'card'})));assert.equal(sensitiveReads,2);
 for(const mutation of ['get','external','duplicate']){
  await session.login('school');await session.command(JSON.stringify({type:'goto',url:origin+'/sensitive'}));
  await session.page.evaluate(({mutation,outsideURL})=>{
   const form=document.querySelector('form');
   if(mutation==='get')form.method='get';
   if(mutation==='external')form.action=outsideURL;
   if(mutation==='duplicate')form.append(document.querySelector('#card').cloneNode());
  },{mutation,outsideURL});
  await assert.rejects(session.command(JSON.stringify({type:'fillSecret',fieldId:'card'})));assert.equal(sensitiveReads,2);
 }
 await session.login('school');await session.command(JSON.stringify({type:'goto',url:origin+'/sensitive'}));
 session.sensitiveFields=async()=>{await session.page.evaluate(()=>document.querySelector('form').method='get');return 'never-filled-canary';};
 await assert.rejects(session.command(JSON.stringify({type:'fillSecret',fieldId:'card'})));assert.equal(session.page,null);
 delete session.profile.connections[0].usernameSelector;delete session.profile.connections[0].passwordSelector;
 assert.equal((await session.login('school')).authenticated,true);

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

test('sensitive fields require unique IDs, saved same-origin pages and private sources',()=>{
 const field={id:'card',url:'https://school.example/checkout',selector:'#card',source:{type:'env-file',path:'/private/card.env',key:'CARD'}};
 assert.doesNotThrow(()=>validateProfile({connections:[{...base,sensitiveFields:[field]}]}));
 for(const fields of [[field,field],[{...field,url:'https://other.example/checkout'}],[{...field,selector:''}],[{...field,source:{type:'env-file',path:'relative',key:'CARD'}}],[{...field,source:{type:'broker',url:'https://other.example',token:'a'.repeat(64)}}]])assert.throws(()=>validateProfile({connections:[{...base,sensitiveFields:fields}]}));
});

test('sensitive broker receives scoped IDs and bearer token, never a model-supplied value',async t=>{
 const http=require('node:http');let received;
 const server=http.createServer(async(req,res)=>{
  let body='';for await(const chunk of req)body+=chunk;
  received={body:JSON.parse(body),authorization:req.headers.authorization};
  res.setHeader('Content-Type','application/json');res.end(JSON.stringify({value:'synthetic-sensitive-value'}));
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 t.after(()=>{server.closeAllConnections();return new Promise(r=>server.close(r));});
 const source={type:'broker',url:'http://127.0.0.1:'+server.address().port+'/',token:'a'.repeat(64)};
 assert.equal(await resolveSensitiveField(base,{id:'card',source}),'synthetic-sensitive-value');
 assert.deepEqual(received,{body:{id:'school',fieldId:'card'},authorization:'Bearer '+source.token});
});

test('semantic discovery maps fields without reading secrets and rejects ambiguity and retargeting',async t=>{
 const browser=await chromium.launch({headless:true});t.after(()=>browser.close());
 const field={id:'personal-card',semanticType:'payment.card.number',url:'https://school.example/checkout',source:{type:'env-file',path:'/unused',key:'CARD'}};
 let reads=0;
 async function setup(html,patch={},provider){
  const session=new SecureSession({connections:[{...base,sensitiveFields:[{...field,...patch}]}]},{sensitiveFields:provider||(async()=>{reads++;return '4242424242424242';})});
  session.connection=session.profile.connections[0];session.context=await browser.newContext();session.page=await session.context.newPage();
  await session.context.route('**/*',route=>route.fulfill({contentType:'text/html',body:html}));
  await session.page.goto(field.url);return session;
 }
 for(const html of ['<input autocomplete="section-payment cc-number">','<label>Card number<input></label>','<span id=label>Credit card number</span><input aria-labelledby=label>','<input placeholder="Card number">']){
  const session=await setup('<form method=post>'+html+'</form>');
  const before=reads;assert.deepEqual(await session.command('{"type":"discoverFields"}'),{fields:[{fieldId:field.id,semanticType:field.semanticType,status:'matched'}],authorizedToRelease:false});assert.equal(reads,before);
  assert.equal((await session.command('{"type":"fillSecret","fieldId":"personal-card"}')).filled,true);
  assert.equal(await session.page.locator('input').inputValue(),'4242424242424242');
  await assert.rejects(session.command('{"type":"discoverFields"}'));await session.close();
 }
 for(const html of ['<input autocomplete=cc-number><input autocomplete=cc-number>','<input aria-label="Card number" autocomplete=email>','<input type=hidden autocomplete=cc-number>','<input readonly autocomplete=cc-number>','<input type=password autocomplete=cc-number>','<input autocomplete=cc-number disabled>']){
  const session=await setup(html);const before=reads;
  assert.equal((await session.discoverFields()).fields[0].status,'needs-configuration');
  await assert.rejects(session.fillSecret(field.id));assert.equal(reads,before);await session.close();
 }
 const address=await setup('<input autocomplete="billing postal-code"><input autocomplete="shipping postal-code">',{semanticType:'person.address.postalCode',context:'billing'});
 await address.fillSecret(field.id);assert.equal(await address.page.locator('[autocomplete="shipping postal-code"]').inputValue(),'');await address.close();
 const override=await setup('<input id=chosen><input autocomplete=cc-number>',{selector:'#chosen'});
 await override.fillSecret(field.id);assert.equal(await override.page.locator('#chosen').inputValue(),'4242424242424242');assert.equal(await override.page.locator('[autocomplete]').inputValue(),'');await override.close();
 for(const change of ['duplicate','replace','meaning']){
  let session;
  session=await setup('<input autocomplete=cc-number>',{},async()=>{
   await session.page.evaluate(change=>{
    const el=document.querySelector('input');
    if(change==='duplicate')el.after(el.cloneNode());
    if(change==='replace')el.replaceWith(el.cloneNode());
    if(change==='meaning')el.autocomplete='email';
   },change);return 'never-filled-secret';
  });
  await assert.rejects(session.fillSecret(field.id));assert.equal(session.page,null);await session.close();
 }
 assert.throws(()=>validateProfile({connections:[{...base,sensitiveFields:[{...field,semanticType:'unknown'}]}]}));
 assert.throws(()=>validateProfile({connections:[{...base,sensitiveFields:[{...field,context:'unknown'}]}]}));
});

test('automatic login requires a unique safe submit and a new authenticated marker',async t=>{
 const dir=mkdtempSync(join(tmpdir(),'ar-auto-login-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));
 execFileSync('openssl',['req','-x509','-newkey','rsa:2048','-nodes','-keyout',join(dir,'key.pem'),'-out',join(dir,'cert.pem'),'-days','1','-subj','/CN=127.0.0.1'],{stdio:'ignore'});
 let mode='ok',reads=0,submissions=0;
 const server=https.createServer({key:readFileSync(join(dir,'key.pem')),cert:readFileSync(join(dir,'cert.pem'))},async(req,res)=>{
  res.setHeader('Content-Type','text/html');
  if(req.method==='POST'){
   submissions++;for await(const chunk of req){};
   return res.end(mode==='no-marker'?'<h1>Something happened</h1>':mode==='mfa'?'<input autocomplete=one-time-code><a href=/logout>Log out</a>':'<h1>Account</h1><a href=/logout>Log out</a>');
  }
  res.end(`<form method=post><input autocomplete=email><input type=password autocomplete=current-password><button ${mode==='get'?'formmethod=get':''} ${mode==='external'?'formaction=https://outside.example/':''}>Log in</button>${mode==='ambiguous'?'<button>Other submit</button>':''}</form>${mode==='already'?'<a href=/logout>Log out</a>':''}`);
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>{server.closeAllConnections();return new Promise(r=>server.close(r));});
 const browser=await chromium.launch({headless:true});t.after(()=>browser.close());
 const {usernameSelector,passwordSelector,submitSelector,successSelector,...connection}=base;
 const create=()=>new SecureSession({connections:[{...connection,loginUrl:'https://127.0.0.1:'+server.address().port+'/'}]},{launch:async()=>({newContext:options=>browser.newContext({...options,ignoreHTTPSErrors:true}),close:async()=>{}}),credentials:async()=>{reads++;return {username:'test-user',password:'test-password'};}});
 for(mode of ['ok','ambiguous','get','external','already','no-marker','mfa']){
  const session=create();t.after(()=>session.close());const before=reads,sent=submissions;
  const open=session.open.bind(session);session.open=async c=>{await open(c);const wait=session.page.waitForFunction.bind(session.page);session.page.waitForFunction=(fn,arg,options)=>wait(fn,arg,{...options,timeout:500});};
  if(['ambiguous','get','external','already'].includes(mode)){await assert.rejects(session.login('school'));assert.equal(reads,before);assert.equal(submissions,sent);}
  else {const result=await session.login('school');assert.equal(Boolean(result.authenticated),mode==='ok');assert.equal(reads,before+1);if(mode!=='ok'){assert.equal(result.needsUser,true);assert.equal(session.page,null);}}
  await session.close();
 }
});

test('reCAPTCHA opt-in allows provider traffic without general external access',()=>{
 const session=new SecureSession({connections:[{...base,recaptcha:true}]});session.connection=session.profile.connections[0];
 const main={},child={};session.page={mainFrame:()=>main};
 const request=(url,type='script',method='GET',frame=child)=>({url:()=>url,resourceType:()=>type,method:()=>method,frame:()=>frame});
 for(const req of [request('https://www.google.com/recaptcha/api.js'),request('https://www.gstatic.com/recaptcha/releases/test.js'),request('https://www.google.com/recaptcha/api2/anchor','document'),request('https://www.google.com/recaptcha/api2/reload','xhr','POST'),request('https://www.recaptcha.net/recaptcha/api.js')])assert.equal(session.requestAllowed(req),true);
 for(const req of [request('https://www.google.com/recaptcha/api2/anchor','document','GET',main),request('https://www.google.com/other'),request('https://www.google.com/recaptcha/../other'),request('https://www.google.com.evil.test/recaptcha/api.js'),request('https://evil.test/recaptcha/api.js'),request('http://www.google.com/recaptcha/api.js'),request('https://www.google.com:444/recaptcha/api.js'),request('https://www.gstatic.com/recaptcha/data','xhr','POST'),request('https://www.google.com/recaptcha/data','xhr','DELETE')])assert.equal(session.requestAllowed(req),false);
 const redirect=request('https://www.google.com/recaptcha/api.js');assert.equal(session.requestAllowed(redirect,'https://www.google.com/other'),false);
 session.connection.recaptcha=false;assert.equal(session.requestAllowed(request('https://www.google.com/recaptcha/api.js')),false);
 assert.throws(()=>validateProfile({connections:[{...base,recaptcha:'true'}]}));
});
