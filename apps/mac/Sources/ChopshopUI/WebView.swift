import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "chopshop")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { wv.isInspectable = true }
        wv.navigationDelegate = context.coordinator
        model.web = wv
        if let index = Self.webIndex() {
            wv.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        } else {
            wv.loadHTMLString("<body style='font:14px -apple-system;color:#ddd;padding:2em'>No encuentro la UI web (Resources/web). Reconstruye la app con apps/mac/build.sh.</body>", baseURL: nil)
        }
        return wv
    }

    static func webIndex() -> URL? {
        var dirs: [URL] = []
        if let d = Bundle.main.resourceURL?.appendingPathComponent("web") { dirs.append(d) }
        if let e = ProcessInfo.processInfo.environment["CHOPSHOP_WEB_DIR"], !e.isEmpty { dirs.append(URL(fileURLWithPath: AppConfig.expand(e))) }
        dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/web"))
        return dirs.map { $0.appendingPathComponent("index.html") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let model: AppModel
        init(_ m: AppModel) { model = m }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            Task { @MainActor in self.model.handle(body) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let u = action.request.url { NSWorkspace.shared.open(u); return .cancel }
            return .allow
        }
    }
}
