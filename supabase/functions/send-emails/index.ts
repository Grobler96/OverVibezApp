// POST (called every minute by the database scheduler, with the x-cron-secret header) -> { claimed, sent, failed }
// Sends the queued notification emails through Resend. Fails closed (503) until configured.
// Secrets: CRON_SECRET, RESEND_API_KEY, EMAIL_FROM (e.g. "OverVibez <no-reply@yourdomain.com>" — the domain must be verified in Resend), SITE_URL.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendBatch } from './sender.js';

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });
const same = (a: string, b: string) => { if (a.length !== b.length) return false; let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i); return d === 0; };

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const secret = Deno.env.get('CRON_SECRET'), key = Deno.env.get('RESEND_API_KEY'), from = Deno.env.get('EMAIL_FROM');
  if (!secret || !key || !from) return json({ error: 'not_configured' }, 503);
  if (!same(req.headers.get('x-cron-secret') ?? '', secret)) return json({ error: 'forbidden' }, 403);
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  try {
    return json(await sendBatch({ admin, apiKey: key, from, site: Deno.env.get('SITE_URL') || 'https://www.overvibez.com/' }));
  } catch (e) { console.error('send failed', (e as Error).message); return json({ error: 'send_failed' }, 500); }
});
