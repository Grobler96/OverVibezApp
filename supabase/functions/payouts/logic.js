// Creator payouts through Stripe Connect (Express accounts). Money flow: the creator's earnings are debited first (request_payout),
// then a Stripe Transfer moves the same amount to their connected account; if the transfer fails the earnings are put back.
// deps: { admin (service-role supabase), userClient (the caller's own login), stripe(path, opts), user: {id,email}, site, currency }

const friendly = (msg) => (/not.*connect|signed up for connect/i.test(msg || '') ? 'Payouts are not switched on yet — please try again soon.' : msg);

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

/** Starts (or resumes) Stripe's hosted onboarding. Returns { url }. */
export async function startOnboarding(deps) {
  await requireCreator(deps);
  const { admin, stripe, user, site } = deps;
  let acct = await loadAccount(deps);
  let accountId = acct?.stripe_account_id;
  if (!accountId) {
    const a = await stripe('/v1/accounts', { params: { type: 'express', country: 'GB', email: user.email, business_type: 'individual',
      capabilities: { transfers: { requested: true } }, metadata: { user_id: user.id } }, idempotencyKey: 'acct_' + user.id });
    accountId = a.id;
    const { error } = await admin.from('payout_accounts').upsert({ user_id: user.id, stripe_account_id: accountId }, { onConflict: 'user_id' });
    if (error) throw new Error('could not save the payout account');
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

/** Pays out the creator's whole earnings balance. Returns { ok, amount_cents } or { error, code }. */
export async function runPayout(deps) {
  const { admin, userClient, stripe, user, currency } = deps;
  const p = await requireCreator(deps);
  const acct = await loadAccount(deps);
  if (!acct) return { error: 'Set up your payout account first', code: 'no_account' };
  const fresh = await refreshAccount(deps, acct.stripe_account_id);
  if (!fresh.payouts_enabled) return { error: 'Finish setting up your payout account first', code: 'not_enabled' };
  const amount = Number(p.earnings_cents);
  if (!(amount >= 1000)) return { error: 'The minimum payout is £10.00', code: 'too_small' };

  // 1) take the money out of earnings and record the payout (atomic, in the database)
  const { data: payoutId, error: reqErr } = await userClient.rpc('request_payout', { p_amount: amount });
  if (reqErr || !payoutId) return { error: friendly(reqErr?.message) || 'Could not start the payout', code: 'request_failed' };

  // 2) move it to their Stripe account; the idempotency key means a retry can never pay twice
  let transfer;
  try {
    transfer = await stripe('/v1/transfers', { params: { amount, currency, destination: acct.stripe_account_id,
      transfer_group: 'payout_' + payoutId, metadata: { payout_id: payoutId, user_id: user.id } }, idempotencyKey: 'payout_' + payoutId });
  } catch (e) {
    console.error('transfer failed', payoutId, e.message);
    await admin.rpc('fail_payout', { p_payout: payoutId, p_reason: String(e.message).slice(0, 250) });     // earnings go back
    return { error: 'The payout could not be sent just now — your money is safe in your earnings. Please try again later.', code: 'transfer_failed' };
  }

  // 3) record that it went. The transfer already happened, so retry rather than ever undoing it.
  for (let i = 0; i < 3; i++) {
    const { error } = await admin.rpc('mark_payout_sent', { p_payout: payoutId, p_transfer: transfer.id });
    if (!error) return { ok: true, amount_cents: amount };
    console.error('mark_payout_sent failed', payoutId, transfer.id, error.message);
  }
  return { ok: true, amount_cents: amount, warning: 'sent_but_not_recorded' };
}
