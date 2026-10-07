/**
 * Stripe Connect sample integration (Node.js + Express)
 * =====================================================
 *
 * What this sample shows, in order:
 *   1. Create a connected account (Accounts v2 API) where the PLATFORM sets prices and collects fees.
 *   2. Onboard that account with a Stripe-hosted Account Link, and read its status straight from the API.
 *   3. Listen for "thin" v2 events when an account's requirements or capabilities change.
 *   4. Create products on the PLATFORM (not on the connected account) and remember which account owns each one.
 *   5. Show a storefront and take payments with a Destination Charge + application fee through hosted Checkout.
 *
 * Every Stripe request below goes through ONE Stripe client: `stripeClient`.
 * The Stripe API version is not set anywhere — the SDK uses the version it was built against.
 *
 * Run it:  see README.md  (copy .env.example to .env, fill in the values, `npm install`, `npm start`).
 *
 * NOTE: this is a demo. It has no user login and keeps no database, so anyone who can reach it can use it.
 * Do not deploy it as-is. In the real app, you would tie each connected account to your own user record.
 */

'use strict';

require('dotenv').config({ quiet: true }); // Loads variables from a local .env file into process.env
const path = require('path');
const express = require('express');
const Stripe = require('stripe'); // In stripe-node the default export is the client class

/* ---------------------------------------------------------------------------------------------
 * 0. Configuration — read from environment variables, with helpful errors when something is missing
 * ------------------------------------------------------------------------------------------- */

const PORT = Number(process.env.PORT) || 4242;

// The public root URL of this app. Stripe sends people back here after onboarding and after paying.
// Locally that is http://localhost:4242. When deployed, set APP_URL to your real https:// address.
const APP_URL = (process.env.APP_URL || `http://localhost:${PORT}`).replace(/\/+$/, '');

// How much of each sale the platform keeps, as a percentage. OverVibez keeps 15%.
const APPLICATION_FEE_PERCENT = Number(process.env.APPLICATION_FEE_PERCENT ?? 15);

// Default country for new connected accounts (two-letter code, lower case). A form field can override it.
const DEFAULT_ACCOUNT_COUNTRY = (process.env.DEFAULT_ACCOUNT_COUNTRY || 'gb').toLowerCase();

/**
 * Read a required setting, or stop with a message that says exactly what to do.
 * @param {string} name   environment variable name
 * @param {string} howTo  where to find the value
 */
function requireEnv(name, howTo) {
  const value = process.env[name];
  if (!value || /REPLACE_ME|your_/i.test(value)) {
    throw new Error(
      `\n\nMissing setting: ${name}\n` +
        `  ${howTo}\n` +
        `  Put it in the .env file next to server.js (copy .env.example to .env first).\n`
    );
  }
  return value;
}

// PLACEHOLDER: STRIPE_SECRET_KEY — your platform's secret API key.
// Find it in the Stripe Dashboard → Developers → API keys. Use a TEST key (starts sk_test_) while building.
let STRIPE_SECRET_KEY;
try {
  STRIPE_SECRET_KEY = requireEnv(
    'STRIPE_SECRET_KEY',
    'Stripe Dashboard → Developers → API keys → "Secret key" (starts with sk_test_ for test mode).'
  );
  if (!/^(sk|rk)_(test|live)_/.test(STRIPE_SECRET_KEY)) {
    throw new Error('\n\nSTRIPE_SECRET_KEY does not look like a Stripe secret key (it should start with sk_test_ or sk_live_).\n');
  }
} catch (err) {
  console.error(err.message);
  process.exit(1); // Nothing works without the key, so stop right away instead of failing on every request.
}

/* ---------------------------------------------------------------------------------------------
 * The Stripe client — used for EVERY Stripe request in this file.
 * ------------------------------------------------------------------------------------------- */
const stripeClient = new Stripe(STRIPE_SECRET_KEY);

/* ---------------------------------------------------------------------------------------------
 * Small helpers
 * ------------------------------------------------------------------------------------------- */

