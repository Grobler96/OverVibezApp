// POST (called every few seconds by the database scheduler, with the x-cron-secret header) -> { claimed, sent, failed }
// Sends the queued push notifications to members' devices using Web Push (VAPID). Fails closed (503) until configured.
// Secret: CRON_SECRET (the same one send-emails uses). The VAPID signing keys are created automatically on first run and kept in the push_vapid table.
import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';
import { composePush } from './compose.js';

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });
const same = (a: string, b: string) => { if (a.length !== b.length) return false; let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i); return d === 0; };

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const secret = Deno.env.get('CRON_SECRET');
  if (!secret) return json({ error: 'not_configured' }, 503);
  if (!same(req.headers.get('x-cron-secret') ?? '', secret)) return json({ error: 'forbidden' }, 403);
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  try {
    let { data: key } = await admin.from('push_vapid').select('public_key,private_key').eq('id', 1).maybeSingle();
    if (!key) {                                                          // first run: make the signing keys (two racing runs are fine, the first insert wins)
      const k = webpush.generateVAPIDKeys();
      await admin.from('push_vapid').upsert({ id: 1, public_key: k.publicKey, private_key: k.privateKey }, { onConflict: 'id', ignoreDuplicates: true });
      key = (await admin.from('push_vapid').select('public_key,private_key').eq('id', 1).single()).data;
    }
    webpush.setVapidDetails('https://www.overvibez.com', key!.public_key, key!.private_key);
    const { data: rows, error } = await admin.rpc('claim_push_batch', { p_limit: 100 });
    if (error) throw error;
    if (!rows || !rows.length) return json({ claimed: 0, sent: 0, failed: 0 });
    const ids = [...new Set(rows.map((r: any) => r.user_id))];
    const [{ data: subs }, { data: prefs }] = await Promise.all([
      admin.from('push_subscriptions').select('id,user_id,endpoint,p256dh,auth,fail_count').in('user_id', ids),
      admin.from('push_prefs').select('user_id,discreet').in('user_id', ids)]);
    const discreet = new Map((prefs ?? []).map((p: any) => [p.user_id, p.discreet]));
    const byUser = new Map<string, any[]>();
    (subs ?? []).forEach((s: any) => { const a = byUser.get(s.user_id) ?? []; a.push(s); byUser.set(s.user_id, a); });
    const sentIds: number[] = [], failedIds: number[] = [], dead: string[] = [], okSubs = new Set<string>(), badSubs = new Set<string>();
    const jobs: Promise<void>[] = [];
    for (const r of rows as any[]) {
      const targets = byUser.get(r.user_id) ?? [];
      if (!targets.length) { failedIds.push(r.id); continue; }
      const payload = JSON.stringify(composePush(r, { discreet: !!discreet.get(r.user_id) }));
      jobs.push((async () => {
        let delivered = false;
        for (const s of targets) {
          try {
            await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400, urgency: 'normal' });
            delivered = true; okSubs.add(s.id);
          } catch (e) {
            const code = (e as any).statusCode;
            if (code === 404 || code === 410) dead.push(s.id); else badSubs.add(s.id);
          }
        }
        (delivered ? sentIds : failedIds).push(r.id);
      })());
    }
    for (let i = 0; i < jobs.length; i += 10) await Promise.all(jobs.slice(i, i + 10));
    if (sentIds.length) await admin.rpc('finish_push', { p_ids: sentIds, p_status: 'sent' });
    if (failedIds.length) await admin.rpc('finish_push', { p_ids: failedIds, p_status: 'failed' });
    if (dead.length) await admin.from('push_subscriptions').delete().in('id', dead);
    if (okSubs.size) await admin.from('push_subscriptions').update({ last_ok_at: new Date().toISOString(), fail_count: 0 }).in('id', [...okSubs]);
    for (const id of badSubs) {                                       // keep a device through a short outage, drop it after 5 failed rounds
      const s = (subs ?? []).find((x: any) => x.id === id); const n = (s?.fail_count ?? 0) + 1;
      if (n >= 5) await admin.from('push_subscriptions').delete().eq('id', id); else await admin.from('push_subscriptions').update({ fail_count: n }).eq('id', id);
    }
    return json({ claimed: rows.length, sent: sentIds.length, failed: failedIds.length });
  } catch (e) { console.error('push failed', (e as Error).message); return json({ error: 'push_failed' }, 500); }
});
