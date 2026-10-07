// POST {} -> { url }   Starts a Stripe Identity check (government ID + selfie). The result arrives via stripe-webhook.
// Secrets: STRIPE_SECRET_KEY (required), SITE_URL. Fails closed (503) if the key is missing.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { stripeFetch } from './stripe.js';

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
  const { error: gate } = await sb.rpc('can_start_verification');
  if (gate) return json({ error: gate.message }, 403);

  const site = Deno.env.get('SITE_URL') || 'https://www.overvibez.com/';
  try {
    const s = await stripeFetch(sk, '/v1/identity/verification_sessions', { params: {
      type: 'document', metadata: { user_id: u.user.id }, return_url: site + '?verify=done',
      options: { document: { require_matching_selfie: true, require_live_capture: true, allowed_types: ['driving_license', 'passport', 'id_card'] } },
    } });
    return json({ url: s.url });
  } catch (e) { return json({ error: 'Could not start verification: ' + (e as Error).message }, 502); }
});
