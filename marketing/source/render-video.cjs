// Renders the animated OverVibez launch video: frames via Playwright, encoding via ffmpeg.
const fs = require('fs'), path = require('path'), { execFileSync } = require('child_process');
const { chromium } = require('/opt/node-tools/node_modules/playwright');
const [build, outDir, fmtId, frameDir] = process.argv.slice(2);
const SIZES = { story: [1080, 1920], post: [1080, 1350] }, FPS = 30, SECONDS = 12;
const icon = (inner) => `<svg viewBox="0 0 24 24">${inner}</svg>`;
const ICONS = {
  ICON_STAR: icon('<path d="M12 3l2.2 5.6L20 9.3l-4.4 3.9L17 19l-5-3.1L7 19l1.4-5.8L4 9.3l5.8-.7L12 3z"/>'),
  ICON_HEART: icon('<path d="M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z"/>'),
  ICON_GIFT: icon('<rect x="4" y="9" width="16" height="11" rx="1.5"/><path d="M12 9v11M3 9h18v-3H3zM12 6c-1-3-5-3.5-5-1.2C7 6 9 6 12 6zm0 0c1-3 5-3.5 5-1.2C17 6 15 6 12 6z"/>'),
};
(async () => {
  let html = fs.readFileSync(path.join(build, 'video.template.html'), 'utf8');
  html = html.replace('/*{{FONTS}}*/', fs.readFileSync(path.join(build, 'fonts-embedded.css'), 'utf8'));
  for (const [k, v] of Object.entries(ICONS)) html = html.split('{{' + k + '}}').join(v);
  const [W, H] = SIZES[fmtId];
  fs.mkdirSync(frameDir, { recursive: true });
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium', args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
  await page.setContent(html, { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready); await page.waitForTimeout(400);
  await page.evaluate((id) => window.setup(id), fmtId);
  const n = FPS * SECONDS;
  for (let i = 0; i < n; i++) {
    await page.evaluate((t) => window.render(t), i / FPS);
    await page.screenshot({ path: path.join(frameDir, 'f' + String(i).padStart(4, '0') + '.png'), clip: { x: 0, y: 0, width: W, height: H } });
  }
  await browser.close();
  const mp4 = path.join(outDir, `overvibez-launch-${fmtId === 'story' ? 'story-1080x1920' : 'feed-1080x1350'}.mp4`);
  // H.264 + silent AAC track: plays everywhere (Instagram, TikTok, Facebook, WhatsApp).
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(FPS), '-i', path.join(frameDir, 'f%04d.png'),
    '-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=stereo', '-shortest', '-t', String(SECONDS),
    '-c:v', 'libx264', '-profile:v', 'high', '-pix_fmt', 'yuv420p', '-crf', '17', '-preset', 'slow', '-movflags', '+faststart',
    '-c:a', 'aac', '-b:a', '96k', mp4]);
  console.log('wrote', mp4, (fs.statSync(mp4).size / 1048576).toFixed(1) + ' MB');
})().catch(e => { console.error('FAIL', e.message); process.exit(1); });
