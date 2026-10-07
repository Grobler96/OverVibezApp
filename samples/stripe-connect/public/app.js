/* Small helpers shared by every page. Plain JavaScript, no framework. */

// Call our own server and return the JSON. Throws an Error with the server's message if it fails.
async function api(path, body) {
  const res = await fetch(path, body === undefined
    ? undefined
    : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `Request failed (${res.status})`);
  return data;
}

// Format an amount in the smallest unit (pence/cents) for display, e.g. 499 + "gbp" -> "£4.99".
function money(amountInSmallestUnit, currency) {
  return new Intl.NumberFormat(undefined, { style: 'currency', currency: String(currency || 'gbp').toUpperCase() })
    .format(amountInSmallestUnit / 100);
}

// Build an element safely (text is never parsed as HTML, so names typed by users cannot inject markup).
function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v);
  }
  for (const c of children) node.append(c instanceof Node ? c : document.createTextNode(String(c)));
  return node;
}

// Show a message under a form. Pass kind "err" or "good".
function say(target, text, kind) {
  target.textContent = text || '';
  target.className = 'msg' + (kind ? ' ' + kind : '');
}

// The same top bar on every page.
function nav(active) {
  const links = [['onboard.html', 'Connected accounts'], ['products.html', 'Products'], ['storefront.html', 'Storefront']];
  const bar = el('nav', {}, el('a', { class: 'logo', href: '/' }, 'OverVibez · Connect sample'),
    ...links.map(([href, label]) => el('a', { class: 'link' + (href === active ? ' on' : ''), href }, label)));
  document.body.prepend(bar);
}

// This demo remembers "my" connected account in the browser, because it has no login or database.
const mine = {
  get: () => { try { return localStorage.getItem('sample_account_id') || ''; } catch (e) { return ''; } },
  set: (id) => { try { localStorage.setItem('sample_account_id', id); } catch (e) { /* ignore */ } },
};
