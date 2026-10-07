// Stripe -> us. Verifies Stripe's signature, then (and only then) credits wallets, reverses refunded/charged-back top-ups
// and records ID-check results. Deployed with verify_jwt = false because Stripe is not a signed-in user; the signature check IS the authentication.
// Secrets: STRIPE_WEBHOOK_SECRET (whsec_...), STRIPE_SECRET_KEY, STRIPE_CURRENCY (default gbp).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { stripeFetch, verifyStripeSignature } from './stripe.js';
import { handleStripeEvent } from './handler.js';

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const secret = Deno.env.get('STRIPE_WEBHOOK_SECRET');
  if (!secret) return json({ error: 'not_configured' }, 503);
  const raw = await req.text();
  if (!(await verifyStripeSignature(raw, req.headers.get('stripe-signature') ?? '', secret))) return json({ error: 'invalid_signature' }, 400);

  const event = JSON.parse(raw);
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const currency = (Deno.env.get('STRIPE_CURRENCY') || 'gbp').toLowerCase();
  const sk = Deno.env.get('STRIPE_SECRET_KEY') ?? '';
  const r = await handleStripeEvent(event, { admin, currency, stripeFetch: (path: string, opts: unknown) => stripeFetch(sk, path, opts as never) });
  return json(r.body, r.status);
});
