// Independent QA: publish-result mapping vs the Python oracle uploader._check_publish (values obtained by running the
// Python function on 2026-10-27; `type(code) is not int` -> PublishUncertainError).
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const L = require('../lib.js');

test('status_code written as a JSON float is "no usable status_code" (uncertain), as in Python', () => {
  for (const body of ['{"status_code":0.0}', '{"status_code":5.0}', '{"status_code":1e0}']) {
    assert.equal(L.mapPublishResult(200, body).outcome, 'uncertain', body);
  }
  assert.equal(L.mapPublishResult(200, '{"status_code":0}').outcome, 'posted');
  assert.equal(L.mapPublishResult(200, '{"status_code":-1}').outcome, 'rejected');
});
