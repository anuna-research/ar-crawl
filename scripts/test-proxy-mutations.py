from pathlib import Path
import subprocess
mutations=[
 ('shared-grammar','playwright-service/proxy-grammar.json','{"literal": "socks5"}','{"literal": "socks4"}',
  [['raco','test','tests/test-proxy-grammar.rkt'],['node','--test','playwright-service/tests/proxy-grammar.test.js']]),
 ('no-direct-fallback','src/proxy-transport.rkt', '(error \'proxy-fetch "Proxy request failed")', '(set! content (port->string (get-pure-port target-url)))', ['python3','-m','unittest','discover','-s','tests','-p','test_proxy_integration.py','-k','bypass_and_no_implicit']),
 ('rotation', 'src/proxy-config.rkt', '(set! index (modulo (add1 index) (length entries)))', '(set! index 0)', ['raco','test','tests/test-proxy.rkt']),
 ('recognition','src/proxy-input.rkt','(<= 1 (string->number (proxy-input-text port)) 65535)','(<= 0 (string->number (proxy-input-text port)) 65535)',['raco','test','tests/test-proxy.rkt']),
 ('authentication','src/proxy-transport.rkt','silent\\ngloboff\\nfail\\n','silent\\ngloboff\\n',['python3','-m','unittest','discover','-s','tests','-p','test_proxy_integration.py','-k','http_auth']),
 ('bypass','playwright-service/proxy-config.js','...domains.flatMap(s => [s, `*.${s}`])','...domains',['node','--test','playwright-service/tests/proxy-config.test.js']),
]
with open('specs/evidence/proxy-grammar-mutation.txt','w') as out:
 for name,path,old,new,command in mutations:
  p=Path(path); original=p.read_text(); assert old in original,name
  try:
   p.write_text(original.replace(old,new,1))
   subprocess.run(['raco','make','src/cli.rkt','tests/test-proxy-grammar.rkt'],check=True,stdout=subprocess.DEVNULL)
   commands = command if isinstance(command[0], list) else [command]
   for check in commands:
    result=subprocess.run(check, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out.write(f'Mutation {name} ({check[0]}): exit {result.returncode}\n'+result.stdout+'\n')
    assert result.returncode != 0, f'surviving mutant {name}'
  finally:
   p.write_text(original)
   subprocess.run(['raco','make','src/cli.rkt','tests/test-proxy-grammar.rkt'],check=True,stdout=subprocess.DEVNULL)
