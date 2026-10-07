/**
 * Smoke test for the sample, with NO network access and NO real Stripe key.
 * It swaps the Stripe SDK for a small fake, starts the real server.js, and checks the important behaviour:
 * the account is created with the exact v2 properties, onboarding links, status maths, products are saved
 * on the platform with the account id in metadata, checkout builds a destination charge with the right fee,
 * and the webhook verifies and dispatches thin events.
 *
 * Run:  node test/smoke.js
 */
'use strict';
const assert = require('assert');
const path = require('path');

const calls = []; // every call our server makes to the fake Stripe client
const log = (name, args) => { calls.push({ name, args }); };

// ---- a fake Stripe client with only the methods the sample uses ----
const accounts = {};
class FakeStripe {
  constructor(key) { this.key = key; }
  parseEventNotification(body, sig, secret) {
    if (sig !== 'good-signature' || secret !== 'whsec_test') throw new Error('bad signature');
    return JSON.parse(body.toString());
  }
  get v2() {
    return { core: {
      accounts: {
        create: async (p) => { log('accounts.create', p); const id = 'acct_' + (Object.keys(accounts).length + 1); accounts[id] = { id, display_name: p.display_name, contact_email: p.contact_email }; return accounts[id]; },
        retrieve: async (id, opts) => {
          log('accounts.retrieve', { id, opts }); const a = accounts[id]; if (!a) { const e = new Error('No such account'); e.statusCode = 404; throw e; }
          const ready = !!a.ready;
          return { ...a, configuration: { recipient: { capabilities: { stripe_balance: { stripe_transfers: { status: ready ? 'active' : 'restricted' } } } } },
            requirements: { summary: { minimum_deadline: { status: ready ? 'eventually_due' : 'currently_due' } } } };
        },
        list: async () => ({ data: Object.values(accounts) }),
      },
      accountLinks: { create: async (p) => { log('accountLinks.create', p); return { url: 'https://connect.stripe.test/onboard/' + p.account }; } },
      events: { retrieve: async (id) => { log('events.retrieve', id); return { id, type: global.__eventType, related_object: { id: 'acct_1' } }; } },
    } };
  }
  get products() {
    return {
      create: async (p) => { log('products.create', p); FakeStripe.product = { id: 'prod_1', name: p.name, description: p.description, metadata: p.metadata, default_price: { unit_amount: p.default_price_data.unit_amount, currency: p.default_price_data.currency } }; return FakeStripe.product; },
      list: async () => ({ data: FakeStripe.product ? [FakeStripe.product] : [] }),
      retrieve: async () => FakeStripe.product,
    };
  }
  get checkout() {
    return { sessions: {
      create: async (p) => { log('checkout.sessions.create', p); return { url: 'https://checkout.stripe.test/pay' }; },
      retrieve: async () => ({ status: 'complete', payment_status: 'paid', amount_total: 1000, currency: 'gbp' }),
    } };
  }
}

// Make `require('stripe')` inside server.js return the fake.
const stripePath = require.resolve('stripe', { paths: [path.join(__dirname, '..')] });
require.cache[stripePath] = { id: stripePath, filename: stripePath, loaded: true, exports: FakeStripe };

process.env.STRIPE_SECRET_KEY = 'sk_test_fake';
process.env.STRIPE_WEBHOOK_SECRET = 'whsec_test';
process.env.PORT = '4398';
process.env.APP_URL = 'http://localhost:4398';
process.env.APPLICATION_FEE_PERCENT = '15';
require('../server.js');

const base = 'http://localhost:4398';
const post = (p, body, headers = {}) => fetch(base + p, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) });
const ok = (m) => console.log('PASS ' + m);
const last = (name) => calls.filter((c) => c.name === name).pop().args;

