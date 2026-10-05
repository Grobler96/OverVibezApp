// Mints a LiveKit access token (HS256 JWT) using only Web Crypto, so it runs in Deno/Supabase Edge Functions and Node.
// Kept dependency-free and pure so it can be tested against the official livekit-server-sdk.

const enc = new TextEncoder();
const b64url = (data) => {
  const bytes = typeof data === 'string' ? enc.encode(data) : new Uint8Array(data);
  let s = ''; for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

/**
 * @param {{apiKey:string, apiSecret:string, identity:string, room:string, role:'broadcaster'|'viewer', ttlSeconds?:number, now?:number}} o
 * Broadcasters may publish camera + microphone only. Viewers may only subscribe — they cannot publish tracks or data.
 */
export async function mintLiveKitToken(o) {
  const now = o.now ?? Math.floor(Date.now() / 1000);
  const ttl = o.ttlSeconds ?? 2 * 60 * 60;
  const broadcaster = o.role === 'broadcaster';
  const video = { room: o.room, roomJoin: true, canSubscribe: true, canPublish: broadcaster, canPublishData: false };
  if (broadcaster) video.canPublishSources = ['camera', 'microphone'];
  const payload = { iss: o.apiKey, sub: o.identity, nbf: now, exp: now + ttl, video };
  const head = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify(payload));
  const key = await crypto.subtle.importKey('raw', enc.encode(o.apiSecret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, enc.encode(head + '.' + body));
  return head + '.' + body + '.' + b64url(sig);
}
