'use strict';
const nearley = require('nearley');
const source = require('./proxy-grammar.json');

// Adapt the shared BNF production table to nearley's public compiled grammar API.
const rules = Object.entries(source.rules).concat(Object.entries(source.classes).map(
  ([name, characters]) => [name, Array.from(characters, c => [{literal: c}])]
));
const ParserRules = rules.flatMap(([name, alternatives]) => alternatives.map(symbols => ({
  name,
  symbols: symbols.flatMap(symbol => typeof symbol === 'string' ? [symbol] :
    Array.from(symbol.literal, literal => ({literal}))),
  postprocess: children => [name, ...children]
})));
const invalid = () => { throw new Error('Invalid proxy input'); };
function nodeText(tree) {
  const pending = [tree], text = [];
  while (pending.length) {
    const node = pending.pop();
    if (typeof node === 'string') text.push(node);
    else for (let i = node.length - 1; i > 0; i--) pending.push(node[i]);
  }
  return text.join('');
}
function nodes(tree, name) {
  const pending = [tree], found = [];
  while (pending.length) {
    const node = pending.pop();
    if (typeof node === 'string') continue;
    if (node[0] === name) found.push(node);
    else for (let i = node.length - 1; i > 0; i--) pending.push(node[i]);
  }
  return found;
}
function parseInput(entry, value) {
  if (typeof value !== 'string' || !source.entries.includes(entry) || value.length > source.maxLengths[entry]) invalid();
  // Negative lexical bounds only. Full grammar recognition still follows.
  if (entry === 'endpoint') {
    const credentialEnd = value.indexOf('@');
    if (credentialEnd === -1) entry = 'wire-endpoint';
    else if (value.length - credentialEnd - 1 > source.authorityTailLimit) invalid();
  }
  if (value.length > source.maxLengths[entry]) invalid();
  try {
    const parser = new nearley.Parser(nearley.Grammar.fromCompiled({ParserRules, ParserStart: entry}));
    parser.feed(value);
    if (parser.results.length !== 1) invalid();
    const tree = parser.results[0];
    for (const label of nodes(tree, 'dns-label')) if (nodeText(label).length > 63) invalid();
    for (const domain of nodes(tree, 'dns-name')) if (nodeText(domain).length > 253) invalid();
    for (const port of nodes(tree, 'port')) {
      const number = Number(nodeText(port));
      if (number < 1 || number > 65535) invalid();
    }
    return tree;
  } catch { invalid(); }
}
function endpointFromTree(tree) {
  const field = name => nodeText(nodes(tree, name)[0]);
  const endpoint = {server: `${field('scheme')}://${field('host')}:${field('port')}`};
  if (nodes(tree, 'credentials').length) {
    try {
      endpoint.username = decodeURIComponent(field('username'));
      endpoint.password = decodeURIComponent(field('password'));
    } catch { invalid(); }
    if (endpoint.username.includes(':') || !cleanString(endpoint.username) || !cleanString(endpoint.password)) invalid();
  }
  return endpoint;
}
const cleanString = value => typeof value === 'string' &&
  Array.from(value).every(c => c.codePointAt(0) >= 32 && c.codePointAt(0) !== 127);
module.exports = {parseInput, nodeText, nodes, endpointFromTree, cleanString};
