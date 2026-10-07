import MarkdownIt from 'markdown-it';
import footnote from 'markdown-it-footnote';
import taskLists from 'markdown-it-task-lists';
import texmath from 'markdown-it-texmath';
import katex from 'katex';
import highlight from 'highlight.js';

const mathOptions = { throwOnError: false, trust: false, strict: 'ignore', maxExpand: 1000 };
const markdown = new MarkdownIt({
  html: true, linkify: true, breaks: true,
  highlight(code, language) {
    if (!language || !highlight.getLanguage(language)) return '';
    return highlight.highlight(code, { language, ignoreIllegals: true }).value;
  },
}).use(footnote).use(taskLists).use(texmath, {
  engine: katex, delimiters: ['dollars', 'brackets', 'beg_end'], katexOptions: mathOptions,
});
markdown.linkify.set({ fuzzyLink: true });

const fence = markdown.renderer.rules.fence;
markdown.renderer.rules.fence = (tokens, index, options, environment, renderer) => {
  const token = tokens[index];
  const language = token.info.trim().split(/\s+/)[0].toLowerCase();
  if (language === 'mermaid') {
    const id = environment.diagrams.push(token.content) - 1;
    return `<div class="diagram" data-diagram="${id}"><pre><code>${markdown.utils.escapeHtml(token.content)}</code></pre></div>\n`;
  }
  if (language === 'math' || language === 'latex') {
    return `<div class="math-block">${katex.renderToString(token.content, { ...mathOptions, displayMode: true })}</div>\n`;
  }
  return fence(tokens, index, options, environment, renderer);
};

export function parseMarkdown(source) {
  const environment = { diagrams: [] };
  return { html: markdown.render(source, environment), diagrams: environment.diagrams };
}
