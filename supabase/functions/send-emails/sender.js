// Sends queued notification emails through Resend. deps: { admin (service-role supabase), fetchFn, apiKey, from, site, limit }
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

export function renderEmail(subject, body, site) {
  const html = `<div style="font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#211736">
<h2 style="margin:0 0 14px;color:#FF3D8A">${esc(subject)}</h2>
<p style="font-size:15px;line-height:1.6;margin:0 0 18px">${esc(body).replace(/\n/g, '<br>')}</p>
<p style="margin:0 0 24px"><a href="${esc(site)}" style="background:#8B5CF6;color:#fff;text-decoration:none;padding:11px 18px;border-radius:10px;font-weight:600">Open OverVibez</a></p>
<p style="font-size:12px;color:#7A6C96;line-height:1.5;margin:0">You are getting this because email notifications are switched on for your account. You can turn them off any time in OverVibez under Me → Email notifications.</p></div>`;
  const text = `${body}\n\nOpen OverVibez: ${site}\n\nYou are getting this because email notifications are switched on. Turn them off in OverVibez under Me → Email notifications.`;
  return { html, text };
}

/** Returns { claimed, sent, failed }. Safe to run often and from several places at once (rows are claimed with skip-locked). */
export async function sendBatch({ admin, fetchFn = fetch, apiKey, from, site, limit = 20 }) {
  const { data: rows, error } = await admin.rpc('claim_emails', { p_limit: limit });
  if (error) throw new Error('claim failed: ' + error.message);
  let sent = 0, failed = 0;
  for (const row of rows || []) {
    let ok = false, err = null;
    try {
      const { data: u } = await admin.auth.admin.getUserById(row.user_id);
      const user = u?.user;
      if (!user?.email || !user.email_confirmed_at) throw new Error('no confirmed email address');
      const { html, text } = renderEmail(row.subject, row.body, site);
      const res = await fetchFn('https://api.resend.com/emails', { method: 'POST',
        headers: { Authorization: 'Bearer ' + apiKey, 'Content-Type': 'application/json', 'Idempotency-Key': 'ov-email-' + row.id },
        body: JSON.stringify({ from, to: [user.email], subject: row.subject, html, text }) });
      if (!res.ok) throw new Error('Resend ' + res.status + ': ' + (await res.text()).slice(0, 200));
      ok = true;
    } catch (e) { err = e.message; }
    await admin.rpc('finish_email', { p_id: row.id, p_ok: ok, p_error: err });
    if (ok) sent++; else failed++;
  }
  return { claimed: (rows || []).length, sent, failed };
}
