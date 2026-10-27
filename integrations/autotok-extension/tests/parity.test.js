// Offline parity tests: lib.js vs Python reference values in fixtures.json (see gen_fixtures.py).
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const L = require('../lib.js');
const fx = require('./fixtures.json');

const pattern = (n) => { const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = (i * 31 + 7) & 255; return u; };
const inRanges = (rs, cp) => { let lo = 0, hi = rs.length - 1; while (lo <= hi) { const m = (lo + hi) >> 1; if (cp < rs[m][0]) hi = m - 1; else if (cp > rs[m][1]) lo = m + 1; else return true; } return false; };

test('SigV4 matches requests_auth_aws_sigv4 for apply (GET) and commit (POST)', async () => {
  for (const c of fx.sigv4.cases) {
    const r = await L.sigv4({ method: c.method, url: c.url, body: c.body, ...fx.sigv4.creds, now: new Date(fx.sigv4.now) });
    assert.deepEqual(r.headers, c.expect, c.method + ' ' + c.url);
  }
});

test('CRC32 known vectors and Python parity', () => {
  assert.equal(L.crc32Hex(new TextEncoder().encode('123456789')), 'cbf43926'); // standard check value
  for (const v of fx.crcVectors) assert.equal(L.crc32Hex(Buffer.from(v.hex, 'hex')), v.crc);
});

test('part splitting, per-part CRC and finish body match Python', () => {
  assert.equal(L.CHUNK_SIZE, fx.chunkSize);
  for (const c of fx.crc) {
    const data = pattern(c.size);
    const parts = L.splitParts(c.size);
    assert.deepEqual(parts.map(([a, b]) => b - a), c.partLengths, 'size ' + c.size);
    const crcs = parts.map(([a, b]) => L.crc32Hex(data.subarray(a, b)));
    assert.deepEqual(crcs, c.crcs);
    assert.equal(crcs.map((x, i) => `${i + 1}:${x}`).join(','), c.finishBody);
  }
});

test('JS hashtag class equals Python \w for every code point', () => {
  const re = /^[\p{L}\p{N}_]$/u;
  const bad = [];
  let skipped = 0;
  for (let cp = 0; cp < 0x110000; cp++) {
    if (cp >= 0xD800 && cp <= 0xDFFF) continue;
    if (inRanges(fx.unassignedRanges, cp)) { skipped++; continue; } // newer Unicode in Node than in Python's tables
    const js = re.test(String.fromCodePoint(cp)), py = inRanges(fx.wRanges, cp);
    if (js !== py) bad.push(cp.toString(16));
    if (bad.length > 20) break;
  }
  assert.deepEqual(bad, [], 'differing code points (hex)');
  console.log(`# python unidata ${fx.pyUnicode}; skipped ${skipped} code points unassigned there`);
});

test('pyStrip equals Python str.strip whitespace set and fixtures', () => {
  for (let cp = 0; cp < 0x10000; cp++) {
    if (cp >= 0xD800 && cp <= 0xDFFF) continue;
    const ch = String.fromCodePoint(cp);
    assert.equal(L.pyStrip(ch) === '', inRanges(fx.spaceRanges, cp), 'U+' + cp.toString(16));
  }
  for (const s of fx.strip) { assert.equal(L.pyStrip(s.s), s.stripped); assert.equal(L.codePointLength(s.s), s.len); }
});

test('caption length rule counts code points (Python len), not UTF-16 units', () => {
  assert.equal(L.validateCaption('é'.repeat(2200)), null);
  assert.match(L.validateCaption('é'.repeat(2201)), /at most 2200/);
  assert.equal(L.validateCaption('🌸'.repeat(2200)), null);           // 4400 UTF-16 units but 2200 code points
  assert.match(L.validateCaption('🌸'.repeat(2201)), /at most 2200/);
  assert.equal(L.validateCaption('  　 '), 'caption is required');
  assert.equal(L.validateCaption(''), 'caption is required');
  assert.equal(L.validateCaption('﻿'), null);                    // JS trim() would reject, Python strip() keeps U+FEFF
});

test('caption markup and text_extra match Python (UTF-16 offsets, Vietnamese, emoji, newlines)', () => {
  for (const c of fx.captions) {
    const r = L.buildCaption(c.text, fx.users);
    assert.equal(r.markup, c.markup, JSON.stringify(c.text));
    assert.deepEqual(r.textExtra, c.text_extra, JSON.stringify(c.text));
  }
  // hand-computed anchor: "🌸 #a" -> emoji is 2 UTF-16 units + space => hashtag starts at 3, ends at 5
  const h = L.buildCaption('🌸 #a', {});
  assert.deepEqual(h.textExtra[0], { end: 5, hashtag_name: 'a', start: 3, tag_id: '0', type: 1, user_id: '' });
});

test('full post body matches Python _payload', () => {
  for (const c of fx.payloads) {
    const { markup, textExtra } = L.buildCaption(c.text, fx.users);
    const p = L.buildPayload({ creationId: 'CrEaTiOnId_0123456789', videoId: 'v0123456789abcdef', caption: c.text, markup, textExtra,
      visibility: c.visibility, allowComment: true, allowDuet: false, allowStitch: true, aiLabel: c.aiLabel, probe: c.probe, scheduleTime: c.schedule });
    assert.deepEqual(p, c.payload, c.text);
  }
});

test('schedule rules: window, private, shift after slow upload', () => {
  const now = 1_800_000_000;
  assert.equal(L.resolveSchedule(null, now, 0), null);
  assert.equal(L.resolveSchedule(now + 900, now, 0), now + 900);
  assert.throws(() => L.resolveSchedule(now + 899, now, 0), /15 minutes and 30 days/);
  assert.equal(L.resolveSchedule(now + 30 * 86400, now, 0), now + 30 * 86400);
  assert.throws(() => L.resolveSchedule(now + 30 * 86400 + 1, now, 0), /15 minutes and 30 days/);
  assert.throws(() => L.resolveSchedule(now + 3600, now, 1), /private/);
  assert.equal(L.finalizeSchedule(now + 900, now), now + 900);
  assert.equal(L.finalizeSchedule(now + 400, now), now + 900);          // 500 s late: shifted to earliest
  assert.throws(() => L.finalizeSchedule(now + 299, now), /quá lâu/);   // 601 s late: definite failure
  assert.equal(L.visibilityCode('public'), 0);
  assert.equal(L.visibilityCode('private'), 1);
  assert.throws(() => L.visibilityCode('friends'));
});
