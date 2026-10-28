import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "chopshop")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")   // transparente: se ve el fondo de vidrio de SwiftUI
        wv.isInspectable = true
        wv.navigationDelegate = context.coordinator
        model.web = wv
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path) {
            wv.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        } else if let root = model.engineRoot {
            let dir = URL(fileURLWithPath: root + "/../mac/Resources/web")
            wv.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        }
        return wv
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
            // Solo el index local; todo lo demás se abre fuera.
            if action.navigationType == .linkActivated, let u = action.request.url { NSWorkspace.shared.open(u); return .cancel }
            return .allow
        }
    }
}
