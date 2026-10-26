"""Local wire-level acceptance for SPEC-001-proxy-support TEST-103..TEST-106.
Run: python3 -m unittest discover -s tests -p 'test_proxy_integration.py' -v
"""
import base64
import contextlib
import http.server
import json
import os
from pathlib import Path
import socket
import socketserver
import ssl
import select
import tempfile
import subprocess
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
RACKET = 'racket'
BODY = b'<html><title>proxied</title><body>proxy-success<img src="http://asset.invalid/pixel"></body></html>'


@contextlib.contextmanager
def serving(handler):
    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True
    server = Server(('127.0.0.1', 0), handler)
    server.events = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.events.append(self.path)
        body = b'User-agent: *\nDisallow: /private\n' if self.path == '/robots.txt' else b'<html>origin-success</html>'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class HTTPProxy(Origin):
    def do_GET(self):
        self.server.events.append((self.path, self.headers.get('Proxy-Authorization')))
        if getattr(self.server, 'auth', False) and self.headers.get('Proxy-Authorization') != 'Basic ' + base64.b64encode(b'user:secret').decode():
            self.send_response(407)
            self.send_header('Proxy-Authenticate', 'Basic realm="test"')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path.endswith('/redirect') and hasattr(self.server, 'redirect'):
            self.send_response(302)
            self.send_header('Location', self.server.redirect)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        body = b'User-agent: *\nDisallow: /private\n' if self.path.endswith('/robots.txt') else BODY
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_CONNECT(self):
        self.server.events.append(('CONNECT', self.path))
        host, port = self.path.rsplit(':', 1)
        with socket.create_connection((host, int(port)), timeout=5) as remote:
            self.send_response(200)
            self.end_headers()
            sockets = [self.connection, remote]
            while True:
                ready, _, _ = select.select(sockets, [], [], 5)
                if not ready:
                    return
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    (remote if source is self.connection else self.connection).sendall(data)


