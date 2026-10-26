'use strict';
// CON-102, SPEC-001-proxy-support: recognise the entire wire value before browser I/O.
function recognizeProxy(value) {
  if (value === undefined || value === null) return undefined;
  const invalid = () => { throw new Error('Invalid proxy configuration'); };
  if (typeof value !== 'object' || Array.isArray(value)) invalid();
  if (Object.keys(value).some(k => !['server', 'username', 'password', 'bypass'].includes(k))) invalid();
  const clean = s => typeof s === 'string' && !/[\x00-\x1f\x7f]/.test(s);
  if (!clean(value.server) || !/^(http|socks5):\/\/(?:[a-zA-Z0-9.-]+|\[[a-fA-F0-9:]+\]):[0-9]+\/?$/.test(value.server)) invalid();
  let url;
  try { url = new URL(value.server); } catch { invalid(); }
  // WHATWG URL removes default HTTP ports, so check the explicit source port.
  const dns = /^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/;
  if (!url.hostname.startsWith('[') && !dns.test(url.hostname)) invalid();
  const port = Number(value.server.match(/:([0-9]+)\/?$/)[1]);
  if (!url.hostname || port < 1 || port > 65535) invalid();
  const hasUser = Object.hasOwn(value, 'username');
  const hasPass = Object.hasOwn(value, 'password');
  if (hasUser !== hasPass || (hasUser && (!clean(value.username) || !clean(value.password) || value.username.includes(':')))) invalid();
  if (url.protocol === 'socks5:' && hasUser) {
    throw new Error('Playwright does not support authenticated SOCKS5; use the direct HTTP adaptor');
  }
  if (value.bypass !== undefined && (!clean(value.bypass) || (value.bypass !== '' &&
      !value.bypass.split(',').every(s => /^\.?(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/.test(s))))) invalid();
  return { ...value };
}
function browserProxy(value) {
  const proxy = recognizeProxy(value);
  if (!proxy) return undefined;
  const domains = (proxy.bypass || '').split(',').filter(Boolean).map(s => s.replace(/^\./, ''));
  return { ...proxy, bypass: ['<-loopback>', ...domains.flatMap(s => [s, `*.${s}`])].join(',') };
}
module.exports = { recognizeProxy, browserProxy };
