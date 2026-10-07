# Stripe Connect sample

A small, runnable example of a Connect marketplace: **onboard sellers → create products → sell from a storefront**. Every line of `server.js` is commented so you can follow what each Stripe call does. The pages use the same dark look as the OverVibez app.

It is a **demo**: no login, no database, in-memory/browser state only. Do not deploy it as-is. It is separate from the OverVibez app (which pays creators from a wallet — see "How this differs from the live app" below).

## What it does

| Step | Stripe API used |
|---|---|
| Create a connected account (platform sets prices and collects fees) | `stripeClient.v2.core.accounts.create` (Accounts v2, `dashboard: 'express'`, recipient configuration, **no** top-level `type`) |
| Onboard the seller | `stripeClient.v2.core.accountLinks.create` (`account_onboarding`, `recipient`) |
| Show onboarding status | `stripeClient.v2.core.accounts.retrieve(id, { include: ['configuration.recipient', 'requirements'] })` — read live, never stored |
| React to requirement changes | thin v2 events: `parseEventNotification` → `v2.core.events.retrieve` → handler per event type |
| Create products | `stripeClient.products.create` on the **platform**; the owning account id is saved in `metadata.connected_account_id` |
| Storefront | `stripeClient.products.list` + `stripeClient.v2.core.accounts.list` |
| Pay | `stripeClient.checkout.sessions.create` — hosted Checkout, **destination charge** with `application_fee_amount` |

All requests go through one `stripeClient`. The API version is not set; the SDK (`stripe` v23, API `2026-09-30.endive`) supplies it.

## Run it

```bash
cd samples/stripe-connect
npm install
cp .env.example .env      # then edit .env
npm start                 # http://localhost:4242
```

Values to fill in `.env` (the server stops with a clear message if `STRIPE_SECRET_KEY` is missing):

- `STRIPE_SECRET_KEY` — Dashboard → Developers → API keys (use the **test** key `sk_test_…`).
- `STRIPE_WEBHOOK_SECRET` — signing secret `whsec_…` for the requirements webhook (see below). Only needed for that webhook.
- `APP_URL` — leave as `http://localhost:4242` locally; use your public `https://` address when deployed.
- `APPLICATION_FEE_PERCENT` — the platform's cut (default 15, like OverVibez).

**Prerequisite:** Connect and Accounts v2 must be enabled on your Stripe account (Dashboard → Connect). Until they are, creating or listing accounts returns Stripe's message "Accounts v2 is not enabled…", which the pages show as-is. Choose the **Marketplace** business model when asked.

## Try it (test mode)

1. **Connected accounts** → create a seller → **Onboard to collect payments**. In test mode Stripe's hosted form accepts test details (it offers to fill them in).
2. Come back: the card shows *Ready to receive payments* once Stripe activates the transfers capability.
3. **Products** → create a product for that seller.
4. **Storefront** → **Buy**. Pay with `4242 4242 4242 4242`, any future date, any CVC. The platform keeps the fee; the rest is transferred to the seller.

## Listen for requirement changes (thin events)

Locally, with the [Stripe CLI](https://docs.stripe.com/cli/listen):

```bash
stripe listen \
  --thin-events 'v2.core.account[requirements].updated,v2.core.account[configuration.recipient].capability_status_updated' \
  --forward-thin-to localhost:4242/webhooks/stripe
```

The CLI prints a signing secret — put it in `.env` as `STRIPE_WEBHOOK_SECRET` and restart.

In production, create an event destination instead: Dashboard → Developers → Webhooks → **+ Add destination** → *Events from:* **Connected accounts** → *Show advanced options* → *Payload style:* **Thin** → events `v2.core.account[requirements].updated` and `v2.core.account[configuration.recipient].capability_status_updated`.

The handlers (`eventHandlers` in `server.js`) just log. Replace the `TODO`s with real actions (email the owner, pause products).

## Tests

`node test/smoke.js` — runs the real server against a fake Stripe client (no network, no key) and checks: the exact account-creation properties, onboarding link, status logic, products + metadata mapping, destination charge + fee maths, and webhook signature/dispatch.

## How this differs from the live OverVibez app

The live app does **not** use destination charges. Followers top up an OverVibez wallet; sales are settled inside the database (85% creator / 15% platform); creators are paid out with Stripe **Transfers** to Connect accounts (`supabase/functions/payouts`). This sample is the reference for the Connect pieces that overlap — account creation, onboarding links, status checks and requirement webhooks — and for selling per-seller products with destination charges if you ever want that model. Note the live payouts function currently creates accounts with the older v1 API; moving it to the v2 calls in this sample is a separate change.
