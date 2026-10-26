'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { recognizeProxy, browserProxy } = require('../proxy-config');
// TEST-104 / TEST-106, SPEC-001-proxy-support
 test('recognises HTTP authentication and SOCKS5; disabled omits proxy', () => {
  const value = {server:'http://localhost:80', username:'user', password:'secret', bypass:'.local,localhost'};
  assert.deepEqual(recognizeProxy(value), value);
  assert.equal(recognizeProxy(null), undefined);
  assert.equal(recognizeProxy(undefined), undefined);
  assert.deepEqual(recognizeProxy({server:'socks5://localhost:1080'}), {server:'socks5://localhost:1080'});
});
test('rejects complete malformed wire values without disclosing credentials', () => {
  for (const value of [false, [], 'secret', {}, {server:'http://u:secret@localhost:80'},
    {server:'http://localhost:0'}, {server:'http://localhost:65536'}, {server:'http://localhost'},
    {server:'http://localhost:80/path'}, {server:'http://localhost:80',extra:true},
    {server:'http://localhost:80',username:'secret'}, {server:'http://localhost:80',bypass:'*'},
    {server:'http://localhost:80',password:'secret'}, {server:'http://localhost:80',bypass:'a,,b'},
    {server:'http://localhost:80',username:'secret\n',password:'secret'},
    {server:'socks5://localhost:1080',username:'secret',password:'secret'}]) {
    assert.throws(() => recognizeProxy(value), e => !e.message.includes('secret'));
  }
});

test('browser bypass expands apex and subdomains and removes implicit loopback exception', () => {
  assert.equal(browserProxy({server:'http://host:80', bypass:'.example.test,local.test'}).bypass,
    '<-loopback>,example.test,*.example.test,local.test,*.local.test');
});
