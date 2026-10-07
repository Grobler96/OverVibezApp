// POST { cents } -> { url, livemode }   Creates a Stripe Checkout Session for a wallet top-up.
// Secrets: STRIPE_SECRET_KEY (required), SITE_URL, STRIPE_CURRENCY (default gbp). Fails closed (503) if the key is missing.
// Money is NOT credited here — only the signed stripe-webhook does that, after Stripe confirms payment.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { stripeFetch } from './stripe.js';

const PACKS = [1000, 2500, 5000, 10000];   // £10 / £25 / £50 / £100
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const sk = Deno.env.get('STRIPE_SECRET_KEY');
  if (!sk) return json({ error: 'not_configured' }, 503);
  const auth = req.headers.get('Authorization');
  if (!auth) return json({ error: 'Not signed in' }, 401);

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } });
  const { data: u } = await sb.auth.getUser();
  if (!u?.user) return json({ error: 'Not signed in' }, 401);
  const { error: gate } = await sb.rpc('can_topup');
  if (gate) return json({ error: gate.message }, 403);

  let cents = 0; try { cents = Number((await req.json()).cents); } catch { /* ignore */ }
  if (!PACKS.includes(cents)) return json({ error: 'Choose one of the listed amounts' }, 400);

  const site = Deno.env.get('SITE_URL') || 'https://grobler96.github.io/OverVibezApp/';
  const currency = (Deno.env.get('STRIPE_CURRENCY') || 'gbp').toLowerCase();
  try {
    const s = await stripeFetch(sk, '/v1/checkout/sessions', { params: {
      mode: 'payment', success_url: site + '?topup=success', cancel_url: site + '?topup=cancel',
      client_reference_id: u.user.id, metadata: { user_id: u.user.id, cents: String(cents) },
      line_items: [{ quantity: 1, price_data: { currency, unit_amount: cents, product_data: { name: 'OverVibez wallet top-up' } } }],
      payment_intent_data: { metadata: { user_id: u.user.id } },
    } });
    return json({ url: s.url, livemode: s.livemode });
  } catch (e) { return json({ error: 'Could not start the payment: ' + (e as Error).message }, 502); }
});
