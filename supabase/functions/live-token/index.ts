// Edge function: POST { stream_id } -> { token, url, role, room, title }
// Runs with the CALLER's Supabase JWT, asks the database (live_access) whether they may broadcast/watch, and only then
// mints a short-lived LiveKit token. The LiveKit API secret exists only here (Supabase secret), never in the browser.
// Required secrets: LIVEKIT_URL (wss://...livekit.cloud), LIVEKIT_API_KEY, LIVEKIT_API_SECRET.
// Without them it fails closed with 503 {"error":"not_configured"}.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { mintLiveKitToken } from './token.js';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const url = Deno.env.get('LIVEKIT_URL'), apiKey = Deno.env.get('LIVEKIT_API_KEY'), apiSecret = Deno.env.get('LIVEKIT_API_SECRET');
  if (!url || !apiKey || !apiSecret) return json({ error: 'not_configured' }, 503);

  const auth = req.headers.get('Authorization');
  if (!auth) return json({ error: 'Not signed in' }, 401);
  let streamId: string | undefined;
  try { streamId = (await req.json()).stream_id; } catch { /* fallthrough */ }
  if (!streamId || !/^[0-9a-f-]{36}$/i.test(streamId)) return json({ error: 'stream_id required' }, 400);

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } });
  const { data: u, error: uerr } = await sb.auth.getUser();
  if (uerr || !u?.user) return json({ error: 'Not signed in' }, 401);

  const { data: access, error } = await sb.rpc('live_access', { p_stream: streamId });
  if (error) return json({ error: error.message }, 403);

  const token = await mintLiveKitToken({
    apiKey, apiSecret, identity: u.user.id, room: access.room,
    role: access.role === 'broadcaster' ? 'broadcaster' : 'viewer',
    ttlSeconds: access.role === 'broadcaster' ? 6 * 3600 : 2 * 3600,
  });
  return json({ token, url, role: access.role, room: access.room, title: access.title });
});
