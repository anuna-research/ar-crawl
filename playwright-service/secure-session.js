// Credential-safe, non-recording sessions. Used only by session --secure-profile.
// The legacy shared service and its recording format remain separate.
const {readFileSync,openSync,fstatSync,closeSync,constants}=require('node:fs');
const {parseEnv}=require('node:util');
const {chromium}=require('playwright');
function privateFile(path){
 const fd=openSync(path,constants.O_RDONLY|constants.O_NOFOLLOW);
 try{const st=fstatSync(fd);if(!st.isFile()||st.size>65536||(st.mode&0o077)||st.uid!==process.getuid())throw Error('Private file must be owned by the current user with mode 0600');return readFileSync(fd,'utf8');}finally{closeSync(fd);}
}
function httpsURL(value){const url=new URL(value);if(url.protocol!=='https:'||url.username||url.password||url.hash)throw Error('Use HTTPS without URL credentials or fragments');return url;}
function validateProfile(profile){
 if(!profile||!Array.isArray(profile.connections)||!profile.connections.length||profile.connections.length>10)throw Error('Profile needs one to ten connections');
 const ids=new Set();
 for(const c of profile.connections){
  if(typeof c.id!=='string'||!/^[-\w]{1,100}$/.test(c.id)||ids.has(c.id))throw Error('Invalid connection identity');ids.add(c.id);
  if(typeof c.name!=='string'||c.name.length>150)throw Error('Invalid connection name');
  for(const key of ['usernameSelector','passwordSelector','submitSelector','successSelector'])if(typeof c[key]!=='string'||!c[key]||c[key].length>500)throw Error('Missing login selector');
  if(typeof c.loginUrl!=='string'||c.loginUrl.length>2000)throw Error('Invalid login URL');
  c.origin=httpsURL(c.loginUrl).origin;
  if(!Array.isArray(c.resourceOrigins||[])||(c.resourceOrigins||[]).length>20)throw Error('Invalid resource origins');
  c.resourceOrigins=(c.resourceOrigins||[]).map(value=>{const u=httpsURL(value);if(u.pathname!=='/'||u.search)throw Error('Use exact resource origins');return u.origin;});
  const source=c.credential;
  if(!source||!['env-file','broker'].includes(source.type))throw Error('Choose an env-file or broker credential source');
  if(source.type==='env-file'){
   if(typeof source.path!=='string'||!source.path.startsWith('/')||![source.usernameKey,source.passwordKey].every(v=>typeof v==='string'&&/^[A-Za-z_][\w]*$/.test(v)))throw Error('Invalid private env-file source');
  }else{
   const u=new URL(source.url);
   if(u.protocol!=='http:'||u.hostname!=='127.0.0.1'||u.username||u.password||u.hash||typeof source.token!=='string'||source.token.length<32)throw Error('Credential broker must use authenticated IPv4 loopback');
  }
 }
 return profile;
}
async function resolveCredential(c){
 const source=c.credential;let result;
 if(source.type==='env-file'){
  if(typeof parseEnv!=='function')throw Error('Secure env files require Node 22.13 or later');
  const values=parseEnv(privateFile(source.path));result={username:values[source.usernameKey],password:values[source.passwordKey]};
 }else{
  const response=await fetch(source.url,{method:'POST',headers:{Authorization:'Bearer '+source.token,'Content-Type':'application/json'},body:JSON.stringify({id:c.id}),redirect:'error',signal:AbortSignal.timeout(15000)});
  if(!response.ok)throw Error('Credential unavailable');
  const body=await response.text();if(body.length>16384)throw Error('Credential response too large');result=JSON.parse(body);
 }
 for(const key of ['username','password'])if(typeof result[key]!=='string'||!result[key]||result[key].length>4000)throw Error('Credential unavailable');
 return result;
}
const safeKeys=new Set(['Enter','Tab','Escape','ArrowDown','ArrowUp','ArrowLeft','ArrowRight','Home','End','PageDown','PageUp']);
class SecureSession {
 constructor(profile,{launch=()=>chromium.launch({headless:true,args:['--disable-extensions','--force-webrtc-ip-handling-policy=disable_non_proxied_udp']}) ,credentials=resolveCredential}={}){
  this.profile=validateProfile(profile);this.launch=launch;this.credentials=credentials;this.secrets=[];
 }
 redact(value){
  if(typeof value==='string'){
   const terms=[...new Set(this.secrets.flatMap(s=>[s,encodeURIComponent(s),Buffer.from(s).toString('base64')]))].filter(Boolean).sort((a,b)=>b.length-a.length);
   if(!terms.length)return value;
   const escaped=terms.map(s=>s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'));
   return value.replace(new RegExp(escaped.join('|'),'g'),'[redacted]');
  }
  if(Array.isArray(value))return value.map(v=>this.redact(v));
  if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).map(([k,v])=>[k,this.redact(v)]));
  return value;
 }
 async closePage(){await this.context?.close();this.context=null;this.page=null;this.connection=null;}
 async close(){try{await this.closePage();}finally{await this.browser?.close();this.browser=null;this.secrets=[];}}
 allowed(value,resource=false){try{const u=httpsURL(value);return u.origin===this.connection.origin||resource&&this.connection.resourceOrigins.includes(u.origin);}catch{return false;}}
 async open(c){
  await this.closePage();this.connection=c;this.browser||=await this.launch();
  this.context=await this.browser.newContext({acceptDownloads:false,serviceWorkers:'block'});
  this.context.setDefaultTimeout(15000);
  if(!this.context.routeWebSocket)throw Error('Secure sessions require Playwright 1.48 or later');
  await this.context.routeWebSocket('**/*',ws=>ws.close());
  await this.context.route('**/*',async route=>{
   const request=route.request();
   // Block external frames/navigation and cross-origin submissions. Allow
   // explicitly trusted static resource hosts, never credentials in URL/query.
   const same=this.allowed(request.url()),staticResource=['script','stylesheet','image','font','media'].includes(request.resourceType());
   const allowed=same||request.method()==='GET'&&staticResource&&this.allowed(request.url(),true);
   if(!allowed||this.secrets.some(s=>request.url().includes(s)||request.url().includes(encodeURIComponent(s))))return route.abort();
   try{
    // route.continue() can follow redirects without invoking the route handler
    // again. Fetch each hop ourselves with automatic redirects disabled.
    let target=request.url();
    for(let hop=0;hop<10;hop++){
     const response=await route.fetch({url:target,maxRedirects:0,timeout:30000});
     const status=response.status(),location=response.headers().location;
     if([301,302,303,307,308].includes(status)&&location){
      const next=new URL(location,target);
      if(next.origin!==new URL(request.url()).origin||!this.allowed(next.href,!request.isNavigationRequest())||this.secrets.some(s=>next.href.includes(s)||next.href.includes(encodeURIComponent(s))))return route.abort();
      if(request.isNavigationRequest()){
       // Convert ordinary navigation redirects into fresh navigations so the
       // browser URL stays correct and every hop re-enters this policy.
       if([307,308].includes(status)&&request.method()!=='GET')return route.abort();
       const escaped=next.href.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
       return route.fulfill({status:200,contentType:'text/html',body:'<!doctype html><meta http-equiv="refresh" content="0;url='+escaped+'">'});
      }
      target=next.href;continue;
     }
     return route.fulfill({response});
    }
    return route.abort();
   }catch{await route.abort().catch(()=>{});}
  });
  this.page=await this.context.newPage();
  this.context.on('page',page=>{if(page!==this.page)void page.close();});
  this.page.on('dialog',dialog=>void dialog.dismiss());
  this.page.on('download',download=>void download.cancel());
  await this.page.goto(c.loginUrl,{waitUntil:'domcontentloaded',timeout:30000});
  if(!this.allowed(this.page.url()))throw Error('Login left the permitted origin');
 }
 async login(id){
  const c=this.profile.connections.find(c=>c.id===id);if(!c)throw Error('Connection not granted to this session');
  try{
   await this.open(c);
   const user=this.page.locator(c.usernameSelector),password=this.page.locator(c.passwordSelector),submit=this.page.locator(c.submitSelector),success=this.page.locator(c.successSelector);
   await user.waitFor({state:'visible'});await password.waitFor({state:'visible'});
   if(await user.count()!==1||await password.count()!==1||await submit.count()!==1||await success.isVisible())throw Error('Ambiguous login fields or success marker');
   const check=async(locator,isPassword)=>locator.evaluate((el,{origin,isPassword})=>{
    if(!(el instanceof HTMLInputElement)||el.disabled||el.readOnly||isPassword&&el.type!=='password'||!isPassword&&!['email','text','tel'].includes(el.type)||location.origin!==origin)return false;
    return !el.form||(new URL(el.form.action||location.href).origin===origin&&el.form.method.toLowerCase()==='post');
   },{origin:c.origin,isPassword});
   if(!await check(user,false)||!await check(password,true))throw Error('Login fields must use a same-origin POST form');
   const secret=await this.credentials(c);this.secrets.push(secret.username,secret.password);
   if(!this.allowed(this.page.url()))throw Error('Login origin changed');
   await user.fill(secret.username);if(!this.allowed(this.page.url())||!await check(password,true))throw Error('Login origin changed');await password.fill(secret.password);
   if(!this.allowed(this.page.url()))throw Error('Login origin changed');
   await submit.click();
   try{await success.waitFor({state:'visible',timeout:15000});if(!this.allowed(this.page.url())||await password.isVisible())throw Error('Unconfirmed login');}
   catch{await this.closePage();return {success:false,needsUser:true,message:'Login could not be confirmed. Check the saved selectors and credentials. MFA or CAPTCHA may require manual sign-in; this session was closed.'};}
   return {success:true,authenticated:true,connectionId:id};
  }catch{await this.closePage();throw Error('Login failed. Check the permitted origin, same-origin POST form, saved selectors and credential access.');}
 }
 async state(view='minimal'){
  if(!this.page||!this.allowed(this.page.url()))throw Error('Log in before using the website session');
  const state={url:new URL(this.page.url()).origin+new URL(this.page.url()).pathname,title:await this.page.title()};
  if(view==='full')state.text=(await this.page.locator('body').innerText()).slice(0,24000);
  if(['full','actions','forms'].includes(view))state.elements=await this.page.evaluate(view=>[...document.querySelectorAll(view==='forms'?'input,textarea,select':'a,button,input,textarea,select,[role="button"]')].filter(el=>el.getClientRects().length).slice(0,100).map(el=>({tag:el.tagName.toLowerCase(),type:el.type||null,label:el.getAttribute('aria-label')||el.getAttribute('placeholder')||(el.matches('a,button')?el.textContent?.slice(0,150):el.name)||null,selector:el.id?'#'+CSS.escape(el.id):el.name?'[name='+JSON.stringify(el.name)+']':null})),view);
  return this.redact(state);
 }
 async command(line){
  if(typeof line!=='string'||line.length>16000||/[\r\n]/.test(line))throw Error('Provide one bounded session command');
  if(line==='exit'){await this.close();return {closed:true};}
  if(line==='help')return {mode:'secure',commands:['login','state','state --full','state --actions','state --forms','goto','click','fill','selectOption','check','uncheck','press','scroll','waitForSelector','exit'],recording:false};
  if(['state','state --full','state --actions','state --forms'].includes(line))return this.state(line.split('--')[1]||'minimal');
  let a;try{a=JSON.parse(line);}catch{throw Error('Unsupported secure-session command');}
  if(a.type==='login')return this.login(a.connectionId);
  if(!this.page||!this.allowed(this.page.url()))throw Error('Log in before using the website session');
  const selector=()=>{if(typeof a.selector!=='string'||!a.selector||a.selector.length>500)throw Error('Invalid selector');return this.page.locator(a.selector);};
  try{
   switch(a.type){
    case 'goto':if(!this.allowed(a.url))throw Error();await this.page.goto(a.url,{waitUntil:'domcontentloaded',timeout:30000});break;
    case 'click':await selector().click();break;
    case 'fill':if(typeof a.value!=='string'||a.value.length>4000||await selector().evaluate(el=>el.type==='password'))throw Error();await selector().fill(a.value);break;
    case 'selectOption':if(typeof a.value!=='string'||a.value.length>500)throw Error();await selector().selectOption(a.value);break;
    case 'check':await selector().check();break;
    case 'uncheck':await selector().uncheck();break;
    case 'press':if(!safeKeys.has(a.key))throw Error();await selector().press(a.key);break;
    case 'scroll':if(!Number.isFinite(a.y)||Math.abs(a.y)>10000)throw Error();await this.page.mouse.wheel(0,a.y);break;
    case 'waitForSelector':await selector().waitFor({state:'visible'});break;
    default:throw Error();
   }
   return {success:true,...await this.state()};
  }catch{throw Error('Website action failed or is not permitted in a secure session');}
 }
}
module.exports={SecureSession,validateProfile,privateFile,resolveCredential};
