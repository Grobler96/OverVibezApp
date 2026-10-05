// POST { confirm: "<username>" } -> { deleted: true }
// Permanently deletes the caller's account: checks it is allowed (no money owed either way, not the last admin), removes their
// uploaded files, then deletes the login — everything else (profile, posts, comments, messages, ...) is removed by cascade.
// Financial records are kept but anonymised (their user link is set to null).
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

async function listAll(admin: any, bucket: string, prefix: string): Promise<string[]> {
  const out: string[] = [];
  const { data } = await admin.storage.from(bucket).list(prefix, { limit: 1000 });
  for (const item of data ?? []) {
    if (item.id === null) out.push(...await listAll(admin, bucket, `${prefix}/${item.name}`));   // a "folder"
    else out.push(`${prefix}/${item.name}`);
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const auth = req.headers.get('Authorization');
  if (!auth) return json({ error: 'Not signed in' }, 401);
  const url = Deno.env.get('SUPABASE_URL')!;
  const sb = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } });
  const { data: u } = await sb.auth.getUser();
  if (!u?.user) return json({ error: 'Not signed in' }, 401);

  const { data: prof } = await sb.rpc('get_my_profile');
  let body: any = {}; try { body = await req.json(); } catch { /* ignore */ }
  if (!prof || String(body.confirm ?? '').trim().toLowerCase() !== prof.username) return json({ error: 'Type your username exactly to confirm' }, 400);

  const { error: gate } = await sb.rpc('can_delete_account');          // money owed / last admin checks, ends any live stream
  if (gate) return json({ error: gate.message }, 403);

  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const uid = u.user.id;
  for (const bucket of ['public-media', 'paid-media']) {
    try { const files = await listAll(admin, bucket, uid); if (files.length) await admin.storage.from(bucket).remove(files); }
    catch (e) { console.error('storage cleanup failed', bucket, (e as Error).message); return json({ error: 'Could not remove your files — nothing was deleted, please try again' }, 500); }
  }
  const { error } = await admin.auth.admin.deleteUser(uid);
  if (error) return json({ error: 'Could not delete the account: ' + error.message }, 500);
  return json({ deleted: true });
});
