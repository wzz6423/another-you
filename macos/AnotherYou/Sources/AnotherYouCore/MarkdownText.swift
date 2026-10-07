import SwiftUI
import WebKit

struct MarkdownText: View {
    private let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 24
    @State private var failed = false

    init(_ source: String) { self.source = source }

    var body: some View {
        Group {
            if failed {
                Text(source).font(.system(size: 13)).textSelection(.enabled)
            } else {
                MarkdownWebView(source: source, dark: colorScheme == .dark, height: $height, failed: $failed)
                    .frame(height: height)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum MarkdownResources {
    static var indexURL: URL? { Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Markdown") }
}

@MainActor
private struct MarkdownWebView: NSViewRepresentable {
    let source: String
    let dark: Bool
    @Binding var height: CGFloat
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(height: $height, failed: $failed) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "markdown")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        if let url = MarkdownResources.indexURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            DispatchQueue.main.async { failed = true }
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(source: source, dark: dark)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "markdown")
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private var source = ""
        private var dark = false
        private var loaded = false
        private var rendered: String?
        private var renderedDark: Bool?
        private let height: Binding<CGFloat>
        private let failed: Binding<Bool>

        init(height: Binding<CGFloat>, failed: Binding<Bool>) {
            self.height = height
            self.failed = failed
        }

        func update(source: String, dark: Bool) {
            self.source = source
            self.dark = dark
            render()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            render()
        }

        private func render() {
            guard loaded, let webView, rendered != source || renderedDark != dark else { return }
            rendered = source
            renderedDark = dark
            // 以参数传入原文，避免 Markdown 或代码中的引号、HTML 被当成脚本执行。
            webView.callAsyncJavaScript("await window.renderMarkdown(source, dark)", arguments: ["source": source, "dark": dark], in: nil, in: .page) { [weak self] result in
                if case .failure = result, let self, self.webView != nil { self.failed.wrappedValue = true }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any] else { return }
            if let measured = value["height"] as? Double, measured.isFinite, measured >= 0 {
                let next = CGFloat(max(1, ceil(measured)))
                if abs(height.wrappedValue - next) > 0.5 { height.wrappedValue = next }
            }
            if let anchor = value["anchor"] as? Double, anchor.isFinite, anchor >= 0, let webView {
                webView.scrollToVisible(NSRect(x: 0, y: anchor, width: max(1, webView.bounds.width), height: 24))
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if navigationAction.navigationType == .linkActivated {
                if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            } else {
                decisionHandler(url.deletingLastPathComponent() == MarkdownResources.indexURL?.deletingLastPathComponent() ? .allow : .cancel)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed.wrappedValue = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed.wrappedValue = true }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed.wrappedValue = true }
    }
}
