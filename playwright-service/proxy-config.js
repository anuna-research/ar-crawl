'use strict';

const cleanString = value => typeof value === 'string' &&
  Array.from(value).every(c => c.codePointAt(0) >= 32 && c.codePointAt(0) !== 127);

function recognizeProxy(value) {
  if (value === undefined || value === null) return undefined;
  const invalid = () => { throw new Error('Invalid proxy configuration'); };
  if (typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).some(k => !['server', 'username', 'password', 'bypass'].includes(k))) invalid();
  let url;
  try { url = new URL(value.server); } catch { invalid(); }
  if (!cleanString(value.server) || Array.from(value.server).some(c => c.trim() === '') ||
      !['http:', 'socks5:'].includes(url.protocol) || !url.hostname ||
      value.server.includes('@') || !['', '/'].includes(url.pathname) || value.server.includes('?') || value.server.includes('#')) invalid();
  const port = Number(url.port || (url.protocol === 'http:' ? 80 : 1080));
  if (port < 1 || port > 65535) invalid();
  const hasUser = Object.hasOwn(value, 'username'), hasPass = Object.hasOwn(value, 'password');
  if (hasUser !== hasPass || (hasUser && (!cleanString(value.username) ||
      !cleanString(value.password) || value.username.includes(':')))) invalid();
  if (url.protocol === 'socks5:' && hasUser) {
    throw new Error('Playwright does not support authenticated SOCKS5; use the direct HTTP adaptor');
  }
  if (value.bypass !== undefined) {
    if (!cleanString(value.bypass)) invalid();
    for (const entry of value.bypass ? value.bypass.split(',') : []) {
      const domain = entry.startsWith('.') ? entry.slice(1) : entry;
      let parsed;
      try { parsed = new URL(`http://${domain}`); } catch { invalid(); }
      if (!domain || Array.from(domain).some(c => c.trim() === '' || ['*',';'].includes(c)) ||
          parsed.hostname !== domain.toLowerCase()) invalid();
    }
  }
  return {...value, server: `${url.protocol}//${url.hostname}:${port}`};
}

function browserProxy(value) {
  const proxy = recognizeProxy(value);
  if (!proxy) return undefined;
  const domains = (proxy.bypass || '').split(',').filter(Boolean).map(s => s.startsWith('.') ? s.slice(1) : s);
  return {...proxy, bypass: ['<-loopback>', ...domains.flatMap(s => [s, `*.${s}`])].join(',')};
}
module.exports = {recognizeProxy, browserProxy};
