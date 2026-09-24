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
// A small vocabulary, independent of provider IDs and website selectors.
const fieldSchema={
 'payment.card.number':{autocomplete:'cc-number',labels:['card number','credit card number','debit card number']},
 'payment.card.name':{autocomplete:'cc-name',labels:['name on card','cardholder name','card holder name']},
 'payment.card.expiry':{autocomplete:'cc-exp',labels:['expiry','expiry date','expiration date','card expiry']},
 'payment.card.expiryMonth':{autocomplete:'cc-exp-month',labels:['expiry month','expiration month']},
 'payment.card.expiryYear':{autocomplete:'cc-exp-year',labels:['expiry year','expiration year']},
 'payment.card.securityCode':{autocomplete:'cc-csc',labels:['cvv','cvc','security code','card security code']},
 'person.name':{autocomplete:'name',labels:['full name']},
 'person.givenName':{autocomplete:'given-name',labels:['first name','given name']},
 'person.familyName':{autocomplete:'family-name',labels:['last name','family name','surname']},
 'person.email':{autocomplete:'email',labels:['email','email address']},
 'person.phone':{autocomplete:'tel',labels:['phone','phone number','telephone']},
 'person.address.street':{autocomplete:'street-address',labels:['street address']},
 'person.address.line1':{autocomplete:'address-line1',labels:['address line 1','address 1']},
 'person.address.line2':{autocomplete:'address-line2',labels:['address line 2','address 2']},
 'person.address.city':{autocomplete:'address-level2',labels:['city','town']},
 'person.address.region':{autocomplete:'address-level1',labels:['state','province','region']},
 'person.address.postalCode':{autocomplete:'postal-code',labels:['postal code','postcode','zip code']},
 'person.address.country':{autocomplete:'country-name',labels:['country']},
 'account.username':{autocomplete:'username',labels:['username','user name','email','email address']},
 'account.password':{autocomplete:'current-password',labels:['password']}
};
async function matchField(page,field){
 if(field.selector){
  const locator=page.locator(field.selector);
  if(await locator.count()!==1)return null;
  return locator.elementHandle();
 }
 // Resolve to an element handle, not an index selector that can silently retarget
 // after the provider returns. No input values leave the browser during discovery.
 const handle=await page.evaluateHandle(({definition,semanticType,context})=>{
  const normalize=value=>(value||'').toLowerCase().replace(/[^a-z0-9]+/g,' ').trim();
  const matches=[...document.querySelectorAll('input,textarea')].filter(el=>{
   if(!el.getClientRects().length||getComputedStyle(el).visibility!=='visible'||el.disabled||el.readOnly)return false;
   if(el.tagName==='INPUT'&&!['text','email','tel','password','number','search','url'].includes(el.type))return false;
   if((semanticType==='account.password')!==(el.type==='password'))return false;
   const tokens=(el.getAttribute('autocomplete')||'').toLowerCase().trim().split(/\s+/);
   if(context&&!tokens.includes(context))return false;
   const detail=tokens.filter(t=>t&&!['on','off','billing','shipping','home','work','mobile','fax','pager','webauthn'].includes(t)&&!t.startsWith('section-'));
   if(detail.length)return detail.length===1&&(detail[0]===definition.autocomplete||semanticType==='account.username'&&detail[0]==='email');
   const labelledBy=(el.getAttribute('aria-labelledby')||'').split(/\s+/).map(id=>document.getElementById(id)?.textContent||'').join(' ');
   const labels=[...(el.labels||[])].map(label=>label.textContent);
   const names=[...labels,el.getAttribute('aria-label'),labelledBy,el.getAttribute('placeholder'),el.name,el.id].map(normalize);
   return names.some(name=>definition.labels.includes(name));
  });
  return matches.length===1?matches[0]:null;
 },{definition:fieldSchema[field.semanticType],semanticType:field.semanticType,context:field.context});
 const element=handle.asElement();if(!element)await handle.dispose();return element;
}
function hasAuthenticatedMarker({origin,checkChallenge=true}){
 if(location.origin!==origin)return false;
 const visible=el=>el.getClientRects().length&&getComputedStyle(el).visibility==='visible';
 if(checkChallenge&&[...document.querySelectorAll('input[type=password],input[autocomplete=one-time-code],input[name*=otp i],iframe[src*=captcha i]')].some(visible))return false;
 return [...document.querySelectorAll('a,button,input[type=submit]')].some(el=>{
  if(!visible(el)||el.disabled)return false;
  const text=(el.getAttribute('aria-label')||el.textContent||el.value||'').trim().toLowerCase().replace(/\s+/g,' ');
  if(!['log out','logout','sign out','signout'].includes(text))return false;
  const target=el.getAttribute('href')||el.getAttribute('formaction')||el.form?.action;
  if(!target)return el.tagName==='BUTTON';
  try{const url=new URL(target,location.href);return url.origin===origin&&/(?:^|\/)(?:logout|signout|sign-out|log-out)(?:\/|$)/i.test(url.pathname);}catch{return false;}
 });
}
async function loginSubmit(page,user,password,selector){
 if(selector){const found=page.locator(selector);return await found.count()===1?found.elementHandle():null;}
 const handle=await page.evaluateHandle(({user,password})=>{
  if(!user.form||user.form!==password.form)return null;
  const buttons=[...user.form.elements].filter(el=>['BUTTON','INPUT'].includes(el.tagName)&&el.type==='submit'&&!el.disabled&&el.getClientRects().length&&getComputedStyle(el).visibility==='visible');
  return buttons.length===1?buttons[0]:null;
 },{user,password});
 const element=handle.asElement();if(!element)await handle.dispose();return element;
}
function validateProfile(profile){
 if(!profile||!Array.isArray(profile.connections)||!profile.connections.length||profile.connections.length>10)throw Error('Profile needs one to ten connections');
 const ids=new Set();
 for(const c of profile.connections){
  if(typeof c.id!=='string'||!/^[-\w]{1,100}$/.test(c.id)||ids.has(c.id))throw Error('Invalid connection identity');ids.add(c.id);
  if(typeof c.name!=='string'||c.name.length>150)throw Error('Invalid connection name');
  for(const key of ['usernameSelector','passwordSelector','submitSelector','successSelector'])if(c[key]!==undefined&&(typeof c[key]!=='string'||!c[key]||c[key].length>500))throw Error('Invalid login selector');
  if(typeof c.loginUrl!=='string'||c.loginUrl.length>2000)throw Error('Invalid login URL');
  c.origin=httpsURL(c.loginUrl).origin;
  if(c.recaptcha!==undefined&&typeof c.recaptcha!=='boolean')throw Error('Invalid reCAPTCHA permission');
  if(!Array.isArray(c.resourceOrigins||[])||(c.resourceOrigins||[]).length>20)throw Error('Invalid resource origins');
  c.resourceOrigins=(c.resourceOrigins||[]).map(value=>{const u=httpsURL(value);if(u.pathname!=='/'||u.search)throw Error('Use exact resource origins');return u.origin;});
  if(!Array.isArray(c.sensitiveFields||[])||(c.sensitiveFields||[]).length>50)throw Error('Invalid sensitive fields');
  const fieldIds=new Set();
  for(const field of c.sensitiveFields||[]){
   if(!field||typeof field.id!=='string'||!/^[-\w]{1,100}$/.test(field.id)||fieldIds.has(field.id))throw Error('Invalid sensitive field identity');
   fieldIds.add(field.id);
   if(typeof field.url!=='string'||field.url.length>2000||httpsURL(field.url).origin!==c.origin)throw Error('Sensitive field must target a saved same-origin HTTPS page');
   if(field.selector!==undefined&&(typeof field.selector!=='string'||!field.selector||field.selector.length>500))throw Error('Invalid sensitive selector');
   if(field.semanticType!==undefined&&!Object.hasOwn(fieldSchema,field.semanticType))throw Error('Unknown semantic field type');
   if(!field.selector&&!field.semanticType)throw Error('Supply a semantic type or selector');
   if(field.context!==undefined&&!['billing','shipping'].includes(field.context))throw Error('Invalid field context');
   const source=field.source;
   if(!source||!['env-file','broker'].includes(source.type))throw Error('Invalid sensitive field source');
   if(source.type==='env-file'){
    if(typeof source.path!=='string'||!source.path.startsWith('/')||typeof source.key!=='string'||!/^[A-Za-z_][\w]*$/.test(source.key))throw Error('Invalid sensitive env-file source');
   }else{
    const u=new URL(source.url);
    if(u.protocol!=='http:'||u.hostname!=='127.0.0.1'||u.username||u.password||u.hash||typeof source.token!=='string'||source.token.length<32)throw Error('Sensitive broker must use authenticated IPv4 loopback');
   }
  }
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
async function resolveSensitiveField(connection,field){
 const source=field.source;let value;
 if(source.type==='env-file'){
  if(typeof parseEnv!=='function')throw Error('Secure env files require Node 22.13 or later');
  value=parseEnv(privateFile(source.path))[source.key];
 }else{
  const response=await fetch(source.url,{method:'POST',headers:{Authorization:'Bearer '+source.token,'Content-Type':'application/json'},body:JSON.stringify({id:connection.id,fieldId:field.id}),redirect:'error',signal:AbortSignal.timeout(15000)});
  if(!response.ok)throw Error('Sensitive value unavailable');
  const body=await response.text();if(body.length>16384)throw Error('Sensitive response too large');value=JSON.parse(body).value;
 }
 if(typeof value!=='string'||!value||value.length>4000)throw Error('Sensitive value unavailable');
 return value;
}
const safeKeys=new Set(['Enter','Tab','Escape','ArrowDown','ArrowUp','ArrowLeft','ArrowRight','Home','End','PageDown','PageUp']);
class SecureSession {
 constructor(profile,{launch=()=>chromium.launch({headless:true,args:['--disable-extensions','--force-webrtc-ip-handling-policy=disable_non_proxied_udp']}) ,credentials=resolveCredential,sensitiveFields=resolveSensitiveField}={}){
  this.profile=validateProfile(profile);this.launch=launch;this.credentials=credentials;this.sensitiveFields=sensitiveFields;this.secrets=[];this.sensitiveMode=false;
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
 async closePage(){await this.context?.close();this.context=null;this.page=null;this.connection=null;this.sensitiveMode=false;}
 async close(){try{await this.closePage();}finally{await this.browser?.close();this.browser=null;this.secrets=[];}}
 allowed(value,resource=false){try{const u=httpsURL(value);return u.origin===this.connection.origin||resource&&this.connection.resourceOrigins.includes(u.origin);}catch{return false;}}
 requestAllowed(request,value=request.url()){
  try{
   const url=httpsURL(value),method=request.method(),type=request.resourceType();
   if(url.origin===this.connection.origin)return true;
   if(method==='GET'&&['script','stylesheet','image','font','media'].includes(type)&&this.connection.resourceOrigins.includes(url.origin))return true;
   if(!this.connection.recaptcha||url.port||!url.pathname.startsWith('/recaptcha/'))return false;
   if(url.hostname==='www.gstatic.com')return method==='GET'&&['script','stylesheet','image','font'].includes(type);
   if(!['www.google.com','recaptcha.google.com','www.recaptcha.net'].includes(url.hostname))return false;
   if(type==='document')return method==='GET'&&request.frame()!==this.page.mainFrame();
   if(['xhr','fetch'].includes(type))return ['GET','POST','OPTIONS'].includes(method);
   return method==='GET'&&['script','stylesheet','image','font'].includes(type);
  }catch{return false;}
 }
 async open(c){
  await this.closePage();this.connection=c;this.browser||=await this.launch();
  this.context=await this.browser.newContext({acceptDownloads:false,serviceWorkers:'block'});
  this.context.setDefaultTimeout(15000);
  if(!this.context.routeWebSocket)throw Error('Secure sessions require Playwright 1.48 or later');
  await this.context.routeWebSocket('**/*',ws=>ws.close());
  await this.context.route('**/*',async route=>{
   const request=route.request();
   // Optional provider access is limited by host, path, method and resource
   // type. Top-level navigation and secret fills stay on the website origin.
   const external=!this.allowed(request.url());
   const body=external?(request.postData()||''):'';
   if(!this.requestAllowed(request)||this.secrets.some(s=>request.url().includes(s)||request.url().includes(encodeURIComponent(s))||body.includes(s)||body.includes(encodeURIComponent(s))))return route.abort();
   try{
    // route.continue() can follow redirects without invoking the route handler
    // again. Fetch each hop ourselves with automatic redirects disabled.
    let target=request.url();
    for(let hop=0;hop<10;hop++){
     const response=await route.fetch({url:target,maxRedirects:0,timeout:30000});
     const status=response.status(),location=response.headers().location;
     if([301,302,303,307,308].includes(status)&&location){
      const next=new URL(location,target);
      if(next.origin!==new URL(request.url()).origin||!this.requestAllowed(request,next.href)||this.secrets.some(s=>next.href.includes(s)||next.href.includes(encodeURIComponent(s))))return route.abort();
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
   const user=await matchField(this.page,{selector:c.usernameSelector,semanticType:'account.username'}),password=await matchField(this.page,{selector:c.passwordSelector,semanticType:'account.password'});
   if(!user||!password)throw Error('Login fields not found');
   const submit=await loginSubmit(this.page,user,password,c.submitSelector),success=c.successSelector?this.page.locator(c.successSelector):null;
   const alreadyAuthenticated=success?await success.isVisible():await this.page.evaluate(hasAuthenticatedMarker,{origin:c.origin,checkChallenge:false});
   if(!user||!password||!await user.isVisible()||!await password.isVisible()||!submit||!await submit.isVisible()||alreadyAuthenticated)throw Error('Ambiguous login fields or success marker');
   const check=async(locator,isPassword)=>locator.evaluate((el,{origin,isPassword})=>{
    if(!el.isConnected||!(el instanceof HTMLInputElement)||el.disabled||el.readOnly||isPassword&&el.type!=='password'||!isPassword&&!['email','text','tel'].includes(el.type)||location.origin!==origin)return false;
    return !el.form||(new URL(el.form.action||location.href).origin===origin&&el.form.method.toLowerCase()==='post');
   },{origin:c.origin,isPassword});
   const checkSubmit=async()=>submit.evaluate((el,{origin,user,password})=>{
    if(!el.isConnected||el.disabled||location.origin!==origin)return false;
    if(user.form!==password.form||el.form!==password.form)return false;
    const action=el.getAttribute('formaction')||el.form?.action;
    const method=el.getAttribute('formmethod')||el.form?.method;
    return !el.form||new URL(action,location.href).origin===origin&&method?.toLowerCase()==='post';
   },{origin:c.origin,user,password});
   if(!await check(user,false)||!await check(password,true)||!await checkSubmit())throw Error('Login fields must use a same-origin POST form');
   const secret=await this.credentials(c);this.secrets.push(secret.username,secret.password);
   if(!this.allowed(this.page.url())||!await check(user,false)||!await check(password,true)||!await checkSubmit())throw Error('Login origin changed');
   await user.fill(secret.username);if(!this.allowed(this.page.url())||!await check(password,true))throw Error('Login origin changed');await password.fill(secret.password);
   if(!this.allowed(this.page.url())||!await checkSubmit())throw Error('Login origin changed');
   await submit.click();
   try{if(success)await success.waitFor({state:'visible',timeout:15000});else await this.page.waitForFunction(hasAuthenticatedMarker,{origin:c.origin},{timeout:15000});if(!this.allowed(this.page.url())||await this.page.locator('input[type=password]:visible').count())throw Error('Unconfirmed login');}
   catch{await this.closePage();return {success:false,needsUser:true,message:'Login could not be confirmed. Check credentials or use Advanced settings to identify the login controls and success marker. MFA or CAPTCHA may require manual sign-in; this session was closed.'};}
   return {success:true,authenticated:true,connectionId:id};
  }catch{await this.closePage();throw Error('Login failed. Check the permitted origin, same-origin POST form, saved selectors and credential access.');}
 }
 async discoverFields(){
  if(this.sensitiveMode)throw Error('Discovery is unavailable after sensitive filling');
  const fields=[];
  for(const field of this.connection.sensitiveFields||[]){
   let element=null;
   try{
    if(this.page.url()===new URL(field.url).href)element=await matchField(this.page,field);
    fields.push({fieldId:field.id,semanticType:field.semanticType||null,status:element?'matched':'needs-configuration'});
   }finally{await element?.dispose();}
  }
  return {fields,authorizedToRelease:false};
 }
 async fillSecret(fieldId){
  const field=this.connection?.sensitiveFields?.find(field=>field.id===fieldId);
  if(!field)throw Error('Sensitive field is not granted');
  try{
   const locator=await matchField(this.page,field);
   const check=async()=>!!locator&&this.page.url()===new URL(field.url).href&&await locator.isVisible()&&await locator.evaluate((el,origin)=>{
    if(!el.isConnected||location.origin!==origin||!(el instanceof HTMLInputElement||el instanceof HTMLTextAreaElement)||el.disabled||el.readOnly)return false;
    if(el instanceof HTMLInputElement&&!['text','email','tel','password','number','search','url'].includes(el.type))return false;
    return !el.form||(new URL(el.form.action||location.href).origin===origin&&el.form.method.toLowerCase()==='post');
   },this.connection.origin);
   if(!await check())throw Error();
   const value=await this.sensitiveFields(this.connection,field);
   if(typeof value!=='string'||!value||value.length>4000)throw Error();
   this.secrets.push(value);
   const matched=await matchField(this.page,field);
   const unchanged=matched&&await locator.evaluate((el,other)=>el===other,matched);
   await matched?.dispose();
   if(!unchanged||!await check())throw Error();
   // Stop DOM output before dispatching input events: sites may echo or format
   // values in ways that exact-string redaction cannot reliably recognize.
   this.sensitiveMode=true;
   await locator.fill(value);
   return {success:true,filled:true,submissionAllowed:false};
  }catch{await this.closePage();throw Error('Sensitive fill failed; the page was closed');}
 }
 async state(view='minimal'){
  if(!this.page||!this.allowed(this.page.url()))throw Error('Log in before using the website session');
  if(this.sensitiveMode)return {sensitiveFieldsFilled:true,submissionAllowed:false,message:'Page output is withheld after sensitive filling. Fill another granted field or close the session.'};
  const state={url:new URL(this.page.url()).origin+new URL(this.page.url()).pathname,title:await this.page.title()};
  if(view==='full')state.text=(await this.page.locator('body').innerText()).slice(0,24000);
  if(['full','actions','forms'].includes(view))state.elements=await this.page.evaluate(view=>[...document.querySelectorAll(view==='forms'?'input,textarea,select':'a,button,input,textarea,select,[role="button"]')].filter(el=>el.getClientRects().length).slice(0,100).map(el=>({tag:el.tagName.toLowerCase(),type:el.type||null,label:el.getAttribute('aria-label')||el.getAttribute('placeholder')||(el.matches('a,button')?el.textContent?.slice(0,150):el.name)||null,selector:el.id?'#'+CSS.escape(el.id):el.name?'[name='+JSON.stringify(el.name)+']':null})),view);
  return this.redact(state);
 }
 async command(line){
  if(typeof line!=='string'||line.length>16000||/[\r\n]/.test(line))throw Error('Provide one bounded session command');
  if(line==='exit'){await this.close();return {closed:true};}
  if(line==='help')return {mode:'secure',commands:['login','discoverFields','fillSecret','state','state --full','state --actions','state --forms','goto','click','fill','selectOption','check','uncheck','press','scroll','waitForSelector','exit'],recording:false};
  if(['state','state --full','state --actions','state --forms'].includes(line))return this.state(line.split('--')[1]||'minimal');
  let a;try{a=JSON.parse(line);}catch{throw Error('Unsupported secure-session command');}
  if(a.type==='login')return this.login(a.connectionId);
  if(!this.page||!this.allowed(this.page.url()))throw Error('Log in before using the website session');
  if(a.type==='discoverFields')return this.discoverFields();
  if(a.type==='fillSecret'){if(Object.keys(a).some(key=>!['type','fieldId'].includes(key)))throw Error('Use only a granted field ID');return this.fillSecret(a.fieldId);}
  if(this.sensitiveMode)throw Error('Only further sensitive fills, state, a fresh login or exit are permitted after sensitive filling');
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
module.exports={SecureSession,validateProfile,privateFile,resolveCredential,resolveSensitiveField,fieldSchema};
