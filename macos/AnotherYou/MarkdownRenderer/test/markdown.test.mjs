import assert from 'node:assert/strict';
import test from 'node:test';
import { parseMarkdown } from '../markdown.mjs';

const examples = [
  ['六级 ATX 标题', '# 一\n## 二\n### 三\n#### 四\n##### 五\n###### 六', /<h1>一<\/h1>[\s\S]*<h6>六<\/h6>/],
  ['Setext 标题与分隔线', '一级\n===\n\n二级\n---\n\n***', /<h1>一级<\/h1>[\s\S]*<h2>二级<\/h2>[\s\S]*<hr>/],
  ['中文嵌套强调和删除线', '**粗体 *斜体*** 与 ~~删除~~', /<strong>粗体 <em>斜体<\/em><\/strong> 与 <s>删除<\/s>/],
  ['引用中的嵌套列表', '> 3. 第一项\n>    - 嵌套\n>\n>      续段', /<blockquote>[\s\S]*<ol start="3">[\s\S]*<ul>[\s\S]*续段/],
  ['任务列表与子任务', '- [x] 完成\n- [ ] 未完成\n  - [X] 子任务', /checked=""[\s\S]*未完成[\s\S]*checked=""/],
  ['表格、对齐与转义分隔符', '| 左 | 中 | 右 |\n| :-- | :-: | --: |\n| a\\|b | **粗** | `c` |', /text-align:left[\s\S]*text-align:center[\s\S]*text-align:right[\s\S]*a\|b/],
  ['直接和引用链接', '[直接](https://example.com "标题") [引用][id]\n\n[id]: https://example.org', /title="标题"[\s\S]*href="https:\/\/example.org"/],
  ['自动链接和邮箱', '<https://example.com> www.example.org test@example.com', /href="https:\/\/example.com"[\s\S]*href="http:\/\/www.example.org"[\s\S]*href="mailto:test@example.com"/],
  ['图片与引用图片', '![替代文本](https://example.com/a.png "图片标题")\n\n![引用][pic]\n\n[pic]: https://example.com/b.png', /<img[^>]*alt="替代文本"[^>]*title="图片标题"[\s\S]*src="https:\/\/example.com\/b.png"/],
  ['行内代码和反引号', '`` `字面 **代码**` ``', /<code>`字面 \*\*代码\*\*`<\/code>/],
  ['缩进代码和波浪线围栏', '    **缩进代码**\n\n~~~text\n**围栏代码**\n~~~', /<pre><code>\*\*缩进代码\*\*[\s\S]*\*\*围栏代码\*\*/],
  ['转义、字符实体和硬换行', '\\*原样\\* &amp; &lt;\n第一行  \n第二行', /\*原样\* &amp; &lt;<br>[\s\S]*第一行<br>[\s\S]*第二行/],
  ['安全 HTML 排版', '<details><summary>更多</summary><kbd>⌘</kbd><sup>2</sup></details>', /<details><summary>更多<\/summary><kbd>⌘<\/kbd><sup>2<\/sup><\/details>/],
  ['脚注引用及多段脚注', '正文[^note]\n\n[^note]: 注释 **粗体**\n\n    第二段', /footnote-ref[\s\S]*footnotes[\s\S]*<strong>粗体<\/strong>[\s\S]*第二段/],
];
for (const [name, source, expected] of examples) test(name, () => assert.match(parseMarkdown(source).html, expected));

test('公式支持美元、括号、环境及 math 围栏，并保留代码中的字面公式', () => {
  for (const source of [String.raw`$x^2$`, String.raw`\(x^2\)`, '$$\nx^2\n$$', String.raw`\[x^2\]`, String.raw`\begin{equation}x^2\end{equation}`, '```math\nx^2\n```']) {
    const { html } = parseMarkdown(source);
    assert.match(html, /class="katex/);
    assert.match(html, /<math/);
  }
  assert.match(parseMarkdown('`$x$`\n\n```text\n$x$\n```').html, /<code>\$x\$<\/code>/);
  assert.doesNotMatch(parseMarkdown('`$x$`\n\n```text\n$x$\n```').html, /class="katex/);
});

test('Mermaid 保留独立原文，普通代码仍进行语言高亮', () => {
  const result = parseMarkdown('```mermaid\ngraph TD\nA-->B\n```\n\n```swift\nlet count = 1\n```');
  assert.deepEqual(result.diagrams, ['graph TD\nA-->B\n']);
  assert.match(result.html, /data-diagram="0"/);
  assert.match(result.html, /hljs-keyword/);
});

test('未闭合格式、未知语言及错误公式不会丢掉后续正文', () => {
  for (const source of ['尚未 **闭合', '```unknown\n**原样**\n```\n\n后续正文', '$\\unknowncommand{x}$\n\n后续正文']) {
    const { html } = parseMarkdown(source);
    assert.ok(html.includes(source.includes('后续正文') ? '后续正文' : '尚未 **闭合'));
  }
  assert.equal(parseMarkdown('').html, '');
});
