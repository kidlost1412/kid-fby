// End-to-end cases: real backend + real extension code + fake TikTok. Run: node --test tests/e2e/e2e.test.js
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Backend, connect, waitFor, sleep, ITEM_ID } = require('./harness');

const A = { username: 'e2e.alice', userId: '7000000000000000001' };
const B = { username: 'e2e.bob', userId: '7000000000000000002' };
const TERMINAL = ['posted', 'rejected', 'uncertain', 'revoked', 'failed'];
const opts = { timeout: 180000 };

async function withBackend(deadlines, fn) {
  const b = await Backend.start(deadlines);
  const cleanups = [];
  try { return await fn(b, (f) => cleanups.push(f)); } catch (e) { e.message += '\n--- backend log tail ---\n' + b.log.split('\n').slice(-25).join('\n'); throw e; }
  finally { for (const c of cleanups) try { c(); } catch (_) { /* best effort */ } await b.stop(); }
}
const track = (later, ...things) => { for (const t of things) later(() => (t.stop ? t.stop() : null)); };
const childState = (b, sid) => (b.child(sid) || {}).state;

test('1. public immediate post: exactly 1 publish request; history = succeeded with the item id', opts, () => withBackend({}, async (b, later) => {
  const { profile, fake, account } = await connect(b, A); track(later, profile, fake);
  const job = await b.submit({ username: account.username, visibility: 0 });
  await waitFor(() => (b.history(job.rid) || {}).status === 'succeeded', { timeout: 60000, what: 'history succeeded' });
  assert.equal(fake.counts.publish, 1);
  const body = fake.publishes[0].body;
  const f = body.feature_common_info_list[0];
  assert.equal(f.privacy_setting_info.visibility_type, 0);
  assert.equal('schedule_time' in f, false);
  assert.equal(body.single_post_req_list[0].single_post_feature_info.text, 'Xin chào 🌸 #việtnam #tiktok');
  assert.equal(body.single_post_req_list[0].video_id, 'v14025fake');
  const h = b.history(job.rid);
  assert.equal(h.post_id, ITEM_ID);
  assert.equal(h.publish_uncertain, 0);
  assert.equal(b.parent(job.schedule_id).status, 'succeeded');
  assert.equal(childState(b, job.schedule_id), 'posted');
  assert.equal(fake.badSig, 0, 'SigV4 headers / part CRC were accepted by the fake storage');
  assert.deepEqual([fake.counts.create, fake.counts.apply, fake.counts.parts, fake.counts.finish, fake.counts.commit], [1, 1, 1, 1, 1]);
  assert.deepEqual(b.cookieCalls(), []);            // the cookie publisher was never used
  await sleep(1500);
  assert.equal(fake.counts.publish, 1);              // still exactly one
}));

test('2. public scheduled post: body carries schedule_time; history shows a native schedule', opts, () => withBackend({}, async (b, later) => {
  const { profile, fake, account } = await connect(b, A); track(later, profile, fake);
  const when = new Date(Date.now() + 40 * 60000);
  const job = await b.submit({ username: account.username, visibility: 0, scheduledFor: when.toISOString() });
  await waitFor(() => (b.history(job.rid) || {}).status === 'succeeded', { timeout: 60000, what: 'history succeeded' });
  assert.equal(fake.counts.publish, 1);
  const f = fake.publishes[0].body.feature_common_info_list[0];
  assert.ok(Math.abs(f.schedule_time - Math.floor(when.getTime() / 1000)) <= 1, 'schedule_time ' + f.schedule_time);
  assert.equal(f.privacy_setting_info.visibility_type, 0);
  const h = b.history(job.rid);
  assert.ok(h.tiktok_schedule_time, 'history has the accepted TikTok schedule time');
  assert.equal(h.post_id, ITEM_ID);
  const view = await b.job(job.rid);
  assert.equal(view.schedule_mode, 'native');
  assert.equal(b.parent(job.schedule_id).status, 'succeeded');
}));

