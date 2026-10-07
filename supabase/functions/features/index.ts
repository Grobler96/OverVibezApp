// GET/POST -> { live, payments, identity, payouts }   Which optional integrations are switched on. Public on purpose: it only reveals
// booleans (never the keys), so the app can hide buttons for features that are not configured yet.
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS' };
Deno.serve((req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const has = (k: string) => !!Deno.env.get(k);
  const stripe = has('STRIPE_SECRET_KEY') && has('STRIPE_WEBHOOK_SECRET');
  const body = { live: has('LIVEKIT_URL') && has('LIVEKIT_API_KEY') && has('LIVEKIT_API_SECRET'), payments: stripe, identity: stripe, payouts: has('STRIPE_SECRET_KEY') };
  return new Response(JSON.stringify(body), { headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=60' } });
});
