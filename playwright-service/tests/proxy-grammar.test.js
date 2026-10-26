'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {parseInput, nodeText, endpointFromTree} = require('../proxy-input');
const corpus = require('../../tests/proxy-grammar-corpus.json');
const recognise = example => {
  try {
    const tree = parseInput(example.entry, example.input);
    return {accepted:true, value:['endpoint','wire-endpoint'].includes(example.entry) ? endpointFromTree(tree) : nodeText(tree)};
  } catch { return {accepted:false}; }
};
// TEST-107 / TEST-108, SPEC-002-proxy-input-grammar.
for (const example of corpus) {
  test(`grammar ${example.entry} ${JSON.stringify(example.input)}`, () => {
    assert.equal(recognise(example).accepted, example.valid);
  });
}
test('shared grammar produces identical Racket and JavaScript recognition and fields', () => {
  const generated = Array.from({length:128}, (_, i) => ({entry:'endpoint', input:`http://a-${i}.example:${i+1}`,valid:true}));
  const cases = corpus.concat(generated, generated.map(c => ({...c,input:c.input+'?trailing',valid:false})));
  const result = spawnSync('racket', ['tests/proxy-grammar-driver.rkt'], {
    cwd:path.resolve(__dirname, '../..'), input:JSON.stringify(cases), encoding:'utf8', maxBuffer:4*1024*1024
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(cases.map(recognise), JSON.parse(result.stdout));
});

test('oversized inputs fail before parser allocation within a bounded subprocess', () => {
  const code = `const {parseInput} = require('./playwright-service/proxy-input');
    for (const [entry,text] of [['wire-endpoint','http://'+'a'.repeat(20000)+':80'],
      ['endpoint','http://'+'a'.repeat(20000)+':80'], ['bypass-host','a'.repeat(20000)],
      ['bypass-list','a'.repeat(20000)]]) {
      let rejected=false; try { parseInput(entry,text); } catch { rejected=true; }
      if (!rejected) process.exit(1);
    }`;
  const result = spawnSync(process.execPath, ['-e',code], {
    cwd:path.resolve(__dirname,'../..'),encoding:'utf8',timeout:1000
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status,0,result.stderr);
});

test('Racket rejects near-limit malformed credential-free endpoints within a bounded subprocess', () => {
  const examples = [
    {entry:'endpoint',input:'http://'+'0'.repeat(4080)+':80'},
    {entry:'endpoint',input:'http://host:'+'0'.repeat(4080)+'80'},
    {entry:'endpoint',input:'http://u:p@'+'0'.repeat(4000)+':80'},
    {entry:'endpoint',input:'http://u:p@host:'+'0'.repeat(4000)+'80'}
  ];
  const result = spawnSync('racket',['tests/proxy-grammar-driver.rkt'], {
    cwd:path.resolve(__dirname,'../..'),input:JSON.stringify(examples),encoding:'utf8',timeout:2000
  });
  assert.equal(result.error,undefined);
  assert.equal(result.status,0,result.stderr);
  assert.deepEqual(JSON.parse(result.stdout),examples.map(() => ({accepted:false})));
});