test('3. extension stops mid-upload (pre-authorize): reconcile revokes, definite failure, 0 publish requests', opts, () => withBackend({}, async (b, later) => {
  const { profile, fake, account } = await connect(b, A); track(later, profile, fake);
  let hung; const hungP = new Promise((r) => { hung = r; });
  fake.onPart = async () => { hung(); await new Promise(() => {}); };   // the upload never finishes
  const job = await b.submit({ username: account.username, visibility: 0 });
  await hungP;
  profile.cut = true;                                                    // Chrome gone: no more heartbeats
  await waitFor(() => childState(b, job.schedule_id) === 'revoked', { timeout: 60000, what: 'child revoked by the stale deadline' });
  await waitFor(() => b.parent(job.schedule_id).status === 'failed', { timeout: 20000, what: 'parent failed' });
  const p = b.parent(job.schedule_id);
  assert.equal(p.publish_uncertain, 0);                                  // definite: nothing was sent
  assert.match(p.result_text, /chưa đăng/);
  assert.equal(fake.counts.publish, 0);
  assert.equal(b.history(job.rid).status, 'failed');
  assert.equal(b.child(job.schedule_id).authorized_at, null);
}));

test('4. result lost after authorize -> uncertain; the late result reconciles history; never a second publish', opts, () => withBackend({}, async (b, later) => {
  const { profile, fake, account } = await connect(b, A); track(later, profile, fake);
  let drop = true;
  profile.failIf = (p) => drop && p === '/api/ext/result';
  const job = await b.submit({ username: account.username, visibility: 0 });
  await waitFor(() => childState(b, job.schedule_id) === 'uncertain', { timeout: 60000, what: 'child uncertain after the result deadline' });
  await waitFor(() => b.parent(job.schedule_id).status === 'failed', { timeout: 20000, what: 'parent failed' });
  assert.equal(b.parent(job.schedule_id).publish_uncertain, 1);          // "may or may not have posted"
  assert.equal(fake.counts.publish, 1);
  drop = false;                                                          // the extension's retry gets through
  await waitFor(() => (b.history(job.rid) || {}).post_id === ITEM_ID, { timeout: 60000, what: 'late result reconciled in history' });
  const h = b.history(job.rid);
  assert.equal(h.status, 'succeeded');
  assert.equal(h.prior_uncertain, 1);                                    // the history remembers it was uncertain
  assert.equal(childState(b, job.schedule_id), 'posted');
  await sleep(6000);                                                     // give the poll loop time to (wrongly) start anything else
  assert.equal(fake.counts.publish, 1);
  assert.equal(b.db('SELECT COUNT(*) AS n FROM extension_jobs WHERE schedule_id=?', job.schedule_id)[0].n, 1);
}));

test('5. identity mismatch: refused before upload, 0 publish requests', opts, () => withBackend({}, async (b, later) => {
  const { profile, fake, account } = await connect(b, A); track(later, profile, fake);
  fake.identity = { username: 'someone.else', userId: '7000000000000000999' };   // the logged-in TikTok account changed
  const job = await b.submit({ username: account.username, visibility: 0 });
  await waitFor(() => TERMINAL.includes(childState(b, job.schedule_id)), { timeout: 60000, what: 'child terminal' });
  await waitFor(() => b.parent(job.schedule_id).status === 'failed', { timeout: 20000, what: 'parent failed' });
  assert.equal(childState(b, job.schedule_id), 'failed');
  assert.equal(b.parent(job.schedule_id).publish_uncertain, 0);
  assert.equal(fake.counts.create, 0, 'nothing was uploaded');
  assert.equal(fake.counts.publish, 0);
  assert.equal(b.child(job.schedule_id).authorized_at, null);
}));

