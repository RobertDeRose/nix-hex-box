import ExecutionEnvironment from '@docusaurus/ExecutionEnvironment';

// Safari tints its toolbar from <meta name="theme-color"> and doesn't follow
// the page's own color changes, so keep one tag on the current page background.
function syncThemeColor(): void {
  const color = getComputedStyle(document.documentElement).getPropertyValue('--hb-glass').trim();
  if (!color) return;
  let meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');
  if (!meta) {
    meta = document.createElement('meta');
    meta.name = 'theme-color';
    document.head.append(meta);
  }
  meta.content = color;
}

if (ExecutionEnvironment.canUseDOM) {
  syncThemeColor();
  new MutationObserver(syncThemeColor).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ['data-theme'],
  });
}