// Wrap an async route so any thrown error becomes a clean JSON error instead of crashing the server.
const route = (fn) => (req, res) =>
  Promise.resolve(fn(req, res)).catch((err) => {
    console.error(`[${req.method} ${req.path}]`, err.message);
    // Stripe errors carry a readable message (e.g. "Connect is not enabled on this account"). Pass it on.
    res.status(err.statusCode && err.statusCode < 600 ? err.statusCode : 500).json({ error: err.message });
  });

// Prices are stored in the smallest currency unit (pence for GBP, cents for USD): £4.99 → 499.
const isWholeNumber = (n) => Number.isInteger(n) && n > 0;

/**
 * Work out whether a connected account is ready, using the v2 Account object.
 * Always read this from the API — this demo deliberately does not copy it into a database.
 *
 *  - readyToReceivePayments: the account can receive transfers (the capability we asked for is active).
 *  - onboardingComplete:     Stripe has nothing outstanding that is due now or overdue.
 */
function summarizeAccount(account) {
  const transfersStatus = account?.configuration?.recipient?.capabilities?.stripe_balance?.stripe_transfers?.status;
  const readyToReceivePayments = transfersStatus === 'active';

  // "minimum_deadline" is the earliest requirement Stripe still needs from this account.
  const requirementsStatus = account?.requirements?.summary?.minimum_deadline?.status;
  const onboardingComplete = requirementsStatus !== 'currently_due' && requirementsStatus !== 'past_due';

  return {
    id: account.id,
    displayName: account.display_name || null,
    contactEmail: account.contact_email || null,
    readyToReceivePayments,
    onboardingComplete,
    transfersStatus: transfersStatus || 'not requested',
    requirementsStatus: requirementsStatus || 'none',
  };
}

// The two extra pieces of the v2 Account we need to compute the summary above.
const ACCOUNT_INCLUDE = ['configuration.recipient', 'requirements'];

/* ---------------------------------------------------------------------------------------------
 * Express app
 * ------------------------------------------------------------------------------------------- */
const app = express();

/* ---------------------------------------------------------------------------------------------
 * 3. Webhook: thin events about connected accounts
 * ---------------------------------------------------------------------------------------------
 * Account requirements can change at any time (new regulations, card-network rules, a document expiring).
 * Stripe tells us with "thin" v2 events. A thin event is just a small notification (an id and a type);
 * we then fetch the full event from the API to see what changed.
 *
 * IMPORTANT: this route must be registered BEFORE express.json(). Stripe signs the exact bytes it sends,
 * so we need the raw, unparsed body to verify the signature.
 *
 * Set up the event destination in the Dashboard (Developers → Webhooks → + Add destination):
 *   - Events from: Connected accounts
 *   - Show advanced options → Payload style: Thin
 *   - Events: v2.core.account[requirements].updated
 *             v2.core.account[configuration.recipient].capability_status_updated
 * For local testing, use the Stripe CLI instead (see README.md) — it prints a signing secret for you.
 */

// What to do for each event type. In a real app these would email the account owner, flag them in your
// admin screen, or update your own records. Here they just log what happened.
const eventHandlers = {
  // Fires when the list of things Stripe needs from the account changes (new, resolved or past due).
  'v2.core.account[requirements].updated': async (event) => {
    const accountId = event.related_object?.id;
    const account = await stripeClient.v2.core.accounts.retrieve(accountId, { include: ACCOUNT_INCLUDE });
    const summary = summarizeAccount(account);
    console.log(`[webhook] Requirements changed for ${accountId}:`, summary.requirementsStatus);
    if (!summary.onboardingComplete) {
      // TODO: tell the account owner there is more to fill in. A fresh onboarding link
      // (POST /api/accounts/:id/onboard) takes them straight to the missing items.
      console.log(`[webhook] ${accountId} needs to provide more information — send them a new onboarding link.`);
    }
  },

  // Fires when the "can receive transfers" capability turns active, restricted, or inactive.
  'v2.core.account[configuration.recipient].capability_status_updated': async (event) => {
    const accountId = event.related_object?.id;
    const account = await stripeClient.v2.core.accounts.retrieve(accountId, { include: ACCOUNT_INCLUDE });
    const summary = summarizeAccount(account);
    console.log(`[webhook] Transfers capability for ${accountId} is now: ${summary.transfersStatus}`);
    // TODO: when this stops being "active", pause that account's products or payouts until it is fixed.
  },
};

