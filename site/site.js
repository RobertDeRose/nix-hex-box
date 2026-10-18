// Hero load sequence: each terminal line prints in turn, and the matching
// pipeline stage lands as the build reaches it.
(() => {
  const root = document.documentElement;
  const lines = document.querySelectorAll('.term .ln');
  lines.forEach((line, i) => {
    line.style.setProperty('--i', i);
    const box = line.dataset.box && document.querySelector(`.box[data-box="${line.dataset.box}"]`);
    if (box) box.style.setProperty('--i', i);
  });
  root.classList.add('js');
  requestAnimationFrame(() => root.classList.add('play'));
})();

// Theme toggle: follows the system until clicked, then remembers the choice.
(() => {
  const root = document.documentElement;
  const button = document.querySelector('.theme-toggle');
  const system = matchMedia('(prefers-color-scheme: dark)');
  const current = () => root.dataset.theme || (system.matches ? 'dark' : 'light');
  const show = () => {
    const theme = current();
    button.dataset.current = theme;
    button.setAttribute('aria-label', `Switch to ${theme === 'dark' ? 'light' : 'dark'} theme`);
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

// GitHub star count beside the header link, shown only once it is worth showing.
(() => {
  const MIN_STARS = 100;
  const repo = 'RobertDeRose/nix-hex-box';
  const badge = document.querySelector('.gh-stars');
  const show = (count) => {
    if (!(count >= MIN_STARS)) return;
    badge.querySelector('.gh-count').textContent = new Intl.NumberFormat('en', { notation: 'compact' }).format(count);
    badge.hidden = false;
  };
  // Cache for the session: the unauthenticated API allows 60 requests an hour per visitor.
  try {
    const cached = sessionStorage.getItem('stars');
    if (cached !== null) return show(Number(cached));
  } catch {}
  fetch(`https://api.github.com/repos/${repo}`)
    .then((response) => (response.ok ? response.json() : Promise.reject(response.status)))
    .then(({ stargazers_count: count }) => {
      try { sessionStorage.setItem('stars', count); } catch {}
      show(count);
    })
    .catch(() => {});
})();

// Copy buttons copy the command next to them.
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

// Tab sets (install routes), each with arrow-key navigation.
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
