// The part of the Stripe webhook that decides what an (already signature-verified) event means. Kept separate so it can be tested.
// deps: { admin (supabase service client), stripeFetch(path, opts), currency }
import { ageFromDob } from './stripe.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const piId = (x) => (typeof x === 'string' ? x : x && x.id) || null;

/** Returns { status, body }. A 500 makes Stripe retry, so only use it when we genuinely failed to record something. */
export async function handleStripeEvent(event, { admin, stripeFetch, currency }) {
  const ok = (body, status = 200) => ({ status, body });

  if (event.type === 'checkout.session.completed' || event.type === 'checkout.session.async_payment_succeeded') {
    const s = event.data.object;
    const uid = s.metadata?.user_id;
    if (s.payment_status !== 'paid') return ok({ received: true, ignored: 'not paid yet' });
    if (!uid || !UUID.test(uid) || !Number.isInteger(s.amount_total) || s.currency !== currency) return ok({ received: true, ignored: 'unexpected session' });
    const { data, error } = await admin.rpc('credit_wallet_from_stripe', { p_user: uid, p_cents: s.amount_total, p_event: s.id, p_type: event.type, p_payment_intent: piId(s.payment_intent) });
    if (error) { console.error('credit failed', error.message); return ok({ error: 'credit_failed' }, 500); }
    return ok({ received: true, credited: data });
  }

  // A top-up was refunded (in the Stripe dashboard) — take the money back out of the wallet.
  if (event.type === 'charge.refunded') {
    const ch = event.data.object;
    const pi = piId(ch.payment_intent);
    if (!pi || !Number.isInteger(ch.amount_refunded)) return ok({ received: true, ignored: 'no payment' });
    const { data, error } = await admin.rpc('reverse_wallet_topup', { p_payment_intent: pi, p_total_reversed: ch.amount_refunded, p_event: event.id, p_reason: 'refunded' });
    if (error) { console.error('reverse failed', error.message); return ok({ error: 'reverse_failed' }, 500); }
    return ok({ received: true, reversed: data });
  }

  // A cardholder disputed a top-up (chargeback): take the money back now; give it back if we win.
  if (event.type === 'charge.dispute.created') {
    const dp = event.data.object;
    const pi = piId(dp.payment_intent);
    if (!pi || !Number.isInteger(dp.amount)) return ok({ received: true, ignored: 'no payment' });
    const { data, error } = await admin.rpc('reverse_wallet_topup', { p_payment_intent: pi, p_total_reversed: dp.amount, p_event: event.id, p_reason: 'chargeback' });
    if (error) { console.error('dispute reverse failed', error.message); return ok({ error: 'reverse_failed' }, 500); }
    return ok({ received: true, reversed: data });
  }
  if (event.type === 'charge.dispute.closed') {
    const dp = event.data.object;
    const pi = piId(dp.payment_intent);
    if (dp.status !== 'won' || !pi || !Number.isInteger(dp.amount)) return ok({ received: true, ignored: 'dispute not won' });
    const { data, error } = await admin.rpc('restore_wallet_topup', { p_payment_intent: pi, p_cents: dp.amount, p_event: event.id });
    if (error) { console.error('restore failed', error.message); return ok({ error: 'restore_failed' }, 500); }
    return ok({ received: true, restored: data });
  }

  if (event.type === 'identity.verification_session.verified') {
    const vs = event.data.object; const uid = vs.metadata?.user_id;
    if (!uid || !UUID.test(uid)) return ok({ received: true, ignored: 'no user' });
    let age = null;
    try {
      const full = await stripeFetch('/v1/identity/verification_sessions/' + vs.id, { method: 'GET', params: { expand: ['verified_outputs'] } });
      age = ageFromDob(full.verified_outputs?.dob);
    } catch (e) { console.error('could not read verified outputs', e.message); }
    const pass = age !== null && age >= 18;           // fail closed: unknown age is NOT verified
    const { error } = await admin.rpc('set_age_verified_from_provider', { p_user: uid, p_event: vs.id, p_ok: pass,
      p_note: pass ? 'document verified, 18+' : age === null ? 'date of birth unavailable' : 'under 18' });
    if (error) return ok({ error: 'record_failed' }, 500);
    return ok({ received: true, verified: pass });
  }

  return ok({ received: true });   // other events are acknowledged and ignored
}
