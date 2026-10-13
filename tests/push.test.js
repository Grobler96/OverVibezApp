// Run: node tests/push.test.js
// Checks the wording of push notifications (supabase/functions/send-push/compose.js).
const assert = require('assert');
(async () => {
  const { composePush } = await import('../supabase/functions/send-push/compose.js');
  const t = composePush({ type: 'tip', actor: 'amy', data: { gross_cents: 200, net_cents: 170 } });
  assert.strictEqual(t.title, '💰 You got a tip'); assert.strictEqual(t.body, '@amy tipped you £2.00 — you keep £1.70'); assert.strictEqual(t.url, '/?go=notifs');
  assert.strictEqual(composePush({ type: 'new_follower', actor: 'bo' }).body, '@bo started following you');
  assert.strictEqual(composePush({ type: 'new_follower' }).body, 'Someone started following you');
  const live = composePush({ type: 'live', actor: 'cat', data: { title: 'Q&A' }, ref_id: 'abc' }); assert.strictEqual(live.url, '/?go=live&id=abc');
  const msg = composePush({ type: 'message', actor: 'dan', data: {} }); assert.strictEqual(msg.url, '/?go=messages'); assert.ok(!/hello/.test(msg.body));
  const long = composePush({ type: 'comment', actor: 'eve', data: { preview: 'x'.repeat(300) } }); assert.ok(long.body.length < 120, 'long comments are shortened');
  const hid = composePush({ type: 'tip', actor: 'amy', data: { gross_cents: 200, net_cents: 170 } }, { discreet: true });
  assert.deepStrictEqual([hid.title, hid.body, hid.tag], ['OverVibez', 'You have new activity', 'ov']); assert.ok(!/amy|£/.test(JSON.stringify(hid)), 'hidden details leak nothing');
  assert.strictEqual(composePush({ type: 'something_new' }).body, 'You have new activity');
  console.log('push tests passed');
})().catch((e) => { console.error(e); process.exit(1); });
