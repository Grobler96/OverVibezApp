// Automatic safety check of uploaded photos. Plain JS with no imports so it can be unit-tested (tests/scan.test.js).
// Uses OpenAI's moderation service, which is free to use and reads images and text. Swap checkImage() to change provider.
// Videos are not scanned here: they wait for a person in the staff review queue.

// A post is held when a score reaches its limit. The limits are deliberately cautious: held posts are looked at by a person within
// minutes, whereas a missed post is live. 'urgent' means a possible risk to a child, which staff see first.
export const LIMITS = [
  { cat: 'sexual/minors', min: 0.10, severity: 'urgent' },
  { cat: 'sexual', min: 0.65, severity: 'normal' },
  { cat: 'violence/graphic', min: 0.80, severity: 'normal' },
  { cat: 'self-harm/instructions', min: 0.50, severity: 'normal' },
  { cat: 'self-harm/intent', min: 0.60, severity: 'normal' },
  { cat: 'illicit/violent', min: 0.80, severity: 'normal' },
  { cat: 'harassment/threatening', min: 0.80, severity: 'normal' },
  { cat: 'hate/threatening', min: 0.60, severity: 'normal' },
];

/** result = one entry of OpenAI's `results` array. Returns { flagged, severity, categories, scores }. */
export function decide(result) {
  const scores = (result && result.category_scores) || {};
  const hit = LIMITS.filter((l) => Number(scores[l.cat] || 0) >= l.min);
  const urgent = hit.some((h) => h.severity === 'urgent');
  const kept = {}; for (const l of LIMITS) if (scores[l.cat] !== undefined) kept[l.cat] = Math.round(Number(scores[l.cat]) * 1000) / 1000;
  return { flagged: hit.length > 0, severity: hit.length ? (urgent ? 'urgent' : 'normal') : null, categories: hit.map((h) => h.cat), scores: kept };
}

export async function checkImage({ fetchFn = fetch, apiKey, imageUrl, caption }) {
  const input = [];
  if (caption && caption.trim()) input.push({ type: 'text', text: caption.slice(0, 2000) });
  input.push({ type: 'image_url', image_url: { url: imageUrl } });
  const res = await fetchFn('https://api.openai.com/v1/moderations', { method: 'POST',
    headers: { Authorization: 'Bearer ' + apiKey, 'Content-Type': 'application/json' }, body: JSON.stringify({ model: 'omni-moderation-latest', input }) });
  if (!res.ok) throw new Error('moderation ' + res.status + ': ' + (await res.text()).slice(0, 160));
  const body = await res.json();
  if (!body.results || !body.results[0]) throw new Error('moderation gave no result');
  return decide(body.results[0]);
}

/** Works through one batch. deps: { admin (service-role supabase), fetchFn, apiKey, supabaseUrl, limit }. Returns counts. */
export async function runScans({ admin, fetchFn = fetch, apiKey, supabaseUrl, limit = 10 }) {
  const { data: claimed, error } = await admin.rpc('claim_media_scans', { p_limit: limit });
  if (error) throw new Error('claim failed: ' + error.message);
  const out = { claimed: (claimed || []).length, clean: 0, flagged: 0, review: 0, failed: 0 };
  for (const { post_id } of claimed || []) {
    try {
      const { data: post } = await admin.from('posts').select('id,caption,media_type,media_path,is_paid,subs_only,removed_at').eq('id', post_id).maybeSingle();
      if (!post || !post.media_path || post.media_type === 'video') { await admin.rpc('finish_media_scan', { p_post: post_id, p_status: 'review', p_severity: null, p_cats: [], p_scores: null, p_error: null }); out.review++; continue; }
      let url;
      if (post.is_paid || post.subs_only) {
        const { data: s, error: se } = await admin.storage.from('paid-media').createSignedUrl(post.media_path, 300);
        if (se || !s) throw new Error('could not open the file');
        url = s.signedUrl;
      } else url = supabaseUrl.replace(/\/$/, '') + '/storage/v1/object/public/public-media/' + post.media_path.split('/').map(encodeURIComponent).join('/');
      const r = await checkImage({ fetchFn, apiKey, imageUrl: url, caption: post.caption });
      await admin.rpc('finish_media_scan', { p_post: post_id, p_status: r.flagged ? 'flagged' : 'clean', p_severity: r.severity, p_cats: r.categories, p_scores: r.scores, p_error: null });
      out[r.flagged ? 'flagged' : 'clean']++;
    } catch (e) {
      await admin.rpc('finish_media_scan', { p_post: post_id, p_status: 'error', p_severity: null, p_cats: [], p_scores: null, p_error: String(e.message).slice(0, 250) });
      out.failed++;
    }
  }
  return out;
}
