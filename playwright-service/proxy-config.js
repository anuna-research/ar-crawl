'use strict';
const {parseInput, endpointFromTree, cleanString} = require('./proxy-input');
// CON-102, SPEC-001-proxy-support: recognise the entire wire value before browser I/O.
function recognizeProxy(value) {
  if (value === undefined || value === null) return undefined;
  const invalid = () => { throw new Error('Invalid proxy configuration'); };
  if (typeof value !== 'object' || Array.isArray(value)) invalid();
  if (Object.keys(value).some(k => !['server', 'username', 'password', 'bypass'].includes(k))) invalid();
  let endpoint;
  try { endpoint = endpointFromTree(parseInput('wire-endpoint', value.server)); } catch { invalid(); }
  const hasUser = Object.hasOwn(value, 'username');
  const hasPass = Object.hasOwn(value, 'password');
  if (hasUser !== hasPass || (hasUser && (!cleanString(value.username) || !cleanString(value.password) || value.username.includes(':')))) invalid();
  if (value.server.startsWith('socks5://') && hasUser) {
    throw new Error('Playwright does not support authenticated SOCKS5; use the direct HTTP adaptor');
  }
  if (value.bypass !== undefined) {
    try { parseInput('bypass-list', value.bypass); } catch { invalid(); }
  }
  return { ...value, server: endpoint.server };
}
function browserProxy(value) {
  const proxy = recognizeProxy(value);
  if (!proxy) return undefined;
  const domains = (proxy.bypass || '').split(',').filter(Boolean).map(s => s.startsWith('.') ? s.slice(1) : s);
  return { ...proxy, bypass: ['<-loopback>', ...domains.flatMap(s => [s, `*.${s}`])].join(',') };
}
module.exports = { recognizeProxy, browserProxy };
