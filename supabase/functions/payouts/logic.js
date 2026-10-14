// Creator payouts through Stripe Connect (Express accounts). Money flow: the creator's earnings are debited first (request_payout),
// then a Stripe Transfer moves the same amount to their connected account; if the transfer fails the earnings are put back.
// deps: { admin (service-role supabase), userClient (the caller's own login), stripe(path, opts), user: {id,email}, site, currency }

const friendly = (msg) => (/not.*connect|signed up for connect/i.test(msg || '') ? 'Payouts are not switched on yet. Please try again soon.' : msg);

async function refreshAccount({ admin, stripe, user }, accountId) {
  const a = await stripe('/v1/accounts/' + accountId, { method: 'GET' });
  const row = { user_id: user.id, stripe_account_id: accountId, details_submitted: !!a.details_submitted, payouts_enabled: !!(a.payouts_enabled && a.capabilities?.transfers === 'active'), updated_at: new Date().toISOString() };
  const { error } = await admin.from('payout_accounts').upsert(row, { onConflict: 'user_id' });
  if (error) throw new Error('could not save the payout account');
  return row;
}

async function loadAccount({ admin, user }) {
  const { data } = await admin.from('payout_accounts').select('*').eq('user_id', user.id).maybeSingle();
  return data || null;
}

async function requireCreator({ userClient }) {
  const { data, error } = await userClient.rpc('get_my_profile');
  const p = Array.isArray(data) ? data[0] : data;
  if (error || !p) throw new Error('Could not load your profile');
  if (p.account_type !== 'creator') throw new Error('Only creators can set up payouts');
  if (p.is_banned) throw new Error('Account suspended');
  if (!p.age_verified) throw new Error('Verify your age first (Me → Identity & age verification)');
  return p;
}

/** What Stripe's "business website" and "what do you sell" boxes are pre-filled with: the creator's own OverVibez page. */
export function businessProfile(site, username) {
  let origin = 'https://www.overvibez.com';
  try { origin = new URL(site).origin; } catch { /* keep the default */ }
  return { url: origin + '/' + username, product_description: 'Online content creator selling subscriptions, exclusive posts and live streams on OverVibez.' };
}

/** Starts (or resumes) Stripe's hosted onboarding. Returns { url }. */
export async function startOnboarding(deps) {
  const p = await requireCreator(deps);
  const { admin, stripe, user, site } = deps;
  const business_profile = p.username ? businessProfile(site, p.username) : undefined;
  let acct = await loadAccount(deps);
  let accountId = acct?.stripe_account_id;
  if (!accountId) {
    const a = await stripe('/v1/accounts', { params: { type: 'express', country: 'GB', email: user.email, business_type: 'individual', business_profile,
      capabilities: { transfers: { requested: true } }, metadata: { user_id: user.id } }, idempotencyKey: 'acct_' + user.id });
    accountId = a.id;
    const { error } = await admin.from('payout_accounts').upsert({ user_id: user.id, stripe_account_id: accountId }, { onConflict: 'user_id' });
    if (error) throw new Error('could not save the payout account');
  } else if (business_profile && !acct.details_submitted) {
    // started earlier but not finished: fill the boxes in now. Never touches an account that has already been submitted.
    try { await stripe('/v1/accounts/' + accountId, { params: { business_profile } }); } catch (e) { console.error('business_profile update failed', e.message); }
  }
  const link = await stripe('/v1/account_links', { params: { account: accountId, type: 'account_onboarding',
    refresh_url: site + '?connect=refresh', return_url: site + '?connect=return' } });
  return { url: link.url };
}

/** Re-reads the account from Stripe so the app knows whether payouts are switched on. */
export async function payoutStatus(deps) {
  const acct = await loadAccount(deps);
  if (!acct) return { connected: false, details_submitted: false, payouts_enabled: false };
  const row = await refreshAccount(deps, acct.stripe_account_id);
  return { connected: true, details_submitted: row.details_submitted, payouts_enabled: row.payouts_enabled };
}

/** Pays out the creator's whole earnings balance (or, with source 'bonus', the whole bonus balance). Returns { ok, amount_cents } or { error, code }. */
export async function runPayout(deps, source = 'earnings') {
  const bonus = source === 'bonus';
  const { admin, userClient, stripe, user, currency } = deps;
  const p = await requireCreator(deps);
  const acct = await loadAccount(deps);
  if (!acct) return { error: 'Set up your payout account first', code: 'no_account' };
  const fresh = await refreshAccount(deps, acct.stripe_account_id);
  if (!fresh.payouts_enabled) return { error: 'Finish setting up your payout account first', code: 'not_enabled' };
  let amount = Number(p.bonus_cents);
  if (!bonus) {      // sales earnings: only what is old enough (the payout hold) can be sent. The database enforces the same rule.
    const { data: bal } = await userClient.rpc('my_payout_balance');
    amount = Number(bal?.available_cents ?? 0);
    if (!(amount >= 1000) && Number(bal?.held_cents) > 0 && Number(bal?.earnings_cents) >= 1000) {
      const when = bal.release_at ? ' The first of it is ready on ' + new Date(bal.release_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', timeZone: 'Europe/London' }) + '.' : '';
      return { error: 'Your latest earnings are held for ' + bal.hold_days + ' days so payments can land.' + when, code: 'held' };
    }
  }
  if (!(amount >= 1000)) return { error: 'The minimum payout is £10.00', code: 'too_small' };

  // 1) take the money out of earnings and record the payout (atomic, in the database)
  const { data: payoutId, error: reqErr } = await userClient.rpc(bonus ? 'request_bonus_payout' : 'request_payout', { p_amount: amount });
  if (reqErr || !payoutId) return { error: friendly(reqErr?.message) || 'Could not start the payout', code: 'request_failed' };

  // 2) move it to their Stripe account; the idempotency key means a retry can never pay twice
  let transfer;
  try {
    transfer = await stripe('/v1/transfers', { params: { amount, currency, destination: acct.stripe_account_id,
      transfer_group: 'payout_' + payoutId, metadata: { payout_id: payoutId, user_id: user.id } }, idempotencyKey: 'payout_' + payoutId });
  } catch (e) {
    console.error('transfer failed', payoutId, e.message);
    await admin.rpc(bonus ? 'fail_bonus_payout' : 'fail_payout', { p_payout: payoutId, p_reason: String(e.message).slice(0, 250) });     // the money goes back
    return { error: 'The payout could not be sent just now. Your money is safe in your balance. Please try again later.', code: 'transfer_failed' };
  }

  // 3) record that it went. The transfer already happened, so retry rather than ever undoing it.
  for (let i = 0; i < 3; i++) {
    const { error } = await admin.rpc('mark_payout_sent', { p_payout: payoutId, p_transfer: transfer.id });
    if (!error) return { ok: true, amount_cents: amount };
    console.error('mark_payout_sent failed', payoutId, transfer.id, error.message);
  }
  return { ok: true, amount_cents: amount, warning: 'sent_but_not_recorded' };
}
