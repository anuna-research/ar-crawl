from pathlib import Path
import subprocess
mutations=[
 ('no-direct-fallback','src/proxy-transport.rkt', '(error \'proxy-fetch "Proxy request failed")', '(set! content (port->string (get-pure-port target-url)))', ['python3','-m','unittest','discover','-s','tests','-p','test_proxy_integration.py','-k','bypass_and_no_implicit']),
 ('rotation', 'src/proxy-config.rkt', '(set! index (modulo (add1 index) (length entries)))', '(set! index 0)', ['raco','test','tests/test-proxy.rkt']),
 ('recognition','src/proxy-config.rkt','(<= 1 (url-port u) 65535)','(<= 0 (url-port u) 65535)',['raco','test','tests/test-proxy.rkt']),
 ('authentication','src/proxy-transport.rkt','silent\\ngloboff\\nfail\\n','silent\\ngloboff\\n',['python3','-m','unittest','discover','-s','tests','-p','test_proxy_integration.py','-k','http_auth']),
 ('bypass','playwright-service/proxy-config.js','...domains.flatMap(s => [s, `*.${s}`])','...domains',['node','--test','playwright-service/tests/proxy-config.test.js']),
]
with open('specs/evidence/proxy-mutation.txt','w') as out:
 for name,path,old,new,command in mutations:
  p=Path(path); original=p.read_text(); assert old in original,name
  try:
   p.write_text(original.replace(old,new,1))
   result=subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
   out.write(f'Mutation {name}: exit {result.returncode}\n'+result.stdout+'\n')
   assert result.returncode != 0, f'surviving mutant {name}'
  finally:p.write_text(original)