test('6. need_reload (protocol mismatch): the extension never claims', opts, () => withBackend({}, async (b, later) => {
  const first = await connect(b, A); track(later, first.profile, first.fake);
  first.profile.cutNow();                                                // the old extension version goes away (its pending long-poll dies)
  // The old SW's long-poll thread keeps running in the backend after the client disconnected (see test 8) and could
  // claim the job for a dead connection. Let it expire first so this test isolates the need_reload behaviour.
  await sleep(26000);
  const { Profile } = require('./harness');
  const upgraded = new Profile({ backend: b, fake: first.fake, store: first.profile.store, protocol: 2, name: 'v2' });   // "newer" extension, same storage
  later(() => upgraded.stop());
  await upgraded.send({ popup: 'poll' });
  const job = await b.submit({ username: first.account.username, visibility: 0 });
  await waitFor(() => upgraded.conn && upgraded.conn.needReload === true, { timeout: 30000, what: 'extension recorded need_reload' });
  assert.match(upgraded.conn.message, /Cần tải lại tiện ích/);
  await waitFor(() => childState(b, job.schedule_id) === 'revoked', { timeout: 60000, what: 'unclaimed job revoked at the claim deadline' });
  assert.equal(b.child(job.schedule_id).claim_client, null, 'never claimed');
  assert.equal(b.parent(job.schedule_id).status, 'failed');
  assert.equal(b.parent(job.schedule_id).publish_uncertain, 0);
  assert.equal(first.fake.counts.create + first.fake.counts.publish, 0);
  const clients = (await b.gui('GET', '/api/ext/clients')).json;
  assert.equal(clients[0].need_reload, true);
}));

test('7. two accounts, one stalled: the other account still completes', opts, () => withBackend({}, async (b, later) => {
  const a = await connect(b, A); track(later, a.profile, a.fake);
  const c = await connect(b, B); track(later, c.profile, c.fake);
  let hung; const hungP = new Promise((r) => { hung = r; });
  a.fake.onPart = async () => { hung(); await new Promise(() => {}); };  // account A's Chrome hangs mid-upload
  const jobA = await b.submit({ username: a.account.username, visibility: 0 });
  await hungP;
  const jobB = await b.submit({ username: c.account.username, visibility: 0 });
  await waitFor(() => (b.history(jobB.rid) || {}).status === 'succeeded', { timeout: 60000, what: 'account B succeeded' });
  assert.ok(!TERMINAL.includes(childState(b, jobA.schedule_id)), 'A is still stuck (not terminal) while B completed: ' + childState(b, jobA.schedule_id));
  assert.equal(c.fake.counts.publish, 1);
  assert.equal(b.history(jobB.rid).post_id, ITEM_ID);
  await waitFor(() => childState(b, jobA.schedule_id) === 'revoked', { timeout: 60000, what: 'A revoked by its stale deadline' });
  assert.equal(a.fake.counts.publish, 0);
  assert.equal(b.parent(jobA.schedule_id).status, 'failed');
  assert.equal(b.parent(jobA.schedule_id).publish_uncertain, 0);
}));

// KNOWN PRODUCT BUG (reported, not fixed here): GET /api/ext/next is a sync handler that loops up to 25 s and never
// notices the client disconnected, so an orphaned long-poll (MV3 service worker restart, Chrome closed, reload)
// claims the next job for nobody. The job is then revoked after the stale deadline = definite failure, owner retries.
test('8. an aborted long-poll must not claim a job (known backend bug, todo)', { todo: 'backend: /api/ext/next keeps polling after the client disconnected (routers/ext.py:146-154)', timeout: 90000 }, () => withBackend({}, async (b, later) => {
  const { profile, fake, account } = await connect(b, A); track(later, profile, fake);
  await sleep(1500);                                                     // the SW's /next?wait=20 is now in flight
  profile.cutNow();                                                      // SW restart / Chrome exit: the connection dies
  const job = await b.submit({ username: account.username, visibility: 0 });
  await sleep(4000);
  assert.equal(b.child(job.schedule_id).claim_client, null, 'job was claimed by a dead long-poll');
}));