app.post('/webhooks/stripe', express.raw({ type: 'application/json' }), async (req, res) => {
  // PLACEHOLDER: STRIPE_WEBHOOK_SECRET — the signing secret of your event destination (starts whsec_).
  // Dashboard → Developers → Webhooks → your destination → "Signing secret",
  // or the one printed by `stripe listen` when you test locally.
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET;
  if (!webhookSecret || /REPLACE_ME|your_/i.test(webhookSecret)) {
    console.error('[webhook] STRIPE_WEBHOOK_SECRET is not set — cannot verify incoming events.');
    return res
      .status(500)
      .send('STRIPE_WEBHOOK_SECRET is not set. Copy the signing secret (whsec_...) from your Stripe event destination into .env.');
  }

  let notification;
  try {
    // Verifies the signature and turns the body into an event notification.
    // (This is the method that older SDK versions called parseThinEvent.)
    notification = stripeClient.parseEventNotification(req.body, req.headers['stripe-signature'], webhookSecret);
  } catch (err) {
    console.error('[webhook] Signature check failed:', err.message);
    return res.status(400).send(`Webhook signature verification failed: ${err.message}`);
  }

  try {
    // A thin notification only carries the id and type. Fetch the full event from the API to see the details.
    const event = await stripeClient.v2.core.events.retrieve(notification.id);

    const handler = eventHandlers[event.type];
    if (handler) await handler(event);
    else console.log(`[webhook] Ignoring event type ${event.type}`);

    res.json({ received: true });
  } catch (err) {
    console.error('[webhook] Handler failed:', err.message);
    res.status(500).send('Handler failed'); // A non-2xx makes Stripe retry later.
  }
});

// Everything else uses normal JSON bodies, and the static pages in /public.
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

/* ---------------------------------------------------------------------------------------------
 * 1. Create a connected account
 * ---------------------------------------------------------------------------------------------
 * We use the v2 Accounts API. The platform (us) is responsible for pricing, collecting fees, and
 * covering losses. The connected account only needs to receive transfers (a "recipient").
 *
 * Do NOT pass a top-level `type` ('express' / 'standard' / 'custom') — v2 accounts do not use it.
 * The Express-style dashboard is requested with `dashboard: 'express'` instead.
 */
app.post(
  '/api/accounts',
  route(async (req, res) => {
    const displayName = String(req.body.displayName || '').trim();
    const contactEmail = String(req.body.email || '').trim();
    const country = String(req.body.country || DEFAULT_ACCOUNT_COUNTRY).trim().toLowerCase();

    if (!displayName) return res.status(400).json({ error: 'Please enter a name for the account.' });
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(contactEmail)) return res.status(400).json({ error: 'Please enter a valid email address.' });
    if (!/^[a-z]{2}$/.test(country)) return res.status(400).json({ error: 'Country must be a two-letter code, e.g. gb or us.' });

    const account = await stripeClient.v2.core.accounts.create({
      display_name: displayName,
      contact_email: contactEmail,
      identity: { country },
      dashboard: 'express',
      defaults: {
        responsibilities: {
          fees_collector: 'application', // the platform collects fees
          losses_collector: 'application', // the platform covers losses (refunds, chargebacks)
        },
      },
      configuration: {
        recipient: {
          capabilities: {
            stripe_balance: {
              stripe_transfers: { requested: true }, // lets us send this account its share of each sale
            },
          },
        },
      },
    });

    // In a real app with a database, save the link between YOUR user and this Stripe account here:
    //   await db.users.update(currentUser.id, { stripeAccountId: account.id });
    // This demo has no users or database; the browser remembers the account id (localStorage) instead.
    res.json({ accountId: account.id });
  })
);

