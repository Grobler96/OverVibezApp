// POST (called every 30 seconds by the database scheduler, with the x-cron-secret header) -> { claimed, clean, flagged, review, failed }
// Checks newly uploaded photos with an automatic moderation service and holds anything that looks wrong for a person to review.
// Secrets: CRON_SECRET (shared with the other scheduled functions) and OPENAI_API_KEY. Without the key it does nothing (503) and
// uploads simply wait in the queue, so nothing is lost and nothing is blocked.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { runScans } from './scanner.js';

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });
const same = (a: string, b: string) => { if (a.length !== b.length) return false; let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i); return d === 0; };

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const secret = Deno.env.get('CRON_SECRET'), apiKey = Deno.env.get('OPENAI_API_KEY');
  if (!secret) return json({ error: 'not_configured' }, 503);
  if (!same(req.headers.get('x-cron-secret') ?? '', secret)) return json({ error: 'forbidden' }, 403);
  if (!apiKey) return json({ error: 'scanner_not_configured' }, 503);
  const url = Deno.env.get('SUPABASE_URL')!;
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  try { return json(await runScans({ admin, apiKey, supabaseUrl: url })); }
  catch (e) { console.error('scan failed', (e as Error).message); return json({ error: 'scan_failed' }, 500); }
});