(async () => {
  await new Promise((r) => setTimeout(r, 500));

  // 1. Account creation uses exactly the v2 properties and never a top-level type
  let r = await post('/api/accounts', { displayName: 'Jane', email: 'jane@example.com', country: 'GB' });
  assert.equal(r.status, 200); const { accountId } = await r.json(); assert.equal(accountId, 'acct_1');
  const create = last('accounts.create');
  assert.equal(create.type, undefined, 'must not pass top-level type');
  assert.equal(create.dashboard, 'express'); assert.equal(create.identity.country, 'gb');
  assert.deepEqual(create.defaults.responsibilities, { fees_collector: 'application', losses_collector: 'application' });
  assert.equal(create.configuration.recipient.capabilities.stripe_balance.stripe_transfers.requested, true);
  ok('creates the connected account with the v2 properties and no top-level type');

  r = await post('/api/accounts', { displayName: '', email: 'x' }); assert.equal(r.status, 400); ok('rejects a bad account form with a clear error');

  // 2. Onboarding link + status
  r = await post('/api/accounts/acct_1/onboard', {}); const link = await r.json();
  assert.match(link.url, /connect\.stripe\.test/);
  const lp = last('accountLinks.create');
  assert.equal(lp.use_case.type, 'account_onboarding'); assert.deepEqual(lp.use_case.account_onboarding.configurations, ['recipient']);
  assert.ok(lp.use_case.account_onboarding.return_url.includes('accountId=acct_1')); ok('creates a v2 onboarding link with refresh and return urls');

  let s = await (await fetch(base + '/api/accounts/acct_1/status')).json();
  assert.equal(s.readyToReceivePayments, false); assert.equal(s.onboardingComplete, false); ok('status: not ready while requirements are currently due');
  accounts.acct_1.ready = true;
  s = await (await fetch(base + '/api/accounts/acct_1/status')).json();
  assert.equal(s.readyToReceivePayments, true); assert.equal(s.onboardingComplete, true); ok('status: ready once transfers are active and nothing is due');

  // 3. Products are created on the platform, mapped to the account in metadata
  r = await post('/api/products', { accountId: 'acct_1', name: 'Print', description: '', priceInCents: 1000, currency: 'GBP' }); assert.equal(r.status, 200);
  const pc = last('products.create');
  assert.equal(pc.metadata.connected_account_id, 'acct_1'); assert.deepEqual(pc.default_price_data, { unit_amount: 1000, currency: 'gbp' }); assert.equal(pc.description, undefined);
  ok('creates the product on the platform with the connected account id in metadata');
  r = await post('/api/products', { accountId: 'acct_nope', name: 'x', priceInCents: 1000 }); assert.equal(r.status, 404); ok('refuses a product for an unknown account');
  r = await post('/api/products', { accountId: 'acct_1', name: 'x', priceInCents: 5 }); assert.equal(r.status, 400); ok('rejects a price that is too low');

  const list = await (await fetch(base + '/api/products')).json();
  assert.equal(list.products[0].unitAmount, 1000); assert.equal(list.products[0].accountId, 'acct_1'); ok('storefront lists products with price and seller');

  // 4. Checkout: destination charge with a 15% application fee
  r = await post('/api/checkout', { productId: 'prod_1', quantity: 2 }); assert.equal(r.status, 200);
  const cs = last('checkout.sessions.create');
  assert.equal(cs.mode, 'payment'); assert.equal(cs.payment_intent_data.transfer_data.destination, 'acct_1');
  assert.equal(cs.payment_intent_data.application_fee_amount, 300, '15% of 2 x 1000');
  assert.equal(cs.line_items[0].quantity, 2); assert.equal(cs.line_items[0].price_data.unit_amount, 1000);
  assert.ok(cs.success_url.includes('{CHECKOUT_SESSION_ID}')); ok('checkout is a destination charge with the right application fee');
  accounts.acct_1.ready = false;
  r = await post('/api/checkout', { productId: 'prod_1', quantity: 1 }); assert.equal(r.status, 400); ok('checkout is refused while the seller is not onboarded');
  accounts.acct_1.ready = true;
  r = await post('/api/checkout', { productId: 'prod_1', quantity: 0 }); assert.equal(r.status, 400); ok('checkout rejects a bad quantity');

  // 5. Webhook: signature check, fetch full event, dispatch by type
  const body = JSON.stringify({ id: 'evt_1', object: 'v2.core.event', type: 'v2.core.account[requirements].updated' });
  global.__eventType = 'v2.core.account[requirements].updated';
  r = await post('/webhooks/stripe', body, { 'stripe-signature': 'bad' }); assert.equal(r.status, 400); ok('webhook rejects a bad signature');
  r = await post('/webhooks/stripe', body, { 'stripe-signature': 'good-signature' }); assert.equal(r.status, 200);
  assert.ok(calls.some((c) => c.name === 'events.retrieve' && c.args === 'evt_1')); ok('webhook verifies, fetches the full event and handles requirements.updated');
  global.__eventType = 'v2.core.account[configuration.recipient].capability_status_updated';
  r = await post('/webhooks/stripe', body, { 'stripe-signature': 'good-signature' }); assert.equal(r.status, 200); ok('webhook handles capability_status_updated');
  global.__eventType = 'v2.core.something.else';
  r = await post('/webhooks/stripe', body, { 'stripe-signature': 'good-signature' }); assert.equal(r.status, 200); ok('webhook ignores unknown event types');

  console.log('\nAll smoke tests passed.');
  process.exit(0);
})().catch((e) => { console.error('FAIL', e.message); process.exit(1); });