class SOCKSProxy(socketserver.StreamRequestHandler):
    def readn(self, n):
        result = self.rfile.read(n)
        if len(result) != n:
            raise EOFError()
        return result

    def handle(self):
        version, count = self.readn(2)
        methods = self.readn(count)
        auth = getattr(self.server, 'auth', False)
        self.wfile.write(bytes([5, 2 if auth else 0]))
        if auth:
            self.readn(1)
            user = self.readn(self.readn(1)[0])
            password = self.readn(self.readn(1)[0])
            self.server.events.append(('auth', user, password))
            ok = (user, password) == (b'user', b'secret')
            self.wfile.write(bytes([1, 0 if ok else 1]))
            if not ok:
                return
        version, command, reserved, kind = self.readn(4)
        if kind == 1:
            host = socket.inet_ntoa(self.readn(4))
        elif kind == 3:
            host = self.readn(self.readn(1)[0]).decode()
        else:
            host = socket.inet_ntop(socket.AF_INET6, self.readn(16))
        port = int.from_bytes(self.readn(2), 'big')
        self.server.events.append(('connect', host, port))
        self.wfile.write(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00')
        request = self.rfile.readline()
        while self.rfile.readline() not in (b'\r\n', b'\n', b''):
            pass
        self.wfile.write(b'HTTP/1.1 200 OK\r\nContent-Length: ' + str(len(BODY)).encode() + b'\r\nConnection: close\r\n\r\n' + BODY)


class ProxyIntegration(unittest.TestCase):
    def driver(self, target, cfg, command='direct', service=None):
        args = [RACKET, 'tests/proxy-transport-driver.rkt', command, target, json.dumps(cfg)]
        if service:
            args.append(service)
        result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('secret', result.stdout + result.stderr)
        return json.loads(result.stdout[result.stdout.index('{'):])

    def test_http_auth_and_robots(self):
        with serving(HTTPProxy) as proxy:
            proxy.auth = True
            cfg = {'server': f'http://user:secret@127.0.0.1:{proxy.server_address[1]}'}
            self.assertTrue(self.driver('http://target.invalid/page', cfg)['success'])
            self.assertTrue(self.driver('http://target.invalid/page', cfg, 'robots')['success'])
            self.assertTrue(any(e[0].endswith('/robots.txt') for e in proxy.events))
            self.assertTrue(all(e[1] == 'Basic dXNlcjpzZWNyZXQ=' for e in proxy.events))
            self.assertFalse(self.driver('http://target.invalid/page', {'server': cfg['server'], 'password':'wrong', 'username':'user'})['success'])


    def test_https_connect(self):
        with tempfile.TemporaryDirectory() as tmp:
            cert, key = str(Path(tmp)/'cert.pem'), str(Path(tmp)/'key.pem')
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key,
                            '-out', cert, '-days', '1', '-subj', '/CN=localhost',
                            '-addext', 'subjectAltName=DNS:localhost'], check=True, capture_output=True)
            with serving(Origin) as origin, serving(HTTPProxy) as proxy:
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain(cert, key)
                origin.socket = context.wrap_socket(origin.socket, server_side=True)
                target = f'https://localhost:{origin.server_address[1]}/secure'
                cfg = {'server': f'http://127.0.0.1:{proxy.server_address[1]}'}
                from unittest.mock import patch
                with patch.dict(os.environ, {'CURL_CA_BUNDLE':cert}):
                    self.assertIn('origin-success', self.driver(target, cfg)['content'])
                self.assertIn(('CONNECT', f'localhost:{origin.server_address[1]}'), proxy.events)
                self.assertEqual(origin.events, ['/secure'])

    def test_secret_free_child_arguments_and_safe_config_quoting(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp)/'curl'
            capture = Path(tmp)/'capture.json'
            fake.write_text('#!/usr/bin/env python3\nimport sys, json\nfrom pathlib import Path\n'
                            + f'Path({str(capture)!r}).write_text(json.dumps([sys.argv, sys.stdin.read()]))\n'
                            + 'print("<html>fixture</html>")\n')
            fake.chmod(0o700)
            from unittest.mock import patch
            with patch.dict(os.environ, {'PATH':tmp+os.pathsep+os.environ['PATH']}):
                self.assertTrue(self.driver('http://target.invalid',
                    {'server':'http://user:secret@proxy.invalid:8080'})['success'])
            argv, config = json.loads(capture.read_text())
            self.assertEqual(argv[1:], ['--disable', '--config', '-'])
            self.assertNotIn('secret', str(argv))
            self.assertIn('proxy-user = "user:secret"', config)
            self.assertIn('noproxy = ""', config)

    def test_socks5_auth_and_bad_password(self):
        with serving(SOCKSProxy) as proxy:
            proxy.auth = True
            cfg = {'server': f'socks5://127.0.0.1:{proxy.server_address[1]}', 'username': 'user', 'password': 'secret'}
            self.assertTrue(self.driver('http://target.invalid:9999/page', cfg)['success'])
            self.assertIn(('auth', b'user', b'secret'), proxy.events)
            self.assertIn(('connect', 'target.invalid', 9999), proxy.events)
            cfg['password'] = 'wrong'
            self.assertFalse(self.driver('http://target.invalid:9999/page', cfg)['success'])

    def test_bypass_and_no_implicit_direct_fallback(self):
        with serving(Origin) as origin, serving(HTTPProxy) as proxy:
            target = f'http://127.0.0.1:{origin.server_address[1]}/page'
            cfg = {'server': f'http://127.0.0.1:{proxy.server_address[1]}'}
            self.assertIn('proxy-success', self.driver(target, cfg)['content'])
            self.assertEqual(origin.events, [])
            self.assertIn('origin-success', self.driver(target, {**cfg, 'bypass': ['127.0.0.1']})['content'])
            origin.events.clear()
            # Reserve and close a port, ensuring a locally refused proxy endpoint.
            with socket.socket() as dead:
                dead.bind(('127.0.0.1', 0))
                port = dead.getsockname()[1]
            self.assertFalse(self.driver(target, {'server': f'http://127.0.0.1:{port}'})['success'])
            self.assertEqual(origin.events, [])

    def test_redirect_honours_explicit_bypass(self):
        with serving(HTTPProxy) as proxy, serving(Origin) as origin:
            proxy.redirect = f'http://127.0.0.1:{origin.server_address[1]}/redirected'
            cfg = {'server':f'http://127.0.0.1:{proxy.server_address[1]}', 'bypass':['127.0.0.1']}
            result = self.driver('http://target.invalid/redirect', cfg)
            self.assertIn('origin-success', result['content'])
            self.assertEqual(origin.events, ['/redirected'])
            self.assertEqual(len(proxy.events), 1)

    def test_cli_rotation_and_site_robots(self):
        with serving(HTTPProxy) as a, serving(HTTPProxy) as b:
            import tempfile
            with tempfile.TemporaryDirectory() as tmp:
                pool = Path(tmp) / 'pool.txt'
                pool.write_text(f'http://127.0.0.1:{a.server_address[1]}\nhttp://127.0.0.1:{b.server_address[1]}\n')
                output = Path(tmp) / 'result.json'
                env = {k:v for k,v in os.environ.items() if not k.startswith('PROXY_')}
                result = subprocess.run([RACKET, 'src/cli.rkt', 'crawl-site', 'http://target.invalid/page', '--proxy-list', str(pool), '--max-pages', '1', '--crawl-delay', '1', '-o', str(output)], cwd=ROOT, env=env, text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(output.exists(), result.stdout)
                self.assertTrue(any(e[0].endswith('/robots.txt') for e in a.events), a.events)
                self.assertTrue(any(e[0].endswith('/page') for e in b.events), b.events)

    def test_playwright_wire_routing_auth_bypass_and_subresources(self):
        with serving(HTTPProxy) as proxy, serving(Origin) as origin:
            proxy.auth = True
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                port = probe.getsockname()[1]
            env = {**os.environ, 'PLAYWRIGHT_SERVICE_PORT': str(port)}
            service = subprocess.Popen(['node', 'server.js'], cwd=ROOT/'playwright-service', env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                for _ in range(100):
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1):
                            break
                    except OSError:
                        time.sleep(.05)
                cfg = {'server': f'http://127.0.0.1:{proxy.server_address[1]}', 'username':'user', 'password':'secret'}
                url = f'http://127.0.0.1:{origin.server_address[1]}/page'
                self.assertTrue(self.driver(url, cfg, 'playwright', f'http://127.0.0.1:{port}')['success'])
                self.assertEqual(origin.events, [])
                self.assertTrue(any('asset.invalid' in e[0] for e in proxy.events), proxy.events)
                self.assertTrue(self.driver(url, {**cfg, 'bypass':['127.0.0.1']}, 'playwright', f'http://127.0.0.1:{port}')['success'])
                self.assertIn('/page', origin.events)
                origin.events.clear()
                for host in ['localhost', 'sub.localhost']:
                    target = f'http://{host}:{origin.server_address[1]}/domain'
                    self.assertTrue(self.driver(target, {**cfg, 'bypass':['.localhost']}, 'playwright', f'http://127.0.0.1:{port}')['success'])
                self.assertEqual(origin.events.count('/domain'), 2)

            finally:
                service.terminate()
                stdout, stderr = service.communicate(timeout=10)
                self.assertNotIn('secret', stdout + stderr)


if __name__ == '__main__':
    unittest.main()
