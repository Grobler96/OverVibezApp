// Unit test for the upload scanner (supabase/functions/scan-media/scanner.js). Run: node tests/scan.test.js
import assert from 'node:assert';
import { decide, checkImage, runScans } from '../supabase/functions/scan-media/scanner.js';

(async () => {
  // thresholds
  assert.deepStrictEqual(decide({ category_scores: { sexual: 0.2, 'violence/graphic': 0.1 } }).flagged, false);
  const sexual = decide({ category_scores: { sexual: 0.7 } });
  assert.deepStrictEqual([sexual.flagged, sexual.severity, sexual.categories], [true, 'normal', ['sexual']]);
  const minors = decide({ category_scores: { 'sexual/minors': 0.12, sexual: 0.9 } });
  assert.deepStrictEqual([minors.flagged, minors.severity], [true, 'urgent']);
  assert.strictEqual(decide({}).flagged, false);

  // request shape: caption + image, bearer key
  let seen;
  const okFetch = async (u, o) => { seen = { u, o }; return { ok: true, json: async () => ({ results: [{ category_scores: { sexual: 0.01 } }] }) }; };
  const r = await checkImage({ fetchFn: okFetch, apiKey: 'k', imageUrl: 'https://x/y.jpg', caption: 'hello' });
  assert.strictEqual(r.flagged, false); assert.ok(/moderations/.test(seen.u)); assert.strictEqual(seen.o.headers.Authorization, 'Bearer k');
  const sent = JSON.parse(seen.o.body); assert.deepStrictEqual(sent.input.map((i) => i.type), ['text', 'image_url']);
  await checkImage({ fetchFn: okFetch, apiKey: 'k', imageUrl: 'https://x/y.jpg', caption: '  ' }); assert.deepStrictEqual(JSON.parse(seen.o.body).input.map((i) => i.type), ['image_url']);
  await assert.rejects(checkImage({ fetchFn: async () => ({ ok: false, status: 429, text: async () => 'slow down' }), apiKey: 'k', imageUrl: 'u' }), /429/);

  // a batch: one clean photo, one flagged paid photo, one video, one that errors
  const posts = {
    p1: { id: 'p1', caption: null, media_type: 'image', media_path: 'u/a b.jpg', is_paid: false, subs_only: false },
    p2: { id: 'p2', caption: 'x', media_type: 'image', media_path: 'u/b.jpg', is_paid: true, subs_only: false },
    p3: { id: 'p3', caption: 'v', media_type: 'video', media_path: 'u/c.mp4', is_paid: false, subs_only: false },
    p4: { id: 'p4', caption: 'e', media_type: 'image', media_path: 'u/d.jpg', is_paid: false, subs_only: false } };
  const finished = {}; const urls = [];
  const admin = {
    rpc: async (name, a) => { if (name === 'claim_media_scans') return { data: ['p1', 'p2', 'p3', 'p4'].map((post_id) => ({ post_id })), error: null }; if (name === 'finish_media_scan') { finished[a.p_post] = a; return { error: null }; } },
    from: () => ({ select: () => ({ eq: (_c, id) => ({ maybeSingle: async () => ({ data: posts[id] }) }) }) }),
    storage: { from: (b) => ({ createSignedUrl: async (p) => ({ data: { signedUrl: 'https://signed/' + b + '/' + p }, error: null }) }) } };
  const fetchFn = async (_u, o) => { const img = JSON.parse(o.body).input.find((i) => i.type === 'image_url').image_url.url; urls.push(img);
    if (/d\.jpg/.test(img)) return { ok: false, status: 500, text: async () => 'boom' };
    return { ok: true, json: async () => ({ results: [{ category_scores: /signed/.test(img) ? { sexual: 0.9 } : { sexual: 0.0 } }] }) }; };
  const out = await runScans({ admin, fetchFn, apiKey: 'k', supabaseUrl: 'https://proj.supabase.co/' });
  assert.deepStrictEqual(out, { claimed: 4, clean: 1, flagged: 1, review: 1, failed: 1 });
  assert.strictEqual(finished.p1.p_status, 'clean'); assert.strictEqual(finished.p2.p_status, 'flagged'); assert.strictEqual(finished.p3.p_status, 'review'); assert.strictEqual(finished.p4.p_status, 'error');
  assert.ok(urls.some((u) => u === 'https://proj.supabase.co/storage/v1/object/public/public-media/u/a%20b.jpg'), 'public photos use their public address, safely encoded');
  assert.ok(urls.some((u) => u.startsWith('https://signed/paid-media/')), 'paid photos use a short signed address');
  console.log('scan tests passed');
})().catch((e) => { console.error(e); process.exit(1); });