/* ---------------------------------------------------------------------------------------------
 * 2a. Onboard a connected account: create an Account Link
 * ---------------------------------------------------------------------------------------------
 * An Account Link is a short-lived, single-use Stripe-hosted page where the account owner enters their
 * details (identity, bank account, ...). Send the user to `url`. Never reuse a link — make a new one each time.
 */
app.post(
  '/api/accounts/:id/onboard',
  route(async (req, res) => {
    const accountId = req.params.id;
    const accountLink = await stripeClient.v2.core.accountLinks.create({
      account: accountId,
      use_case: {
        type: 'account_onboarding',
        account_onboarding: {
          configurations: ['recipient'],
          // If the link expires or was already used, Stripe sends the user here. The page then
          // automatically asks for a fresh link.
          refresh_url: `${APP_URL}/onboard.html?refresh=${encodeURIComponent(accountId)}`,
          // When the user finishes (or leaves) the Stripe page, they land here. We then read the account
          // status from the API — the redirect itself does not mean onboarding succeeded.
          return_url: `${APP_URL}/onboard.html?accountId=${encodeURIComponent(accountId)}`,
        },
      },
    });
    res.json({ url: accountLink.url });
  })
);

/* ---------------------------------------------------------------------------------------------
 * 2b. Read an account's onboarding status — always straight from the API
 * ------------------------------------------------------------------------------------------- */
app.get(
  '/api/accounts/:id/status',
  route(async (req, res) => {
    const account = await stripeClient.v2.core.accounts.retrieve(req.params.id, { include: ACCOUNT_INCLUDE });
    res.json(summarizeAccount(account));
  })
);

/* ---------------------------------------------------------------------------------------------
 * List connected accounts (with their status) — used by the dashboard, product form and storefront
 * ------------------------------------------------------------------------------------------- */
app.get(
  '/api/accounts',
  route(async (req, res) => {
    const page = await stripeClient.v2.core.accounts.list({ limit: 20 });
    // The list call does not include requirement details, so fetch each account's full status.
    const summaries = await Promise.all(
      page.data.map((a) =>
        stripeClient.v2.core.accounts.retrieve(a.id, { include: ACCOUNT_INCLUDE }).then(summarizeAccount)
      )
    );
    res.json({ accounts: summaries });
  })
);

/* ---------------------------------------------------------------------------------------------
 * 4. Create a product (on the PLATFORM account, not on the connected account)
 * ---------------------------------------------------------------------------------------------
 * The platform owns the catalogue and sets the prices. To know who gets paid when it sells, we store
 * the owning connected account's id in the product's metadata. (A database table would work too.)
 */
app.post(
  '/api/products',
  route(async (req, res) => {
    const name = String(req.body.name || '').trim();
    const description = String(req.body.description || '').trim();
    const priceInCents = Number(req.body.priceInCents);
    const currency = String(req.body.currency || 'gbp').trim().toLowerCase();
    const accountId = String(req.body.accountId || '').trim();

    if (!name) return res.status(400).json({ error: 'Please enter a product name.' });
    if (!isWholeNumber(priceInCents) || priceInCents < 100) {
      return res.status(400).json({ error: 'Price must be at least 1.00.' });
    }
    if (!/^[a-z]{3}$/.test(currency)) return res.status(400).json({ error: 'Currency must be a three-letter code, e.g. gbp.' });
    if (!accountId) return res.status(400).json({ error: 'Choose which connected account sells this product.' });

    // Make sure the account really exists (and belongs to this platform) before we attach products to it.
    await stripeClient.v2.core.accounts.retrieve(accountId);

    const product = await stripeClient.products.create({
      name,
      description: description || undefined, // Stripe rejects an empty string
      default_price_data: { unit_amount: priceInCents, currency },
      metadata: { connected_account_id: accountId }, // the product → connected account mapping
    });
    res.json({ productId: product.id });
  })
);

/* ---------------------------------------------------------------------------------------------
 * 5a. Storefront: list every active product
 * ------------------------------------------------------------------------------------------- */
