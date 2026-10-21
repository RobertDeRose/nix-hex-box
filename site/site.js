document.documentElement.classList.add('js');

// Theme toggle: follows the system until clicked, then remembers the choice.
// The docs read and write the same `theme` key.
(() => {
  const root = document.documentElement;
  const button = document.querySelector('.theme-toggle');
  const system = matchMedia('(prefers-color-scheme: dark)');
  const current = () => root.dataset.theme || (system.matches ? 'dark' : 'light');
  const tint = document.querySelector('meta[name="theme-color"]');
  const show = () => {
    const theme = current();
    button.dataset.current = theme;
    button.setAttribute('aria-label', `Switch to ${theme === 'dark' ? 'light' : 'dark'} theme`);
    // Safari tints its toolbar from theme-color and doesn't follow the page's
    // own color changes, so keep the tag on the current page background.
    tint.content = getComputedStyle(root).getPropertyValue('--glass').trim();
  };
  button.addEventListener('click', () => {
    const next = current() === 'dark' ? 'light' : 'dark';
    root.dataset.theme = next;
    try { localStorage.setItem('theme', next); } catch {}
    show();
  });
  system.addEventListener('change', show);
  show();
})();

// Copy buttons copy the code next to them.
document.addEventListener('click', async (event) => {
  const button = event.target.closest('.copy');
  if (!button) return;
  const holder = button.closest('[data-copy]');
  const text = holder ? holder.dataset.copy : button.parentElement.querySelector('code').textContent;
  // The live region tells screen readers; the label change shows everyone else.
  const status = document.getElementById('copy-status');
  try {
    await navigator.clipboard.writeText(text);
    button.textContent = 'Copied';
    status.textContent = 'Copied to clipboard';
  } catch {
    button.textContent = 'Copy failed';
    status.textContent = 'Copy failed. Select the text and copy it instead.';
  }
  setTimeout(() => {
    button.textContent = 'Copy';
    status.textContent = '';
  }, 1600);
});

// Install tabs, with arrow-key navigation.
document.querySelectorAll('.tabs').forEach((set) => {
  const tabs = [...set.querySelectorAll('[role="tab"]')];
  const select = (tab) => {
    tabs.forEach((t) => {
      const on = t === tab;
      t.setAttribute('aria-selected', on);
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute('aria-controls')).hidden = !on;
    });
  };
  // Panels ship visible so the page works without this script.
  select(tabs.find((t) => t.getAttribute('aria-selected') === 'true') || tabs[0]);
  tabs.forEach((tab, i) => {
    tab.addEventListener('click', () => select(tab));
    tab.addEventListener('keydown', (event) => {
      const target = {
        ArrowRight: (i + 1) % tabs.length,
        ArrowLeft: (i - 1 + tabs.length) % tabs.length,
        Home: 0,
        End: tabs.length - 1,
      }[event.key];
      if (target === undefined) return;
      event.preventDefault();
      const next = tabs[target];
      select(next);
      next.focus();
    });
  });
});
