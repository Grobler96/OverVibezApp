// Small dependency-free Stripe helpers (Deno + Node). Kept identical in each function folder.
const enc = new TextEncoder();

/** Flatten nested objects/arrays into Stripe's form encoding: a[b]=1, a[0][b]=2 */
export function formEncode(obj, prefix = '', out = new URLSearchParams()) {
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null) continue;
    const key = prefix ? `${prefix}[${k}]` : k;
    if (Array.isArray(v)) v.forEach((item, i) => (typeof item === 'object' ? formEncode(item, `${key}[${i}]`, out) : out.append(`${key}[${i}]`, String(item))));
    else if (typeof v === 'object') formEncode(v, key, out);
    else out.append(key, String(v));
  }
  return out;
}

export async function stripeFetch(secretKey, path, { method = 'POST', params = {}, idempotencyKey } = {}) {
  const qs = formEncode(params).toString();
  const isGet = method === 'GET';
  const res = await fetch('https://api.stripe.com' + path + (isGet && qs ? '?' + qs : ''), {
    method,
    headers: { Authorization: 'Bearer ' + secretKey, ...(isGet ? {} : { 'Content-Type': 'application/x-www-form-urlencoded' }), ...(idempotencyKey ? { 'Idempotency-Key': idempotencyKey } : {}) },
    body: isGet ? undefined : qs,
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data?.error?.message || 'Stripe error ' + res.status);
  return data;
}

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
function safeEqual(a, b) { if (a.length !== b.length) return false; let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i); return d === 0; }

/** Verifies a Stripe-Signature header: HMAC-SHA256 of `${t}.${rawBody}` with the endpoint secret, within `tolerance` seconds. */
export async function verifyStripeSignature(rawBody, header, secret, { tolerance = 300, now = Math.floor(Date.now() / 1000) } = {}) {
  if (!header || !secret) return false;
  const parts = Object.fromEntries(header.split(',').map((p) => { const i = p.indexOf('='); return [p.slice(0, i), p.slice(i + 1)]; }));
  const sigs = header.split(',').filter((p) => p.startsWith('v1=')).map((p) => p.slice(3));
  const t = parseInt(parts.t, 10);
  if (!t || !sigs.length || Math.abs(now - t) > tolerance) return false;
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const expected = hex(await crypto.subtle.sign('HMAC', key, enc.encode(`${t}.${rawBody}`)));
  return sigs.some((s) => safeEqual(s, expected));
}

/** Age in whole years from Stripe's verified date of birth {day, month, year}; null if unknown. */
export function ageFromDob(dob, now = new Date()) {
  if (!dob || !dob.year || !dob.month || !dob.day) return null;
  let age = now.getUTCFullYear() - dob.year;
  const had = now.getUTCMonth() + 1 > dob.month || (now.getUTCMonth() + 1 === dob.month && now.getUTCDate() >= dob.day);
  if (!had) age--;
  return age;
}