app.get(
  '/api/products',
  route(async (req, res) => {
    // `expand` swaps the default price id for the full Price object, so we get the amount in one request.
    const products = await stripeClient.products.list({ active: true, limit: 100, expand: ['data.default_price'] });
    res.json({
      products: products.data
        .filter((p) => p.default_price && typeof p.default_price === 'object')
        .map((p) => ({
          id: p.id,
          name: p.name,
          description: p.description,
          unitAmount: p.default_price.unit_amount,
          currency: p.default_price.currency,
          accountId: p.metadata?.connected_account_id || null,
        })),
    });
  })
);

/* ---------------------------------------------------------------------------------------------
 * 5b. Buy a product: Checkout Session with a Destination Charge + application fee
 * ---------------------------------------------------------------------------------------------
 * How the money moves:
 *   - The customer pays the PLATFORM (the charge is created on our account).
 *   - `application_fee_amount` is what the platform keeps.
 *   - The rest is transferred automatically to `transfer_data.destination` (the connected account).
 * We use Stripe-hosted Checkout, so we never touch card details.
 */
app.post(
  '/api/checkout',
  route(async (req, res) => {
    const productId = String(req.body.productId || '');
    const quantity = Number(req.body.quantity ?? 1); // ?? (not ||) so a quantity of 0 is rejected, not turned into 1
    if (!productId) return res.status(400).json({ error: 'Missing productId.' });
    if (!Number.isInteger(quantity) || quantity < 1 || quantity > 20) return res.status(400).json({ error: 'Quantity must be between 1 and 20.' });

    // Always look the price up on the server. Never trust a price sent from the browser.
    const product = await stripeClient.products.retrieve(productId, { expand: ['default_price'] });
    const price = product.default_price;
    const destination = product.metadata?.connected_account_id;
    if (!price || typeof price !== 'object') return res.status(400).json({ error: 'This product has no price.' });
    if (!destination) return res.status(400).json({ error: 'This product is not linked to a connected account.' });

    // Don't take money for an account that cannot yet be paid out to.
    const account = summarizeAccount(await stripeClient.v2.core.accounts.retrieve(destination, { include: ACCOUNT_INCLUDE }));
    if (!account.readyToReceivePayments) {
      return res.status(400).json({ error: `${account.displayName || 'This seller'} has not finished onboarding yet, so this product cannot be bought.` });
    }

    const total = price.unit_amount * quantity;
    const applicationFee = Math.round((total * APPLICATION_FEE_PERCENT) / 100); // the platform's cut, in the smallest unit

    const session = await stripeClient.checkout.sessions.create({
      mode: 'payment',
      line_items: [
        {
          price_data: { currency: price.currency, product: product.id, unit_amount: price.unit_amount },
          quantity,
        },
      ],
      payment_intent_data: {
        application_fee_amount: applicationFee, // what the platform keeps
        transfer_data: { destination }, // where the rest is sent
      },
      // {CHECKOUT_SESSION_ID} is a literal that Stripe replaces with the real id.
      success_url: `${APP_URL}/success.html?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${APP_URL}/storefront.html`,
    });

    res.json({ url: session.url }); // send the customer to Stripe's hosted payment page
  })
);

// Used by the success page to show what was just paid.
app.get(
  '/api/checkout/:sessionId',
  route(async (req, res) => {
    const session = await stripeClient.checkout.sessions.retrieve(req.params.sessionId);
    res.json({
      status: session.status,
      paymentStatus: session.payment_status,
      amountTotal: session.amount_total,
      currency: session.currency,
    });
  })
);

// Tell the pages how much the platform keeps, so the UI can say so.
app.get('/api/config', (req, res) => res.json({ applicationFeePercent: APPLICATION_FEE_PERCENT, defaultCountry: DEFAULT_ACCOUNT_COUNTRY }));

app.listen(PORT, () => {
  console.log(`Stripe Connect sample running at ${APP_URL}`);
  if (!process.env.STRIPE_WEBHOOK_SECRET) {
    console.log('Tip: STRIPE_WEBHOOK_SECRET is not set yet — requirement-change webhooks will be rejected until you add it (see README.md).');
  }
});
