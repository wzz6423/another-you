import SwiftUI
import WebKit
import XCTest
@testable import AnotherYouCore

@MainActor
final class MarkdownRenderingTests: XCTestCase {
    private func renderer(width: CGFloat = 640) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 480), configuration: configuration)
        let url = try XCTUnwrap(MarkdownResources.indexURL)
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        for _ in 0..<500 {
            if (try? await view.evaluateJavaScript("typeof window.renderMarkdown === 'function'")) as? Bool == true { return view }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("离线 Markdown 渲染资源未能加载")
        throw CocoaError(.fileReadUnknown)
    }

    private func render(_ source: String, in view: WKWebView, dark: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            view.callAsyncJavaScript("await window.renderMarkdown(source, dark); await document.fonts.ready; return true",
                arguments: ["source": source, "dark": dark], in: nil, in: .page) { result in
                    continuation.resume(with: result.map { _ in () })
                }
        }
    }

    private func snapshot(_ script: String, in view: WKWebView) async throws -> [String: Any] {
        let result = try await view.evaluateJavaScript("(() => { \(script) })()")
        return try XCTUnwrap(result as? [String: Any])
    }

    func testCommonMarkAndGFMRenderAllBlockAndInlineFamilies() async throws {
        let view = try await renderer()
        defer { view.stopLoading() }
        let source = """
        # 一级
        ## 二级
        ### 三级
        #### 四级
        ##### 五级
        ###### 六级

        Setext
        ======

        中文 **粗体**、*斜体*、~~删除~~、`行内代码`。
        下一行\u{20}\u{20}
        硬换行

        ---

        > 引用
        >
        > 3. 有序项
        >    - 子项

        - [x] 已完成
        - [ ] 待办

        | 左 | 中 | 右 |
        | :-- | :-: | --: |
        | **粗体** | `代码` | 空值 |
        | 空 | | |

        [直接](https://example.com/docs "标题") [引用][ref]
        <https://example.org> www.example.net user@example.com

        [ref]: https://example.com/reference

        <details><summary>展开</summary><kbd>⌘</kbd><sup>2</sup><sub>1</sub><mark>标记</mark></details>
        """
        try await render(source, in: view)
        let result = try await snapshot("""
            const c = document.getElementById('content');
            return { headings: [...c.querySelectorAll('h1,h2,h3,h4,h5,h6')].map(e => e.tagName),
                strong: c.querySelector('strong').textContent, strike: c.querySelector('s').textContent,
                nested: !!c.querySelector('blockquote ol[start="3"] ul li'),
                checked: c.querySelectorAll('input[type=checkbox]:checked').length,
                disabled: [...c.querySelectorAll('input')].every(e => e.disabled),
                cells: c.querySelectorAll('td').length,
                align: [...c.querySelectorAll('th')].map(e => e.style.textAlign),
                rules: c.querySelectorAll('hr').length, breaks: c.querySelectorAll('br').length,
                email: !!c.querySelector('a[href="mailto:user@example.com"]'),
                reference: !!c.querySelector('a[href="https://example.com/reference"]'),
                details: !!c.querySelector('details summary'), height: c.scrollHeight };
            """, in: view)
        XCTAssertEqual(result["headings"] as? [String], ["H1", "H2", "H3", "H4", "H5", "H6", "H1"])
        XCTAssertEqual(result["strong"] as? String, "粗体")
        XCTAssertEqual(result["strike"] as? String, "删除")
        for key in ["nested", "disabled", "email", "reference", "details"] { XCTAssertEqual(result[key] as? Bool, true, key) }
        XCTAssertEqual(result["checked"] as? Int, 1)
        XCTAssertEqual(result["cells"] as? Int, 6)
        XCTAssertEqual(result["align"] as? [String], ["left", "center", "right"])
        XCTAssertEqual(result["rules"] as? Int, 1)
        XCTAssertGreaterThan(result["breaks"] as? Int ?? 0, 1)
        XCTAssertGreaterThan(result["height"] as? Int ?? 0, 400)
    }

    func testMathFootnotesImagesAndDarkAppearanceUseBundledResources() async throws {
        let view = try await renderer()
        defer { view.stopLoading() }
        let source = #"""
        公式 $E=mc^2$ 与 \(\frac{a}{b}\)。

        $$
        \begin{pmatrix}1 & 2 \\ 3 & 4\end{pmatrix}
        $$

        \[\sum_{n=1}^{\infty}\frac{1}{n^2}=\frac{\pi^2}{6}\]

        ```math
        \int_0^1 x^2 dx = \frac{1}{3}
        ```

        正文[^note]

        [^note]: 脚注 **内容**

            第二段

        ![像素](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=)
        """#
        try await render(source, in: view, dark: true)
        let result = try await snapshot("""
            const c = document.getElementById('content');
            return { formulas: c.querySelectorAll('.katex').length, mathml: c.querySelectorAll('math').length,
                display: c.querySelectorAll('.katex-display').length, footnote: c.querySelector('.footnotes').textContent,
                reference: c.querySelector('.footnote-ref a').getAttribute('href'), back: !!c.querySelector('.footnote-backref'),
                image: c.querySelector('img').alt, theme: document.documentElement.dataset.theme,
                font: document.fonts.check('12px KaTeX_Main'), ready: document.documentElement.dataset.state };
            """, in: view)
        XCTAssertEqual(result["formulas"] as? Int, 5)
        XCTAssertEqual(result["mathml"] as? Int, 5)
        XCTAssertEqual(result["display"] as? Int, 3)
        XCTAssertTrue((result["footnote"] as? String)?.contains("第二段") == true)
        XCTAssertEqual(result["reference"] as? String, "#fn1")
        XCTAssertEqual(result["back"] as? Bool, true)
        XCTAssertEqual(result["image"] as? String, "像素")
        XCTAssertEqual(result["theme"] as? String, "dark")
        XCTAssertEqual(result["font"] as? Bool, true)
        XCTAssertEqual(result["ready"] as? String, "ready")
    }

    func testMermaidRendersDifferentDiagramFamiliesAndKeepsMalformedSource() async throws {
        let view = try await renderer()
        defer { view.stopLoading() }
        for (source, labels) in [
            ("flowchart TD\nA[开始] --> B[完成]", ["开始", "完成"]),
            ("sequenceDiagram\nAlice->>Bob: Hello", ["Alice", "Bob", "Hello"]),
            ("classDiagram\nAnimal <|-- Duck", ["Animal", "Duck"]),
            ("stateDiagram-v2\n[*] --> Ready", ["Ready"]),
            ("erDiagram\nUSER ||--o{ MESSAGE : sends", ["USER", "MESSAGE", "sends"]),
            ("pie title Tasks\n\"Done\" : 8\n\"Todo\" : 2", ["Done", "Todo"])
        ] {
            try await render("```mermaid\n\(source)\n```", in: view)
            let result = try await snapshot("""
                return { svg: document.querySelectorAll('.diagram svg').length,
                    errors: document.querySelectorAll('[data-error]').length,
                    labels: [...document.querySelectorAll('.diagram text, .diagram foreignObject')]
                        .filter(e => e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().height > 0)
                        .map(e => e.textContent).join(' ') };
                """, in: view)
            XCTAssertEqual(result["svg"] as? Int, 1, source)
            XCTAssertEqual(result["errors"] as? Int, 0, source)
            for label in labels { XCTAssertTrue((result["labels"] as? String)?.contains(label) == true, "\(source): \(label)") }
        }
        try await render("```mermaid\nnot a diagram\n```\n\n**后续内容**", in: view)
        let invalid = try await snapshot("return { source: document.querySelector('.diagram code').textContent, following: document.querySelector('strong').textContent, error: document.querySelector('.diagram').dataset.error };", in: view)
        XCTAssertEqual(invalid["source"] as? String, "not a diagram\n")
        XCTAssertEqual(invalid["following"] as? String, "后续内容")
        XCTAssertEqual(invalid["error"] as? String, "true")
    }

    func testMermaidHTMLLabelsRemainVisibleWithoutExecutingInjectedHTML() async throws {
        let view = try await renderer()
        defer { view.stopLoading() }
        try await render(#"""
        ```mermaid
        %%{init: {"securityLevel": "loose"}}%%
        flowchart LR
        A["正常标签<b>粗体</b><img src='missing' onerror='window.compromised=true'>"] --> B["完成"]
        click B "javascript:window.compromised=true"
        ```
        """#, in: view)
        let result = try await snapshot("""
            const diagram = document.querySelector('.diagram');
            return { compromised: window.compromised === true, error: diagram.dataset.error === 'true',
                dangerous: diagram.querySelectorAll('script,[onerror]').length
                    + [...diagram.querySelectorAll('a')].filter(e =>
                        (e.getAttribute('href') || e.getAttribute('xlink:href') || '').startsWith('javascript:')).length,
                labels: [...diagram.querySelectorAll('text, foreignObject')]
                    .filter(e => e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().height > 0)
                    .map(e => e.textContent).join(' ') };
            """, in: view)
        XCTAssertEqual(result["compromised"] as? Bool, false)
        XCTAssertEqual(result["error"] as? Bool, false)
        XCTAssertEqual(result["dangerous"] as? Int, 0)
        for label in ["正常标签", "完成"] { XCTAssertTrue((result["labels"] as? String)?.contains(label) == true, label) }
    }

    func testUnsafeHTMLCannotRunOrChangeTheDocumentAndCodeStaysLiteral() async throws {
        let view = try await renderer()
        defer { view.stopLoading() }
        let source = #"""
        <script>window.compromised = true</script>
        <img src="missing" onerror="window.compromised = true">
        <iframe srcdoc="<script>window.compromised=true</script>"></iframe>
        <a href="javascript:window.compromised=true">不安全链接</a>
        <style>body { display:none }</style>

        ```unknown-language
          let text = "**不要解析**";
        </script><script>window.compromised=true</script>
        $literal$
        ```

        **安全正文**
        """#
        try await render(source, in: view)
        let result = try await snapshot("""
            const c = document.getElementById('content');
            return { compromised: window.compromised === true,
                dangerous: c.querySelectorAll('script,iframe,style,[onerror],a[href^="javascript:"]').length,
                code: c.querySelector('pre code').textContent, strong: c.querySelector('strong').textContent };
            """, in: view)
        XCTAssertEqual(result["compromised"] as? Bool, false)
        XCTAssertEqual(result["dangerous"] as? Int, 0)
        XCTAssertTrue((result["code"] as? String)?.contains("**不要解析**") == true)
        XCTAssertTrue((result["code"] as? String)?.contains("$literal$") == true)
        XCTAssertEqual(result["strong"] as? String, "安全正文")
    }

    func testWideCodeAndTablesScrollInsideNarrowMessageAndUnclosedTextSurvives() async throws {
        let view = try await renderer(width: 280)
        defer { view.stopLoading() }
        let long = String(repeating: "abcdefgh", count: 30)
        try await render("```swift\nlet value = \"\(long)\"\n```\n\n| 标题 |\n| --- |\n| \(long) |\n\n尚未 **闭合", in: view)
        let result = try await snapshot("""
            const pre = document.querySelector('pre'), table = document.querySelector('.table-scroll');
            return { codeScrolls: pre.scrollWidth > pre.clientWidth, tableScrolls: table.scrollWidth > table.clientWidth,
                documentFits: document.documentElement.scrollWidth <= 281, text: document.getElementById('content').textContent,
                highlight: document.querySelectorAll('.hljs-keyword').length };
            """, in: view)
        for key in ["codeScrolls", "tableScrolls", "documentFits"] { XCTAssertEqual(result[key] as? Bool, true, key) }
        XCTAssertTrue((result["text"] as? String)?.contains("尚未 **闭合") == true)
        XCTAssertGreaterThan(result["highlight"] as? Int ?? 0, 0)
    }
}
