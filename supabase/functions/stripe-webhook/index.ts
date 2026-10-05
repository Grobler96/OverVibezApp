// Stripe -> us. Verifies Stripe's signature, then (and only then) credits wallets / records ID-check results.
// Deployed with verify_jwt = false because Stripe is not a signed-in user; the signature check IS the authentication.
// Secrets: STRIPE_WEBHOOK_SECRET (whsec_...), STRIPE_SECRET_KEY, STRIPE_CURRENCY (default usd).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { stripeFetch, verifyStripeSignature, ageFromDob } from './stripe.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ok = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return ok({ error: 'method_not_allowed' }, 405);
  const secret = Deno.env.get('STRIPE_WEBHOOK_SECRET');
  if (!secret) return ok({ error: 'not_configured' }, 503);
  const raw = await req.text();
  if (!(await verifyStripeSignature(raw, req.headers.get('stripe-signature') ?? '', secret))) return ok({ error: 'invalid_signature' }, 400);

  const event = JSON.parse(raw);
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const currency = (Deno.env.get('STRIPE_CURRENCY') || 'usd').toLowerCase();

  if (event.type === 'checkout.session.completed' || event.type === 'checkout.session.async_payment_succeeded') {
    const s = event.data.object;
    const uid = s.metadata?.user_id;
    if (s.payment_status !== 'paid') return ok({ received: true, ignored: 'not paid yet' });
    if (!uid || !UUID.test(uid) || !Number.isInteger(s.amount_total) || s.currency !== currency) return ok({ received: true, ignored: 'unexpected session' });
    const { data, error } = await admin.rpc('credit_wallet_from_stripe', { p_user: uid, p_cents: s.amount_total, p_event: s.id, p_type: event.type });
    if (error) { console.error('credit failed', error.message); return ok({ error: 'credit_failed' }, 500); }   // 500 => Stripe retries
    return ok({ received: true, credited: data });
  }

  if (event.type === 'identity.verification_session.verified') {
    const vs = event.data.object; const uid = vs.metadata?.user_id;
    if (!uid || !UUID.test(uid)) return ok({ received: true, ignored: 'no user' });
    let age: number | null = null;
    try {
      const full = await stripeFetch(Deno.env.get('STRIPE_SECRET_KEY')!, '/v1/identity/verification_sessions/' + vs.id, { method: 'GET', params: { expand: ['verified_outputs'] } });
      age = ageFromDob(full.verified_outputs?.dob);
    } catch (e) { console.error('could not read verified outputs', (e as Error).message); }
    const pass = age !== null && age >= 18;           // fail closed: unknown age is NOT verified
    const { error } = await admin.rpc('set_age_verified_from_provider', { p_user: uid, p_event: vs.id, p_ok: pass,
      p_note: pass ? 'document verified, 18+' : age === null ? 'date of birth unavailable' : 'under 18' });
    if (error) return ok({ error: 'record_failed' }, 500);
    return ok({ received: true, verified: pass });
  }

  return ok({ received: true });   // other events are acknowledged and ignored
});
