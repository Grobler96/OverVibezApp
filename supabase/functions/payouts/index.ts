// POST { action: 'onboard' | 'status' | 'payout' } with the member's login.
//   onboard -> { url }   Stripe-hosted onboarding for the creator's payout account
//   status  -> { connected, details_submitted, payouts_enabled }
//   payout  -> { ok, amount_cents } | { error, code }   Sends the whole earnings balance to the creator's account
// Secrets: STRIPE_SECRET_KEY (required), SITE_URL, STRIPE_CURRENCY (default gbp). Fails closed (503) without the key.
// Requires "Connect" to be switched on in the Stripe dashboard.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { stripeFetch } from './stripe.js';
import { startOnboarding, payoutStatus, runPayout } from './logic.js';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const sk = Deno.env.get('STRIPE_SECRET_KEY');
  if (!sk) return json({ error: 'not_configured' }, 503);
  const auth = req.headers.get('Authorization');
  if (!auth) return json({ error: 'Not signed in' }, 401);

  const userClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } });
  const { data: u } = await userClient.auth.getUser();
  if (!u?.user) return json({ error: 'Not signed in' }, 401);
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const deps = { admin, userClient, user: { id: u.user.id, email: u.user.email }, stripe: (path: string, opts: unknown) => stripeFetch(sk, path, opts as never),
    site: Deno.env.get('SITE_URL') || 'https://grobler96.github.io/OverVibezApp/', currency: (Deno.env.get('STRIPE_CURRENCY') || 'gbp').toLowerCase() };

  let action = ''; try { action = (await req.json()).action; } catch { /* ignore */ }
  try {
    if (action === 'onboard') return json(await startOnboarding(deps));
    if (action === 'status') return json(await payoutStatus(deps));
    if (action === 'payout') { const r = await runPayout(deps); return json(r, r.error ? 400 : 200); }
    return json({ error: 'Unknown action' }, 400);
  } catch (e) {
    const m = (e as Error).message || 'Something went wrong';
    return json({ error: /signed up for connect/i.test(m) ? 'Payouts are not switched on yet — please try again soon.' : m }, 400);
  }
});
