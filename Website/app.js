const root = document.documentElement;
const toggle = document.querySelector('.theme-toggle');
const systemTheme = matchMedia('(prefers-color-scheme: dark)');
let preference;
try { preference = localStorage.getItem('circuitstudio-theme'); } catch { /* Storage can be disabled. */ }
if (preference === 'dark' || preference === 'light') root.dataset.theme = preference;
function updateToggle() {
  const dark = root.dataset.theme ? root.dataset.theme === 'dark' : systemTheme.matches;
  toggle.textContent = dark ? '浅色' : '深色';
  toggle.setAttribute('aria-label', dark ? '切换浅色主题' : '切换深色主题');
  toggle.setAttribute('aria-pressed', String(dark));
}
toggle.addEventListener('click', () => {
  const dark = root.dataset.theme ? root.dataset.theme === 'dark' : systemTheme.matches;
  root.dataset.theme = dark ? 'light' : 'dark';
  try { localStorage.setItem('circuitstudio-theme', root.dataset.theme); } catch { /* Keep the selected theme for this visit. */ }
  updateToggle();
});
systemTheme.addEventListener('change', updateToggle);
updateToggle();
const captions = {
  schematic: '元件、连线、工程参数与波形，在同一个工作空间。',
  illustration: '框图、端口和箭头，让信号路径清晰可读。',
  blank: '没有预置电路。你的每个新文档，都从空白开始。'
};
const tabs = [...document.querySelectorAll('[role="tab"]')];
function selectTab(tab) {
  for (const item of tabs) {
    const selected = item === tab;
    item.setAttribute('aria-selected', String(selected));
    item.tabIndex = selected ? 0 : -1;
    document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
  }
  document.getElementById('view-caption').textContent = captions[tab.id.replace('tab-', '')];
}
for (const tab of tabs) {
  tab.addEventListener('click', () => selectTab(tab));
  tab.addEventListener('keydown', event => {
    let index = tabs.indexOf(tab);
    if (event.key === 'ArrowRight') index = (index + 1) % tabs.length;
    else if (event.key === 'ArrowLeft') index = (index - 1 + tabs.length) % tabs.length;
    else if (event.key === 'Home') index = 0;
    else if (event.key === 'End') index = tabs.length - 1;
    else return;
    event.preventDefault(); selectTab(tabs[index]); tabs[index].focus();
  });
}
if (!matchMedia('(prefers-reduced-motion: reduce)').matches && 'IntersectionObserver' in window) {
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) if (entry.isIntersecting) { entry.target.classList.add('visible'); observer.unobserve(entry.target); }
  }, { threshold: .08 });
  for (const element of document.querySelectorAll('.reveal')) { element.classList.add('reveal-ready'); observer.observe(element); }
}
const counter = document.getElementById('download-count');
async function refreshStats() {
  if (document.hidden) return;
  try {
    const response = await fetch('api/stats', { cache: 'no-store', credentials: 'omit' });
    if (!response.ok) throw new Error('Statistics unavailable');
    const stats = await response.json();
    if (!Number.isInteger(stats.downloads) || stats.downloads < 0) throw new Error('Invalid statistics');
    const label = `${stats.downloads.toLocaleString('zh-CN')} 位用户已下载`;
    if (counter.textContent !== label) counter.textContent = label;
    const release = stats.release;
    if (Number.isFinite(release.bytes) && release.bytes > 0) document.getElementById('download-size').textContent = `${(release.bytes / 1024 / 1024).toFixed(1)} MB · DMG`;
    if (typeof release.version === 'string') {
      document.getElementById('download-version').textContent = `当前版本 ${release.version} · 支持应用内更新`;
      document.querySelector('.checksum-link').href = `downloads/SHA256SUMS.txt?v=${encodeURIComponent(release.version)}`;
    }
  } catch { counter.textContent = '下载统计暂时不可用'; }
}
refreshStats();
setInterval(refreshStats, 5000);
document.addEventListener('visibilitychange', refreshStats);
const form = document.getElementById('download-form');
form.addEventListener('submit', async event => {
  event.preventDefault();
  const button = form.querySelector('button');
  const status = document.getElementById('download-status');
  button.disabled = true; status.dataset.error = 'false'; status.textContent = '正在准备安装包…';
  try {
    const response = await fetch('api/request-download', { method: 'POST', credentials: 'omit', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email: form.elements.email.value, company: form.elements.company.value }) });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(result.error || (response.status === 429 ? '请求较多，请稍后再试。' : '暂时无法下载，请稍后再试。'));
    if (typeof result.downloadURL !== 'string' || !/^api\/download\/[A-Za-z0-9_-]{43}$/.test(result.downloadURL)) throw new Error('下载链接无效，请稍后再试。');
    const link = document.createElement('a');
    link.href = result.downloadURL; link.textContent = '重新下载';
    status.replaceChildren(document.createTextNode('下载已准备好。若未开始，点击'), link, document.createTextNode('。'));
    window.location.assign(result.downloadURL);
    setTimeout(refreshStats, 2000);
  } catch (error) { status.dataset.error = 'true'; status.textContent = error.message; }
  finally { button.disabled = false; }
});
