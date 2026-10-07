import DOMPurify from 'dompurify';
import { parseMarkdown } from './markdown.mjs';

const content = document.getElementById('content');
let revision = 0;
let mermaidLoading;

function loadMermaid() {
  return mermaidLoading ??= new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = 'mermaid.js';
    script.onload = () => resolve(window.mermaid);
    script.onerror = reject;
    document.head.append(script);
  });
}

function reportSize() {
  window.webkit?.messageHandlers.markdown?.postMessage({ height: Math.ceil(content.getBoundingClientRect().height) });
}
new ResizeObserver(reportSize).observe(content);
document.fonts.ready.then(reportSize);

window.renderMarkdown = async (source, dark) => {
  const rendering = ++revision;
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  document.documentElement.dataset.state = 'rendering';
  const parsed = parseMarkdown(source);
  // 回复中的 HTML 也属于不可信内容；清洗后才进入 WebView。
  content.innerHTML = DOMPurify.sanitize(parsed.html, {
    ADD_TAGS: ['eq', 'eqn'],
    FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form', 'base', 'meta', 'link'],
    FORBID_ATTR: ['srcset'],
  });
  for (const link of content.querySelectorAll('a[href]')) link.rel = 'noopener noreferrer';
  for (const image of content.querySelectorAll('img')) {
    image.referrerPolicy = 'no-referrer';
    image.addEventListener('load', reportSize, { once: true });
    image.addEventListener('error', () => { image.classList.add('unavailable'); reportSize(); }, { once: true });
  }
  for (const table of content.querySelectorAll('table')) {
    const wrapper = document.createElement('div');
    wrapper.className = 'table-scroll';
    wrapper.tabIndex = 0;
    table.replaceWith(wrapper);
    wrapper.append(table);
  }
  reportSize();
  if (parsed.diagrams.length) {
    const mermaid = await loadMermaid();
    if (rendering !== revision) return;
    mermaid.initialize({
      startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
      theme: dark ? 'dark' : 'default', fontFamily: '-apple-system, sans-serif',
    });
    for (const [index, diagram] of parsed.diagrams.entries()) {
      if (rendering !== revision) return;
      const target = content.querySelector(`[data-diagram="${index}"]`);
      if (!target) continue;
      try {
        const result = await mermaid.render(`diagram-${rendering}-${index}`, diagram);
        if (rendering !== revision) return;
        target.innerHTML = DOMPurify.sanitize(result.svg, {
          USE_PROFILES: { svg: true, svgFilters: true, html: true },
          ADD_TAGS: ['foreignobject'], ADD_ATTR: ['dominant-baseline'],
          HTML_INTEGRATION_POINTS: { foreignobject: true },
        });
      } catch {
        // 未闭合或错误的图表保留源代码，不能影响同一回复的其余内容。
        target.dataset.error = 'true';
      }
      reportSize();
    }
  }
  if (rendering !== revision) return;
  document.documentElement.dataset.state = 'ready';
  reportSize();
};

content.addEventListener('click', event => {
  const link = event.target.closest('a[href]');
  if (!link) return;
  const href = link.getAttribute('href');
  if (href.startsWith('#')) {
    event.preventDefault();
    let id;
    try { id = decodeURIComponent(href.slice(1)); } catch { return; }
    const target = document.getElementById(id);
    if (target) window.webkit?.messageHandlers.markdown?.postMessage({ anchor: target.getBoundingClientRect().top + window.scrollY });
  }
});
