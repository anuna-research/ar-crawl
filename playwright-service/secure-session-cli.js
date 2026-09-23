#!/usr/bin/env node
const {createInterface}=require('node:readline');
const {SecureSession,privateFile}=require('./secure-session');
// No HTTP service, command recording, disk profile, screenshots or raw HTML.
(async()=>{
 let session;
 const send=value=>process.stdout.write(JSON.stringify(value)+'\n');
 try{
  session=new SecureSession(JSON.parse(privateFile(process.argv[2])));
  const cleanup=async()=>{await session.close();process.exit(0);};
  process.on('SIGTERM',cleanup);process.on('SIGINT',cleanup);
  send({status:'ready',mode:'secure',recording:false});
  for await(const line of createInterface({input:process.stdin,crlfDelay:Infinity})){
   try{const result=await session.command(line);send(result);if(line==='exit')break;}
   catch{send({success:false,error:'Secure session command failed. Check the saved connection, credential access and permitted actions.'});}
  }
 }catch{send({success:false,error:'Cannot start secure session. Check the private profile, credential source and Playwright installation.'});process.exitCode=1;}
 finally{await session?.close();}
})().catch(()=>{process.stderr.write('Secure session stopped.\n');process.exitCode=1;});
