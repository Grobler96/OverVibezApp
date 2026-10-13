// Turns a queued notification into the text of a push. Kept as plain JS with no imports so it can be unit-tested (tests/push.test.js).
// The wording matches the in-app notification list. Message text is never included. With "hide details" on, only a generic line is shown.
const money = (c) => '£' + (Number(c || 0) / 100).toFixed(2);
const clip = (s, n) => { s = String(s ?? ''); return s.length > n ? s.slice(0, n - 1) + '…' : s; };

export function composePush(row, opts = {}) {
  const d = row.data || {};
  const who = row.actor ? '@' + row.actor : 'Someone';
  let url = '/?go=notifs', title = 'OverVibez', body = 'You have new activity', tag = row.type;
  switch (row.type) {
    case 'new_follower': title = '👤 New follower'; body = `${who} started following you`; break;
    case 'new_subscriber': title = '💜 New subscriber'; body = `${who} subscribed to you${d.price_cents ? ' (' + money(d.price_cents) + '/mo)' : ''}`; break;
    case 'subscription_renewed': title = '🔁 Subscription renewed'; body = `${who} renewed their subscription`; break;
    case 'tip': title = '💰 You got a tip'; body = `${who} tipped you ${money(d.gross_cents)} — you keep ${money(d.net_cents)}`; break;
    case 'unlock': title = '🔓 Post unlocked'; body = `${who} unlocked your post — you earned ${money(d.net_cents)}`; break;
    case 'ticket': title = '🎟️ Ticket sold'; body = `${who} bought a ticket to your live stream — you earned ${money(d.net_cents)}`; break;
    case 'comment': title = '💬 New comment'; body = `${who}: “${clip(d.preview, 90)}”`; break;
    case 'like': title = '♥ New like'; body = `${who} liked your post`; break;
    case 'live': title = '🔴 Live now'; body = `${who} is live${d.title ? ': ' + clip(d.title, 80) : ''}`; url = row.ref_id ? '/?go=live&id=' + row.ref_id : '/?go=home'; break;
    case 'message': title = '✉️ New message'; body = `${who} sent you a message`; url = '/?go=messages'; break;
    case 'payout_paid': title = '🏦 Payout sent'; body = `Your payout of ${money(d.amount_cents)} has been sent`; break;
    case 'won': title = '🏆 You won!'; body = `You won ${clip(d.prize || 'a prize', 60)} in “${clip(d.title || 'a giveaway', 60)}”`; url = '/?go=raffles'; break;
    case 'prize_shipped': title = '📦 Prize on its way'; body = 'Your prize has been posted'; url = '/?go=raffles'; break;
    case 'removed': title = '⚠️ Content removed'; body = `A moderator removed your ${clip(d.kind || 'content', 20)}`; break;
    case 'raffle_result': title = '🎲 Draw complete'; body = `The draw for ${clip(d.prize || 'the raffle', 60)} is done`; url = '/?go=raffles'; break;
    case 'new_giveaway': title = '🎁 New giveaway'; body = `Free giveaway: ${clip(d.prize || 'a prize', 60)} — tap to enter`; url = '/?go=raffles'; break;
    case 'refunded': title = '↩️ Refund'; body = d.role === 'payee' ? `A sale was refunded — ${money(d.cents)} was taken from your earnings` : `You were refunded ${money(d.cents)} to your wallet`; break;
    case 'topup_reversed': title = '⚠️ Top-up reversed'; body = `A top-up of ${money(d.cents)} was reversed`; break;
    case 'topup_restored': title = '✅ Money restored'; body = `${money(d.cents)} was put back in your wallet`; break;
    case 'debt_repaid': title = '🧾 Balance cleared'; body = `${money(d.cents)} of your latest payment cleared what you owed`; break;
    case 'sub_renew_soon': title = '🔔 Renewal coming up'; body = `Your subscription to ${clip(d.creator || 'a creator', 40)} renews soon for ${money(d.cents)}`; break;
    case 'sub_renewed': title = '💜 Subscription renewed'; body = `${money(d.cents)} taken to renew ${clip(d.creator || 'a creator', 40)}`; break;
    case 'sub_renew_failed': title = '⚠️ Renewal failed'; body = `Your wallet was too low to renew ${clip(d.creator || 'a creator', 40)} — add funds`; url = '/?go=wallet'; break;
    case 'sub_ended': title = '💔 Subscription ended'; body = `Your subscription to ${clip(d.creator || 'a creator', 40)} has ended`; break;
    case 'collab_invite': title = '🤝 Collab invitation'; body = `@${clip(d.who || 'a creator', 30)} wants to post with you — you would get ${d.pct || 50}% of every sale`; url = '/?go=studio'; break;
    case 'collab_response': title = '🤝 Collab update'; body = d.left ? `@${clip(d.who || 'your collaborator', 30)} left your collab post` : `@${clip(d.who || 'they', 30)} ${d.accepted ? 'accepted' : 'declined'} your collab`; url = '/?go=studio'; break;
    case 'featured': title = '⭐ Creator of the Week'; body = 'You are featured at the top of Explore for 7 days!'; break;
    case 'bonus': title = '🎁 Bonus paid'; body = `OverVibez paid you a bonus of ${money(d.cents)}`; url = '/?go=studio'; break;
    case 'age_approved': title = '✅ 18+ check done'; body = 'You can now post, go live and add money'; break;
    case 'age_rejected': title = '⚠️ 18+ check'; body = 'Your 18+ check was not approved — you can request another from Me'; break;
    case 'appeal_result': title = '⚖️ Appeal reviewed'; body = d.action === 'overturn' ? 'Your appeal was accepted' : 'Your appeal has been reviewed'; break;
    default: break;
  }
  if (opts.discreet) { title = 'OverVibez'; body = 'You have new activity'; }
  return { title, body, url, tag: opts.discreet ? 'ov' : tag };
}
