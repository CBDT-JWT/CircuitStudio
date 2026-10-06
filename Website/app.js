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
fetch('downloads/release.json', { cache: 'no-cache' }).then(response => response.ok ? response.json() : Promise.reject()).then(release => {
  if (Number.isFinite(release.bytes) && release.bytes > 0) document.getElementById('download-size').textContent = `${(release.bytes / 1024 / 1024).toFixed(1)} MB · DMG`;
}).catch(() => { /* The direct download remains available without metadata. */ });
